# BadmintonHub GitOps — CLAUDE.md

Repo **desired-state (GitOps)** cho nền tảng BadmintonHub. **KHÔNG chứa source code ứng dụng** — chỉ Helm chart, values theo môi trường, ArgoCD Application, ExternalSecret. ArgoCD trong cụm EKS **watch repo này** và sync cụm về đúng trạng thái khai báo ở đây.

> Repo app (source Java/React, Dockerfile, Terraform, CI) = **`badmintonHub`** (folder sibling).
> Kế hoạch đầy đủ + lộ trình 7 ngày (+ Day 8 gắn domain) + prompt paste-ready mỗi Day: xem **`Planning_CICD.md`**.
> Bức tranh tổng quát hệ thống (hạ tầng AWS · 1 ALB 2 namespace · secret/storage · vòng đời request & buổi demo): xem **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)**.
> Thao tác tay phải tự làm (AWS Console · GitHub · third-party API key · 22 SSM param) + bản đồ verify Console theo Day: xem **[`docs/MANUAL-SETUP.md`](docs/MANUAL-SETUP.md)**.

## Rules Index

Rule chi tiết nằm ở `.claude/rules/`. Hai file đầu **luôn đọc**; còn lại đọc khi động vào thư mục tương ứng.

| File | Trigger | Covers |
|---|---|---|
| [`gitops-workflow.md`](.claude/rules/gitops-workflow.md) | **always** | 2 repo · Day→repo · 8 never-violate · hợp đồng tên values · promote · rollback · commit |
| [`ephemeral-cost.md`](.claude/rules/ephemeral-cost.md) | **always** | Tiêu chí vàng 0 thao tác tay · runbook teardown §7.1 · PVC mồ côi · chi phí |
| [`helm-chart.md`](.claude/rules/helm-chart.md) | `charts/**`, `values/**` | Chart generic cho cả 9 svc · probe liveness/readiness tách rời · graceful shutdown · không PDB |
| [`values-env-map.md`](.claude/rules/values-env-map.md) | `values/*.yaml` | Bảng svc→port→datastore→probe · env→ConfigMap/Secret · DNS in-cluster · bẫy đã biết |
| [`bitnami-datastores.md`](.claude/rules/bitnami-datastores.md) | `infra/**`, `values/infra*.yaml` | 5 override bắt buộc (Redis/Kafka/Mongo/RabbitMQ/PG) · registry `bitnamilegacy` |
| [`argocd-appset.md`](.claude/rules/argocd-appset.md) | `apps/**` | ApplicationSet matrix · multi-source `$values` · labels · `CreateNamespace` · debug |
| [`secrets-eso.md`](.claude/rules/secrets-eso.md) | `external-secrets/**` | ESO + SSM · vì sao không SealedSecrets · danh sách param · thứ tự bootstrap |
| [`ingress-alb.md`](.claude/rules/ingress-alb.md) | `infra/**ingress**` | 2 công tắc host/cert · `group.name` · `idle_timeout` · TTL 60 · không cert-manager · FE same-origin |

**Slash command** ở `.claude/commands/`: `/day <N>` · `/done-check <N>` · `/self-review` · `/debug` · `/helm-verify` · `/new-values <svc>` · `/promote <svc>` · `/demo-check` · `/teardown-check` · `/explain-manifest` · `/handoff`.

## 🎯 Nguyên tắc hàng đầu — Demo ephemeral 5–10 phút
Cụm **chỉ sống đúng lúc demo**: `terraform apply` (~15') → **người dùng thật vào dùng 5–10 phút** (login → đặt sân → thanh toán → chat trên URL live) → `terraform destroy` (~10') → **bill ≈ vài xu/buổi**.
- Mọi thứ **tái lập 100% bằng code** (Terraform + GitOps + image ở ECR + state ở S3 + **secret ở SSM**) → dựng lại nhanh, xoá sạch không tiếc.
- 🎯 **Tiêu chí vàng của rebuild = 0 THAO TÁC TAY.** `destroy` → `apply` → `bootstrap.sh` → e2e xanh mà **không** phải: nạp lại secret (ESO đọc SSM) · build lại image FE (same-origin) · sửa ConfigMap theo ALB DNS mới · **sửa DNS/xin lại cert tay** (ExternalDNS + ACM, từ Day 8). Bất cứ thiết kế nào buộc làm 1 trong 4 việc đó là **sai** với repo này.
- **KHÔNG giữ data lâu dài** (ephemeral, `ddl-auto` tạo schema rỗng mỗi lần). Muốn onboard user giữ data → **Phụ lục** `Planning_CICD.md` (RDS/Flyway/không teardown), ngoài scope.
- **Rẻ = kỷ luật teardown.** Một buổi trọn gói (apply+demo+destroy) ≈ $0.15; quên tắt cả tháng ≈ $180. Teardown **phải xoá PVC khi cụm còn sống**, không thì EBS mồ côi vẫn tính tiền.

