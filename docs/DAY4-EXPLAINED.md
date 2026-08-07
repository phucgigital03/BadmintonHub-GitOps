# Day 4 giải thích cho người mới — đưa hệ thống lên EKS và mở một URL công khai

> Đọc kèm: [`DAY2-EXPLAINED.md`](DAY2-EXPLAINED.md) (Helm + K8s cơ bản) · [`ARCHITECTURE.md`](ARCHITECTURE.md) (bức tranh hạ tầng) · [`MANUAL-SETUP.md`](MANUAL-SETUP.md) (thao tác tay + verify Console)
>
> Tài liệu này có 3 phần: **§1 khái niệm** (đọc trước) · **§2 runbook** (bạn gõ tay từng lệnh) · **§3 tự kiểm tra**.

---

## §0 — Day 4 là gì, và KHÔNG phải gì

Day 2 đã chứng minh chart + values + wiring đúng: 9/9 service Ready trên **kind**, e2e đặt sân khép vòng qua Kafka. Nhưng kind là máy bạn — không ALB, không ECR, không EBS.

Day 4 trả lời **đúng một câu**: *"đưa nguyên bộ đó lên EKS và cho người lạ vào bằng một URL http được không?"*

| Day 4 CÓ | Day 4 KHÔNG có |
|---|---|
| EKS thật · ECR thật · ALB thật · EBS thật | ArgoCD (Day 6) — hôm nay `helm install` **bằng tay** |
| namespace `staging` | namespace `prod` (Day 6) |
| http trên **DNS thô của ALB** | domain + HTTPS (Day 8) |
| Secret nạp bằng script đọc SSM | External Secrets Operator (Day 6) |

**Vì sao cố tình làm tay?** Vì Day 6 sẽ giao chính những lệnh này cho ArgoCD. Khi ArgoCD báo đỏ, người đã từng gõ tay biết đi soi chỗ nào; người chưa từng thì chỉ biết nhìn dashboard.

---

## §1 — Bốn khái niệm mới (đây là phần đáng đọc kỹ nhất)

### 1.1 Ingress không phải load balancer. Nó là *tờ đơn đặt hàng*.

Đây là hiểu lầm số một của người mới. Object `Ingress` **tự nó không làm gì cả** — nó chỉ là một mẩu YAML nằm trong etcd nói rằng *"tôi muốn `/api` đi vào Service `api-gateway`"*.

Thứ biến tờ đơn đó thành hạ tầng thật là một **pod đang chạy trong cụm**: `aws-load-balancer-controller` (cài ở Day 3, nằm ở namespace `kube-system`). Nó:

1. watch mọi object Ingress có `ingressClassName: alb`,
2. gọi **API của AWS** để tạo ALB, listener, target group,
3. ghi ngược DNS của ALB vào `status.loadBalancer.ingress[0].hostname` của chính object Ingress.

```
Bạn: kubectl apply Ingress ──► etcd ──► controller đọc ──► gọi AWS API ──► ALB ra đời
                                                                              │
                        kubectl get ingress  ◄── controller ghi DNS ngược lại ┘
```

**Hệ quả thực dụng — nhớ câu này**: `kubectl get ingress` mà cột `ADDRESS` **rỗng** thì vấn đề gần như **không bao giờ** nằm ở file Ingress của bạn. Nó nằm ở controller: controller chết? thiếu quyền IAM? không tìm được subnet? Đi đọc log controller, đừng ngồi sửa YAML.

```bash
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=50
```

### 1.2 `target-type: ip` — ALB bắn thẳng vào pod

Có 2 kiểu ALB nói chuyện với K8s:

| Kiểu | Đường đi | Ghi chú |
|---|---|---|
| `instance` | ALB → NodePort trên EC2 → kube-proxy → pod | thêm 1 hop, cần NodePort |
| **`ip`** ← ta dùng | ALB → **thẳng IP của pod** | pod có IP thật trong VPC nhờ **VPC CNI** |

Trên EKS, mỗi pod nhận một IP **thật của VPC** (không phải mạng overlay như nhiều cụm khác), nên ALB — vốn là dịch vụ của VPC — gọi thẳng vào được.

Điểm quan trọng để debug sau này: **controller chỉ đăng ký pod đã `Ready`** vào target group. Nên `readinessProbe` của bạn không chỉ ảnh hưởng Service nội bộ, nó còn quyết định pod có được nhận traffic từ Internet hay không.

### 1.3 Target group có health-check RIÊNG — và mặc định của nó sai với gateway

Đây là **cái bẫy đắt nhất của Day 4**. Bạn đã có 3 probe của K8s (startup/liveness/readiness). ALB có thêm **cái thứ tư**, hoàn toàn độc lập, chạy từ phía AWS:

```
ALB ──probe mỗi 15s──► pod:3000/     ← mặc định là "/" và chờ mã 200
```

`frontend` (nginx) trả 200 ở `/` → qua. Nhưng **Spring Cloud Gateway không có route cho `/`** → trả **404** → ALB kết luận "target hỏng" → gỡ khỏi vòng quay → **`/api` trả 502**.

Triệu chứng đánh lừa hoàn hảo:

```
kubectl get pods         → 9/9 Running, READY 1/1, RESTARTS 0   ✅ xanh hết
curl http://$ALB/api/... → 502                                   ❌
```

Vì `kubectl` xanh nên bạn sẽ đi soi Ingress, soi Service, soi gateway route — trong khi lỗi nằm ở một target group trên Console AWS mà `kubectl` **không hề nhìn thấy**.

Cách xử ở repo này (đã làm sẵn) — khai đè trên chính Service, controller ưu tiên annotation ở Service hơn ở Ingress:

```yaml
# values/api-gateway-staging.yaml
service:
  annotations:
    alb.ingress.kubernetes.io/healthcheck-path: /actuator/info
    alb.ingress.kubernetes.io/success-codes: "200"
```

**Vì sao `/actuator/info` chứ không `/actuator/health`?** Vì `/actuator/health` là *composite* — nó gộp trạng thái db + redis + mongo + Eureka. Readiness probe của K8s đã dùng cái đó rồi, và pod chưa Ready thì **không được đăng ký** vào target group. Nếu cho ALB dùng composite nữa thì một nhịp Redis nhấp nháy bị phạt **hai lần** (rút khỏi Endpoints **và** ALB đánh unhealthy). `/actuator/info` không chạm datastore nào.

