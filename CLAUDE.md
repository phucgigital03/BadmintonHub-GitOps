# BadmintonHub GitOps — CLAUDE.md

Repo **desired-state (GitOps)** cho nền tảng BadmintonHub. **KHÔNG chứa source code ứng dụng** — chỉ Helm chart, values theo môi trường, ArgoCD Application, ExternalSecret. ArgoCD trong cụm EKS **watch repo này** và sync cụm về đúng trạng thái khai báo ở đây.

> Repo app (source Java/React, Dockerfile, Terraform, CI) = **`badmintonHub`** (folder sibling).
> ⚠️ Cần dữ kiện thuộc repo app (Day 1/3/5 đã ra gì · tên biến env · ECR repo URL · output Terraform):
> **hỏi user** — user đã handoff đủ ở `../badmintonHub/CLAUDE.md`. Đừng copy/snapshot sang repo này.
> Kế hoạch đầy đủ + lộ trình 7 ngày (+ Day 8 gắn domain) + prompt paste-ready mỗi Day: xem **`Planning_CICD.md`**.
> Bức tranh tổng quát hệ thống (hạ tầng AWS · 1 ALB 2 namespace · secret/storage · vòng đời request & buổi demo): xem **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)**.
> Thao tác tay phải tự làm (AWS Console · GitHub · third-party API key · 20 SSM param) + bản đồ verify Console theo Day: xem **[`docs/MANUAL-SETUP.md`](docs/MANUAL-SETUP.md)**.

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
                    #            Ingress ALB (Day 4), ExternalSecret app-secrets (Day 6)
values/             # Day 2 ✅ — 27 file <svc>-<env>.yaml (9 svc × 3 env)
infra/              # Day 2 ✅ — umbrella chart 5 datastore Bitnami (GHIM version) → ns data-<env>
                    #            + ExternalSecret datastore-secrets (Day 6)
                    #            values/infra-<env>.yaml   : override datastore
                    #            values/platform-<env>.yaml: env của app-config (+ Day 4 thêm 2 CÔNG TẮC
                    #                                        ingress host/certificateArn, mặc định "")
scripts/            # Day 2 ✅ — kind-up.sh · kind-secret.sh · kind-deploy.sh
                    # Day 4 ✅ — eks-secret.sh · eks-deploy.sh (ArgoCD đã thay thế, giữ để debug)
                    # Day 6 ✅ — argocd-install.sh
apps/               # Day 6 ✅ — app-of-apps: root.yaml + infra-<env> (wave 1) + platform-<env> (wave 2)
                    #            + appset-services.yaml (wave 3 → 9 svc × 2 env = 18 child)
docs/               # Tài liệu — ARCHITECTURE.md: bức tranh tổng quát hệ thống (góc nhìn hạ tầng)
                    #            MANUAL-SETUP.md: checklist thao tác tay (account/IAM/API key/SSM param/
                    #            GitHub secret) + bản đồ verify AWS Console theo Day + verify bill về 0
                    #            DAY2-EXPLAINED.md: giải thích Day 2 cho NGƯỜI MỚI — 13 phát hiện khi
                    #            chạy thật (nhóm theo loại sai lầm) + khái niệm K8s/Helm cần học + tự kiểm tra
                    #            DAY4-EXPLAINED.md: giải thích Day 4 + RUNBOOK lệnh rời để gõ tay
                    #            (Ingress≠ALB · target-type ip · ALB health-check là tầng THỨ TƯ · ECR amd64)
                    #            DAY6-EXPLAINED.md: giải thích Day 6 + runbook (app-of-apps · goTemplate
                    #            của ArgoCD 3.x · sync-wave · ESO rewrite/mergePolicy)