## Quan hệ 2 repo & phân chia sở hữu
- **`badmintonHub`** (app): CI build image → push ECR → **bump image tag** vào `values/*` của repo NÀY. Sở hữu: **Dockerfiles · `docker-compose.app.yml` · `terraform/` · `.github/workflows/`**.
- **`badmintonHub-gitops`** (repo này): ArgoCD đọc → deploy. **Đổi gì ở đây = đổi cụm.** Rollback = `git revert`. Sở hữu: **`charts/service/` · `values/` · `apps/` · `external-secrets/` · `infra/`**.
- Vòng lặp: CI (app repo) *ghi* tag → ArgoCD (đọc repo này) *sync*. **KHÔNG** chỉnh cụm bằng `kubectl` tay (self-heal ghi đè). **KHÔNG** vòng lặp CI-trigger-CI (tách 2 repo).

## Day nào làm ở repo nào (lộ trình 7 ngày + Day 8 gắn domain)
| Day | Repo (mở Claude Code ở) | Deliverable chính |
|---|---|---|
| 1 | `badmintonHub` (app) | 8 Dockerfile Java + FE nginx + `.dockerignore` + `docker-compose.app.yml` |
| 2 | **`badmintonHub-gitops`** | `charts/service/` (reusable, dùng cho **cả 9** svc kể cả FE) + `values/<svc>-<env>.yaml` + `values/infra.yaml` → test trên **kind** (dev) |
| 3 | `badmintonHub` (app) | `terraform/bootstrap/` (S3+DynamoDB+9 ECR, không destroy) + `terraform/` (VPC/EKS/IRSA) + add-on |
| 4 | **`badmintonHub-gitops`** | Deploy infra+app lên EKS `staging` + **Ingress http trên ALB DNS** + **FE same-origin (1 image mọi env)** |
| 5 | `badmintonHub` (app) | `.github/workflows/ci.yml` + `terraform.yml` |
| 6 | **`badmintonHub-gitops`** | `apps/` ApplicationSet + cài ArgoCD + **External Secrets (SSM)** + promote |
| 7 | **cả 2** | Observability (gitops manifests) + teardown/rebuild (`terraform destroy` ở app repo) |
| **8** | **cả 2** | *(T-2 trước demo)* **Gắn domain + HTTPS**: Route53 zone + ACM wildcard vào `bootstrap/` (app) · điền 2 values ingress + `FRONTEND_URL` (repo này) |

> Repo này = **Day 2, 4, 6** (+ 7, 8). Day 1, 3, 5 ở repo app.
>
> 🚩 **Day 1–7 chạy hoàn toàn KHÔNG có domain** — http trên ALB DNS thô. Domain là **add-on cắm vào sau** ở Day 8, và diff của nó đã được thiết kế trước để chỉ còn **2 dòng values × 2 env**. Đừng đưa domain/TLS vào bất kỳ Day nào trước 8.

## Cấu trúc repo (dựng dần theo Day)
```
charts/service/     # Day 2 — 1 Helm chart tái sử dụng cho CẢ 9 service kể cả frontend
                    #          (Deployment + Service + probe + envFrom; generic: port/probePath/envFrom optional)
values/             # Day 2 — values theo (service × env): <svc>-dev.yaml, <svc>-staging.yaml, <svc>-prod.yaml
infra/              # Day 2/4 — values Bitnami (Postgres/Redis/Kafka/Mongo/RabbitMQ) + ingress
                    #          ingress-<env>.yaml mang 2 CÔNG TẮC mặc định "": host + certificateArn
                    #          rỗng = http/ALB DNS (Day 4–7) · điền = HTTPS/domain (Day 8). ĐỪNG hardcode Ingress.
apps/               # Day 6 — ArgoCD Application/ApplicationSet (app-of-apps: staging + prod)
external-secrets/   # Day 6 — ExternalSecret: CHỈ ref tên param SSM, không chứa giá trị
docs/               # Tài liệu — ARCHITECTURE.md: bức tranh tổng quát hệ thống (góc nhìn hạ tầng)
                    #            MANUAL-SETUP.md: checklist thao tác tay (account/IAM/API key/SSM param/
                    #            GitHub secret) + bản đồ verify AWS Console theo Day + verify bill về 0
```
> Hiện repo **mới có `first commit`** (chỉ 2 doc này) — charts/apps **CHƯA dựng**. Đã có remote `github.com/phucgigital03/BadmintonHub-GitOps`.

