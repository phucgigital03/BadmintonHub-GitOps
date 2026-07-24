# BadmintonHub GitOps — CLAUDE.md

Repo **desired-state (GitOps)** cho nền tảng BadmintonHub. **KHÔNG chứa source code ứng dụng** — chỉ Helm chart, values theo môi trường, ArgoCD Application, SealedSecrets. ArgoCD trong cụm EKS **watch repo này** và sync cụm về đúng trạng thái khai báo ở đây.

> Repo app (source Java/React, Dockerfile, Terraform, CI) = **`badmintonHub`** (folder sibling).
> Kế hoạch đầy đủ + lộ trình 7 ngày + prompt paste-ready mỗi Day: xem **`Planning_CICD.md`**.

## 🎯 Nguyên tắc hàng đầu — Demo ephemeral 5–10 phút
Cụm **chỉ sống đúng lúc demo**: `terraform apply` (~15') → **người dùng thật vào dùng 5–10 phút** (login → đặt sân → thanh toán → chat trên URL live) → `terraform destroy` (~10') → **bill ≈ vài xu/buổi**.
- Mọi thứ **tái lập 100% bằng code** (Terraform + GitOps + image ở ECR + state ở S3) → dựng lại nhanh, xoá sạch không tiếc.
- **KHÔNG giữ data lâu dài** (ephemeral, `ddl-auto` tạo schema rỗng mỗi lần). Muốn onboard user giữ data → **Phụ lục** `Planning_CICD.md` (RDS/Flyway/không teardown), ngoài scope.
- **Rẻ = kỷ luật teardown.** Quên tắt cả tháng ≈ $150–200; demo 3 giờ (spot, né NAT) ≈ dưới $1.

## Quan hệ 2 repo & phân chia sở hữu
- **`badmintonHub`** (app): CI build image → push ECR → **bump image tag** vào `values/*` của repo NÀY. Sở hữu: **Dockerfiles · `docker-compose.app.yml` · `terraform/` · `.github/workflows/`**.
- **`badmintonHub-gitops`** (repo này): ArgoCD đọc → deploy. **Đổi gì ở đây = đổi cụm.** Rollback = `git revert`. Sở hữu: **`charts/service/` · `values/` · `apps/` · `sealed-secrets/` · `infra/`**.
- Vòng lặp: CI (app repo) *ghi* tag → ArgoCD (đọc repo này) *sync*. **KHÔNG** chỉnh cụm bằng `kubectl` tay (self-heal ghi đè). **KHÔNG** vòng lặp CI-trigger-CI (tách 2 repo).

## Day nào làm ở repo nào (lộ trình 7 ngày)
| Day | Repo (mở Claude Code ở) | Deliverable chính |
|---|---|---|
| 1 | `badmintonHub` (app) | 8 Dockerfile Java + FE nginx + `.dockerignore` + `docker-compose.app.yml` |
| 2 | **`badmintonHub-gitops`** | `charts/service/` (reusable) + `values/<svc>.yaml` + `values/infra.yaml` → test trên **kind** (dev) |
| 3 | `badmintonHub` (app) | `terraform/` (VPC/EKS/ECR/IRSA + backend S3/DynamoDB) + add-on |
| 4 | **`badmintonHub-gitops`** | Deploy infra+app lên EKS `staging` + Ingress/TLS + FE per-env |
| 5 | `badmintonHub` (app) | `.github/workflows/ci.yml` + `terraform.yml` |
| 6 | **`badmintonHub-gitops`** | `apps/` ApplicationSet + cài ArgoCD + SealedSecrets + promote |
| 7 | **cả 2** | Observability (gitops manifests) + teardown/rebuild (`terraform destroy` ở app repo) |

> Repo này = **Day 2, 4, 6** (+ 7). Day 1, 3, 5 ở repo app.