```

> 🔴 **KHÔNG có thư mục `external-secrets/`** — bản kế hoạch cũ ghi thế, đã bỏ ở Day 6.
> ExternalSecret sống ở **4 namespace** mà một ArgoCD Application chỉ khai được **một**
> `destination.namespace` ⇒ tách ra thư mục riêng thì phải đẻ thêm 4 Application chỉ để nạp
> secret. Nhúng vào chart thì Application nào tự tạo namespace của nó, tự nạp secret của nó.
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

**Cập nhật lần cuối**: 2026-08-06 (**Day 4 XONG**: Ingress ALB template hoá + 18 values trỏ ECR thật + deploy staging lên EKS và **e2e trọn vẹn trên URL công khai** — đăng ký → verify → đặt sân → **chat 2 chiều realtime**. Teardown sạch, bill về ~$0.30/tháng chỉ còn ECR.)

### ✅ Đã hoàn thành

**Nền** — `CLAUDE.md` + `Planning_CICD.md` (Day 1→8, prompt paste-ready, runbook §7) · `.claude/rules/` **8 file** + `.claude/commands/` **11 command**.

**Day 2** (kind, dev) — `charts/service/` generic cho cả 9 svc · `charts/platform/` (ConfigMap `app-config`) · `infra/` umbrella 5 datastore Bitnami ghim version · **27** `values/<svc>-<env>.yaml` · `scripts/kind-*.sh`. Trên kind: 5/5 datastore + 9/9 service Ready, **e2e đường ghi khép vòng** (`register` → `verify-email` → `POST /api/bookings` 201 → slot `RESERVED`), **15 topic Kafka tự sinh** dù không có bean `NewTopic`, gateway trả **429** ⇒ Redis + rate-limiter chạy.

**Day 4** (EKS, staging) — **deliverable ở repo này**:
- `charts/platform/templates/ingress.yaml` — **1 bản Ingress ALB duy nhất** cho mọi env và cho cả trước/sau domain. 2 công tắc `ingress.host` / `ingress.certificateArn` mặc định rỗng.
- `charts/service/templates/service.yaml` — thêm `service.annotations` (optional, 27 values cũ không phải sửa) để khai ALB healthcheck riêng cho từng target group.
- **18** `values/<svc>-{staging,prod}.yaml` — ECR thật `547602846935.dkr.ecr.ap-southeast-1.amazonaws.com/<svc>` + tag = git SHA (bỏ hết placeholder). 9 file `-dev` giữ nguyên `badmintonhub/<svc>:dev`.
- `infra/values/infra-{staging,prod}.yaml` — ghim `global.defaultStorageClass: gp3`.
- `scripts/eks-secret.sh` (SSM → `app-secrets` + `datastore-secrets`) · `scripts/eks-deploy.sh` (bản ghi lại runbook, `DRY_RUN=1` được).
- `docs/DAY4-EXPLAINED.md` — khái niệm + **runbook lệnh rời để gõ tay** + bảng triệu chứng→nghi gốc.

**Đã chạy thật trên EKS** (cụm dựng lúc 13:16, teardown lúc ~15:40):
- 5/5 datastore Running, **5 PVC `Bound` trên gp3** (26 Gi) · 9/9 pod Running **RESTARTS 0**, image từ ECR `linux/amd64`.
- ALB tự sinh từ Ingress, **đúng 1 ALB** (`group.name`), listener 80.
- `/` → frontend **200** · `POST /api/auth/login` → **401 + JSON `INVALID_CREDENTIALS`** ⇒ chuỗi ALB → gateway → user-service → Postgres thông.
- Mongo connected (`?authSource=admin` đúng) · **STOMP relay RabbitMQ 61613 `available=true` trên EKS** (5 override Bitnami đúng, không chỉ trên kind).
- **Chat 2 chiều realtime chạy thật trên URL công khai** — tin gửi có `✓✓`, phía staff trả lời hiện ngay ⇒ WS handshake qua ALB + Mongo + STOMP khép vòng.
- **Teardown sạch**: EKS/EC2/EBS/ELB/NAT/EIP/snapshot/VPC/IAM đều rỗng. Chi phí buổi ≈ **$0.57** cho 2.5 giờ (≈ **$0.22/giờ cụm sống**).

### 🔄 Đang làm / còn dở

- ✅ Day 4 **đã commit đủ** — 5 commit: `dd9ff9b` ingress · `5c0d45e` values · `1770124` scripts · `18a77b5` docs/handoff · `358faf8` promote frontend prod. Working tree **sạch**, **chưa push** (`main` ahead 6 so với `origin/main`).
- ⚠️ **Tag image LỆCH giữa các service — bình thường trong GitOps, đừng "sửa" cho đều**:

  | Values | Tag | Vì sao |
  |---|---|---|
  | 8 service Java (staging + prod) | `5a7067c` | lần build đầu, đã gồm patch `WebSocketConfig` + FE same-origin |
  | `frontend-{staging,prod}.yaml` | **`59bf4c6`** | build lại **chỉ mình frontend** để fix `crypto.randomUUID` (secure context); prod đã promote sang cùng SHA |

  Mỗi service có vòng đời riêng nên tag khác nhau là đúng — **KHÔNG** build lại 8 service Java chỉ để cho tag bằng nhau. Trên ECR: 8 repo Java chỉ có `5a7067c`; repo `frontend` có **cả `5a7067c` và `59bf4c6`**.

### 📋 Việc tiếp theo (theo thứ tự ưu tiên)
1. **Push `main`** lên `origin` (6 commit đang chờ) — hoặc để đó nếu muốn xem lại trước.
2. **Day 5 — CI/CD**: mở Claude Code ở **`../badmintonHub` (app repo)**, dùng **📋 Prompt paste-ready — Day 5** trong `Planning_CICD.md`. **Không làm ở repo này.**
3. **Day 6** (repo này): `apps/` ApplicationSet + cài ArgoCD + chuyển `scripts/eks-secret.sh` → `ExternalSecret` (ESO + ClusterSecretStore **đã cài sẵn và `Valid`** từ `bootstrap.sh` của Day 3 ⇒ rủi ro Day 6 giảm hẳn). Nhớ **bật `ingress.enabled: true` cho prod chỉ từ Day 8** (xem §Quyết định).
4. Day 7 (observability + teardown) → Day 8 (domain + HTTPS, cả 2 repo).

**Việc thuộc repo app, ghi lại để không quên** (không chặn Day 5/6):
- `court-service` `GlobalExceptionHandler` map `HttpRequestMethodNotSupportedException` → **500** thay vì 405.
- chat-service map `NoResourceFoundException` → **500** thay vì 404.
- `frontend/nginx.conf` dùng `resolver 127.0.0.11` (DNS của Docker, không có trong K8s) → không ảnh hưởng vì ALB route `/api` thẳng vào gateway.
- Tuỳ chọn: ECR lifecycle policy (giữ 5 image gần nhất + xoá untagged) — hiện ECR 3.2 GB ≈ $0.32/tháng, tăng ~1.8 GB mỗi lần push đủ 9 image.

### ✅ Cờ 🚩 của Day 4 đã đóng — nhưng bằng ĐỦ 2 NỬA ở 2 REPO
`WebSocketConfig` ban đầu dùng `setAllowedOrigins(frontendUrl)` (so khớp chuỗi **chính xác**) ⇒ thao tác tay mỗi rebuild ⇒ vi phạm tiêu chí vàng.
- **Nửa 1 (repo app)**: `setAllowedOriginPatterns(frontendUrl.split(","))` + `@Value("${app.frontend-url:*}")`. KHÔNG dùng `setAllowedOrigins("*")` — Spring ném exception khi `allowCredentials` bật.
- **Nửa 2 (repo này)**: `values/chat-service-{staging,prod}.yaml` → `env: { FRONTEND_URL: "*" }`.

🔴 **Nửa 2 bắt buộc dù image đã default `*`**: `charts/platform` phát `FRONTEND_URL` cho **mọi** service vô điều kiện (user-service cần cho link email), mà **env tường minh thắng default của image** ⇒ pattern thành ALB DNS ⇒ **WS 403**. Chính ConfigMap của repo này vô hiệu hoá default đã đúng sẵn trong image — cả 2 repo đều "làm đúng phần mình" mà hệ thống vẫn hỏng.
**Đừng** đặt `*` ở `platform-*.yaml`: link email thành `*/verify-email?token=…`.
⚠️ Chỉ hiệu lực với image chat-service **build sau khi patch** (hiện tại: SHA `5a7067c`).
💡 Day 8: `.split(",")` nhận nhiều origin → siết lại đúng domain thật mà không sửa code.
🔴 Bẫy kèm: **Origin header không có `/` cuối** — `http://host` ≠ `http://host/`.