## Quy ước (BẮT BUỘC)
- **Image tag = git SHA** (bất biến, KHÔNG `latest`). CI của app repo tự bump.
- **Tên file values = `values/<svc>-<env>.yaml`** (`env ∈ dev|staging|prod`). Đây là **hợp đồng với CI**: đặt sai tên thì CI vẫn xanh, commit vẫn vào repo, nhưng ArgoCD không đọc → **không deploy gì và không báo lỗi ở đâu**.
- **Promote staging → prod** = PR sửa `values/<svc>-prod.yaml` sang **đúng SHA** đã verify ở staging. KHÔNG build lại.
- **Secret**: **External Secrets Operator + SSM Parameter Store**. Chỉ commit `ExternalSecret` **ref tên param** (`/badminton/<env>/*`). **TUYỆT ĐỐI không commit secret thô / mật khẩu.** KHÔNG dùng SealedSecrets — keypair của nó khoá theo cụm, mà cụm bị destroy mỗi buổi.
- **ArgoCD**: app-of-apps (ApplicationSet), `syncPolicy.automated` (prune + selfHeal) + `syncOptions: [CreateNamespace=true]` + template có `labels: {env, svc}`.
- **Image phải `linux/amd64`**: máy dev arm64, node EKS amd64 → build đẩy ECR luôn dùng `docker buildx --platform linux/amd64`.
- Mỗi service **1 replica** (demo ephemeral). Datastore **in-cluster Bitnami** (ghim chart version). Giữ **Eureka**.
- **TLS/domain**: Day 1–7 **http qua ALB DNS thô** · Day 8 **HTTPS bằng ACM** (+ ExternalDNS giữ record tự động). **KHÔNG dùng cert-manager/Let's Encrypt** — ALB terminate TLS ở tầng AWS và chỉ nhận cert từ **ACM/IAM**, *không đọc được K8s Secret* nơi cert-manager cất cert → gắn vào là im lặng không có HTTPS. (Phụ: LE giới hạn 5 cert/tuần cùng hostname, mà cụm này rebuild mỗi buổi.)
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
- **Health probe**: `GET /actuator/health/liveness` + `/actuator/health/readiness` (bật bằng env `MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED=true`). **KHÔNG dùng `/actuator/health` cho liveness** — nó là composite gộp db+redis+mongo+Eureka, một nhịp Redis lỗi là K8s restart pod → cascade. `frontend` (nginx) dùng `/`.
- `SPRING_PROFILES_ACTIVE=prod` → payment/chat **bắt buộc** có `CLOUDINARY_*` (thiếu = fail boot, by design — `CloudinaryProdGuard` `@Profile("prod")`).
- DNS in-cluster (namespace data): `postgresql.<data-ns>.svc.cluster.local:5432` (1 instance / 5 DB) · `redis-master...:6379` · `kafka...:9092` · `mongodb...:27017/chat_db` · `rabbitmq...:61613` (STOMP) · `eureka-server.<app-ns>...:8761`. Creds thật: `RABBITMQ_USER=badminton`.
- ⚠️ **Default của Bitnami đánh nhau với app — phải override** (chi tiết §Day 2 `Planning_CICD.md`):
  - **Redis `auth.enabled=false`** — app chỉ có `host`/`port`, không có field password → auth bật = `NOAUTH`, và vì gateway rate-limit áp mọi route nên **toàn bộ request 500**.
  - **Kafka** `sasl.enabled=false` + `autoCreateTopicsEnable=true` — code dùng ~17 topic theo tên, không có bean `NewTopic`.
  - **Mongo** URI cần `?authSource=admin` (root user ở db `admin`) hoặc khai user scoped.
  - **RabbitMQ** cần `extraPlugins=rabbitmq_stomp` **+** `extraContainerPorts` **+** `service.extraPorts` cho 61613 **+** `auth.username=badminton`.
  - **Postgres** dùng superuser `postgres` (`ddl-auto=update` cần quyền tạo schema; app chỉ có 1 cặp user/pass cho cả 5 DB).
