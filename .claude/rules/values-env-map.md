---
description: Bảng tra service → port → datastore → probe, bảng env var → ConfigMap/Secret, DNS in-cluster. Đủ để viết values mà không cần mở repo app.
globs: values/*.yaml
---

# Values & env map

## Service → port → datastore (9 image deploy)

| Service | Port | Postgres | Redis | Kafka | Mongo | RabbitMQ | probe path |
|---|---|:--:|:--:|:--:|:--:|:--:|---|
| `eureka-server` | 8761 | — | — | — | — | — | live `/actuator/info` · ready `/actuator/health` |
| `api-gateway` | 3000 | — | ✅ | — | — | — | ↑ |
| `user-service` | 3001 | `user_db` | ✅ | ✅ | — | — | ↑ |
| `court-service` | 3002 | `court_db` | ✅ | ✅ | — | — | ↑ |
| `booking-service` | 3003 | `booking_db` | ✅ | ✅ | — | — | ↑ |
| `payment-service` | 3006 | `payment_db` | ✅ | ✅ | — | — | ↑ |
| `escrow-service` | 3007 | `escrow_db` | — | ✅ | — | — | ↑ |
| `chat-service` | 3011 | — | ✅ | — | `chat_db` | ✅ STOMP 61613 | ↑ |
| `frontend` | 80 | — | — | — | — | — | **`/`** (nginx, không actuator) |

> ✏️ **Đã sửa ở Day 2 sau khi đọc `application.yml` thật**: `user-service` **CÓ** Kafka
> (`spring.kafka.bootstrap-servers`, `application.yml:21-22`) — bảng cũ ghi "—". Thiếu
> `KAFKA_BOOTSTRAP_SERVERS` thì nó trỏ `localhost:9092`.

**KHÔNG deploy**: `ai-service` (3010, Python — Phụ lục A, nặng RAM Free-Tier) · `matchmaking`/`coach`/`notification`/`event` (scaffold rỗng).

## ⚠️ Nguồn sự thật về TÊN BIẾN

= `../badmintonHub/<svc>/src/main/resources/application.yml` của **từng** service.
`.env.example` **CHỈ để đối chiếu và KHÔNG đầy đủ** — đã kiểm: `CHAT_BROKER_RELAY` và `BOOKING_MAX_HOLD_MINUTES` có trong `application.yml` nhưng **không có** trong `.env.example`. Đọc file thật trước khi viết values, đừng suy đoán tên biến.

## Env → giá trị in-cluster (ví dụ env `staging`, data ns `data-staging`)

| Env var | Giá trị | Loại |
|---|---|---|
| `DB_<SVC>_URL` | `jdbc:postgresql://postgresql.data-staging.svc.cluster.local:5432/<svc>_db` | ConfigMap |
| `POSTGRES_USERNAME` / `POSTGRES_PASSWORD` | 1 user (`postgres`) dùng chung cho cả 5 DB | **Secret** |
| `REDIS_HOST` / `REDIS_PORT` | `redis-master.data-staging.svc.cluster.local` / `6379` | ConfigMap |
| `KAFKA_BOOTSTRAP_SERVERS` | `kafka.data-staging.svc.cluster.local:9092` | ConfigMap |
| `MONGODB_CHAT_URI` | `mongodb://<u>:<p>@mongodb.data-staging.svc.cluster.local:27017/chat_db`**`?authSource=admin`** | **Secret** |
| `RABBITMQ_HOST` / `RABBITMQ_STOMP_PORT` | `rabbitmq.data-staging.svc.cluster.local` / `61613` | ConfigMap |
| `RABBITMQ_USER` / `RABBITMQ_PASS` | `badminton` / creds | ConfigMap · **Secret** |
| `CHAT_BROKER_RELAY` | `true` | ConfigMap |
| `EUREKA_URL` | `http://eureka-server.staging.svc.cluster.local:8761/eureka` | ConfigMap |
| `FRONTEND_URL` | URL công khai của env — sau patch Day 4 chỉ còn **1 chỗ dùng** (link email), xem dưới | ConfigMap |
| `MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED` | `true` | ConfigMap |
| `MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE` | `health,info,prometheus` — mở `/actuator/prometheus` cho Prometheus scrape (Day 7) | ConfigMap |
| `SERVER_SHUTDOWN` | `graceful` — nửa Spring của graceful shutdown (Day 7) | ConfigMap |
| `SPRING_LIFECYCLE_TIMEOUT_PER_SHUTDOWN_PHASE` | `20s` — trần drain; 15 (preStop) + 20 + 10 dư = `terminationGracePeriodSeconds: 45` ở `charts/service` | ConfigMap |
| `SPRING_PROFILES_ACTIVE` | `prod` | ConfigMap |
| `JWT_SECRET` · `CLOUDINARY_*` · `GOOGLE_CLIENT_*` · `SENDGRID_*` | giá trị ở SSM `/badminton/<env>/*` | **Secret (ExternalSecret)** |

Prod: thay `staging`→`prod`, `data-staging`→`data-prod`.

> 📌 **Day 7 — `/actuator/prometheus` cần CẢ HAI repo, thiếu nửa nào cũng ra cùng một triệu chứng (target DOWN).**
>
> | Repo | Phần việc | Thiếu thì |
> |---|---|---|
> | `badmintonHub` | `micrometer-registry-prometheus` (parent `pom.xml`, scope runtime) | endpoint **không tồn tại** → 404 |
> | `badmintonHub` | `"/actuator/prometheus"` trong `permitAll` của 6 `SecurityConfig` | **403** — các matcher đó là path LITERAL, không phải prefix |
> | repo này | `MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE` (ConfigMap) | endpoint không được phơi → 404 |
> | repo này | `metrics.enabled: true` → label `badminton.io/metrics` (`charts/service`) | ServiceMonitor không chọn được → **target biến mất, không lỗi** |
>
> `frontend` cố ý **không** có cả 4: nginx không có actuator, scrape nó chỉ tạo một target đỏ vĩnh viễn.

### Biến có thật nhưng từng thiếu ở bảng này

`JWT_ACCESS_EXPIRATION_MS` · `JWT_REFRESH_EXPIRATION_MS` · `SENDGRID_FROM_EMAIL` · `SENDGRID_FROM_NAME` · `BOOKING_HOLD_MINUTES` · `BOOKING_MAX_HOLD_MINUTES` · `PAYMENT_EXPIRE_MINUTES` · `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`. Tất cả đã nằm trong `app-config` (trừ 2 biến Google là Secret).

## 🔴 Đặt sân YÊU CẦU email đã verify — ảnh hưởng trực tiếp buổi demo

`BookingController.create` khai:

```java
@PreAuthorize("hasAnyRole('USER','COACH','STAFF','ADMIN') and hasAuthority('EMAIL_VERIFIED')")
```

Tài liệu cũ ghi "login email/password không gate theo `emailVerified`" — **đúng với login, nhưng sai nếu hiểu là cả luồng demo không cần verify**. Người dùng mới đăng ký sẽ **403 `FORBIDDEN`** ngay ở bước đặt sân, tức chết đúng giữa buổi demo.

Đường verify: `user-service` gửi mail chứa link `${FRONTEND_URL}/verify-email?token=<uuid>` → FE gọi `GET /api/auth/verify-email?token=...`.

> 📌 **Day 4 — `FRONTEND_URL` là biến DUY NHẤT có ngoại lệ per-service.**
>
> Mọi biến non-secret khác đều dùng chung một giá trị từ ConfigMap `app-config`. Riêng biến này
> **chat-service phải nhận giá trị khác** với 8 service còn lại:
>
> | Ai | Giá trị | Lấy từ |
> |---|---|---|
> | 8 service (user-service dựng link email verify/reset) | URL công khai của env | `app-config` (ConfigMap) |
> | **chat-service** (allowed-origin của WS handshake) | **`"*"`** | block `env:` của `values/chat-service-<env>.yaml` |
>
> Vì sao phải tách: `charts/platform/templates/configmap.yaml` phát biến này **vô điều kiện cho
> mọi service**, mà **env tường minh thắng default `*` nằm trong image chat-service** → pattern
> thành ALB DNS → **WS 403**. Đặt `*` ở platform values thì hỏng link email (`*/verify-email?…`).
> Đây là chỗ dùng đúng cơ chế `env` thắng `envFrom` của K8s.
> ⚠️ Chỉ đúng với image chat-service build **sau** patch (`setAllowedOriginPatterns`).
> Chi tiết + bẫy "Origin không có `/` cuối" + đường Day 8: [`ingress-alb.md`](ingress-alb.md).

**Hệ quả phải xử lý trước demo** (chọn 1):

| Cách | Đánh đổi |
|---|---|
| `SENDGRID_API_KEY` **thật** trong SSM | mail gửi được → luồng tự nhiên, nhưng người xem phải mở hộp thư |
| Seed sẵn 1-2 tài khoản đã verify | không phụ thuộc mail, nhưng phải có bước seed sau mỗi rebuild (đụng tiêu chí 0 thao tác tay) |
| Người xem dùng tài khoản demo dựng sẵn | đơn giản nhất cho buổi 5–10 phút |

Khi `SENDGRID_API_KEY` rỗng, `EmailServiceImpl` **log link ra console** thay vì gửi (`[DEV] Email verify link for <email>: ...`) — tiện cho kind, vô dụng cho người dùng thật.

## Bẫy đã biết

- **1 PostgreSQL / 5 DB** (compose local chạy 9 PG riêng — ở K8s gộp 1 instance). Mỗi service trỏ full-URL `DB_<SVC>_URL` → **0 đổi code**. `initdbScripts` tạo: `user_db, court_db, booking_db, payment_db, escrow_db`. (escrow **không** Redis · chat **không** Postgres, chỉ Mongo.)
- **`SPRING_PROFILES_ACTIVE=prod` → `payment-service` và `chat-service` BẮT BUỘC có `CLOUDINARY_*`**, thiếu = fail boot. Đây là **by design** (`CloudinaryProdGuard` `@Profile("prod")`), đừng "sửa" bằng cách bỏ profile.
- **`VITE_WS_URL`: BỎ** khỏi mọi values — nó trỏ `matchmaking-service :3004`, service không deploy.
- **`VITE_GOOGLE_CLIENT_ID`: vẫn bake** vào image FE (public client ID, không phải secret). Thiếu → nút Google bị `disabled`, nhưng đường login của demo là **email/password**, không phải Google.
- **Tên file**: `values/<svc>-<env>.yaml`, không có ngoại lệ. Sai tên = deploy im lặng không xảy ra (xem [`gitops-workflow.md`](gitops-workflow.md) rule 2).

Liên quan: [`bitnami-datastores.md`](bitnami-datastores.md) · [`secrets-eso.md`](secrets-eso.md)
