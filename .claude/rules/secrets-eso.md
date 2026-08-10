---
description: Secret = External Secrets Operator + SSM Parameter Store. Git chỉ ref tên param, không bao giờ chứa giá trị. Vì sao KHÔNG SealedSecrets.
globs: external-secrets/**/*.yaml, apps/**/*secret*.yaml
---

# Secrets — External Secrets Operator + SSM

## Luật tuyệt đối

**KHÔNG commit secret thô, ciphertext, `.env`, hay bất kỳ giá trị nào vào repo này.** Repo **PUBLIC**.
Git chỉ chứa `ExternalSecret` **ref tên param** SSM. Giá trị thật nạp **1 lần** vào SSM `SecureString`, sống **ngoài cụm** → `terraform destroy` không xoá → rebuild là có secret ngay, **0 thao tác tay**.

Trước khi commit bất cứ file nào có chữ `password`/`secret`/`key`/`token`: dừng lại, kiểm giá trị có phải placeholder không.

## Vì sao KHÔNG SealedSecrets

SealedSecrets controller sinh **keypair mới mỗi lần cài**. Mô hình này `terraform destroy` sau mỗi buổi → cụm mới = khoá mới → **mọi `SealedSecret` đã commit thành rác không giải mã được** → rebuild xong toàn bộ pod `CreateContainerConfigError`. Nó đánh thẳng vào tiêu chí vàng "0 thao tác tay" ([`ephemeral-cost.md`](ephemeral-cost.md)).
*(Chữa được bằng cách backup keypair vào SSM rồi seed lại trước khi cài — nhưng nếu đã phải dùng SSM thì dùng thẳng SSM gọn hơn.)*

## 🔴 ExternalSecret nằm TRONG chart, KHÔNG có thư mục `external-secrets/`

Chốt ở Day 6. Bản kế hoạch cũ ghi `external-secrets/app-<env>.yaml` riêng — **đã bỏ**.

| File | Sinh Secret | Namespace |
|---|---|---|
| `charts/platform/templates/externalsecret.yaml` | `app-secrets` | `<env>` |
| `infra/templates/externalsecret.yaml` | `datastore-secrets` | `data-<env>` |

Lý do: Secret sống ở **4 namespace** (`staging`, `prod`, `data-staging`, `data-prod`) mà **một ArgoCD Application chỉ khai được MỘT `destination.namespace`**. Tách ra thư mục riêng ⇒ phải đẻ thêm 4 Application chỉ để nạp secret, và namespace `data-*` lại phải do app khác tạo trước. Nhúng vào chart thì **Application nào tự tạo namespace của nó, tự nạp secret của nó**, thứ tự xử bằng sync-wave *trong* chart. Cùng lý lẽ đã dùng cho Ingress ở Day 4.

Bật/tắt bằng `externalSecret.enabled` — **`false` ở dev** (kind không có IRSA; `scripts/kind-secret.sh` sinh Secret **cùng tên** nên 27 file values không phân biệt env).

## Cấu hình

```yaml
# ClusterSecretStore — 1 lần cho cả cụm, do bootstrap.sh của Day 3 (repo app) cài
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata: { name: aws-ssm }
spec:
  provider:
    aws:
      service: ParameterStore
      region: ap-southeast-1
      auth: { jwt: { serviceAccountRef: { name: external-secrets, namespace: external-secrets } } }
---
# charts/platform/templates/externalsecret.yaml — KHÔNG chứa giá trị, chỉ ref tên
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: app-secrets
  annotations: { argocd.argoproj.io/sync-wave: "-1" }   # Secret trước pod
spec:
  refreshInterval: 1h
  secretStoreRef: { name: aws-ssm, kind: ClusterSecretStore }
  target:
    name: app-secrets                      # ← chính là Secret mà envFrom của chart dùng
    creationPolicy: Owner
    template:
      engineVersion: v2
      mergePolicy: Merge                   # xem 🔴 "3 key rỗng" dưới
      data: { SENDGRID_API_KEY: "", GOOGLE_CLIENT_ID: "", GOOGLE_CLIENT_SECRET: "" }
  dataFrom:
    - find:
        path: /badminton/staging/          # hút cả cây param thành 1 Secret
        name: { regexp: ".*" }             # 🔴 BẮT BUỘC — xem dưới
      rewrite:                             # 🔴 BẮT BUỘC — xem dưới
        - regexp: { source: "^.*/([^/]+)$", target: "${1}" }
```

### 🔴 `find.path` một mình là KHÔNG ĐỦ — phải kèm `find.name.regexp`

