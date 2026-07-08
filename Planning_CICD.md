# Planning_CICD.md — GitOps CI/CD cho BadmintonHub lên AWS EKS

> **Mô hình**: *Reproducible ephemeral production-shaped demo* — làm **đúng chuẩn production**, đẩy lên **AWS Free-Tier**, chạy **ổn** rồi **`terraform destroy` xoá sạch**; khi cần demo **`terraform apply` dựng lại**. Toàn hệ thống **tái lập 100% bằng code**.
>
> Kiến trúc bám sát khoá **vprofile GitOps** đã học (Terraform→EKS · GitHub Actions→ECR · Helm+ArgoCD · SonarQube · Slack), điều chỉnh cho **6 service ĐÃ BUILD** của BadmintonHub.
>
> **Tài liệu này là KẾ HOẠCH để hiểu + runbook 7 ngày.** Chưa tạo Dockerfile/Helm/Terraform thật — đó là việc từng Day.

---

## 1. Mục tiêu & phạm vi

**Mục tiêu**: đưa hệ thống BadmintonHub từ *chạy-local-bằng-`mvn spring-boot:run`* lên **cụm Kubernetes trên AWS EKS**, vận hành theo **GitOps** (mọi thay đổi = 1 commit → tự động deploy), có **CI đầy đủ** (build/test/quét chất lượng/quét bảo mật) và **tái lập được** (destroy → apply → tự hồi phục).

**Deploy cái gì** (10 image):

| Nhóm | Thành phần | Port | Ghi chú |
|---|---|---|---|
| Platform | `eureka-server` | 8761 | service discovery — **giữ nguyên**, 0 đổi code |
| Platform | `api-gateway` | 3000 | JWT filter · rate-limit (cần Redis) · CORS · `lb://` routing |
| Business | `user-service` | 3001 | auth/JWT/OAuth2 |
| Business | `court-service` | 3002 | sân/slot/pricing · Kafka consumer |
| Business | `booking-service` | 3003 | đặt sân · Outbox · Feign→court |
| Business | `payment-service` | 3006 | Bank QR · Outbox · Feign→booking |
| Business | `escrow-service` | 3007 | ký quỹ · Outbox (đang "ngủ") |
| Business | `chat-service` | 3011 | STOMP realtime · Mongo · RabbitMQ relay |
| Frontend | `frontend` (nginx) | 80 | React 19 + Vite (static) |

**KHÔNG deploy** (mới scaffold rỗng): `matchmaking` (3004), `coach` (3005), `notification` (3008), `event` (3009), `ai` (3010). Gateway vẫn có route sẵn — khi build xong chỉ cần thêm 1 `values-*.yaml`.

**Nguyên tắc vàng của tài liệu này**:
1. **Reproducible-from-code** — không click tay trên AWS Console. `terraform apply` + ArgoCD = cả hệ thống tự lắp ráp.
2. **Rẻ nhất có thể** — datastore chạy **in-cluster** (không managed), node **spot**, **teardown sau mỗi demo**.
3. **Chất lượng production ở chỗ MIỄN PHÍ** — GitOps, CI gates, health probe, TLS, SealedSecrets, observability.
4. **0 đổi code service** — cấu hình 100% qua env (`${VAR:default}` + `spring-dotenv`) → map thẳng ConfigMap/Secret.

---

## 2. Bản đồ khoá học → dự án (cái đã học dùng ở đâu)

| Section khoá vprofile | Áp vào BadmintonHub | Day |
|---|---|---|
| S8 — Containerization (Docker) | Dockerfile multi-stage cho 8 service Java + nginx cho FE | **Day 1** |
| S15–16 — Kubernetes + Java trên K8s | Helm chart tái sử dụng · Deployment/Service/Ingress · probe | **Day 2, 4** |
| S17–18 — Terraform + State | `terraform/` dựng VPC/EKS/ECR + backend S3/DynamoDB | **Day 3** |
| S14, S20 — GitHub Actions CI/CD + GitOps | `.github/workflows` CI + Terraform pipeline | **Day 5** |
| S12–13 — Continuous Delivery | ArgoCD GitOps loop + promote staging→prod | **Day 6** |
| S10–11 — CI với SonarQube/Nexus/Slack | SonarCloud gate + Trivy + Slack notify | **Day 5** |
| S19 — GitOps (Argo) | `badmintonHub-gitops` repo + app-of-apps | **Day 6** |
| (mở rộng) — Observability | kube-prometheus-stack + Loki + tracing | **Day 7** |

