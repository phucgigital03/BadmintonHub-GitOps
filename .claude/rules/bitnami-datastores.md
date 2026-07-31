---
description: 5 datastore Bitnami in-cluster — mọi default đánh nhau với app và bắt buộc override (Redis auth, Kafka SASL/auto-topic, Mongo authSource, RabbitMQ STOMP, Postgres superuser) + bẫy registry bitnamilegacy.
globs: infra/**/*.yaml, values/infra*.yaml
---

# Bitnami datastores — 5 default PHẢI override

Datastore chạy **in-cluster** (ns `data-<env>`), chart Bitnami, **ghim chart version**. Không dùng RDS/ElastiCache (ngoài scope, xem Phụ lục B).

> Quy tắc chung: **mọi default của Bitnami đều đánh nhau với app này.** Chưa override thì mặc định là hỏng, không phải mặc định là chạy.

## 🔴 Redis — cái vỡ to nhất

```yaml
auth.enabled: false          # app KHÔNG có chỗ nhập password
architecture: standalone     # → Service tên redis-master
```
Đã kiểm `api-gateway`, `user`, `court`, `booking`, `payment`, `chat`: chỉ khai `spring.data.redis.host` + `port`, **không có field `password`** → auth bật = mọi lệnh trả `NOAUTH`. Nặng hơn: gateway có `default-filters: RequestRateLimiter` áp cho **mọi route** → **toàn bộ request 500**, không phải mất một tính năng.
*(Muốn giữ auth: nạp env `SPRING_DATA_REDIS_PASSWORD` từ Secret — relaxed binding của Spring Boot nhận, vẫn 0 đổi code.)*

## ⚠️ Kafka — SASL + auto-create topic

> 🔴 **Key đã đổi ở chart 32.x** (bản đang ghim). `sasl.enabled` và `autoCreateTopicsEnable`
> **không còn tồn tại**. Helm **bỏ qua key sai trong im lặng** nên viết theo bản cũ thì
> `helm template` vẫn xanh, deploy vẫn lên, và bạn chỉ phát hiện lúc client không kết nối được.

```yaml
# Tắt SASL = đặt protocol của CẢ BA listener, không có công tắc sasl.enabled nữa
listeners:
  client:      { protocol: PLAINTEXT }
  controller:  { protocol: PLAINTEXT }
  interbroker: { protocol: PLAINTEXT }
controller:
  replicaCount: 1
  # thay cho autoCreateTopicsEnable + *.replicationFactor của chart cũ
  overrideConfiguration:
    auto.create.topics.enable: "true"      # ⚠️ BẮT BUỘC
    offsets.topic.replication.factor: "1"
    transaction.state.log.replication.factor: "1"
    transaction.state.log.min.isr: "1"
    default.replication.factor: "1"
    min.insync.replicas: "1"
```

Verify đã ăn: `helm template ... | grep -E 'auto.create.topics.enable|security.protocol.map'` phải thấy `auto.create.topics.enable=true` và `CONTROLLER:PLAINTEXT,CLIENT:PLAINTEXT,INTERNAL:PLAINTEXT`.
Code publish/consume **~17 topic theo tên ở runtime** (`booking.slot.changed`, `payment.proof.submitted`, `payment.host.confirmed`, `payment.refund.queued`, `escrow.host.reimbursed`, …) và **không có bean `NewTopic`** nào. `docker-compose.yml` local có `KAFKA_AUTO_CREATE_TOPICS_ENABLE: true` nên bẫy này không lộ ra khi dev. Không bật → consumer treo / producer `UNKNOWN_TOPIC_OR_PARTITION`, **im lặng**, triệu chứng duy nhất là "đặt sân xong slot không cập nhật".

## ⚠️ MongoDB — `authSource`

Root user nằm ở db `admin`. URI trỏ `/chat_db` bằng creds root mà thiếu `?authSource=admin` → **auth fail lúc boot**.
Chọn 1: thêm `?authSource=admin` vào `MONGODB_CHAT_URI`, **hoặc** (sạch hơn) khai user scoped qua `auth.usernames` / `auth.passwords` / `auth.databases`.

