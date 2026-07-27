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

```yaml
controller.replicaCount: 1
listeners.client.protocol: PLAINTEXT
sasl.enabled: false                        # chart mới mặc định SASL_PLAINTEXT, client chỉ có bootstrap-servers
offsets.topic.replicationFactor: 1
transaction.state.log.replicationFactor: 1
autoCreateTopicsEnable: true               # ⚠️ BẮT BUỘC
```
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
- ghim chart version (`--version <x.y.z>`), **và**
- override registry (`global.imageRegistry` + `image.repository: bitnamilegacy/<img>`), **hoặc** mirror ảnh vào ECR (hợp tinh thần reproducible hơn).

## Check nhanh (làm trên kind, miễn phí — đừng để lộ ra trên EKS)

```bash
kubectl -n data exec statefulset/redis-master -- redis-cli ping                     # PONG, KHÔNG phải NOAUTH
kubectl -n badminton exec deploy/chat-service -- sh -c 'echo $MONGODB_CHAT_URI'     # phải có ?authSource=admin
kubectl -n data exec statefulset/kafka-controller -- kafka-topics.sh --list \
  --bootstrap-server localhost:9092 | grep booking.slot.changed                     # topic tự sinh sau 1 lần đặt sân
kubectl -n badminton exec deploy/api-gateway -- sh -c 'nc -z rabbitmq.data 61613'   # STOMP port mở
```

> Docker Desktop cần **≥ 12 GB RAM** cho 5 datastore + 9 service trên kind. Thiếu RAM → deploy 2 đợt (infra trước, app sau).