Đo thật trên EKS ở Day 6. Provider AWS Parameter Store chọn cách tìm theo **toán tử**:

```
find.name có  → tìm theo regexp tên
find.tags có  → tìm theo tag
không cái nào → error "unexpected find operator"
```

`path` chỉ là **bộ lọc phạm vi**, tự nó không phải toán tử. Viết `find.path` trần thì ExternalSecret đứng ở `SecretSyncedError` **vĩnh viễn**, và message chỉ nói `unexpected find operator` — **không nhắc gì** tới việc thiếu `name`. Dùng `name: { regexp: ".*" }` cho đúng ý "hút cả cây".

⚠️ Bẫy phụ: `ClusterSecretStore` báo `Valid` **không** chứng minh đường fetch chạy được — nó chỉ chứng minh ESO xác thực được với AWS. Day 4 có ESO `Valid` suốt mà bug này không lộ, vì lúc đó Secret nạp bằng `scripts/eks-secret.sh` (gọi thẳng AWS CLI) và **chưa có ExternalSecret nào tồn tại**. → Luôn smoke test một ExternalSecret thật trước khi thả cả cụm xuống.

Đổi env = đổi `ssmPath` ở `infra/values/{platform,infra}-<env>.yaml`. Tên target Secret phải khớp `envFrom.secret` trong `values/<svc>-<env>.yaml`.

### 🔴 `apiVersion: v1`, KHÔNG phải `v1beta1`

`external-secrets.io/v1beta1` **đã bị gỡ ở ESO v0.17.0** (v0.16.x phục vụ cả hai). Hai kiểu hỏng:

