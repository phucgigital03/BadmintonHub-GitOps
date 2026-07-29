# BadmintonHub — Thao tác tay & bản đồ verify (AWS Console · GitHub · third-party)

Tài liệu này trả lời **hai** câu hỏi mà `Planning_CICD.md` và [`ARCHITECTURE.md`](ARCHITECTURE.md) không gom lại một chỗ:

1. **Tôi phải tự tay cung cấp những gì?** — account, IAM, API key, SSM param, GitHub secret.
2. **Chạy lệnh code xong thì mở màn hình nào trong AWS Console để biết nó đúng?**

> `ARCHITECTURE.md` = *hệ thống trông như thế nào*. File này = *tôi phải làm gì bằng tay, và nhìn đâu để kiểm chứng*.

## Quy ước đọc

| Ký hiệu | Nghĩa |
|---|---|
| `☐` | Việc **bạn** làm bằng tay trong Console/UI |
| ▶ `../badmintonHub` | Việc thuộc **app repo** (Day 1/3/5) — mở Claude Code ở đó, không làm ở repo này |
| `<acct>`, `<domain>`, `<owner>` | Placeholder — repo này **PUBLIC**, không ghi giá trị thật |

> 🔴 **Repo này PUBLIC.** File này chỉ ghi **TÊN** param/secret và **cách lấy** giá trị. Không bao giờ ghi giá trị thật, account ID, ARN, hay domain thật vào đây.
>
> ⚠️ **Region = `ap-southeast-1` (Singapore).** Bẫy phổ biến nhất khi verify: Console mở đúng trang nhưng **sai region ở góc phải trên** → thấy danh sách rỗng và tưởng code chạy hỏng. Kiểm region **trước** khi kết luận bất cứ điều gì thiếu.

---

## §0 — Sự thật về Free Tier (đọc trước khi bấm `terraform apply` lần đầu)

**Dự án này KHÔNG chạy trong 12-month Free Tier.** Nguyên văn `Planning_CICD.md:1122`:

> **Sự thật thẳng thắn: EKS + node + ALB + NAT KHÔNG thuộc Free-Tier.** "Rẻ" đến từ **teardown sau mỗi demo**.

| Hạng mục | Giá xấp xỉ | Free-Tier? | Ai tạo |
|---|---|---|---|
| EKS control plane | ~$0.10/giờ (~$73/tháng) | ❌ | Terraform (ephemeral) |
| EC2 node `t3.xlarge` spot ×2 | ~$0.13/giờ tổng | ❌ (`t3.micro` free nhưng quá nhỏ) | Terraform (ephemeral) |
| ALB | ~$0.0225/giờ + LCU | ❌ | AWS LB Controller (từ Ingress) |
| NAT Gateway | ~$0.045/giờ | ❌ — **né hoàn toàn** | *(không tạo)* |
| EBS gp3 | ~$0.08/GB-tháng | ✅ 30 GB free | EBS CSI (từ PVC) |
| ECR | ~$0.10/GB-tháng | ✅ 500 MB free — 9 image Java ≈ 3 GB → **~$0.30/tháng** | Terraform (**bootstrap**) |
| Route53 hosted zone | $0.50/zone-tháng | ❌ — chỉ từ Day 8, chạy **24/7 kể cả khi cụm đã destroy** | Terraform (**bootstrap**) |
| ACM certificate | **$0** khi dùng với ALB | ✅ free | Terraform (**bootstrap**) |
| S3 + DynamoDB (state) | ~vài cent | ✅ phần lớn free | Terraform (**bootstrap**) |
| SSM Parameter Store | **$0** với standard param | ✅ free | **Bạn, bằng tay** |

**Con số phải nhớ** (`Planning_CICD.md:1137`):