> Khác biệt so với vprofile: vprofile deploy 1 app Java + MySQL/Memcached/RabbitMQ. BadmintonHub = **8 service Spring Cloud** (Eureka discovery, Kafka event-driven, 2 loại DB) → ta tái dùng **cùng bộ khung** (Terraform/Helm/ArgoCD/GHA) nhưng nhân bản chart cho nhiều service + thêm Kafka/Mongo/RabbitMQ vào tầng data.

---

## 3. Kiến trúc tổng thể

### 3.1 Sơ đồ 1 — Luồng GitOps CI/CD đầu-cuối (bản BadmintonHub của PDF vprofile)

```mermaid
flowchart LR
    Dev["Developer"]
    subgraph GH["GitHub"]
        direction TB
        subgraph APP["badmintonHub · app monorepo"]
            direction TB
            SRC["Source · 6 services + gateway + eureka + frontend"]
            subgraph CI["GitHub Actions · CI (vprofile-app)"]
                direction TB
                B1["Maven build + test · Testcontainers"]
                B2["Checkstyle"]
                B3["SonarCloud gate"]
                B4["Docker build · multi-stage"]
                B5["Trivy scan"]
                B6["Push to ECR · tag=SHA"]
                B7["Bump image tag to gitops"]
                B1 --> B2 --> B3 --> B4 --> B5 --> B6 --> B7
            end
            subgraph TF["GitHub Actions · Terraform (vprofile-infra)"]
                direction LR
                T1["Validate"] --> T2["Plan"] --> T3["Apply"] --> T4["Drift"] --> T5["Destroy"]
            end
        end
        subgraph GOPS["badmintonHub-gitops · desired state (vprofile-helm)"]
            direction TB
            HELM["Helm chart + values per env"]
            SEALED["SealedSecrets"]
            ARGOAPP["ArgoCD app-of-apps"]
        end
    end
    Slack["Slack"]
    subgraph AWS["AWS Cloud"]
        direction TB
        ECR["Amazon ECR"]
        subgraph EKS["Amazon EKS"]
            direction TB
            ARGOCD["ArgoCD · watches gitops"]
            NS["Namespaces · staging + prod"]
        end
        ALB["ALB Ingress · HTTPS + WS"]
    end
    Users["Real users"]
    Cloud["Cloudinary"]
    Dev -->|"push · PR to main"| SRC
    SRC --> CI
    B6 --> ECR
    B7 --> HELM
    CI -.notify.-> Slack
    TF -.notify.-> Slack
    T3 -->|"provision VPC · EKS · ECR · IRSA"| EKS
    HELM --> ARGOCD
    SEALED --> ARGOCD
    ARGOAPP --> ARGOCD
    ARGOCD -->|"sync · self-heal"| NS
    ECR -->|"pull image"| NS
    NS --> ALB
    ALB --> Users
    NS -.image upload.-> Cloud
```

**Giải thích từng thành phần:**

| Thành phần | Vai trò |
|---|---|
| **app monorepo** (`badmintonHub`) | Chứa source + Dockerfile + workflow CI + `terraform/`. Developer commit vào đây. |
| **CI (GitHub Actions)** | Build→test→Checkstyle→Sonar→Docker→Trivy→push ECR→**bump tag** sang gitops repo. |
| **Terraform pipeline** | Dựng/huỷ hạ tầng AWS (6 hộp validate→destroy). |
| **gitops repo** (`badmintonHub-gitops`) | **Desired state**: Helm chart + values mỗi env + SealedSecrets + ArgoCD Application. ArgoCD chỉ đọc repo này. |
| **ECR** | Kho image Docker. |
| **ArgoCD** (trong EKS) | Watch gitops repo → **sync** cụm về đúng desired state (self-heal + prune). Đây là "watches Git Repo" trong PDF. |
| **ALB Ingress** | Cổng HTTPS + WebSocket vào cụm, chia route `/`→FE, `/api`+`/ws`→gateway. |
| **Slack / Cloudinary** | Notify CI/CD · lưu ảnh biên lai + ảnh chat (SaaS ngoài). |

**Vì sao tách 2 repo?** CI (app repo) *ghi* tag vào gitops repo, ArgoCD *đọc* gitops repo → không có vòng lặp "CI commit → CI tự trigger lại". Đây là chuẩn app/helm-repo của vprofile.

### 3.2 Sơ đồ 2 — Bên trong cụm EKS (1 environment: routing + service→datastore)