### 1.4 ECR + `linux/amd64` — lỗi im lặng nhất của cả lộ trình

`docker login` vào ECR không dùng mật khẩu cố định. `aws ecr get-login-password` **sinh ra một token sống 12 giờ** từ credential AWS của bạn:

```bash
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin $ECR
#         └─ sinh token 12h ─┘                         └─ user LUÔN là "AWS", không phải tên bạn ─┘
```

Nhưng cái bẫy thật là **kiến trúc CPU**:

| Nơi | Kiến trúc |
|---|---|
| MacBook của bạn (Apple Silicon) | **arm64** |
| Node EKS `t3.xlarge` | **amd64** |

`docker build` mặc định build cho máy đang chạy → ra image **arm64** → node amd64 không chạy nổi → pod `CrashLoopBackOff` với `exec format error`, **và log của app không hề nhắc một chữ nào về kiến trúc**. Bạn sẽ đi soi env, soi Secret, soi datastore.

→ Mọi lệnh build-để-đẩy-ECR **bắt buộc** `docker buildx build --platform linux/amd64`, và verify **trước** khi đi tiếp (§2 bước B3).

### 1.5 Bonus — `envFrom` KHÔNG tự restart pod khi ConfigMap đổi

Sẽ dùng đến ở bước C6. Chart này bơm env vào pod bằng `envFrom.configMapRef`. Container **chỉ đọc ConfigMap đúng một lần lúc khởi động**. Sửa ConfigMap sau đó:

- `helm upgrade` → ✅ thành công
- ArgoCD (Day 6) → ✅ Synced / Healthy
- pod → **vẫn chạy giá trị CŨ**, im lặng tuyệt đối

→ Sửa `app-config` trên cụm đang sống thì **luôn** kèm `kubectl -n staging rollout restart deploy`.

---

## §2 — Runbook: bạn gõ tay từng lệnh

> Quy ước mỗi khối: **lệnh · làm gì · output đúng · sai thì sao**.
> **Chạy từng bước, xem output rồi mới đi tiếp.** Chạy một mạch thì lỗi ở bước 1 sẽ hiện ra ở bước 5 dưới một hình dạng chẳng liên quan gì.

### Phần B — ở repo app `../badmintonHub`

#### B1 · 🚩 `WebSocketConfig` — ĐÃ KIỂM, ĐÃ CÓ KẾT LUẬN

```bash
grep -rn "setAllowedOrigin" chat-service/src/main/java/
# → WebSocketConfig.java:61: registry.addEndpoint("/ws").setAllowedOrigins(frontendUrl);
```

**Kết quả**: rơi vào **nhánh xấu**. `setAllowedOrigins` so khớp chuỗi **CHÍNH XÁC**, không nhận wildcard. Mà **ALB DNS đổi sau mỗi `terraform apply`** ⇒ nguyên trạng thì mỗi buổi demo phải sửa ConfigMap + `rollout restart` (bước C6) — đúng một trong 4 việc tay bị cấm ở [`ephemeral-cost.md`](../.claude/rules/ephemeral-cost.md).

**Đã xử — nhưng cần ĐỦ HAI NỬA, ở HAI repo khác nhau.** Đây là chỗ dễ làm hụt nhất của cả Day 4.

**Nửa 1 — repo app** (`chat-service/.../config/WebSocketConfig.java`):

```java
@Value("${app.frontend-url:*}")                                        // ← default là "*"
private String frontendUrl;
...
registry.addEndpoint("/ws").setAllowedOriginPatterns(frontendUrl.split(","));
// application.yml:48   frontend-url: ${FRONTEND_URL:*}
```

Vì sao **không** dùng `setAllowedOrigins("*")`: Spring **ném exception lúc khởi động** nếu đưa `"*"` vào `setAllowedOrigins` khi `allowCredentials` đang bật. `setAllowedOriginPatterns` là API sinh ra đúng cho origin động (Spring ≥ 5.3).

**Nửa 2 — repo này** (`values/chat-service-{staging,prod}.yaml`):

```yaml
env:
  FRONTEND_URL: "*"
```

🔴 **Vì sao nửa 2 là BẮT BUỘC, dù image đã default `"*"` rồi.** Đọc kỹ chuỗi này — nó là bài học kiến trúc, không phải mẹo vặt:

1. Image mặc định `*` ở **cả hai tầng** (`@Value` và `application.yml`). Không ai đặt `FRONTEND_URL` ⇒ chat chạy tốt.
2. Nhưng `charts/platform/templates/configmap.yaml` phát `FRONTEND_URL` cho **MỌI service, vô điều kiện** — vì `user-service` cần nó để dựng link email verify/reset.
3. Env tường minh (`envFrom`/`env`) **luôn thắng** default nằm trong image ⇒ pattern trở thành `http://REPLACE-WITH-ALB-DNS` ⇒ **mọi handshake 403**.

Tức là **chính ConfigMap của repo này vô hiệu hoá cái default đã đúng sẵn trong image**. Cả hai repo đều "làm đúng phần mình" mà hệ thống vẫn hỏng — kiểu lỗi chỉ lộ ra khi bạn nhìn hai repo cùng lúc.

**Vì sao ghi đè ở values chat-service chứ không sửa `frontendUrl` ở `platform-*.yaml`**: `user-service` dựng `${FRONTEND_URL}/verify-email?token=…` từ **cùng** biến đó → đặt `*` ở platform là link email thành `*/verify-email?token=…`, hỏng. Trong K8s `env` thắng `envFrom` khi trùng key ⇒ đó là chỗ đúng để tách một service ra khỏi giá trị dùng chung.

Về bảo mật: WS handshake nhận mọi origin, chấp nhận được vì auth của STOMP là **JWT trong header CONNECT**, không phải cookie — trang lạ không tự lấy được token. (Nếu auth bằng cookie thì đây là lỗ CSRF thật.)

💡 **Quà cho Day 8**: code dùng `.split(",")` nên biến này nhận **nhiều origin**. Hôm gắn domain chỉ cần đổi values thành `"https://staging.badminton.<domain>,https://www.badminton.<domain>"` là siết lại đúng origin thật — **không phải sửa code lần nữa**.