## ⚠️ RabbitMQ — là 3–4 chỗ riêng, không phải 1

```yaml
extraPlugins: "rabbitmq_stomp"      # bật plugin
extraContainerPorts: [...61613]     # mở port trên POD
service.extraPorts: [...61613]      # mở port trên SERVICE
auth.username: badminton            # khớp default RABBITMQ_USER trong code
```
Thiếu **bất kỳ** cái nào → chat-service kết nối STOMP relay thất bại.

## ⚠️ PostgreSQL — superuser

Dùng **`postgres`** (`auth.postgresPassword`) cho cả 5 DB: `ddl-auto=update` cần quyền tạo schema, và app chỉ có **một** cặp `POSTGRES_USERNAME`/`POSTGRES_PASSWORD` dùng chung. 5 DB tạo bằng `initdbScripts`.

## ⚠️ Registry 2025→2026 — `bitnamilegacy`

Từ 28/8/2025 ảnh free chuyển sang `bitnamilegacy`, nhiều tag `docker.io/bitnami/*` bị gỡ → chart mặc định có thể **pull 404**. Bắt buộc cho **cả 5**:
- ghim chart version, **và**
- override `<chart>.image.repository: bitnamilegacy/<img>`, **hoặc** mirror ảnh vào ECR.

Hai cái bẫy đi kèm:

- 🔴 **`global.security.allowInsecureImages: true` là BẮT BUỘC.** Chart Bitnami từ 2025 có bước verify image và sẽ **chặn render** với `Original containers have been substituted for unrecognized ones` ngay khi `repository` khác mặc định.
- 🔴 **Chart mới nhất trỏ `tag: latest`** (Bitnami Secure Images) — vừa không ghim được, vừa 404 với tài khoản free. Chọn version có **tag tường minh**, rồi verify: `docker manifest inspect bitnamilegacy/<img>:<tag>`.

**Version đang ghim ở `infra/Chart.yaml`** (đã verify tag có trong `bitnamilegacy`):
`postgresql 16.7.27` · `redis 21.2.13` · `kafka 32.4.3` · `mongodb 16.5.45` · `rabbitmq 16.0.14`.

## 🔴 MongoDB của Bitnami chỉ có amd64 — kind trên Apple Silicon KHÔNG chạy được

Đã kiểm `bitnamilegacy/mongodb` các tag `8.0.13`, `8.0.4`, `7.0.14`, `latest`: **amd64 only**. Node kind trên máy dev arm64 sẽ cho pod chết với `exec format error` mà log không nhắc gì tới kiến trúc. 4 datastore còn lại đều multi-arch nên bẫy này chỉ dính Mongo.

Cách xử ở repo này: `infra/templates/mongodb-oss.yaml` dựng Mongo bằng image chính chủ `mongo:8.0` (multi-arch), bật bằng `mongodbOss.enabled` và **chỉ dùng cho `dev`**. EKS là amd64 nên `staging`/`prod` vẫn dùng chart Bitnami. Hai đường cho ra **cùng** Service `mongodb:27017` + root user ở db `admin`, nên `MONGODB_CHAT_URI` (kể cả `?authSource=admin`) giống hệt nhau ở mọi env. Template có guard `fail` nếu bật cả hai.

## Check nhanh (làm trên kind, miễn phí — đừng để lộ ra trên EKS)

```bash
kubectl -n data exec statefulset/redis-master -- redis-cli ping                     # PONG, KHÔNG phải NOAUTH
kubectl -n badminton exec deploy/chat-service -- sh -c 'echo $MONGODB_CHAT_URI'     # phải có ?authSource=admin
kubectl -n data exec statefulset/kafka-controller -- kafka-topics.sh --list \
  --bootstrap-server localhost:9092 | grep booking.slot.changed                     # topic tự sinh sau 1 lần đặt sân
kubectl -n badminton exec deploy/api-gateway -- sh -c 'nc -z rabbitmq.data 61613'   # STOMP port mở
```

> Docker Desktop cần **≥ 12 GB RAM** cho 5 datastore + 9 service trên kind. Thiếu RAM → deploy 2 đợt (infra trước, app sau).
