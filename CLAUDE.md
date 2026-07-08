# BadmintonHub GitOps — CLAUDE.md

Repo **desired-state (GitOps)** cho nền tảng BadmintonHub. **KHÔNG chứa source code ứng dụng** — chỉ Helm chart, values theo môi trường, ArgoCD Application, SealedSecrets. ArgoCD trong cụm EKS **watch repo này** và sync cụm về đúng trạng thái khai báo ở đây.

> Repo app (source Java/React, Dockerfile, Terraform, CI) = **`badmintonHub`** (folder sibling).
> Thiết kế đầy đủ + lộ trình 7 ngày: xem **`Planning_CICD.md`** (đã copy vào repo này).

## Quan hệ 2 repo
- **`badmintonHub`** (app): CI build image → push ECR → **bump image tag** vào `values/*` của repo NÀY.
- **`badmintonHub-gitops`** (repo này): ArgoCD đọc → deploy. **Đổi gì ở đây = đổi cụm.** Rollback = `git revert`.
- Vòng lặp: CI ghi tag → ArgoCD sync. **KHÔNG** chỉnh cụm bằng `kubectl` tay (self-heal sẽ ghi đè).

## Cấu trúc repo (sẽ dựng ở Day 6)
```
charts/service/     # 1 Helm chart tái sử dụng cho MỌI service (Deployment+Service+probe+envFrom)
values/             # values theo (service × env): <svc>-staging.yaml, <svc>-prod.yaml
apps/               # ArgoCD Application (app-of-apps: staging + prod)
sealed-secrets/     # SealedSecret đã mã hoá (an toàn commit)
infra/              # values Bitnami (Postgres/Redis/Kafka/Mongo/RabbitMQ) + ingress
```

## Quy ước (BẮT BUỘC)
- **Image tag = git SHA** (bất biến, KHÔNG `latest`). CI của app repo tự bump.
- **Promote staging → prod** = PR sửa `values/<svc>-prod.yaml` sang **đúng SHA** đã verify ở staging. KHÔNG build lại.
- **Secret**: chỉ commit **SealedSecret** (`kubeseal`). **TUYỆT ĐỐI không commit secret thô / mật khẩu.**
- **ArgoCD**: app-of-apps, `syncPolicy.automated` (prune + selfHeal).
- Mỗi service **1 replica** (demo ephemeral). Datastore **in-cluster Bitnami**. Giữ **Eureka**. TLS **cert-manager**.
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

- Health probe mọi service: `GET /actuator/health`.
- `SPRING_PROFILES_ACTIVE=prod` → payment/chat **bắt buộc** có `CLOUDINARY_*` (thiếu = fail boot, by design).
- DNS in-cluster: `postgresql.<data-ns>.svc.cluster.local`, `redis-master...`, `kafka...`, `mongodb...`, `rabbitmq...`, `eureka-server.<app-ns>...:8761`.

## Môi trường
- **staging** + **prod** = 2 namespace trên MỘT cụm EKS. **dev** = kind local (ở repo app).
- Namespace: app = `staging`/`prod` · data = `data-staging`/`data-prod` · `argocd`.

## Cách làm việc ở repo này
- Sửa values/chart/app → PR → merge → ArgoCD tự sync. KHÔNG chạy service Spring ở đây (không có code).
- Việc = YAML / Helm / ArgoCD. Nguồn thiết kế = `Planning_CICD.md`.