⚠️ **Patch chỉ có hiệu lực với image chat-service build SAU khi sửa.** Values còn trỏ SHA cũ = bẫy vẫn nguyên. → Làm patch **trước** B3 để push cả 9 image ở cùng một SHA.

**Triệu chứng nếu thiếu bất kỳ nửa nào**: chat chết (403 lúc handshake) trong khi **mọi luồng khác xanh** — pod Ready, Ingress có ADDRESS, `/api` trả 200. Log gateway không có gì bất thường.

🔴 Bẫy đi kèm: **Origin header không bao giờ có dấu `/` cuối**. `http://host` ≠ `http://host/`. Nhìn bằng mắt thấy giống nhau nhưng so khớp fail.

#### B2 · FE same-origin — sửa 2 file

```ts
// frontend/src/api/axiosClient.ts
const BASE_URL = import.meta.env.VITE_API_URL || '';        // '' → gọi /api/... TƯƠNG ĐỐI

// frontend/src/lib/stompClient.ts — derive từ window.location, KHÔNG từ VITE_API_URL
const WS_URL = import.meta.env.VITE_CHAT_WS_URL
  ?? `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`;
```

**Làm gì**: cho FE gọi đường dẫn tương đối thay vì URL tuyệt đối bake lúc build.

**Vì sao đáng sửa code** (đây là 1 trong 2 ngoại lệ "0 đổi code" của cả dự án): biến `VITE_*` bị **nướng cứng vào bundle lúc `npm run build`**. ALB DNS đổi mỗi `apply` ⇒ nếu bake URL thì **mỗi buổi demo** phải build lại image FE + push ECR + sửa ConfigMap + chờ sync ≈ 10 phút thao tác tay. Same-origin biến 10 phút đó thành **0**:

- 1 image FE cho **mọi** env (dev/staging/prod)
- CORS biến mất (cùng origin thì không có preflight)
- 🔑 hôm bật HTTPS ở Day 8, FE **tự** chuyển `ws://` → `wss://`. Bake cứng `ws://` = chat chết vì mixed content, và bạn phát hiện đúng lúc T-2.

**Giữ** bake `VITE_GOOGLE_CLIENT_ID` (public client ID, không phải secret). **Bỏ** `VITE_WS_URL` (nó trỏ `matchmaking-service:3004` — service không deploy).

#### B3 · Build + push 9 image lên ECR

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ECR=$ACCOUNT.dkr.ecr.ap-southeast-1.amazonaws.com
SHA=$(git rev-parse --short HEAD)
echo "ECR=$ECR  SHA=$SHA"
```
**Làm gì**: lấy account ID và git SHA. **Output đúng**: 12 chữ số + 7 ký tự hex.
Vì sao tag = SHA: tag **bất biến**, truy được về đúng commit. `latest` thì không ai biết cụm đang chạy code nào — và rollback thành đoán mò.

```bash
aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin $ECR
```
**Output đúng**: `Login Succeeded`. **Sai thì**: `no basic auth credentials` ở bước push ⇒ token hết hạn (12h) hoặc sai region.

```bash
for s in eureka-server api-gateway user-service court-service booking-service \
         payment-service escrow-service chat-service frontend; do
  echo "──── $s"
  docker buildx build --platform linux/amd64 -f $s/Dockerfile -t $ECR/$s:$SHA --push . || break
done
```
**Làm gì**: build 9 image cho **amd64** rồi đẩy thẳng lên ECR.
**Mất bao lâu**: lần đầu ~20-40' (build amd64 trên máy arm64 chạy qua emulation, chậm). Lần sau nhanh hơn nhờ cache.

```bash
docker buildx imagetools inspect $ECR/user-service:$SHA | grep -i platform
```
🔴 **Lệnh này tiết kiệm cả tiếng.** **Output đúng**: `Platform: linux/amd64`.
**Sai thì**: thấy `linux/arm64` → pod sẽ `CrashLoopBackOff` với `exec format error` và log app không nói gì về kiến trúc. Build lại, đừng đi tiếp.

```bash
aws ecr describe-images --repository-name user-service \
  --query 'imageDetails[].imageTags' --output text
```
**Output đúng**: thấy `$SHA`. 🔴 **Không được có `latest`**.

→ **Báo cho Claude: `ACCOUNT` + `SHA`** để điền vào 18 file values.

---

### Phần C — ở repo này, sau khi `terraform apply` dựng lại cụm

#### C0 · Kiểm tiền đề — 7 lệnh, đừng bỏ lệnh nào

```bash
aws eks update-kubeconfig --name badminton --region ap-southeast-1
```
**Làm gì**: ghi thông tin cụm vào `~/.kube/config` để `kubectl` biết nói chuyện với ai. Không có bước này thì `kubectl` vẫn trỏ vào **kind** của Day 2 — và bạn sẽ deploy nhầm chỗ mà không biết.
**Kiểm ngay**: `kubectl config current-context` phải chứa `badminton`, không phải `kind-...`.

```bash
kubectl get nodes
```
**Output đúng**: 2 node `Ready`, type `t3.xlarge`. **Sai thì**: 0 node ⇒ node group chưa lên (hoặc spot bị thu hồi).

```bash
kubectl get storageclass
```
**Output đúng**: có `gp3`. **Sai thì**: PVC sẽ kẹt `Pending` vĩnh viễn ⇒ 5 datastore không boot ⇒ 9 service không boot. (Values đã ghim `global.defaultStorageClass: gp3` nên **không** có `gp3` là hỏng ngay, không phải "im lặng dùng gp2".)

```bash
kubectl get ingressclass alb
```
**Output đúng**: có 1 dòng. **Sai thì**: Ingress của bạn sẽ nằm im mãi mãi — **không lỗi, không event, không ADDRESS** — vì không controller nào nhận nó.

```bash
kubectl -n kube-system get deploy aws-load-balancer-controller
```
**Output đúng**: `READY 1/1`. **Sai thì**: xem log; hay gặp nhất là IRSA thiếu quyền `elasticloadbalancing:*`.

```bash
aws ecr describe-repositories --query 'repositories[].repositoryName' --output text
```
**Output đúng**: đủ 9 tên. (ECR nằm ở bootstrap stack nên `destroy` không xoá — image bạn push hôm trước vẫn còn.)

```bash
aws ec2 describe-subnets --filters Name=tag:kubernetes.io/role/elb,Values=1 \
  --query 'Subnets[].SubnetId' --output text