✅ **Đã verify bằng handshake thật trên EKS** (không phải suy luận): origin = ALB host → **`101 Switching Protocols`**, origin lạ → `403`. ALB host **không được khai ở đâu cả** (`platform-staging.yaml` vẫn là `http://REPLACE-WITH-ALB-DNS`) mà vẫn qua ⇒ chỉ có thể do `FRONTEND_URL: "*"`. Hai kết quả không mâu thuẫn: Spring coi Origin trùng host là *same-origin* nên **bỏ qua CORS**, còn origin lạ mới bị `CorsFilter` chặn — đúng cấu hình mong muốn.

### 🧠 Quyết định kỹ thuật đã chốt
- **1 chart `charts/service/` cho cả 9 service kể cả `frontend`** — điều kiện để ApplicationSet matrix của Day 6 dùng được.
- **Tên object lấy từ `nameOverride`, KHÔNG từ `.Release.Name`** — xem §Bẫy tên Service.
- **Toàn bộ biến non-secret nằm ở MỘT ConfigMap `app-config`/namespace** (kể cả 5 `DB_*_URL`) → 27 file values rất mỏng, ít chỗ sai. **Ngoại lệ duy nhất: `FRONTEND_URL` của chat-service** ghi đè bằng block `env:` (xem 🚩 trên).
- **Secret = ESO + SSM, KHÔNG SealedSecrets** — keypair của SealedSecrets khoá theo cụm, mà cụm destroy mỗi buổi. Day 2 trên kind tạm dùng `scripts/kind-secret.sh` sinh từ `.env`; Day 4 trên EKS tạm dùng `scripts/eks-secret.sh` đọc SSM; tên target Secret giữ nguyên `app-secrets` nên Day 6 đổi sang ESO không phải sửa values.
- **HTTPS = ACM, KHÔNG cert-manager** — ALB chỉ nhận cert ACM/IAM, không đọc K8s Secret.
- **Domain là add-on của Day 8**, Day 1–7 chạy http trên ALB DNS thô.
- **Probe tách `liveness`/`readiness`** + **`timeoutSeconds` khai tường minh** (mặc định 1s là quá ngắn cho actuator).