```mermaid
flowchart TB
    Users["Users"] --> ALB["ALB · HTTPS + WebSocket"]
    subgraph ENV["EKS namespace · one per env (staging / prod)"]
        direction TB
        ALB --> FE["frontend · nginx"]
        ALB --> GW["api-gateway :3000"]
        subgraph APPS["App services · 1 replica each"]
            direction TB
            USER["user :3001"]
            COURT["court :3002"]
            BOOK["booking :3003"]
            PAY["payment :3006"]
            ESC["escrow :3007"]
            CHAT["chat :3011"]
            EUREKA["eureka :8761 · discovery"]
        end
        subgraph DATA["Datastores · in-cluster Bitnami"]
            direction TB
            PG["PostgreSQL · 5 DBs"]
            REDIS["Redis"]
            KAFKA["Kafka + Zookeeper"]
            MONGO["MongoDB · chat_db"]
            RABBIT["RabbitMQ · STOMP 61613"]
        end
    end
    GW --> USER
    GW --> COURT
    GW --> BOOK
    GW --> PAY
    GW --> ESC
    GW --> CHAT
    GW -.discovery lb.-> EUREKA
    BOOK -.Feign.-> COURT
    PAY -.Feign.-> BOOK
    USER --> PG
    COURT --> PG
    BOOK --> PG
    PAY --> PG
    ESC --> PG
    USER --> REDIS
    COURT --> REDIS
    BOOK --> REDIS
    PAY --> REDIS
    CHAT --> REDIS
    GW --> REDIS
    COURT --> KAFKA
    BOOK --> KAFKA
    PAY --> KAFKA
    ESC --> KAFKA
    CHAT --> MONGO
    CHAT --> RABBIT
```

**Service → datastore matrix** (nguồn: khảo sát code thật):

| Service | PostgreSQL | Redis | Kafka | MongoDB | RabbitMQ | Ghi chú |
|---|:---:|:---:|:---:|:---:|:---:|---|
| user | `user_db` | ✅ | — | — | — | Kafka có dep nhưng **không dùng runtime** |
| court | `court_db` | ✅ | ✅ | — | — | consumer `booking.slot.changed` + scheduler gen slot |
| booking | `booking_db` | ✅ | ✅ | — | — | Outbox + Feign→court |
| payment | `payment_db` | ✅ | ✅ | — | — | Outbox + Feign→booking + Cloudinary |
| escrow | `escrow_db` | — | ✅ | — | — | **không Redis**; Outbox; đang ngủ |
| chat | — (exclude JPA) | ✅ | — | `chat_db` | ✅ (STOMP :61613) | Cloudinary; `CHAT_BROKER_RELAY=true` |
| gateway | — | ✅ | — | — | — | rate-limit token-bucket |

**Ghi chú kiến trúc quan trọng:**
- **Eureka được GIỮ** làm 1 pod. Gateway + Feign vẫn resolve `lb://<service>` qua Eureka → **0 đổi code**. (Hướng "cloud-native" bỏ Eureka dùng K8s DNS = Phụ lục.)
- **1 PostgreSQL** chứa **5 database** (init script tạo user/court/booking/payment/escrow_db) — nhẹ hơn 5 instance, đúng tinh thần demo.
- **RabbitMQ chỉ để STOMP relay** (fan-out tin nhắn chat cross-instance) — dữ liệu ephemeral, không cần bền.
- **Tất cả app = 1 replica** (demo ephemeral, khớp posture pilot của CLAUDE.md; HA = Phụ lục).

### 3.3 Sơ đồ 3 — Promote dev → staging → prod (cùng image SHA đi lên)

```mermaid
flowchart LR
    DEV["dev · local kind · hack + smoke"]
    MERGE["merge to main"]
    CI["CI · build · scan · push ECR"]
    VS["gitops values-staging · tag=SHA"]
    STG["staging namespace · ArgoCD sync + verify"]
    VP["gitops values-prod · same SHA"]
    PRD["prod namespace · ArgoCD sync · users"]
    DEV --> MERGE --> CI --> VS --> STG
    STG -->|"PR promote"| VP --> PRD
```

| Env | Chạy ở đâu | Chi phí | Mục đích |
|---|---|---|---|
| **dev** | Cụm **local kind/minikube** | **$0** | Hack + smoke-test nhanh, không tốn AWS |
| **staging** | Namespace `staging` trên EKS | ephemeral | ArgoCD auto-sync mọi merge → verify trước |
| **prod** | Namespace `prod` trên EKS | ephemeral | Promote **cùng image SHA** đã verify ở staging bằng 1 PR |