```
🔴 **Lệnh hay bị bỏ qua nhất, hậu quả xuất hiện muộn nhất.** **Output đúng**: ít nhất 2 subnet ID.
**Sai thì (rỗng)**: Day 3 vẫn xanh, Ingress vẫn tạo được, nhưng **treo vô hạn không có ADDRESS** và `kubectl describe ingress` chỉ nói `couldn't auto-discover subnets`. Sửa = thêm tag ở Terraform (repo app), không phải sửa ở đây.

#### C1 · Hai namespace

```bash
kubectl create namespace staging
kubectl create namespace data-staging
```
**Vì sao tách 2 namespace**: app và datastore có vòng đời khác nhau. Teardown xoá app thoải mái nhưng PVC ở `data-staging` phải xoá **có chủ đích** (xem C8). Day 6 ArgoCD tự tạo bằng `CreateNamespace=true`; hôm nay làm tay.

#### C1b · Nạp 8 param vào SSM — làm MỘT LẦN, không phải mỗi rebuild

Param sống **ngoài cụm** nên `terraform destroy` không xoá. Nạp rồi thì các buổi sau bỏ qua bước này — đó chính là cơ chế giữ tiêu chí "rebuild 0 thao tác tay". Kiểm trước xem đã có chưa:

```bash
aws ssm get-parameters-by-path --path /badminton/staging/ --query 'Parameters[].Name' --output table --no-cli-pager
```

Nếu **rỗng**, chạy khối này:

```bash
REGION=ap-southeast-1; ENV=staging
put() { aws ssm put-parameter --region $REGION --type SecureString --overwrite \
          --name "/badminton/$ENV/$1" --value "$2" >/dev/null && echo "  ✔ $1"; }

put JWT_SECRET        "$(openssl rand -hex 64)"
put POSTGRES_USERNAME "postgres"
put POSTGRES_PASSWORD "$(openssl rand -hex 24)"
put RABBITMQ_PASS     "$(openssl rand -hex 24)"
put MONGODB_CHAT_URI  "mongodb://root:$(openssl rand -hex 24)@mongodb.data-$ENV.svc.cluster.local:27017/chat_db?authSource=admin"

put CLOUDINARY_CLOUD_NAME  '<cloud-name>'
put CLOUDINARY_API_KEY     '<api-key>'
put CLOUDINARY_API_SECRET  '<api-secret>'
```

🔴 **KHÔNG tạo `SENDGRID_API_KEY` / `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`.** SSM **từ chối giá trị rỗng**:

```
ValidationException: Value at 'value' failed to satisfy constraint:
Member must have length greater than or equal to 1
```

Và bạn **không cần** chúng: `eks-secret.sh` dùng `${VAR:-}` nên param không tồn tại vẫn sinh **key rỗng** trong Secret. Spring chỉ cần key **tồn tại** để resolve `${...}`; giá trị rỗng thì chấp nhận được. ⇒ Thực tế chỉ **8** param, không phải 11 như `MANUAL-SETUP.md` §3 liệt kê.

**Vì sao `openssl rand -hex` chứ không `-base64`**: hex chỉ có `0-9a-f`. Base64 sinh `+ / =` — mà mật khẩu Mongo nằm **nhúng trong URI**, nơi `/ : @ ? #` là ký tự cấu trúc và phải percent-encode. Hex né sạch cả một lớp bug, đổi lại chuỗi dài hơn (không ai gõ tay nó).

**Vì sao `CLOUDINARY_*` không bỏ qua được**: `platform-staging.yaml` set `SPRING_PROFILES_ACTIVE=prod` ⇒ `CloudinaryProdGuard` (`@Profile("prod")`) **chặn boot** `payment-service` + `chat-service` nếu thiếu ⇒ chỉ lên được 7/9 pod. Đây là by design, đừng "sửa" bằng cách bỏ profile.

**Vì sao dùng nháy đơn** quanh giá trị Cloudinary: API secret có `-`, `_`; nháy đơn chặn shell diễn giải.

#### C2 · Secret — TRƯỚC datastore

```bash
./scripts/eks-secret.sh staging
```
**Làm gì**: đọc param từ SSM `/badminton/staging/` → tạo `app-secrets` (ns `staging`, 11 key — 8 có giá trị + 3 rỗng) + `datastore-secrets` (ns `data-staging`, 4 key).

**Vì sao phải trước**: chart Bitnami trỏ `existingSecret: datastore-secrets`. Secret chưa có ⇒ Postgres/Mongo/RabbitMQ không boot ⇒ bạn sẽ đi soi chart Bitnami thay vì soi thứ tự.

**Vì sao mật khẩu phải đến từ SSM chứ không tự sinh**: đây là điểm mà mật khẩu **datastore dựng lên bằng** và mật khẩu **app kết nối bằng** phải là MỘT. Để Bitnami tự sinh random = app auth fail 100%, triệu chứng chỉ là `CrashLoopBackOff` không nói gì về nguyên nhân.

**Output đúng**: `✅ Xong.` + danh sách **tên key** (script cố tình **không in giá trị**).
**Sai thì**:
- `SSM ... RỖNG` → chưa nạp param → quay lại **C1b**.
- `thiếu ?authSource=admin` → sửa param `MONGODB_CHAT_URI` ở SSM. Root user của Bitnami Mongo nằm ở db `admin`, không phải `chat_db`.
- `AccessDenied` → user AWS của bạn thiếu `ssm:GetParametersByPath` hoặc `kms:Decrypt`.

Muốn gõ tay thay vì chạy script: mở `scripts/eks-secret.sh`, mọi lệnh nằm nguyên trong đó.

#### C3 · 5 datastore

```bash
helm dependency build infra/
helm upgrade --install infra infra/ -n data-staging \
  -f infra/values/infra-staging.yaml --wait --timeout 900s
```
**Làm gì**: cài umbrella chart 5 datastore Bitnami (version đã ghim).