**Chốt thêm ở Day 4:**
- **Ingress nằm trong `charts/platform/`, values ở `infra/values/platform-<env>.yaml`** — KHÔNG tách file `ingress-<env>.yaml` riêng như bản kế hoạch cũ. Chart cài bằng **một** release với **một** `-f`; tách ra chỉ thêm chỗ để quên.
- **`spec.ingressClassName: alb`**, không dùng annotation `kubernetes.io/ingress.class` (deprecated ở controller v2). → runbook có bước `kubectl get ingressclass alb` trước khi cài.
- 🔴 **`ingress.enabled: false` cho `prod` tới Day 8** — không phải quên bật. staging + prod cùng `group.name` mà cùng `host: ""` ⇒ hai Ingress cùng khai `/`, `/api`, `/ws`; controller gộp rule và **cái đứng sau không bao giờ khớp**, traffic prod lặng lẽ chảy vào staging, cả hai đều có ADDRESS giống hệt nhau. Host header mới là thứ tách 2 env, mà host chỉ có từ Day 8.
- **ALB healthcheck khai trên Service, dùng `/actuator/info`** — ALB probe mặc định `/` mà gateway trả 404 ⇒ target unhealthy ⇒ `/api` 502 dù `kubectl` xanh. Chọn `/actuator/info` chứ không `/actuator/health` vì readiness của K8s đã gác composite rồi; dùng composite hai lần = Redis nhấp nháy bị phạt hai lần.
- **Ghim `global.defaultStorageClass: gp3`** — EKS còn sẵn `gp2` với provisioner in-tree `kubernetes.io/aws-ebs` **đã bị gỡ khỏi K8s từ 1.31** (cụm đang chạy 1.33) ⇒ gp2 là mồi nhử, không provision được gì.
- **Teardown phải `helm uninstall infra` TRƯỚC khi xoá PVC** — finalizer `pvc-protection` làm `kubectl delete pvc` **treo vô hạn** khi pod còn mount. Đã sửa vào runbook §7.1.

### 💬 Claude đã làm trong phiên này (Day 4)