| Cụm | Khai `v1beta1` thì sao |
|---|---|
| ESO ≥ 0.17 | manifest không apply được — app ArgoCD đỏ ngay, còn dễ thấy |
| ESO 0.16.x | webhook **tự chuyển** sang `v1` ⇒ ArgoCD so desired (`v1beta1`) với live (`v1`) thấy khác ⇒ app **OutOfSync VĨNH VIỄN**, bấm sync bao nhiêu lần cũng không hết ([external-secrets#5478](https://github.com/external-secrets/external-secrets/issues/5478)) |

Kiểm: `kubectl get crd externalsecrets.external-secrets.io -o jsonpath='{.spec.versions[*].name}'`. ESO < 0.16 thì sửa đúng 1 dòng `externalSecret.apiVersion` ở values.

### 🔴 `rewrite` là BẮT BUỘC với `dataFrom.find`, không phải làm đẹp

ESO trả key **kèm nguyên đường dẫn**: `/badminton/staging/JWT_SECRET`. Mà key của một Kubernetes Secret bắt buộc khớp `[-._a-zA-Z0-9]+` — **dấu `/` không hợp lệ** ⇒ ExternalSecret không sync được, mọi pod đứng ở `CreateContainerConfigError`.

Regex `^.*/([^/]+)$` → `${1}` cắt lấy đoạn sau dấu `/` cuối. An toàn hai chiều: chuỗi đã sạch prefix thì không khớp regex và `ReplaceAllString` trả về nguyên vẹn.

### 🔴 3 key phải TỒN TẠI nhưng KHÔNG có ở SSM

SSM **từ chối giá trị rỗng** (`ValidationException: length ≥ 1`) nên `SENDGRID_API_KEY`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` không được tạo. Nhưng Spring cần key **tồn tại** (kể cả rỗng) để resolve `${...}`; thiếu hẳn key thì context fail bằng `Could not resolve placeholder` — một thông báo **không nhắc gì tới Secret**.

→ `target.template` + `mergePolicy: Merge` bơm 3 key với giá trị literal `""` (danh sách ở `externalSecret.optionalKeys`).

- ⚠️ **KHÔNG** viết `{{ .SENDGRID_API_KEY | default "" }}` — docs ESO: *"referencing a non-existing key in the template will raise an error, instead of being suppressed"*.
- 🔴 **Landmine**: `mergePolicy: Merge` ⇒ **template thắng provider** (*"data and dataFrom keys … having lower priority than the template outcome"*). Ngày nào nạp giá trị **thật** vào SSM thì **phải xoá tên đó khỏi `optionalKeys`**, không thì bị ghi đè rỗng **trong im lặng**: ExternalSecret vẫn `SecretSynced`, key vẫn tồn tại, chỉ là email không bao giờ gửi.

## Param cần có ở SSM (`/badminton/<env>/*`) — **13 tên × 2 env**

**10 bắt buộc**: `JWT_SECRET` · `POSTGRES_USERNAME` · `POSTGRES_PASSWORD` · `MONGODB_CHAT_URI` (nhớ `?authSource=admin`) · **`MONGODB_ROOT_PASSWORD`** · `RABBITMQ_PASS` · **`RABBITMQ_ERLANG_COOKIE`** · `CLOUDINARY_CLOUD_NAME` / `CLOUDINARY_API_KEY` / `CLOUDINARY_API_SECRET`.

**3 optional, CỐ TÌNH không tạo**: `SENDGRID_API_KEY` · `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` (xem mục trên).

> 🆕 **2 param in đậm là mới ở Day 6.** `scripts/eks-secret.sh` trước đây tự chế ra chúng — `mongodb-root-password` tách từ `MONGODB_CHAT_URI` bằng `sed`, `rabbitmq-erlang-cookie` bằng `openssl rand`. **ESO không chạy script được**, nên chúng phải trở thành param thật. Đổi lại, con regex "`@` cuối cùng" từng cắn ở Day 4 biến mất hẳn.
>
> ⚠️ **Bất biến không ai tự kiểm được**: `MONGODB_ROOT_PASSWORD` phải **trùng** password đã nhúng trong `MONGODB_CHAT_URI` của cùng env. Lệch ⇒ Mongo dựng bằng mật khẩu A, chat-service kết nối bằng mật khẩu B ⇒ auth fail lúc boot, log chỉ nói `Authentication failed` và bạn sẽ đi soi `?authSource=admin` (vốn đang đúng).

Non-secret → **ConfigMap**, đừng nhét vào SSM: `RABBITMQ_USER=badminton` · mọi `*_HOST`/`*_URL` in-cluster · `CHAT_BROKER_RELAY` · `MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED`.
Danh sách biến đầy đủ = `application.yml` từng service ở `../badmintonHub` (xem [`values-env-map.md`](values-env-map.md)).

```bash
aws ssm put-parameter --type SecureString --name /badminton/staging/JWT_SECRET --value "$(openssl rand -hex 64)"
aws ssm get-parameters-by-path --path /badminton/staging/ --query 'Parameters[].Name'   # đối chiếu đủ chưa
```

## Thứ tự bootstrap có ràng buộc

**ESO + ClusterSecretStore phải Ready TRƯỚC khi ArgoCD sync app.** Không thì pod khởi động lúc `Secret` chưa tồn tại → `CreateContainerConfigError` (tự khỏi sau khi ESO sync, nhưng buổi demo trông như hỏng).

## Debug

```bash
kubectl get externalsecret -A                              # tất cả phải SecretSynced
kubectl describe externalsecret app-secrets -n staging     # xem Events khi không sync
kubectl -n external-secrets logs deploy/external-secrets --tail=100
kubectl get secret app-secrets -n staging -o jsonpath='{.data}' | tr ',' '\n' | cut -d'"' -f2   # CHỈ liệt kê KEY
```

| Triệu chứng | Nghi gốc |
|---|---|
| `SecretSyncedError` / `AccessDenied` | IRSA role của ServiceAccount `external-secrets` thiếu quyền `ssm:GetParameter*` / `kms:Decrypt` |
| Secret sync ra nhưng **rỗng key** | sai `path` (thiếu `/` cuối) hoặc param nằm ở env khác |
| Key trong Secret có dạng `/badminton/staging/JWT_SECRET` → không sync được | **thiếu `rewrite`** trong `dataFrom` — xem 🔴 ở trên |
| App ArgoCD **OutOfSync vĩnh viễn**, sync bao nhiêu lần cũng không hết | khai `apiVersion: v1beta1` trên ESO 0.16.x (webhook tự chuyển sang `v1`) |
| SSM **có** giá trị thật mà pod nhận **rỗng**, ExternalSecret vẫn `SecretSynced` | key đó còn nằm trong `externalSecret.optionalKeys` — template thắng provider |
| Pod `CreateContainerConfigError` | Secret chưa tồn tại lúc pod start → thiếu `sync-wave: "-1"`, hoặc tên target Secret ≠ `envFrom.secret` |
| Datastore `CrashLoopBackOff` / chat-service `Authentication failed` | `MONGODB_ROOT_PASSWORD` lệch password nhúng trong `MONGODB_CHAT_URI` |
| Pod boot fail vì thiếu `CLOUDINARY_*` | **by design** (`CloudinaryProdGuard` `@Profile("prod")`) — nạp param, đừng bỏ profile prod |

> ⚠️ Khi debug: **in ra KEY, không in VALUE.** Đừng `base64 -d` secret rồi để giá trị nằm trong transcript.