**Vì sao `--wait`**: bắt Helm đứng chờ tới khi mọi pod Ready. Nếu để app boot lúc Postgres chưa sẵn sàng, app fail → restart → và **`RESTARTS` tăng chính là thứ đã làm ta chẩn đoán nhầm sang "máy yếu" ở Day 2**.

**Mất bao lâu**: 3–5 phút — chậm vì mỗi PVC phải tạo EBS volume thật rồi attach vào node.

**Output đúng**: `STATUS: deployed`. Kiểm thêm:
```bash
kubectl -n data-staging get pods    # 5 pod Running
kubectl -n data-staging get pvc     # 5 PVC Bound, tổng 26Gi
kubectl -n data-staging get pvc -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName
                                    # cột SC phải là gp3
```
**Sai thì**: PVC `Pending` → `kubectl describe pvc` xem lý do (thường là EBS CSI driver chưa chạy hoặc IRSA thiếu quyền `ec2:CreateVolume`).

#### C4 · platform = ConfigMap + Ingress

```bash
helm upgrade --install platform charts/platform -n staging \
  -f infra/values/platform-staging.yaml
```
**Làm gì**: tạo ConfigMap `app-config` (toàn bộ env non-secret) + **object Ingress**.

**Vì sao đứng trước 9 service**: (a) pod đọc ConfigMap lúc khởi động, phải có sẵn; (b) Ingress tạo ở đây thì AWS **bắt đầu provision ALB ngay**, chạy song song với lúc 9 JVM đang boot — 2 việc chậm chồng lên nhau thay vì nối tiếp.

**Output đúng**:
```bash
kubectl -n staging get configmap app-config
kubectl -n staging get ingress                 # ADDRESS lúc này còn RỖNG là BÌNH THƯỜNG
```

#### C5 · 9 service

```bash
helm upgrade --install eureka-server charts/service -n staging \
  -f values/eureka-server-staging.yaml --wait --timeout 900s
```
**Vì sao eureka đi riêng và đi trước**: 7 service Java đăng ký vào Eureka lúc boot. Eureka chưa có thì chúng vẫn boot được nhưng phải chờ retry — kéo dài thời gian Ready một cách vô ích.

```bash
for s in api-gateway user-service court-service booking-service \
         payment-service escrow-service chat-service frontend; do
  helm upgrade --install $s charts/service -n staging -f values/$s-staging.yaml
done
kubectl -n staging wait --for=condition=available deploy --all --timeout=900s
```
**Vì sao ở đây song song được, mà trên kind thì không**: kind chạy trên máy 8 GB / 8 vCPU, một JVM Spring lúc boot ăn gần trọn 1–2 vCPU trong ~2 phút → thả 4 cái cùng lúc là CPU vọt lên 1298% (trần 800%), không cái nào mở nổi cổng trong ngân sách startup probe. EKS có 2× `t3.xlarge` = 8 vCPU / 32 GB → thoải mái cho 8 JVM.

**Output đúng**: `deployment.apps/... condition met` ×9.
**Sai thì** — nhìn cột `RESTARTS` **trước tiên**:

| Dấu hiệu | Nghĩa |
|---|---|
| `RESTARTS` tăng đều ở nhiều pod | **vòng lặp restart** → tìm nguyên nhân (probe? OOM? thiếu env?), đừng nới timeout |
| `RESTARTS` = 0 mà vẫn chậm | mới thật sự là thiếu tài nguyên / đang boot |
| Nhiều pod restart **cùng lúc** | sự kiện tầng node, không phải lỗi từng service |

```bash
kubectl -n staging get pods
kubectl -n staging describe pod -l app=<svc> | grep -E 'Unhealthy|Killing|OOM|Failed'
kubectl -n staging logs deploy/<svc> --tail=100
```

Riêng `ErrImagePull` / `ImagePullBackOff` ⇒ sai ECR URL hoặc sai tag trong values, **hoặc** node thiếu quyền pull ECR.
`CrashLoopBackOff` + `exec format error` ⇒ image build sai kiến trúc (B3).

#### C5b · Chờ ALB

```bash
kubectl -n staging get ingress -w        # Ctrl-C khi ADDRESS hiện ra
```
**Mất bao lâu**: 2–3 phút. Đây là AWS provision hạ tầng thật, không phải K8s chậm.