- **FE same-origin**: FE gọi `/api` tương đối và derive WS từ `window.location` → 1 image FE cho mọi env, ALB DNS đổi sau mỗi `apply` không cần build lại. Chỉ `VITE_GOOGLE_CLIENT_ID` còn bake.

## Môi trường
- **staging** + **prod** = 2 namespace trên MỘT cụm EKS. **dev** = kind local (Day 2).
- Namespace: app = `staging`/`prod` · data = `data-staging`/`data-prod` · `argocd`.

## Cách làm việc ở repo này
- Sửa values/chart/app → PR → merge → ArgoCD tự sync. KHÔNG chạy service Spring ở đây (không có code).
- Việc = YAML / Helm / ArgoCD. Nguồn thiết kế + prompt paste-ready mỗi Day = **`Planning_CICD.md`**.

---

## Session Progress

> Phần này được cập nhật tự động bằng lệnh `/handoff` cuối mỗi phiên làm việc.
> Chỉ phản ánh **việc đang thực sự làm** ở repo này — kế hoạch chưa động tới thì để trong `Planning_CICD.md`.

**Cập nhật lần cuối**: 2026-07-27 (dựng `.claude/` cho repo gitops: **8 rule** + **11 slash command** + Rules Index + mục Session Progress này. Rule adapt sang domain GitOps — không copy rule Java/Kafka/Redis từ repo app vì repo này không có source code.)

### ✅ Đã hoàn thành
- `CLAUDE.md` + `Planning_CICD.md` (Day 1→8, prompt paste-ready mỗi Day, runbook teardown/rebuild/demo §7).
- `.claude/rules/` **8 file** + `.claude/commands/` **11 command** (xem §Rules Index).
- Remote: `github.com/phucgigital03/BadmintonHub-GitOps`.

### 🔄 Đang làm
- *(chưa có — repo mới chỉ có doc + `.claude/`)*

### 📋 Việc tiếp theo (theo thứ tự ưu tiên)
1. **Day 1 — Containerize**: mở Claude Code ở **`../badmintonHub` (app repo)**, paste prompt §Day 1 của `Planning_CICD.md`. **Không làm ở repo này.**
2. **Day 2 — Helm + kind** (repo NÀY): `charts/service/` + `values/<svc>-<env>.yaml` (9 × 3) + `values/infra.yaml`. Gõ `/day 2`.
3. Day 3 (app repo) → Day 4 (repo này) → Day 5 (app repo) → Day 6 (repo này) → Day 7, 8 (cả 2).

### 🧠 Quyết định kỹ thuật đã chốt
- **1 chart `charts/service/` cho cả 9 service kể cả `frontend`** — điều kiện để ApplicationSet matrix của Day 6 dùng được.
- **Secret = ESO + SSM, KHÔNG SealedSecrets** — keypair của SealedSecrets khoá theo cụm, mà cụm destroy mỗi buổi.
- **HTTPS = ACM, KHÔNG cert-manager** — ALB chỉ nhận cert ACM/IAM, không đọc K8s Secret.
- **Domain là add-on của Day 8**, Day 1–7 chạy http trên ALB DNS thô; Ingress template hoá sẵn 2 công tắc `host`/`certificateArn`.
- **Probe tách `liveness`/`readiness`**, không dùng `/actuator/health` composite.

### 💬 Claude đã làm trong phiên này
Dựng `.claude/rules/` + `.claude/commands/` cho repo gitops theo cùng tổ chức với repo app: port `handoff.md`, `done-check.md`, `self-review.md`, `debug.md`, `explain-*.md` sang domain GitOps và thêm command đặc thù (`/day`, `/helm-verify`, `/new-values`, `/promote`, `/demo-check`, `/teardown-check`). Nội dung rule rút từ `Planning_CICD.md` (Day 2/4/6/7/8 + §7 runbook) nên không phải mở lại doc 1200 dòng mỗi phiên.