Viết toàn bộ deliverable Day 4 ở repo này, rồi **user tự gõ tay từng lệnh** deploy lên EKS thật (tôi không chạy lệnh nào lên cụm/AWS — chỉ `helm lint`/`helm template` để kiểm cú pháp). Chạy thật lộ ra **7 chỗ tài liệu sai hoặc thiếu**, tất cả đã sửa vào `.claude/rules/` + `docs/DAY4-EXPLAINED.md`:

1. 🔴 **Nghiệm thu bằng `curl /api/actuator/health` là SAI** (bản kế hoạch ghi thế). Ingress **không rewrite path** ⇒ gateway nhận nguyên văn `/api/actuator/health`, mà actuator của nó ở `/actuator/health` (không tiền tố) ⇒ **404**. Phải nghiệm thu bằng route nghiệp vụ thật. Đã thêm bảng đọc mã: **502/503** = target group hỏng · **404** = đã tới gateway, sai path · **401/400/405** = đã tới service.
2. 🔴 **Một LỚP lỗi mới: Web API secure-context-only.** Trên http thô, trình duyệt khoá `crypto.randomUUID` và `navigator.clipboard` ⇒ **nút Gửi của chat không làm gì** (dễ đổ oan cho WebSocket/origin) và nút copy số tài khoản báo "Đã copy" nhưng không copy. Day 8 (HTTPS) sửa cả lớp này miễn phí. Đã fix tạm ở repo app bằng fallback uuid 3 tầng.
3. **SSM không nhận giá trị rỗng** (`ValidationException: length ≥ 1`). ⇒ 3 param optional (`SENDGRID_API_KEY`, `GOOGLE_CLIENT_*`) **đừng tạo**; `eks-secret.sh` đã dùng `${VAR:-}` nên vẫn sinh key rỗng trong Secret — Spring chỉ cần key **tồn tại**. Thực tế chỉ cần **8** param, không phải 11.
4. **`kubectl delete pvc` TREO vô hạn** khi pod còn mount (finalizer `pvc-protection`) — và output vẫn in `deleted` cho cả 5, rất dễ Ctrl-C rồi destroy luôn ⇒ **EBS mồ côi**. Runbook §7.1 đã thêm bước `helm uninstall infra` trước.
5. **`/ws/info` trả 500, không phải bằng chứng WS hỏng** — chat-service dùng **WebSocket thuần**, không SockJS, nên endpoint đó không tồn tại. Phải đo bằng **handshake thật** (`Upgrade: websocket`); lệnh **treo chính là dấu hiệu `101` thành công**.
6. **KMS key `PendingDeletion` KHÔNG tốn tiền** — mỗi `apply` tạo 1 key, `destroy` chỉ schedule xoá với cửa sổ 30 ngày nên chúng tích lại. Đã tra trang pricing AWS: *"There is no charge for customer managed KMS keys that you manage and are scheduled for deletion."* Ghi vào rule vì AWS để thông tin này ở trang **pricing** chứ không ở trang *Deleting keys*.
7. **Bộ verify bill cũ quá hẹp** — chỉ kiểm EBS + ELB nên không bắt được NAT/EIP/snapshot/EKS/CloudWatch log group. Đã mở rộng.

**Bài học lớn nhất của Day 4** — bug nằm ở **chỗ giao nhau giữa 2 repo, không ở repo nào cả**: image chat-service đã default `FRONTEND_URL=*` (đúng), `charts/platform` phát `FRONTEND_URL` cho mọi service vì user-service cần nó cho link email (cũng đúng), nhưng **env tường minh thắng default của image** ⇒ cái đúng thứ hai giết cái đúng thứ nhất ⇒ WS 403. Chỉ nhìn thấy khi đặt hai repo cạnh nhau. Triệu chứng thì vô hại nhất có thể: **chat chết một mình, mọi thứ khác xanh.**

**Chi phí thực đo**: buổi 2.5 giờ ≈ **$0.57** (≈ $0.22/giờ cụm sống). Bảng trong `ephemeral-cost.md` ghi "$0.15/buổi" — đúng với buổi gọn ~40 phút, không đúng với buổi vừa dựng vừa debug. Sau teardown còn **~$0.30/tháng**, toàn bộ là ECR 3.2 GB.