| Kịch bản | Tiền |
|---|---|
| Cụm sống | **~$0.25/giờ** |
| 1 buổi trọn gói (apply 15' + demo 10' + destroy 10') | **≈ $0.15** |
| Chạy 3 giờ | ≈ $0.75 |
| **Quên tắt 1 tháng** | **≈ $180** |
| Thường trực giữa các buổi (đã destroy) | **$0.30/tháng** (ECR) → **$0.80/tháng** sau Day 8 (+ Route53 zone) |

### ☐ Budget alert — làm TRƯỚC mọi thứ khác

Console → **Billing and Cost Management** → **Budgets** → *Create budget*:
- `Customize (advanced)` → **Cost budget** → Period **Monthly** → Budgeted amount **$5**
- Alert 1: **80%** of budgeted amount, trigger **Actual** → email bạn
- Alert 2: **100%** of budgeted amount, trigger **Forecasted** → email bạn

☐ Bật cho IAM user xem được billing: Console → tên account (góc phải) → **Account** → *IAM user and role access to Billing information* → **Edit** → tick **Activate**. Không bật thì chỉ root thấy hoá đơn.

☐ Đặt hẹn giờ điện thoại **"DESTROY"** ngay sau mỗi buổi demo (`.claude/rules/ephemeral-cost.md`). Budget alert báo *sau khi* đã tốn tiền; hẹn giờ mới là cái chặn.

---

## §1 — Chuẩn bị một lần, trước Day 1

### ☐ 1.1 AWS account + IAM user riêng

1. Tạo AWS account → **bật MFA cho user root ngay** → sau đó **không dùng root nữa**.
2. Console → **IAM** → **Users** → *Create user*
   - User name: ví dụ `badminton-dev`
   - Permissions options → **Attach policies directly**
   - Quyền cần (`Planning_CICD.md:281`): **EKS · EC2 · VPC · ECR · IAM · S3 · DynamoDB** — cộng thêm **SSM**, **Route53**, **ACM**, **CloudTrail** (read) cho Day 6/8.
   - 👉 **Khuyến nghị thực dụng cho dự án solo: gắn thẳng `AdministratorAccess`.** Ghép policy tay cho đủ 11 dịch vụ tốn cả buổi và mỗi lần thiếu quyền lại nhận `AccessDenied` giữa lúc `terraform apply` — không đáng đổi với dự án 1 người, ephemeral. Bảo mật thật nằm ở **MFA cho root + không commit access key**, không nằm ở việc bào mỏng policy của IAM user này.
3. → tab **Security credentials** → *Create access key* → use case **Command Line Interface (CLI)** → lưu key vào `aws configure`.

**Verify:**
```bash
aws sts get-caller-identity      # thấy Account + Arn = user vừa tạo, KHÔNG phải :root
aws configure get region         # phải in ra: ap-southeast-1
```

### ☐ 1.2 Hai GitHub repo — cả hai đều PUBLIC

| Repo | Chứa gì |
|---|---|
| `badmintonHub` | Source Java/React · Dockerfile · `terraform/` · `.github/workflows/` |
| `badmintonHub-gitops` | Repo này — `charts/` · `values/` · `apps/` · `external-secrets/` · `infra/` |

Vì sao PUBLIC (`Planning_CICD.md:283`): SonarCloud free + GitHub Actions **không giới hạn phút**. Repo private chỉ có 2000 phút/tháng, mà sửa `common/**` fan-out ra 8 build Testcontainers ≈ **80 phút billed mỗi lần push**.

☐ Trước khi để public, xác nhận `.env` chưa từng vào history (`Planning_CICD.md:284` — repo app đã verify):
```bash
cd ../badmintonHub && git log --all --oneline -- .env frontend/.env    # phải RỖNG
git ls-files | grep -E '\.env'                                          # chỉ được thấy *.example
```

### ☐ 1.3 Domain — mua ở Day 3, gắn ở Day 8

Console → **Route 53** → **Registered domains** → *Register domain* (~$13–15/năm `.com`).

> ⚠️ **Mua sớm, gắn muộn.** Domain **không** phải tiền đề của Day 1–7 (chạy trên ALB DNS thô). Nhưng đổi nameserver mất **1–48h** và không cần cụm → mua từ giai đoạn Day 3 rồi để đó, đừng để nó thành đường găng đúng hôm T-2 (`Planning_CICD.md:282`).
>
> **Nên mua thẳng tại Route53** dù đắt hơn Namecheap ~$3: NS tự cấu hình → hết rủi ro propagation trước buổi demo.

### ☐ 1.4 CLI trên máy dev

```bash
aws --version          # AWS CLI v2
kubectl version --client
helm version           # v3
terraform version      # >= 1.6
docker version
kind version           # cụm K8s local (dev, Day 2)
docker buildx version  # BẮT BUỘC
```

> ⚠️ **arm64 → amd64**: máy Apple Silicon build ra image **arm64**, node `t3.*` là **amd64** → pod chết ngay `exec format error` mà log **không nhắc gì tới kiến trúc**. Mọi lệnh build-để-đẩy-ECR phải có `--platform linux/amd64` (Day 1 · 4 · 5).
>
> Docker Desktop cần **≥ 12 GB RAM** cho Day 2 (5 datastore + 9 service trên kind).

---

## §2 — Năm tài khoản third-party → API key nào, thiếu thì hỏng gì

| Dịch vụ | Lấy key ở đâu | Key đi vào | Thiếu thì |
|---|---|---|---|
| **Cloudinary** | cloudinary.com → **Dashboard** → *Cloud name* · *API Key* · *API Secret* | **SSM** ×3 | 🔴 `payment-service` + `chat-service` **fail boot** khi `SPRING_PROFILES_ACTIVE=prod`. Đây là **by design** (`CloudinaryProdGuard` `@Profile("prod")`) — nạp param, **đừng "sửa" bằng cách bỏ profile prod** |
| **SendGrid** | sendgrid.com → **Settings → API Keys** → *Create API Key* → scope **Restricted: Mail Send** | **SSM** ×1 | Email verify/reset không gửi. **Không chặn demo** — login email/password không gate theo `emailVerified` |
| **Google OAuth** | console.cloud.google.com → **APIs & Services → Credentials** → *Create OAuth client ID* → **Web application** | **SSM** ×2 | Nút Google render `disabled`. **Không phải** đường login của demo. *(`VITE_GOOGLE_CLIENT_ID` bake vào image FE — public client ID, **không** phải secret)* |
| **SonarCloud** | sonarcloud.io → **My Account → Security** → *Generate token* | **GitHub secret** | CI quality gate fail (Day 5) |
| **Slack** | api.slack.com/apps → *Create App* → **Incoming Webhooks** → *Add New Webhook* | **GitHub secret** | Không có notify CI/CD + alert DLT (Day 7) |

> ⚠️ **Chỗ dễ nhầm nhất là cột "Key đi vào".** 3 dịch vụ đầu là **secret của ứng dụng lúc runtime** → vào **SSM**, pod đọc qua ExternalSecret. 2 dịch vụ cuối là **secret của CI** → vào **GitHub Actions secrets**, cụm không bao giờ thấy chúng. Nhét nhầm chỗ thì không có lỗi rõ ràng, chỉ là thứ đó im lặng không hoạt động.
>
> **Google OAuth**: hiện chưa cần khai *Authorized JavaScript origins* — `GoogleButton.tsx` mới là stub. Khi bật login Google thật, domain cố định của Day 8 nghĩa là **đăng ký 1 lần** thay vì mỗi lần ALB DNS đổi.

---

## §3 — 22 SSM parameter (11 tên × 2 env)

Đường dẫn: **`/badminton/<env>/<TÊN>`**, `env ∈ {staging, prod}`, type **`SecureString`**, tier **Standard** (free).

Vì sao SSM chứ không phải SealedSecrets: param **sống ngoài cụm** → `terraform destroy` không xoá → rebuild là có secret ngay, **0 thao tác tay**. SealedSecrets sinh keypair mới mỗi lần cài cụm → mọi SealedSecret đã commit thành rác (`.claude/rules/secrets-eso.md`).

### 3a. Năm param **bạn tự nghĩ ra**

| Tên | Giá trị lấy ở đâu |
|---|---|
| `JWT_SECRET` | `openssl rand -hex 64` |
| `POSTGRES_USERNAME` | **`postgres`** — superuser, vì `ddl-auto=update` cần quyền tạo schema và app chỉ có **một** cặp user/pass cho cả 5 DB |
| `POSTGRES_PASSWORD` | Bạn đặt (`openssl rand -base64 24`) |
| `RABBITMQ_PASS` | Bạn đặt. *(`RABBITMQ_USER=badminton` là **non-secret → ConfigMap**, đừng nhét vào SSM)* |
| `MONGODB_CHAT_URI` | Bạn ghép: `mongodb://root:<mongo-pass>@mongodb.data-<env>.svc.cluster.local:27017/chat_db?authSource=admin` |

> 🔴 **Thiếu `?authSource=admin` = auth fail ngay lúc boot.** Root user của Bitnami MongoDB nằm ở db `admin`, không phải `chat_db`.

> ⚠️ **Bẫy sẽ cắn ở Day 4, ghi lại từ bây giờ.** Ba giá trị `POSTGRES_PASSWORD`, `RABBITMQ_PASS`, và mật khẩu Mongo nhúng trong `MONGODB_CHAT_URI` phải **khớp ở HAI nơi**:
> - **(a)** SSM — để app đọc qua `ExternalSecret`
> - **(b)** chart Bitnami — để datastore dựng lên với đúng mật khẩu đó
>
> Để Bitnami tự sinh password ngẫu nhiên là app auth fail 100%, và triệu chứng chỉ là "pod `CrashLoopBackOff`" không nói gì về nguyên nhân. **Hướng chốt: chart Bitnami dùng `existingSecret` trỏ vào chính Secret do ESO sinh ra** — hiện thực ở Day 2 (values `infra/`) và nối dây ở Day 6.

### 3b. Sáu param **lấy từ third-party** (§2)

`CLOUDINARY_CLOUD_NAME` · `CLOUDINARY_API_KEY` · `CLOUDINARY_API_SECRET` · `SENDGRID_API_KEY` · `GOOGLE_CLIENT_ID` · `GOOGLE_CLIENT_SECRET`

### 3c. Nạp — chọn một trong hai đường

**Console:** Systems Manager → **Parameter Store** → *Create parameter* → Name `/badminton/staging/JWT_SECRET` → Tier **Standard** → Type **SecureString** → KMS key `alias/aws/ssm` → Value → *Create parameter*. Lặp 22 lần.

**CLI (nhanh hơn nhiều):**
```bash
# ví dụ 2 param; lặp cho đủ 11 tên, rồi lặp cả cây cho env prod
aws ssm put-parameter --type SecureString --name /badminton/staging/JWT_SECRET \
  --value "$(openssl rand -hex 64)"
aws ssm put-parameter --type SecureString --name /badminton/staging/POSTGRES_USERNAME \
  --value 'postgres'
# … CLOUDINARY_CLOUD_NAME/API_KEY/API_SECRET · SENDGRID_API_KEY
#     GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET · POSTGRES_PASSWORD · RABBITMQ_PASS · MONGODB_CHAT_URI
```

**Verify — phải ra đủ 11 tên cho mỗi env:**
```bash
aws ssm get-parameters-by-path --path /badminton/staging/ --query 'Parameters[].Name' --output table
aws ssm get-parameters-by-path --path /badminton/prod/    --query 'Parameters[].Name' --output table
```

> ⚠️ Khi debug secret: **in ra KEY, không in VALUE.** Đừng `base64 -d` rồi để giá trị nằm trong transcript hay ảnh chụp màn hình.

### 3d. KHÔNG cho vào SSM (những cái này là ConfigMap)

`RABBITMQ_USER=badminton` · mọi `*_HOST` / `*_URL` in-cluster (`DB_<SVC>_URL`, `REDIS_HOST`, `KAFKA_BOOTSTRAP_SERVERS`, `EUREKA_URL`, `FRONTEND_URL`) · `CHAT_BROKER_RELAY=true` · `MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED=true` · `SPRING_PROFILES_ACTIVE=prod`.

---

## §4 — Bản đồ verify Console theo Day

> Nguồn sự thật vẫn là `kubectl` / `aws` CLI. Console dùng để **cross-check độc lập** — nhất là khi CLI báo xanh mà hệ thống vẫn không chạy.

### Day 3 · bootstrap stack — ▶ `../badmintonHub` · *apply 1 lần, KHÔNG BAO GIỜ destroy*

| Code tạo | Console → | Phải thấy | CLI |
|---|---|---|---|
| S3 bucket (tf state) | **S3 → Buckets** | Bucket tồn tại · **Properties → Bucket Versioning = Enabled** · trong bucket có `terraform.tfstate` | `aws s3 ls` |
| DynamoDB (state lock) | **DynamoDB → Tables** | Bảng tồn tại · Partition key = **`LockID`** kiểu **String** | `aws dynamodb list-tables` |
| **9 ECR repository** | **ECR → Repositories** | Đúng **9** repo: `eureka-server` `api-gateway` `user-service` `court-service` `booking-service` `payment-service` `escrow-service` `chat-service` `frontend` | `aws ecr describe-repositories --query 'repositories[].repositoryName'` |

### Day 3 · ephemeral stack — ▶ `../badmintonHub` · *destroy sau mỗi buổi*

| Code tạo | Console → | Phải thấy |
|---|---|---|
| VPC | **VPC → Your VPCs** | 1 VPC |
| Subnet + **tag** | **VPC → Subnets** → chọn subnet → tab **Tags** | 🔴 Public subnet phải có `kubernetes.io/role/elb = 1` **và** `kubernetes.io/cluster/badminton = shared`; private subnet có `kubernetes.io/role/internal-elb = 1` |
| *(không tạo NAT)* | **VPC → NAT Gateways** | **0** — thấy 1 cái là đang chảy **$45/tháng** |
| EKS cluster | **EKS → Clusters** | `badminton` · Status **Active** · tab **Overview** có **OpenID Connect provider URL** |
| Node group | **EKS → badminton → Compute** | 1 node group, **2** node, Desired size 2 |
| Node EC2 | **EC2 → Instances** | 2 instance **Running**, Type **`t3.xlarge`**, cột **Lifecycle = `spot`** |
| OIDC provider | **IAM → Identity providers** | Provider `oidc.eks.ap-southeast-1.amazonaws.com/id/…` |
| **4 IRSA role** | **IAM → Roles** | 4 role, mỗi role tab **Trust relationships** tham chiếu OIDC trên + `sub` = `system:serviceaccount:<ns>:<sa>` |
| StorageClass gp3 | *(không có ở Console)* | `kubectl get storageclass` → có `gp3` |

**🔴 Tag subnet là thứ dễ quên nhất và hậu quả xuất hiện muộn nhất**: thiếu tag thì Day 3 vẫn xanh, nhưng **Day 4 Ingress treo vô hạn** và `kubectl describe ingress` chỉ nói `couldn't auto-discover subnets` (`Planning_CICD.md:552-562`).

**Bốn IRSA role — thiếu cái nào hỏng cái đó** (`ARCHITECTURE.md` §3a):

| Role cho | ServiceAccount / ns | Quyền chính | Thiếu thì |
|---|---|---|---|
| AWS Load Balancer Controller | `kube-system` | `elasticloadbalancing:*`, `ec2:Describe*` | Ingress **không có ADDRESS** → không có ALB → không vào được hệ thống |
| EBS CSI driver | `kube-system` | `ec2:CreateVolume`, `AttachVolume`… | PVC kẹt `Pending` → 5 datastore không boot |
| **External Secrets** | `external-secrets` / `external-secrets` | `ssm:GetParameter*` + `ssm:DescribeParameters` trên `arn:aws:ssm:<region>:<acct>:parameter/badminton/*` **+** `kms:Decrypt` trên `alias/aws/ssm`. **Không** cấp `ssm:*` toàn account | `SecretSyncedError` / `AccessDenied` → pod `CreateContainerConfigError` |
| **ExternalDNS** *(dùng ở Day 8)* | `kube-system` | `route53:ChangeResourceRecordSets`, `ListHostedZones`, `ListResourceRecordSets` | Record DNS không tự tạo → phải sửa DNS tay mỗi buổi (**vi phạm tiêu chí 0 thao tác tay**) |

> 💡 **Tạo cả 4 role ngay ở Day 3** dù ExternalDNS đến Day 8 mới cài chart — **IAM role không tính tiền khi không dùng**.

### Day 4 — Deploy staging + Ingress ALB *(repo này)*

| Code tạo | Console → | Phải thấy |
|---|---|---|
| Image đã push | **ECR → repo → Images** | Tag = **git SHA** (7 hoặc 40 ký tự hex). 🔴 **Không được có tag `latest`** |
| ALB | **EC2 → Load Balancers** | **Đúng 1** ALB (không phải 2 — `group.name: badminton` gộp staging+prod) · Scheme **internet-facing** · DNS name khớp `kubectl get ingress -A` |
| Listener | ALB → tab **Listeners** | Day 4–7: **chỉ có `HTTP:80`**. Thấy 443 lúc này là ai đó đã kéo domain vào sớm |
| Attribute | ALB → **Attributes** | `idle_timeout.timeout_seconds = 300` (mặc định 60s **ngắt WebSocket chat** giữa buổi demo) |
| Target group | **EC2 → Target Groups** | Target type **`ip`** (là IP pod, không phải instance) · Health status **healthy** |
| PVC → EBS | **EC2 → Volumes** | Volume type **gp3**, State **`in-use`** |

**Kiến trúc image — Console không hiển thị rõ, phải dùng CLI:**
```bash
docker inspect <acct>.dkr.ecr.ap-southeast-1.amazonaws.com/user-service:<SHA> \
  --format '{{.Architecture}}'                       # PHẢI là amd64, không phải arm64
curl -s http://<ALB-DNS>/api/actuator/health         # 200
```

### Day 5 — CI/CD ▶ `../badmintonHub`

| Code tạo | Console/UI → | Phải thấy |
|---|---|---|
| OIDC provider **thứ hai** | **IAM → Identity providers** | ⚠️ Có **2** provider: cái của EKS (`oidc.eks…`) **và** `token.actions.githubusercontent.com`. Hai cái khác nhau hoàn toàn — rất hay nhầm là trùng |
| Role cho GitHub Actions | **IAM → Roles** → tab **Trust relationships** | Condition `token.actions.githubusercontent.com:sub` = `repo:<owner>/badmintonHub:*` |
| Repo secrets | GitHub → repo app → **Settings → Secrets and variables → Actions** | **5 secret**: ECR registry · `GITOPS_DEPLOY_KEY` · `SONAR_TOKEN` · `SLACK_WEBHOOK` · AWS OIDC role ARN. 🔴 **Không** có `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` — auth bằng OIDC, không lưu access key |
| Branch protection | GitHub → **Settings → Branches** | `main` protected, required checks = build + Sonar gate |
| Workflow chạy | GitHub → **Actions** | `ci.yml` + `terraform.yml` xanh |
| **Vòng lặp đã đóng** | GitHub → **repo gitops → Commits** | ✅ Có commit **tự động** sửa `values/<svc>-staging.yaml` sang SHA mới. **Đây mới là bằng chứng thật** rằng CI→GitOps đã nối — Actions xanh thôi chưa đủ |

> 🔴 **Lỗi tốn thời gian nhất của cả mô hình**: CI ghi sai tên file values. `values/<svc>-<env>.yaml` là **hợp đồng** với ArgoCD. Ghi sai tên → **CI vẫn xanh, commit vẫn vào repo, ArgoCD không đọc → không deploy gì và không báo lỗi ở đâu.** Luôn mở tab Commits của repo gitops mà đối chiếu đúng tên file.

### Day 6 — ArgoCD + External Secrets *(repo này)*

| Kiểm | Console → | Phải thấy |
|---|---|---|
| 22 param | **Systems Manager → Parameter Store** | 22 dòng `/badminton/{staging,prod}/*`, Type **SecureString** |
| **ESO thật sự đọc được** | **CloudTrail → Event history** → lọc *Event name* = `GetParameters` | Có event, User name = role IRSA của `external-secrets`. Đây là **cross-check độc lập với `kubectl`**: chứng minh IRSA + KMS + policy đều đúng, chứ không phải Secret cũ còn sót lại trong cụm |

```bash
kubectl get externalsecret -A                       # tất cả SecretSynced
kubectl get applications -n argocd -l env=staging   # ĐÚNG 9 app
argocd app list                                     # 20 app (18 child + infra + ingress), Synced/Healthy
```

### Day 8 — Domain + HTTPS

| Code tạo | Console → | Phải thấy |
|---|---|---|
| Hosted zone | **Route 53 → Hosted zones** | Zone của `<domain>` · 4 bản ghi NS |
| NS khớp | **Route 53 → Registered domains** → domain | Name servers **khớp đúng** 4 NS của hosted zone |
| ACM cert | **Certificate Manager** | `*.badminton.<domain>` · Status **Issued** |
| ⚠️ **Region của cert** | ACM — kiểm region góc phải | 🔴 **Phải là `ap-southeast-1`**, cùng region với ALB. Bẫy kinh điển: nhiều hướng dẫn nói ACM phải ở `us-east-1` — điều đó **chỉ đúng cho CloudFront**. Cert `us-east-1` gắn vào ALB Singapore thì không dùng được |
| Record của ExternalDNS | **Route 53 → hosted zone → Records** | A/ALIAS `staging.badminton.<domain>` + `prod.…` trỏ ALB · **TTL 60** (mặc định 300 → URL chết 5' đầu buổi demo vì cache resolver còn ALB cũ) |
| Listener HTTPS | **EC2 → Load Balancers → Listeners** | Nay có **`HTTPS:443`** cạnh `HTTP:80` |

```bash
dig NS <domain>                                                    # NS đã trỏ Route53 chưa
curl -sI https://staging.badminton.<domain>/api/actuator/health    # 200
curl -sI http://staging.badminton.<domain>                         # 301 → https
```

### 🔴 Thấy những thứ này trong Console = SAI thiết kế

| Thấy gì | Vì sao sai |
|---|---|
| **NAT Gateway** | Cố tình né — $45/tháng. Node ở public subnet với `map_public_ip_on_launch=true`, hoặc VPC endpoints (`ecr.api`, `ecr.dkr`, `s3`, `sts`, `logs`). Thiếu **cả hai** thì pod kẹt `ImagePullBackOff` |
| **2 ALB** | `group.name: badminton` phải gộp staging + prod vào 1 |
| **RDS / ElastiCache / MSK / DocumentDB / AmazonMQ** | Datastore chạy **in-cluster Bitnami**. Managed service = ngoài scope (Phụ lục B) và phá mô hình chi phí |
| **Tag `latest` trong ECR** | Image tag **phải** = git SHA, bất biến |
| **Cert của Let's Encrypt / cert-manager trong cụm** | ALB terminate TLS ở tầng AWS và **chỉ nhận cert ACM/IAM** — không đọc được K8s Secret. Gắn vào là **im lặng không có HTTPS** |

---

## §5 — Verify teardown: bill về ~0

Chạy runbook `.claude/rules/ephemeral-cost.md` §7.1 **đúng thứ tự** (xoá root app → **xoá PVC khi cụm còn sống** → xoá ingress → gỡ LB controller → `terraform destroy`), rồi kiểm:

### ☐ Phải về 0

| Console → | Phải thấy |
|---|---|
| **EKS → Clusters** | 0 |
| **EC2 → Instances** | 0 Running |
| **EC2 → Load Balancers** | 0 |
| **EC2 → Volumes** → lọc **State = `available`** | 🔴 **0** — đây là chỗ rò tiền |
| **VPC → NAT Gateways** | 0 |
| **EC2 → Elastic IPs** | 0 cái không associated (EIP mồ côi vẫn tính tiền) |

```bash
aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'   # phải RỖNG
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'                   # phải RỖNG
```

> 🔴 **Bỏ bước xoá PVC** (khi cụm còn sống) → reclaim policy `Delete` không ai gọi → **~40 GB volume mồ côi** (5 datastore × 2 env × 8 Gi) ≈ **$3.2/tháng chảy âm thầm**. Nhỏ, nhưng tích luỹ qua nhiều buổi và **không ai nhìn thấy**.

### ☐ Phải CÒN (đây là lý do rebuild chỉ mất ~15')

| Console → | Còn gì | Mất thì phải làm lại gì |
|---|---|---|
| **S3** | Bucket state | Terraform mất state → không destroy được stack cũ |
| **DynamoDB** | Bảng lock | — |
| **ECR** | 9 repo + image | **Build lại toàn bộ 9 image** |
| **Systems Manager → Parameter Store** | 22 param | **Nạp lại toàn bộ secret bằng tay** |
| **Route 53** | Hosted zone *(Day 8)* | Đổi NS lại + chờ 1–48h |
| **Certificate Manager** | ACM cert *(Day 8)* | Xin + validate lại cert |

### ☐ Hôm sau

**Billing and Cost Management → Cost Explorer** → granularity **Daily** → ngày demo có một cột nhỏ, ngày sau đó **gần 0**. Đây là xác nhận cuối cùng, đáng tin hơn mọi cảm giác.

> 💡 Tuỳ chọn giảm chi phí dài hạn: **ECR → repo → Lifecycle policy** → giữ 5 image gần nhất. Mỗi lần push thêm một SHA là thêm ~3 GB; con số "$0.30/tháng" trong §0 chỉ đúng cho **một** bộ tag.

---

## §6 — Bảng tra nhanh: cái gì tay, cái gì code

| Resource | Ai tạo | Sống sót `destroy`? | Tốn tiền khi cụm đã tắt? |
|---|---|---|---|
| AWS account · IAM user · Budget alert | 🖐 **Tay** | ✅ | Không |
| 22 SSM parameter | 🖐 **Tay** (1 lần) | ✅ | **Không** (standard = free) |
| Key Cloudinary / SendGrid / Google | 🖐 **Tay** (third-party) | ✅ | Không |
| GitHub repo · 5 Actions secret · branch protection | 🖐 **Tay** | ✅ | Không |
| Domain (đăng ký) | 🖐 **Tay** | ✅ | ~$13/năm |
| S3 · DynamoDB · **9 ECR repo** | Terraform `bootstrap/` | ✅ | ~**$0.30/tháng** (ECR) |
| Route53 zone · ACM cert *(Day 8)* | Terraform `bootstrap/` | ✅ | **$0.50/tháng** (zone) · ACM free |
| VPC · EKS · node group · OIDC · 4 IRSA role | Terraform `terraform/` | ❌ | Không |
| **ALB** | AWS LB Controller (từ Ingress) | ❌ | Không — *nếu* đã xoá Ingress trước khi destroy |
| **EBS volume** | EBS CSI (từ PVC) | ❌ | 🔴 **CÓ, nếu quên xoá PVC lúc cụm còn sống** |
| Image trong ECR | CI (app repo) | ✅ | Tính theo GB |
| Deployment · Service · Ingress · Secret | ArgoCD (đọc repo này) | ❌ | Không |

**Tiêu chí vàng — rebuild = 0 thao tác tay.** Sau `destroy` → `apply` → `bootstrap.sh`, bạn **không** được phải: nạp lại secret (ESO đọc SSM) · build lại image FE (same-origin) · sửa ConfigMap theo ALB DNS mới · sửa DNS/xin lại cert tay (ExternalDNS + ACM). Cột "Sống sót `destroy`" ở trên chính là cái bảo đảm điều đó.

---

## Đọc tiếp

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — bức tranh tổng quát hệ thống (hạ tầng · 1 ALB 2 namespace · secret/storage · vòng đời request)
- `Planning_CICD.md` — kế hoạch đầy đủ + prompt paste-ready mỗi Day (§5 tiền đề · §7 runbook · §8 chi phí)
- `.claude/rules/ephemeral-cost.md` · `secrets-eso.md` · `ingress-alb.md` — luật chi tiết