> **Promote = đổi tag ở `values-prod.yaml` sang đúng SHA đã chạy ổn ở staging.** Không build lại → image bất biến, "cái đã test là cái lên prod".

---

## 4. Quyết định kiến trúc & lý do

| Quyết định | Chọn | Lý do |
|---|---|---|
| Datastore | **In-cluster Bitnami** (không managed) | Demo bị xoá sau mỗi lần → backup/HA/PITR của RDS/MSK là **lãng phí** + phá Free-Tier. |
| Sửa code app? | **KHÔNG** | Mỗi demo rebuild DB rỗng ở **1 replica** → `ddl-auto=update` tạo schema mới sạch; đua Outbox/scheduler chỉ cắn khi >1 replica. |
| Discovery | **Giữ Eureka** | Lift-and-shift, 0 rủi ro. Bỏ Eureka = code change → để Phụ lục. |
| Replica | **1 mỗi service** | Ephemeral demo, tiết kiệm RAM Free-Tier. |
| Môi trường | **dev-local + staging/prod trên EKS** | 3 env như yêu cầu, nhưng dev free-local để rẻ. |
| Secret | **SealedSecrets** | Miễn phí, **commit an toàn vào Git** (hợp GitOps + rebuild). Không dùng plain Secret. |
| Node | **t3.large/xlarge spot ×2-3** | Rẻ nhất; demo vài giờ ≈ vài $. |
| TLS | **cert-manager + Let's Encrypt** | Miễn phí, tự cấp lại mỗi lần rebuild. |
| IaC state | **S3 + DynamoDB lock** | State **sống sót qua destroy→rebuild** → apply lại 1 phát. |

---

## 5. Tiền đề & công cụ

**Tài khoản/dịch vụ:**
- AWS account (12-tháng Free-Tier) + IAM user có quyền EKS/EC2/VPC/ECR/IAM/S3/DynamoDB.
- 1 domain (Route53 hosted zone, ~$0.50/mo) — cho TLS + host đẹp. *(Có thể bỏ, dùng thẳng DNS ALB.)*
- GitHub account (2 repo: `badmintonHub`, `badmintonHub-gitops`) + GitHub Actions.
- SonarCloud (free cho public repo) · Slack workspace + Incoming Webhook.
- Cloudinary account (ảnh biên lai/chat) — bắt buộc khi `SPRING_PROFILES_ACTIVE=prod`.

**Cài trên máy dev:**
```bash
aws --version          # AWS CLI v2
kubectl version --client
helm version           # v3
terraform version      # >= 1.6
docker version
kind version           # cụm K8s local (dev)
kubeseal --version     # SealedSecrets CLI
eksctl version         # (tuỳ chọn, tiện tạo add-on/IRSA)
```

**Secret cần chuẩn bị** (nạp qua SealedSecret, KHÔNG commit thô): `JWT_SECRET`, `SENDGRID_API_KEY`, `CLOUDINARY_CLOUD_NAME/API_KEY/API_SECRET`, `GOOGLE_CLIENT_ID/SECRET`, mật khẩu Postgres/Mongo/RabbitMQ. *(Danh sách đầy đủ = `.env.example`.)*

---

## 6. Lộ trình 7 ngày

> Mỗi Day = 1 mảng trọn vẹn, kết thúc bằng **✅ acceptance check**. Thứ tự phụ thuộc: Docker → Helm/local → EKS → deploy → CI → CD/GitOps → observability/teardown.

### Day 1 — Containerize (Docker)

**Mục tiêu**: mọi service + FE chạy được bằng image tự build.

**Việc làm:**
1. **Dockerfile multi-stage dùng chung** cho 8 service Java (`eureka-server`, `api-gateway`, `user/court/booking/payment/escrow/chat-service`). Vì monorepo → build cần các module nội bộ (`common`, `common-security`).
2. **Dockerfile FE** (`frontend/`): build Vite → phục vụ `dist/` bằng nginx (kèm `nginx.conf` fallback SPA + proxy `/api`,`/ws` khi chạy compose).
3. `.dockerignore` (bỏ `target/`, `node_modules/`, `.git/`).
4. `docker-compose.app.yml` = `docker-compose.yml` (infra) **+ 9 app image** — wiring env sang DNS service (`postgres-user`, `redis`, `kafka:29092`, `mongodb-chat`, `rabbitmq`, `eureka-server`).