**Sai thì (quá 5' vẫn rỗng)**:
```bash
kubectl -n staging describe ingress badminton | tail -20
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=50
```
| Thông báo | Nghi gốc |
|---|---|
| `couldn't auto-discover subnets` | thiếu tag `kubernetes.io/role/elb=1` (C0 lệnh cuối) |
| `AccessDenied` / `UnauthorizedOperation` | IRSA của controller thiếu quyền |
| không có event nào cả | Ingress không được controller nhận → sai `ingressClassName` |

```bash
ALB=$(kubectl -n staging get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "http://$ALB"

curl -s -o /dev/null -w 'fe: %{http_code}\n' http://$ALB/                  # 200

# 🔴 KHÔNG dùng /api/actuator/health để nghiệm thu — bản kế hoạch ghi thế là SAI.
# Ingress KHÔNG rewrite path: gateway nhận nguyên văn "/api/actuator/health", mà actuator của
# chính nó nằm ở "/actuator/health" (không tiền tố /api) → gateway trả 404. Đo thật ở Day 4.
# Dùng một route NGHIỆP VỤ thật thì mới chứng minh được cả chuỗi ALB → gateway → service → DB:
curl -s -w '\nlogin: %{http_code}\n' -X POST http://$ALB/api/auth/login \
  -H 'Content-Type: application/json' -d '{"email":"x@y.z","password":"wrong"}'
# → 401 + body JSON {"code":"INVALID_CREDENTIALS",...} là ĐẠT: phải truy được Postgres mới
#   biết user không tồn tại. 502/503 mới là target group hỏng.
```

**Bảng đọc mã trả về khi nghiệm thu qua ALB** (ba mã này bị nhầm lẫn với nhau nhiều nhất):

| Mã | Nghĩa | Đi soi ở đâu |
|---|---|---|
| **502 / 503** | ALB không có target healthy | target group · `healthcheck-path` · pod Ready |
| **404** | Request **đã tới** gateway, gateway không có route cho path đó | path bạn gọi, không phải hạ tầng |
| **401 / 400 / 405** | Request đã tới tận **service** | ✅ hạ tầng đúng |

**Nếu ra 502** — đúng cái bẫy §1.3. ALB có địa chỉ nghĩa là Ingress ổn; 502 nghĩa là **target group không có target nào healthy**:
```bash
aws elbv2 describe-target-groups --query 'TargetGroups[].[TargetGroupName,HealthCheckPath]' --output table
aws elbv2 describe-target-health --target-group-arn <arn> \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output table
```
`HealthCheckPath` của target group api-gateway phải là `/actuator/info`. Nếu nó là `/` ⇒ annotation ở `values/api-gateway-staging.yaml` chưa tới nơi (helm upgrade thiếu, hoặc controller version cũ không đọc annotation trên Service — khi đó chuyển annotation lên Ingress và chấp nhận dùng chung 1 path cho cả 2 backend).

#### C6 · `FRONTEND_URL` — ✅ ĐÃ BỎ ĐƯỢC nhờ 2 nửa ở B1

Sau khi chat-service nhận `FRONTEND_URL: "*"` từ block `env:` riêng của nó, biến `frontendUrl` ở `platform-*.yaml` chỉ còn ảnh hưởng **link trong email verify/reset**. Lệch một buổi là chấp nhận được (người dùng vẫn login được bằng email/password). → **Bỏ qua bước này trong mọi lần rebuild** — đây chính là phần thưởng của việc tách biến ra.

Giữ lại phần dưới cho 2 trường hợp: (a) bạn muốn link email trỏ đúng ALB của buổi hôm nay, (b) Day 8 đổi sang domain.

⚠️ **Nếu chat vẫn 403 sau khi đã patch**, kiểm theo đúng thứ tự này:
```bash
kubectl -n staging get deploy chat-service -o jsonpath='{.spec.template.spec.containers[0].image}'
#   → phải là :5a7067c (SHA có patch). Image cũ = patch không tồn tại trong đó.
kubectl -n staging exec deploy/chat-service -- sh -c 'echo $FRONTEND_URL'
#   → phải là "*". Ra ALB DNS = thiếu block env: trong values/chat-service-staging.yaml,
#     tức ConfigMap app-config đang đè mất default của image.
```

```bash
# sửa infra/values/platform-staging.yaml:  frontendUrl: "http://<ALB-DNS>"
helm upgrade platform charts/platform -n staging -f infra/values/platform-staging.yaml
kubectl -n staging rollout restart deploy          # 🔴 BẮT BUỘC — xem §1.5
kubectl -n staging rollout status deploy/chat-service
```
Bỏ `rollout restart` thì: Helm ✅, ConfigMap ✅ giá trị mới, pod ❌ vẫn chạy giá trị cũ, chat vẫn chết, **và không có gì báo lỗi**.

#### C7 · e2e trên URL live

Mở `http://$ALB` bằng trình duyệt: đăng ký → verify email → đăng nhập → đặt sân → chat.

🔴 **Đặt sân YÊU CẦU email đã verify** (`BookingController` khai `hasAuthority('EMAIL_VERIFIED')`). Người mới đăng ký sẽ **403** ngay ở bước đặt sân — tức chết đúng giữa buổi demo. Ba đường xử:

| Cách | Đánh đổi |
|---|---|
| `SENDGRID_API_KEY` thật trong SSM | mail gửi được, luồng tự nhiên, nhưng người xem phải mở hộp thư |
| Lấy link verify từ log (khi key rỗng) | `kubectl -n staging logs deploy/user-service \| grep '\[DEV\] Email verify'` — tiện cho bạn, vô dụng cho người xem |
| Tài khoản demo dựng sẵn | đơn giản nhất cho buổi 5–10 phút |

Trước Day 8 (còn http): ở màn thanh toán **đọc/gõ tay số tài khoản, đừng bấm nút copy** — `navigator.clipboard` chỉ chạy trên secure context, nên trên http không copy gì nhưng toast **vẫn báo "Đã copy"**. Hết ngay sau Day 8.

#### C7b · Seed dữ liệu demo — 2 câu SQL, làm sau khi đăng ký tài khoản

Cụm ephemeral nên DB rỗng mỗi lần dựng: **không có role `STAFF`**, và tài khoản mới **chưa verify email**. Thiếu cả hai thì không demo được: đặt sân trả 403, chat không có phía nhân viên để trò chuyện.

Đăng ký trước 2 tài khoản trên trình duyệt (1 khách + 1 nhân viên, dùng cửa sổ ẩn danh cho cái thứ hai), rồi:

```bash
kubectl -n data-staging exec -i statefulset/postgresql -- sh -c 'PGPASSWORD=$(cat $POSTGRES_PASSWORD_FILE) psql -U postgres -d user_db -P pager=off -c "INSERT INTO roles (id, created_at, updated_at, name) SELECT gen_random_uuid(), now(), now(), '"'"'STAFF'"'"' WHERE NOT EXISTS (SELECT 1 FROM roles WHERE name='"'"'STAFF'"'"');" -c "INSERT INTO user_roles (user_id, role_id) SELECT u.id, r.id FROM users u, roles r WHERE u.email='"'"'staff@test.local'"'"' AND r.name='"'"'STAFF'"'"' ON CONFLICT DO NOTHING;" -c "UPDATE users SET is_email_verified=true;" -c "SELECT u.email, r.name FROM users u JOIN user_roles ur ON ur.user_id=u.id JOIN roles r ON r.id=ur.role_id;"'
```

**Cấu trúc cần biết**: `roles` và `user_roles` là **bảng nối uuid–uuid** (`user_roles(user_id, role_id)`, PK ghép) — gán quyền là **INSERT vào bảng nối**, không phải UPDATE một cột trong `users`. App tạo role theo nhu cầu nên lúc đầu bảng `roles` **chỉ có `USER`**; phải tự thêm `STAFF`.

Cả 2 câu INSERT đều **idempotent** (`WHERE NOT EXISTS` / `ON CONFLICT DO NOTHING`) nên chạy lại không nhân bản.

🔴 **Sau khi chạy SQL phải ĐĂNG XUẤT rồi ĐĂNG NHẬP LẠI.** Role được nhúng vào **JWT lúc đăng nhập**; token đang cầm trên trình duyệt được cấp trước khi có `STAFF` nên vẫn mang quyền cũ. Sửa DB không làm token tự đổi — đây là chỗ dễ tưởng "SQL không ăn" nhất.

*(Dữ liệu chat nằm ở **MongoDB** chứ không phải Postgres. Nếu widget chat báo `403 "Bạn không có quyền truy cập hội thoại này"` thì đó là id hội thoại cũ còn trong localStorage của phiên đăng nhập trước — mở Console gõ `localStorage.clear(); location.reload();` là hết.)*

#### C8 · 🔴 Teardown — làm ĐÚNG THỨ TỰ, sai là chảy tiền

```bash
# 1. GỠ POD TRƯỚC — nếu không, bước 2 TREO VÔ HẠN
helm uninstall infra -n data-staging

# 2. Xoá PVC KHI CỤM CÒN SỐNG
kubectl delete pvc --all -n data-staging
kubectl get pv                                  # phải RỖNG trước khi đi tiếp

# 3. Xoá Ingress để controller tự gỡ ALB (PHẢI trước khi destroy)
kubectl delete ingress --all -A

# 4. Huỷ hạ tầng (ở repo app) — gõ `yes` khi nó hỏi, rồi chờ ~10-15 phút
cd ../badmintonHub/terraform && terraform destroy
```

🔴 **Vì sao bước 1 tồn tại** (đo thật ở Day 4, bản runbook cũ **thiếu** bước này): PVC có finalizer `kubernetes.io/pvc-protection` — K8s **không xoá PVC đang được pod mount**. Chạy bước 2 khi 5 pod datastore còn sống thì lệnh in `persistentvolumeclaim "..." deleted` cho **cả 5** rồi **đứng im vô hạn**, không trả về dấu nhắc.

Cái làm nó nguy hiểm là output **trông như đã xong**. Ctrl-C rồi `terraform destroy` luôn ⇒ PVC chưa finalize ⇒ reclaim không chạy ⇒ **EBS mồ côi** — đúng cái bẫy mà cả runbook này sinh ra để tránh.

**Vì sao bước 2 không được bỏ**: reclaim policy `Delete` chỉ chạy **lúc PVC bị xoá**. `terraform destroy` thẳng cụm thì không ai gọi nó → **26 GB EBS mồ côi vẫn tính tiền** mãi mãi, không có gì nhắc bạn.

**Vì sao bước 3 không được bỏ**: ALB do controller tạo bằng AWS API, **Terraform không quản lý nó**. Controller chết trước khi Ingress bị xoá ⇒ ALB mồ côi ($0.0225/giờ ≈ $16/tháng).

**Verify bill về 0 — chạy thật, đừng tin cảm giác.** Bộ cũ chỉ kiểm EBS + ELB nên **không bắt được** NAT/EIP/snapshot/cụm còn sống:

```bash
R=ap-southeast-1
aws eks list-clusters --region $R --no-cli-pager
aws ec2 describe-instances --region $R --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text --no-cli-pager
aws ec2 describe-volumes --region $R --filters Name=status,Values=available \
  --query 'Volumes[].VolumeId' --output text --no-cli-pager
aws elbv2 describe-load-balancers --region $R --query 'LoadBalancers[].LoadBalancerName' --output text --no-cli-pager
aws ec2 describe-nat-gateways --region $R --filter Name=state,Values=available \
  --query 'NatGateways[].NatGatewayId' --output text --no-cli-pager
aws ec2 describe-addresses --region $R --query 'Addresses[?!AssociationId].PublicIp' --output text --no-cli-pager
aws ec2 describe-snapshots --region $R --owner-ids self --query 'Snapshots[].SnapshotId' --output text --no-cli-pager
```

**Tất cả phải rỗng.** Ba thứ **KHÔNG** phải rác, đừng dọn:
- **9 ECR repo · S3 state · DynamoDB lock · SSM param** — bootstrap stack, cố ý giữ để rebuild nhanh.
- **KMS key `PendingDeletion`** — mỗi `apply` tạo 1 key, `destroy` chỉ *schedule* xoá với cửa sổ 30 ngày nên chúng tích lại. **Miễn phí**: trang pricing AWS ghi *"There is no charge for customer managed KMS keys that you manage and are scheduled for deletion."*
- **CloudWatch log group** — hiện không có cái nào vì EKS control-plane logging đang tắt. Nếu sau này bật, nhớ là log **ở lại sau destroy** và tính tiền.

#### 💰 Chi phí thực đo (buổi đầu tiên, 2026-08-06)

| | |
|---|---|
| Cụm sống | **2.5 giờ** (vừa dựng vừa debug) |
| EKS control plane $0.10/giờ | ~$0.25 |
| 2× `t3.xlarge` spot | ~$0.25 |
| ALB $0.0225/giờ | ~$0.06 |
| EBS 26 GB × 2.5 giờ | ~$0.01 |
| **Tổng buổi** | **≈ $0.57** — tức **≈ $0.22/giờ cụm sống** |

`ephemeral-cost.md` ghi *"1 buổi trọn gói ≈ $0.15"* — đúng cho buổi **gọn** (~40 phút: apply → demo 10' → destroy). Buổi đầu bao giờ cũng lâu hơn vì phải debug; dùng hệ số **$0.22/giờ** để tự ước tính.

Sau teardown còn **~$0.30/tháng**, toàn bộ là **ECR 3.2 GB** ($0.10/GB/tháng). Mỗi lần push đủ 9 image thêm ~1.8 GB ⇒ cân nhắc ECR lifecycle policy (giữ 5 image gần nhất + xoá untagged) ở `terraform/bootstrap/` nếu demo nhiều buổi.

---

## §3 — Tự kiểm tra

Trả lời được hết là đã hiểu Day 4. (Đáp án nằm trong §1–§2.)

1. `kubectl get ingress` có ADDRESS rỗng suốt 10 phút. Bạn đọc log của **cái gì** đầu tiên, và vì sao **không** phải sửa file Ingress?
2. `kubectl get pods` xanh 9/9, `RESTARTS` = 0, nhưng `curl http://$ALB/api/courts` trả **502**. Nghi chỗ nào trước, và dùng lệnh nào để xác nhận — biết rằng `kubectl` **không nhìn thấy** thứ đó?
3. Cũng cấu hình đó nhưng trả **404** thay vì 502. Vì sao hai mã này dẫn bạn đi **hai hướng hoàn toàn khác nhau**?
4. Pod `CrashLoopBackOff`, log app không có exception nào lạ. Kiểm tra **một** thứ ở phía image trước khi đọc tiếp log — thứ đó là gì?
5. Bạn sửa `FRONTEND_URL` trong `platform-staging.yaml`, `helm upgrade` báo thành công, ConfigMap trên cụm đã có giá trị mới. Vì sao chat vẫn chết?
6. `values/chat-service-staging.yaml` có `env.FRONTEND_URL: "*"`, trong khi image vốn đã mặc định `*` rồi. Vì sao xoá dòng đó đi thì chat **hỏng**?
7. Vì sao `values/platform-prod.yaml` để `ingress.enabled: false` mà **không** phải là quên bật?
8. Bạn chạy `kubectl delete pvc --all -n data-staging`, nó in `deleted` cho cả 5 PVC rồi **đứng im**. Chuyện gì đang xảy ra, và vì sao Ctrl-C rồi `terraform destroy` là **tốn tiền**?
9. Bạn `terraform destroy` mà quên xoá PVC. Tiền chảy ở đâu, mỗi tháng bao nhiêu, và vì sao **không** có cảnh báo nào?
10. Vì sao ALB health-check của api-gateway dùng `/actuator/info` chứ không phải `/actuator/health`, trong khi readiness probe của K8s thì ngược lại?
11. Nút Gửi của chat bấm không ăn, Console báo `crypto.randomUUID is not a function`. Vì sao **không** phải lỗi WebSocket, và vì sao Day 8 sửa nó mà không cần đổi dòng code nào?

---

## §4 — Bảng tra nhanh: triệu chứng → nghi gốc (riêng Day 4)

| Triệu chứng | Nghi gốc đầu tiên |
|---|---|
| Ingress không có ADDRESS | subnet thiếu tag `kubernetes.io/role/elb=1` · controller chết · sai `ingressClassName` |
| ALB có DNS nhưng `/api` → **502** | target group unhealthy → `healthcheck-path` sai (mặc định `/` mà gateway trả 404) |
| ALB có DNS nhưng `/` → 502 | pod `frontend` chưa Ready ⇒ không được đăng ký vào target group |
| Pod `CrashLoopBackOff`, `exec format error` | image build arm64, node amd64 → thiếu `--platform linux/amd64` |
| Pod `ErrImagePull` | sai ECR URL/tag trong values · node thiếu quyền pull ECR |
| Pod `CreateContainerConfigError` | Secret chưa tồn tại lúc pod start → chạy `eks-secret.sh` rồi `rollout restart` |
| PVC `Pending` | thiếu StorageClass `gp3` · EBS CSI chưa chạy · IRSA thiếu `ec2:CreateVolume` |
| payment/chat fail boot, log nhắc Cloudinary | **by design** (`CloudinaryProdGuard` `@Profile("prod")`) → nạp `CLOUDINARY_*` vào SSM |
| chat-service auth fail Mongo | `MONGODB_CHAT_URI` thiếu `?authSource=admin`, hoặc password lệch giữa SSM và chart |
| chat kết nối STOMP **timeout** (không phải refused) | NetworkPolicy của RabbitMQ chưa mở 61613 — *refused = không ai nghe · timeout = có thứ nuốt gói tin* |
| Sửa ConfigMap xong không có tác dụng | thiếu `kubectl rollout restart deploy` (§1.5) |
| **chat 403 lúc WS handshake, mọi thứ khác xanh** | thiếu `FRONTEND_URL: "*"` trong `env:` của `values/chat-service-<env>.yaml` → ConfigMap `app-config` đang đè default `*` của image (§B1) · hoặc image còn là SHA trước patch |
| **Nút Gửi của chat bấm không ăn**, Console báo `crypto.randomUUID is not a function` | **secure context** — API này chỉ có trên https/localhost. KHÔNG phải lỗi WS/origin/hạ tầng. Day 8 hết, hoặc fallback ở FE |
| Bấm copy số tài khoản không copy gì nhưng toast báo "Đã copy" | cùng lớp trên — `navigator.clipboard` secure-context-only |
| Đặt sân trả **403** | tài khoản chưa verify email (`hasAuthority('EMAIL_VERIFIED')`) |
| WebSocket rớt sau ~60s im lặng | thiếu `idle_timeout.timeout_seconds=300` trên Ingress |

---

## §5 — Cái Day 4 để lại cho Day 8 (và vì sao Day 8 sẽ rẻ)

Ba thứ làm hôm nay khiến Day 8 chỉ còn là **sửa vài dòng values**:

| Làm ở Day 4 | Trả cổ tức ở Day 8 |
|---|---|
| Ingress template hoá 2 công tắc `host` / `certificateArn` | điền 2 dòng × 2 env → có host + listener 443 + redirect + record Route53. Không viết lại manifest lúc T-2 |
| FE derive `ws`/`wss` từ `location.protocol` | bật HTTPS xong chat **tự** chuyển sang `wss://`, không build lại FE |
| `external-dns ttl: "60"` đặt sẵn trong template | record cũ không kẹt 5' trong cache resolver khi cụm rebuild ra ALB mới |

Kiểm đường may Day 8 **ngay hôm nay, không tốn xu nào**:
```bash
helm template t charts/platform -f infra/values/platform-staging.yaml \
  --set ingress.certificateArn=arn:aws:acm:ap-southeast-1:111122223333:certificate/xxx \
  | grep -cE 'certificate-arn|listen-ports|ssl-redirect'      # phải = 3
```

Và nhớ: **KHÔNG cert-manager**. ALB terminate TLS ở tầng AWS và chỉ đọc cert từ **ACM/IAM** — nó *không đọc được K8s Secret* nơi cert-manager cất cert. Gắn vào là **im lặng không có HTTPS**, không có lỗi rõ ràng nào để lần ra.