## Cấu trúc repo (dựng dần theo Day)
```
charts/service/     # Day 2 — 1 Helm chart tái sử dụng cho MỌI service (Deployment+Service+probe+envFrom)
values/             # Day 2 — values theo (service × env): <svc>-staging.yaml, <svc>-prod.yaml
infra/              # Day 2/4 — values Bitnami (Postgres/Redis/Kafka/Mongo/RabbitMQ) + ingress
apps/               # Day 6 — ArgoCD Application/ApplicationSet (app-of-apps: staging + prod)
sealed-secrets/     # Day 6 — SealedSecret đã mã hoá (an toàn commit)
```
> Hiện repo **mới có `first commit`** (chỉ 2 doc này) — charts/apps **CHƯA dựng**. Đã có remote `github.com/phucgigital03/BadmintonHub-GitOps`.

## Quy ước (BẮT BUỘC)
- **Image tag = git SHA** (bất biến, KHÔNG `latest`). CI của app repo tự bump.
- **Promote staging → prod** = PR sửa `values/<svc>-prod.yaml` sang **đúng SHA** đã verify ở staging. KHÔNG build lại.
- **Secret**: chỉ commit **SealedSecret** (`kubeseal`). **TUYỆT ĐỐI không commit secret thô / mật khẩu.**
- **ArgoCD**: app-of-apps (ApplicationSet), `syncPolicy.automated` (prune + selfHeal).
- Mỗi service **1 replica** (demo ephemeral). Datastore **in-cluster Bitnami** (ghim chart version). Giữ **Eureka**. TLS **cert-manager** (hoặc DNS ALB thô cho buổi 5–10').
- Commit message: **KHÔNG** thêm `Co-Authored-By` (giống repo app).

## Bảng service → port → datastore (đủ để viết values, khỏi cần mở repo app)
| Service | Port | Postgres | Redis | Kafka | Mongo | RabbitMQ |
|---|---|---|:--:|:--:|:--:|:--:|
| eureka-server | 8761 | — | — | — | — | — |
| api-gateway | 3000 | — | ✅ | — | — | — |
| user-service | 3001 | user_db | ✅ | — | — | — |
| court-service | 3002 | court_db | ✅ | ✅ | — | — |
| booking-service | 3003 | booking_db | ✅ | ✅ | — | — |
| payment-service | 3006 | payment_db | ✅ | ✅ | — | — |
| escrow-service | 3007 | escrow_db | — | ✅ | — | — |
| chat-service | 3011 | — | ✅ | — | chat_db | ✅ STOMP 61613 |
| frontend | 80 | — | — | — | — | — |

- **= 9 image deploy.** `ai-service` (3010, **Python** · Ollama/Gemini) = **NGOÀI scope demo** (nặng RAM Free-Tier) → xem Phụ lục `Planning_CICD.md`. `matchmaking`/`coach`/`notification`/`event` = scaffold rỗng, không deploy.
- Health probe mọi service: `GET /actuator/health`.
- `SPRING_PROFILES_ACTIVE=prod` → payment/chat **bắt buộc** có `CLOUDINARY_*` (thiếu = fail boot, by design).
- DNS in-cluster (namespace data): `postgresql.<data-ns>.svc.cluster.local:5432` (1 instance / 5 DB) · `redis-master...:6379` · `kafka...:9092` · `mongodb...:27017/chat_db` · `rabbitmq...:61613` (STOMP) · `eureka-server.<app-ns>...:8761`. Creds thật: `RABBITMQ_USER=badminton`.

## Môi trường
- **staging** + **prod** = 2 namespace trên MỘT cụm EKS. **dev** = kind local (Day 2).
- Namespace: app = `staging`/`prod` · data = `data-staging`/`data-prod` · `argocd`.

## Cách làm việc ở repo này
- Sửa values/chart/app → PR → merge → ArgoCD tự sync. KHÔNG chạy service Spring ở đây (không có code).
- Việc = YAML / Helm / ArgoCD. Nguồn thiết kế + prompt paste-ready mỗi Day = **`Planning_CICD.md`**.