**Ví dụ Dockerfile Java (mẫu, chỉnh `SERVICE`):**
```dockerfile
# ---- build ----
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
COPY common common
COPY common-security common-security
COPY user-service user-service
RUN mvn -q -pl user-service -am -DskipTests package
# ---- runtime ----
FROM eclipse-temurin:21-jre
WORKDIR /app
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+UseContainerSupport"
COPY --from=build /app/user-service/target/user-service-1.0.0-SNAPSHOT.jar app.jar
EXPOSE 3001
ENTRYPOINT ["java","-jar","app.jar"]
```

**Lệnh chính:**
```bash
docker build -f user-service/Dockerfile -t badmintonhub/user-service:dev .
docker compose -f docker-compose.yml -f docker-compose.app.yml up -d
```

✅ **Check**: `docker compose ... up` → toàn stack lên bằng image tự build; đăng ký → đăng nhập → đặt sân → thanh toán → chat chạy qua các container.

---

### Day 2 — Helm + cụm DEV local (kind)

**Mục tiêu**: deploy toàn hệ thống lên Kubernetes local (= môi trường **Dev**), **de-risk trước khi trả tiền EKS**.

**Việc làm:**
1. **1 Helm chart tái sử dụng** `charts/service/` (template chung): `Deployment` (3 probe: startup/liveness/readiness = `/actuator/health`) + `Service` (ClusterIP) + `envFrom` (ConfigMap + Secret) + `resources` (requests nhỏ `128Mi/100m`) + `imagePullPolicy`.
2. **values mỗi service** (`values/user.yaml`...): image, port, env riêng.
3. Chart riêng cho **FE** (nginx) + **eureka**.
4. **Infra bằng Bitnami Helm** (`values/infra.yaml`): 1 PostgreSQL (initdb 5 DB qua `initdbScripts`), Redis, Kafka+Zookeeper (`kraft` off/on tuỳ chart, single-node), MongoDB, RabbitMQ (**bật plugin `rabbitmq_stomp`** + expose 61613).
5. **ConfigMap** (env non-secret trỏ DNS in-cluster) + **SealedSecret** (JWT/Cloudinary/…).

**Ví dụ probe trong `charts/service/templates/deployment.yaml`:**
```yaml
readinessProbe:
  httpGet: { path: /actuator/health, port: {{ .Values.port }} }
  initialDelaySeconds: 20
  periodSeconds: 10
livenessProbe:
  httpGet: { path: /actuator/health, port: {{ .Values.port }} }
  initialDelaySeconds: 40
```

**Lệnh chính:**
```bash
kind create cluster --name badminton-dev
kubectl create ns badminton && kubectl create ns data
helm install infra bitnami-umbrella -n data -f values/infra.yaml
helm install user charts/service -n badminton -f values/user.yaml   # lặp cho từng service
kubectl -n badminton port-forward svc/api-gateway 3000:3000
```

✅ **Check**: e2e xanh trên kind (login→book→pay→chat); `kubectl get pods -A` tất cả Running/Ready.

---

### Day 3 — EKS bằng Terraform + add-on

**Mục tiêu**: hạ tầng AWS **dựng bằng code**, có ECR, sẵn sàng nhận app.

