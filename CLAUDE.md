# BadmintonHub GitOps — CLAUDE.md

Repo **desired-state (GitOps)** cho nền tảng BadmintonHub. **KHÔNG chứa source code ứng dụng** — chỉ Helm chart, values theo môi trường, ArgoCD Application, ExternalSecret. ArgoCD trong cụm EKS **watch repo này** và sync cụm về đúng trạng thái khai báo ở đây.

> Repo app (source Java/React, Dockerfile, Terraform, CI) = **`badmintonHub`** (folder sibling).
> ⚠️ Cần dữ kiện thuộc repo app (Day 1/3/5 đã ra gì · tên biến env · ECR repo URL · output Terraform):
> **hỏi user** — user đã handoff đủ ở `../badmintonHub/CLAUDE.md`. Đừng copy/snapshot sang repo này.
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
charts/service/     # Day 2 ✅ — 1 Helm chart tái sử dụng cho CẢ 9 service kể cả frontend
                    #            (Deployment + Service + probe + envFrom optional; tên object lấy từ
                    #             nameOverride, KHÔNG từ Release.Name — xem §Bẫy tên Service)
charts/platform/    # Day 2 ✅ — object dùng chung 1 namespace app: ConfigMap app-config (Day 2),
                    #            Ingress ALB (Day 4), ExternalSecret (Day 6)
values/             # Day 2 ✅ — 27 file <svc>-<env>.yaml (9 svc × 3 env)
infra/              # Day 2 ✅ — umbrella chart 5 datastore Bitnami (GHIM version) → ns data-<env>
                    #            values/infra-<env>.yaml   : override datastore
                    #            values/platform-<env>.yaml: env của app-config (+ Day 4 thêm 2 CÔNG TẮC
                    #                                        ingress host/certificateArn, mặc định "")
scripts/            # Day 2 ✅ — kind-up.sh · kind-secret.sh · kind-deploy.sh
apps/               # Day 6 — ArgoCD Application/ApplicationSet (app-of-apps: staging + prod)
external-secrets/   # Day 6 — ExternalSecret: CHỈ ref tên param SSM, không chứa giá trị
docs/               # Tài liệu — ARCHITECTURE.md: bức tranh tổng quát hệ thống (góc nhìn hạ tầng)
                    #            MANUAL-SETUP.md: checklist thao tác tay (account/IAM/API key/SSM param/
                    #            GitHub secret) + bản đồ verify AWS Console theo Day + verify bill về 0