**Việc làm:**
1. **Backend Terraform**: S3 bucket (state) + DynamoDB table (lock) — tạo 1 lần, **không nằm trong destroy**.
2. `terraform/` (dùng module cộng đồng `terraform-aws-modules/vpc` + `.../eks`): VPC (public + private subnet, 2 AZ) · EKS control plane · **1 managed node group spot** (t3.large ×2) · **ECR repo mỗi service** · OIDC provider + **IRSA** (cho ALB controller, EBS CSI, cert-manager, External-DNS).
3. `terraform apply` → `aws eks update-kubeconfig --name badminton`.
4. **Add-on cụm** (Helm, dùng IRSA): **AWS EBS CSI driver** + StorageClass `gp3` · **AWS Load Balancer Controller** · **cert-manager** (+ ClusterIssuer Let's Encrypt) · (tuỳ chọn) **ExternalDNS**.

**Lệnh chính:**
```bash
cd terraform && terraform init && terraform apply
aws eks update-kubeconfig --name badminton --region ap-southeast-1
helm install aws-lb-controller eks/aws-load-balancer-controller -n kube-system ...
helm install cert-manager jetstack/cert-manager -n cert-manager --set crds.enabled=true
```

✅ **Check**: `kubectl get nodes` → Ready; `aws ecr describe-repositories` liệt kê 9 repo; StorageClass `gp3` tồn tại.

---

### Day 4 — Deploy lên EKS + Ingress/TLS (staging)

**Mục tiêu**: hệ thống truy cập được qua **HTTPS domain thật** trên EKS (namespace `staging`).

**Việc làm:**
1. **Push image lên ECR** (thủ công lần đầu): `docker tag` + `docker push` cho 9 image (hoặc script vòng lặp).
2. `helm install` **infra** (Bitnami) vào ns `data-staging` + **app** (charts/service) vào ns `staging` — trỏ image = ECR URL.
3. **Ingress** (ALB): rule `/`→frontend, `/api/**`+`/ws/**`→gateway; annotation `alb.ingress.kubernetes.io/scheme=internet-facing`, `target-type=ip`, listener 443. **cert-manager** cấp cert cho host.
4. **FE build per-env**: image FE staging nhúng `VITE_API_URL=https://staging.badminton.<domain>`, `VITE_CHAT_WS_URL=wss://staging.badminton.<domain>/ws`.

**Ví dụ Ingress (rút gọn):**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  rules:
    - host: staging.badminton.example.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend: { service: { name: api-gateway, port: { number: 3000 } } }
          - path: /ws
            pathType: Prefix
            backend: { service: { name: api-gateway, port: { number: 3000 } } }
          - path: /
            pathType: Prefix
            backend: { service: { name: frontend, port: { number: 80 } } }
```

✅ **Check**: `curl https://staging.badminton.<domain>/actuator/health` = 200; mở trình duyệt đăng nhập + đặt sân + chat qua domain thật.

---

### Day 5 — CI (GitHub Actions) + Terraform pipeline

**Mục tiêu**: mỗi push tự build/quét/đẩy image + bump tag; hạ tầng có pipeline riêng.

**Việc làm:**
1. **`.github/workflows/ci.yml`**:
   - **path-filter matrix** (`dorny/paths-filter`) → chỉ build service có file đổi; đổi `common/**` → build hết.
   - Job build: `mvn -pl <svc> -am verify` (Testcontainers — `ubuntu-latest` có sẵn Docker) + **Checkstyle**.
   - **SonarCloud** scan + quality gate (fail nếu gate đỏ).
   - Docker build multi-stage → **Trivy** scan (fail HIGH/CRITICAL) → **push ECR** tag = `${{ github.sha }}`.
   - **Bump tag**: checkout `badmintonHub-gitops`, sửa `values-<svc>-staging.yaml` `image.tag`, commit/push (dùng PAT/deploy key).
   - **Slack** notify success/fail.
2. **`.github/workflows/terraform.yml`** (mirror vprofile-infra): `validate` + `plan` (comment PR) + `apply` (merge main) + `drift` (scheduled cron) + `destroy` (`workflow_dispatch` thủ công). Auth AWS bằng **OIDC role** (không lưu access key).
3. **Branch protection** `main`: required checks = build + Sonar gate.

**Lệnh/idea chính:**
```yaml
# ci.yml (rút gọn 1 service)
- run: mvn -pl payment-service -am verify
- uses: aquasecurity/trivy-action@master
  with: { image-ref: "${{ steps.ecr.outputs.uri }}:${{ github.sha }}", exit-code: '1', severity: 'HIGH,CRITICAL' }
```

✅ **Check**: push 1 commit → CI xanh → image mới trong ECR (tag=SHA) + `values-staging` trong gitops repo được bump.

---

### Day 6 — GitOps CD + promote (ArgoCD)

**Mục tiêu**: đóng vòng lặp GitOps — commit → tự lên EKS; promote staging→prod bằng PR.

**Việc làm:**
1. **Tạo repo `badmintonHub-gitops`**: `charts/` (copy chart tái sử dụng) + `values/<svc>-{staging,prod}.yaml` + `sealed-secrets/` + `apps/` (ArgoCD Application).
2. **Cài ArgoCD** vào ns `argocd` (Helm/manifest) + **SealedSecrets controller**.
3. **App-of-apps**: 1 root `Application` trỏ `apps/` → sinh child Application mỗi service × mỗi env (staging, prod) + 1 app cho infra (Bitnami) + 1 cho ingress. Bật `syncPolicy.automated` (prune + selfHeal).
4. **Đóng vòng**: CI (Day 5) bump `values-staging` → ArgoCD auto-sync ns `staging`.
5. **Promote**: PR sửa `values-prod` sang **đúng SHA** đã verify ở staging → merge → ArgoCD sync ns `prod`.

**Ví dụ ArgoCD Application (staging/payment):**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: payment-staging, namespace: argocd }
spec:
  project: default
  source:
    repoURL: https://github.com/<you>/badmintonHub-gitops
    path: charts/service
    helm: { valueFiles: [ "../../values/payment-staging.yaml" ] }
  destination: { server: https://kubernetes.default.svc, namespace: staging }
  syncPolicy: { automated: { prune: true, selfHeal: true } }
```

✅ **Check**: đổi 1 dòng code → merge → **tự lên prod không thao tác tay**; `argocd app list` Healthy/Synced; rollback = `git revert` PR trong gitops repo.

---

### Day 7 — Observability + teardown/rebuild + hardening-free

**Mục tiêu**: nhìn thấy hệ thống (metrics/log/trace) + chứng minh **tái lập được** + siết các thứ production-free.

**Việc làm:**
1. **Observability** (in-cluster, miễn phí): `kube-prometheus-stack` (Prometheus + Grafana) + **Loki** (log) + expose `/actuator/prometheus` (thêm `micrometer-registry-prometheus` vào `management.endpoints` — **thay đổi config/pom nhẹ, không đụng logic**) + tracing đẩy về Zipkin/OTel.
2. **Alert DLT/limbo** (điều kiện go-live ③ của CLAUDE.md): rule Prometheus/Loki bắt log `[DLT]` ERROR + gauge `*.outbox.stuck`/`payment.proof.stuck` → Slack.
3. **Production-free hardening**: `resources` requests/limits chuẩn, `PodDisruptionBudget`, **graceful shutdown** (`server.shutdown=graceful` + `preStop` sleep để Eureka deregister), `terminationGracePeriodSeconds`.
4. **Diễn tập teardown → rebuild** (workflow lõi — xem §7).

✅ **Check**: Grafana thấy metrics; kích 1 event lỗi → Slack cảnh báo; **`destroy` sạch (bill≈0) → `apply` → ArgoCD tự lắp lại → e2e xanh**.

---

## 7. Runbook TEARDOWN / REBUILD (workflow lõi)

> Đây là **lý do tồn tại của toàn bộ thiết kế IaC/GitOps**: xoá sạch để khỏi tốn tiền, dựng lại khi cần demo.

### 7.1 Teardown (xoá sạch — bill về ~0)
```bash
# 1. Xoá app + ingress trước (để ALB/PVC được release đúng)
argocd app delete -l env=staging --cascade
argocd app delete -l env=prod --cascade
kubectl delete ingress --all -A          # để AWS LB Controller gỡ ALB
# 2. Gỡ add-on tạo AWS resource ngoài (ALB, EBS)
helm uninstall aws-lb-controller -n kube-system
# 3. Huỷ hạ tầng
cd terraform && terraform destroy
```
- **Giữ lại**: S3 (state) + DynamoDB (lock) + ECR (image) → rebuild nhanh, không build lại image.
- **Kiểm tra hết tiền**: AWS Console → EC2 (0 instance), EKS (0 cluster), EC2 Load Balancers (0 ALB), NAT (0), EBS (0 volume "available").

### 7.2 Rebuild (dựng lại cho demo — vài lệnh)
```bash
cd terraform && terraform apply                      # VPC/EKS/nodes/ECR (~15')
aws eks update-kubeconfig --name badminton
# cài lại add-on + ArgoCD (script bootstrap.sh) → ArgoCD tự kéo gitops → cả hệ thống mọc lại
./bootstrap.sh
```
- Vì **desired state nằm trong gitops repo** + **image đã ở ECR** → ArgoCD tự lắp ráp toàn bộ. Chỉ chờ pod Ready.

---

## 8. Chi phí & kiểm soát (Free-Tier)

**Sự thật thẳng thắn: EKS + node + ALB + NAT KHÔNG thuộc Free-Tier.** "Rẻ" đến từ **teardown sau mỗi demo**.

| Hạng mục | Giá xấp xỉ | Free-Tier? |
|---|---|---|
| EKS control plane | ~$0.10/giờ (~$73/tháng) | ❌ |
| EC2 node t3.large **spot** ×2 | ~$0.05/giờ tổng | ❌ (t3.micro 750h có free nhưng quá nhỏ) |
| ALB | ~$0.0225/giờ + LCU | ❌ |
| NAT Gateway | ~$0.045/giờ + data | ❌ (**né**: dùng public subnet cho node hoặc NAT instance) |
| EBS gp3 | ~$0.08/GB-tháng | 30GB free |
| ECR | ~$0.10/GB-tháng | 500MB free |
| Route53 | $0.50/zone-tháng | ❌ |
| S3 + DynamoDB (state) | ~vài cent | phần lớn free |

**Ước tính**: demo **3 giờ** (spot, né NAT) ≈ **dưới $1**. Nếu **quên tắt cả tháng** ≈ **$150–200**. → **Kỷ luật `terraform destroy`** là quan trọng nhất.

**Mẹo tiết kiệm**: node **spot** · **né NAT Gateway** (đặt node ở public subnet cho demo) · scale app xuống 0 khi không demo · dùng **1 AZ** cho demo · đặt **AWS Budget alert** (email khi > $5).

---

## 9. Rủi ro & giảm thiểu

| Rủi ro | Giảm thiểu |
|---|---|
| Quên tắt → cháy tiền | `terraform destroy` + AWS Budget alert + checklist §7.1 |
| 3 env × full infra nặng RAM | 1 replica + `-XX:MaxRAMPercentage=75` + Kafka/PG single-node + **dev để local** |
| `ddl-auto` + không Flyway | Chấp nhận cho demo (rebuild schema rỗng, 1 replica). Flyway = Phụ lục |
| Outbox chưa `SKIP LOCKED` | Giữ **1 replica** booking/payment/escrow (không scale) trong demo |
| Secret lộ trong Git | **SealedSecrets** — chỉ commit bản đã seal |
| Testcontainers cần Docker (CI) | GHA `ubuntu-latest` có sẵn Docker daemon |
| Cloudinary prod-guard fail boot | Nạp `CLOUDINARY_*` qua SealedSecret khi `SPRING_PROFILES_ACTIVE=prod` |
| Eureka single-node | Chấp nhận cho demo; HA/K8s-native = Phụ lục |
| FE `VITE_*` bake lúc build | Build image FE **per-env** (staging/prod URL khác nhau) |

---

## 10. Definition of Done

- [ ] 9 image build được + smoke-test qua `docker-compose.app.yml` (Day 1).
- [ ] Helm deploy toàn hệ thống lên **kind** (dev) e2e xanh (Day 2).
- [ ] `terraform apply` dựng EKS + ECR + add-on; `kubectl get nodes` Ready (Day 3).
- [ ] App chạy trên EKS `staging` qua **HTTPS**; `/actuator/health`=200 (Day 4).
- [ ] CI xanh: build→test→Sonar→Trivy→ECR→bump gitops + Slack (Day 5).
- [ ] ArgoCD Synced/Healthy; đổi 1 dòng code → tự lên prod; promote staging→prod bằng PR (Day 6).
- [ ] Grafana có metrics + alert DLT→Slack; **destroy→apply→self-heal** thành công (Day 7).
- [ ] Toàn bộ tái lập bằng code; teardown về bill≈0.

---

## Phụ lục — Graduate to always-on real production

*(Khi có user thật lâu dài — ngoài scope demo ephemeral này. Cần cả thay đổi code app.)*

| Hạng mục | Nâng cấp |
|---|---|
| Datastore | **RDS PostgreSQL Multi-AZ** (backup + PITR) · **MSK** (Kafka) · **ElastiCache** (Redis) · **DocumentDB/Atlas** (Mongo) · **Amazon MQ** (RabbitMQ) |
| Migration | **Flyway** thay `ddl-auto` (gộp `PaymentIndexInitializer`/`ChatIndexInitializer` thành versioned migration) |
| Concurrency | **Outbox `FOR UPDATE SKIP LOCKED`** + **ShedLock** (khoá scheduler phân tán) → scale mọi service **≥2** |
| Discovery | Bỏ Eureka → **Spring Cloud Kubernetes** / K8s Service DNS (hoặc Eureka HA peer-replication) |
| Secret | **External Secrets Operator + AWS Secrets Manager** (thay SealedSecrets) |
| Availability | HPA + Cluster Autoscaler/Karpenter + multi-AZ node group + PodDisruptionBudget |
| Bảo mật | **WAF** trên ALB + NetworkPolicy + private datastore + image signing (cosign) + SBOM |
| DR/Backup | Velero (cluster state) + RDS snapshot + tested restore |
| Môi trường | Tách **cluster** riêng cho prod (thay vì namespace) |

---

> **Tiếp theo**: duyệt tài liệu này → bắt đầu **Day 1** (Dockerfile + `docker-compose.app.yml`). Mỗi Day chạy độc lập, kết thúc bằng acceptance check + commit.