```
Remote: `github.com/phucgigital03/BadmintonHub-GitOps`.

### 🔴 Bẫy tên Service — lý do chart không dùng `.Release.Name`
Day 6 ArgoCD đặt release name = `<svc>-<env>` (vd `user-service-staging`). Nếu chart đặt tên object theo release name thì Service thành `user-service-staging`, và: `EUREKA_URL` trỏ `eureka-server.<ns>.svc.cluster.local` → **NXDOMAIN, mất service discovery** · nginx trong image FE proxy `/api` sang host `api-gateway` → **502** · Ingress Day 4 khai `backend.service.name: api-gateway`/`frontend` → **không match**.
→ Mọi `values/<svc>-<env>.yaml` **bắt buộc** có `nameOverride: <svc>`; chart `required` nó.

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
| user-service | 3001 | user_db | ✅ | ✅ | — | — |
| court-service | 3002 | court_db | ✅ | ✅ | — | — |
| booking-service | 3003 | booking_db | ✅ | ✅ | — | — |
| payment-service | 3006 | payment_db | ✅ | ✅ | — | — |
| escrow-service | 3007 | escrow_db | — | ✅ | — | — |
| chat-service | 3011 | — | ✅ | — | chat_db | ✅ STOMP 61613 |
| frontend | 80 | — | — | — | — | — |

- **= 9 image deploy.** `ai-service` (3010, **Python** · Ollama/Gemini) = **NGOÀI scope demo** (nặng RAM Free-Tier) → xem Phụ lục `Planning_CICD.md`. `matchmaking`/`coach`/`notification`/`event` = scaffold rỗng, không deploy.
- **Health probe**: liveness `GET /actuator/info` · readiness `GET /actuator/health` · `frontend` (nginx) dùng `/`.
  🔴 **KHÔNG dùng `/actuator/health/liveness`** dù đã set `MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED=true`: đo thật trên kind, `SecurityConfig` của app chỉ `permitAll` đúng 2 path **literal** `/actuator/health` và `/actuator/info`, mọi sub-path trả **403** (không phải 404) → **pod không bao giờ Ready**, đúng với cả 7 service Java có Spring Security.
  Nguyên tắc gốc vẫn được giữ: **liveness không được phụ thuộc datastore** — `/actuator/info` thoả điều đó còn chặt hơn; composite dùng cho **readiness** thì an toàn vì chỉ rút pod khỏi Endpoints chứ không restart.
  📌 **TODO repo app**: thêm `/actuator/health/**` vào `permitAll` (1 chỗ ở `common-security`), build lại 8 image, rồi đổi probe về đúng nhóm liveness/readiness.
- `SPRING_PROFILES_ACTIVE=prod` → payment/chat **bắt buộc** có `CLOUDINARY_*` (thiếu = fail boot, by design — `CloudinaryProdGuard` `@Profile("prod")`).
- DNS in-cluster (namespace data): `postgresql.<data-ns>.svc.cluster.local:5432` (1 instance / 5 DB) · `redis-master...:6379` · `kafka...:9092` · `mongodb...:27017/chat_db` · `rabbitmq...:61613` (STOMP) · `eureka-server.<app-ns>...:8761`. Creds thật: `RABBITMQ_USER=badminton`.
- ⚠️ **Default của Bitnami đánh nhau với app — phải override** (chi tiết §Day 2 `Planning_CICD.md`):
  - **Redis `auth.enabled=false`** — app chỉ có `host`/`port`, không có field password → auth bật = `NOAUTH`, và vì gateway rate-limit áp mọi route nên **toàn bộ request 500**.
  - **Kafka** tắt SASL bằng `listeners.{client,controller,interbroker}.protocol=PLAINTEXT` + bật auto-create qua `controller.overrideConfiguration.auto.create.topics.enable` — code dùng ~17 topic theo tên, không có bean `NewTopic`. *(Chart 32.x đã bỏ `sasl.enabled` và `autoCreateTopicsEnable`; key sai bị Helm bỏ qua trong im lặng.)*
  - **Mongo** URI cần `?authSource=admin` (root user ở db `admin`) hoặc khai user scoped.
  - **RabbitMQ** cần **5** thứ cho STOMP: `extraPlugins=rabbitmq_stomp` + `extraContainerPorts` + `service.extraPorts` cho 61613 + `auth.username=badminton` + **`networkPolicy.extraIngress` mở 61613** (NetworkPolicy mặc định của chart chỉ cho 4369/5672/5671/25672/15672 → cổng phụ bị chặn trong im lặng, triệu chứng là *timeout* chứ không phải *refused*).
  - **Postgres** dùng superuser `postgres` (`ddl-auto=update` cần quyền tạo schema; app chỉ có 1 cặp user/pass cho cả 5 DB).
  - **Registry**: `image.repository=bitnamilegacy/<img>` **+ `global.security.allowInsecureImages=true`** (thiếu cờ này chart chặn render), và chọn chart version có **tag tường minh** — bản mới nhất trỏ `tag: latest`.
  - **MongoDB Bitnami chỉ có amd64** → kind trên Apple Silicon phải dùng `mongodbOss` (image `mongo:8.0`, multi-arch). EKS amd64 vẫn dùng chart Bitnami.
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

**Cập nhật lần cuối**: 2026-07-31 (**Day 2**: dựng `charts/service/` + `charts/platform/` + `infra/` umbrella + 27 values + scripts kind; deploy thật lên kind và sửa 5 chỗ mà bản thiết kế trên giấy sai.)

### ✅ Đã hoàn thành
- `CLAUDE.md` + `Planning_CICD.md` (Day 1→8, prompt paste-ready mỗi Day, runbook teardown/rebuild/demo §7).
- `.claude/rules/` **8 file** + `.claude/commands/` **11 command** (xem §Rules Index).
- **Day 2** — `charts/service/` (generic, render được cả `frontend` lẫn `eureka-server`) · `charts/platform/` (ConfigMap `app-config`) · `infra/` umbrella 5 datastore Bitnami **đã ghim version** · **27** `values/<svc>-<env>.yaml` · `scripts/kind-*.sh` · `.env.example` + `.gitignore`.
- `helm lint` xanh 27/27; `helm template` render đúng cho cả 3 env.
- Trên kind: **5/5 datastore Running**, Redis trả `PONG` (không NOAUTH), Postgres có đủ 5 DB, RabbitMQ mở `stomp:61613` + plugin `rabbitmq_stomp` bật.

- **Trên kind, đã chạy thật**: cả **9/9 service đều Ready được**; `scripts/kind-verify.sh` **13/14 xanh**; e2e qua `api-gateway`: `register` 201 · `login` trả JWT · `/api/clubs` 200 (có seed data) · `/api/clubs/{id}/courts` 200 · `/api/bookings` 200 · Kafka consumer connected · Eureka nhận đủ đăng ký.

### 🔄 Đang làm
- Đóng nốt Day 2: e2e phần `thanh toán → chat` (cần lượt 2 vì máy chỉ gánh ~6 service cùng lúc).

### 📋 Việc tiếp theo (theo thứ tự ưu tiên)
1. **Đóng nốt Day 2**: e2e trên kind + 4 check bẫy P0.
2. **Day 3 — EKS bằng Terraform**: mở Claude Code ở **`../badmintonHub` (app repo)**. **Không làm ở repo này.**
3. **Day 4** (repo này): điền ECR URL + SHA thật vào 18 values `staging`/`prod` (đang là placeholder), thêm `templates/ingress.yaml` vào `charts/platform/`, và **xác minh `WebSocketConfig` của chat-service** (xem 🚩 dưới).
4. Day 5 (app repo) → Day 6 (repo này) → Day 7, 8 (cả 2).

### 🚩 Việc BẮT BUỘC làm ở Day 4 — không được quên
`FRONTEND_URL` **không chỉ** dùng cho link email: `chat-service` nạp nó vào `app.frontend-url` → `WebSocketConfig.setAllowedOrigins()` để validate Origin của WS handshake. ALB DNS đổi sau mỗi `terraform apply` → **nếu không nhận wildcard thì mỗi buổi demo phải sửa ConfigMap**, phá tiêu chí vàng "rebuild 0 thao tác tay". Day 4 phải đọc `chat-service/.../WebSocketConfig.java` xem dùng được `setAllowedOriginPatterns("*")` không.

### 🧠 Quyết định kỹ thuật đã chốt
- **1 chart `charts/service/` cho cả 9 service kể cả `frontend`** — điều kiện để ApplicationSet matrix của Day 6 dùng được.
- **Tên object lấy từ `nameOverride`, KHÔNG từ `.Release.Name`** — xem §Bẫy tên Service.
- **Toàn bộ biến non-secret nằm ở MỘT ConfigMap `app-config`/namespace** (kể cả 5 `DB_*_URL`) → 27 file values rất mỏng, ít chỗ sai.
- **Secret = ESO + SSM, KHÔNG SealedSecrets** — keypair của SealedSecrets khoá theo cụm, mà cụm destroy mỗi buổi. Day 2 trên kind tạm dùng `scripts/kind-secret.sh` sinh từ `.env`; tên target Secret giữ nguyên `app-secrets` nên Day 6 đổi sang ESO không phải sửa values.
- **HTTPS = ACM, KHÔNG cert-manager** — ALB chỉ nhận cert ACM/IAM, không đọc K8s Secret.
- **Domain là add-on của Day 8**, Day 1–7 chạy http trên ALB DNS thô.
- **Probe tách `liveness`/`readiness`** + **`timeoutSeconds` khai tường minh** (mặc định 1s là quá ngắn cho actuator).

### 💬 Claude đã làm trong phiên này
Dựng toàn bộ Day 2 rồi **deploy thật lên kind**. Chính việc chạy thật lộ ra 9 chỗ bản thiết kế trên giấy sai — tất cả đã sửa vào `.claude/rules/` kèm cách chẩn đoán:

**Sai ở bảng env / doc**
1. `user-service` **có** Kafka (bảng ghi "—").
2. `FRONTEND_URL` còn là **WS allowed-origin** của chat-service, không chỉ link email → việc bắt buộc của Day 4.

**Sai ở override Bitnami**
3. Kafka chart 32.x **bỏ** `sasl.enabled` + `autoCreateTopicsEnable`; Helm bỏ qua key sai **trong im lặng** → phải kiểm `server.properties` trên broker, không phải YAML đã render.
4. `bitnamilegacy/mongodb` **chỉ có amd64** → kind arm64 dùng `mongodbOss` (`mongo:8.0`); chart cần `global.security.allowInsecureImages=true`.
5. **NetworkPolicy mặc định của chart nuốt cổng phụ**: RabbitMQ chỉ mở 4369/5672/5671/25672/15672 → STOMP 61613 bị chặn bằng **timeout** trong khi Service, EndpointSlice, `rabbitmq-diagnostics listeners` và plugin đều báo xanh. RabbitMQ vì vậy là **5 chỗ** phải override.

**Sai ở chart**
6. 🔴 **Spring Security chặn `/actuator/health/**` → 403** (kể cả khi đã bật `MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED`) → **7/8 service Java không bao giờ Ready**. Đổi sang liveness `/actuator/info` + readiness `/actuator/health`.
7. Probe `timeoutSeconds` mặc định **1s** giết pod đang khoẻ; liveness `failureThreshold` 3 quá nhạy → 6.
8. `MaxRAMPercentage=75` + limit 448Mi → **OOMKilled** (chỉ còn 112Mi cho non-heap). dev: 640Mi + 55%.
9. `RollingUpdate` với 1 replica bắt 2 JVM cùng chạy lúc rollout → dev dùng `Recreate`.

**Bài học chẩn đoán quan trọng nhất**: CPU 1298% và load average 61 **không phải** dấu hiệu thiếu phần cứng — đó là hệ quả của vòng lặp restart do (6) và (8), mỗi vòng lại boot thêm một JVM. Tôi đã kết luận nhầm "máy 8 GB không đủ" và suýt dời cả phần verify sang EKS. Sửa xong 2 bug: 3 service Ready trong <60s, load average về 3.67. **Luôn nhìn cột `RESTARTS` trước khi đổ lỗi cho phần cứng.**

**Phát hiện thuộc repo app** (không chặn EKS, ghi lại để biết): `frontend/nginx.conf` dùng `resolver 127.0.0.11` — DNS của Docker, không tồn tại trong K8s (kube-dns là `10.96.0.10`) → nginx của FE trả **502** với mọi `/api`, `/ws`. Không ảnh hưởng Day 4 vì ALB Ingress route `/api` thẳng vào gateway, FE chỉ phục vụ file tĩnh.
