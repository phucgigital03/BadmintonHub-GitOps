---
description: Chart charts/service/ dùng chung cho cả 9 service — template generic, probe liveness/readiness tách rời, resources, envFrom optional.
globs: charts/**/*.yaml, charts/**/*.tpl, values/*.yaml
---

# Helm chart `charts/service/`

**MỘT chart tái sử dụng cho CẢ 9 service, kể cả `frontend`.** Day 6 ApplicationSet matrix trỏ cả 9 vào chart này — viết chart riêng cho FE/eureka là phá luôn ApplicationSet.

## Chart phải generic thật

| Values key | Ý nghĩa | Vì sao phải template hoá |
|---|---|---|
| `image.repository` / `image.tag` | ECR URL + **git SHA** | CI bump `image.tag`; không bao giờ `latest` |
| `port` | container + Service port | 9 service 9 port khác nhau |
| `livenessPath` / `readinessPath` | **path đầy đủ**, không tự nối chuỗi | FE nginx dùng `/`, Java dùng `/actuator/health/liveness` |
| `envFrom.configMap` / `envFrom.secret` | **optional** | FE không có env Eureka/DB; bật/tắt bằng `{{- if }}` |
| `replicaCount` | mặc định **1** | demo ephemeral |
| `resources` | requests `128Mi/100m` | node `t3.xlarge` phải gánh staging + prod + obs |

Template tối thiểu: `Deployment` + `Service` (ClusterIP) + `_helpers.tpl`. Ingress **không** nằm trong chart này (xem [`ingress-alb.md`](ingress-alb.md)).

## 🔴 Probe — Spring Security chặn `/actuator/health/**` (đo thật, Day 2)

**Đây là thứ phải đọc trước tiên khi động vào probe.** Trên kind, `user-service`:

```
/actuator/health              → 200      SecurityConfig permitAll đúng path LITERAL này
/actuator/info                → 200      idem
/actuator/health/liveness     → 403      ⬅ probe của chart gọi cái này
/actuator/bat-ky-cai-gi       → 403      ⬅ chứng minh là Security chặn, KHÔNG phải 404
```

`MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED=true` **đã tới container** — endpoint có tồn tại, chỉ là bị chặn ở tầng security. Hệ quả: **pod không bao giờ Ready**, và đúng với **cả 7 service Java có Spring Security** (`eureka-server` thoát vì không có security). Triệu chứng đánh lừa: `connection refused` lúc đang boot rồi `403` sau đó, dễ đọc nhầm thành "app chưa lên".

**Cách đang dùng — 0 đổi code app, giữ nguyên tinh thần của rule:**

| Probe | Path | Vì sao |
|---|---|---|
| liveness | **`/actuator/info`** | không chạm db/redis/mongo/eureka → chỉ fail khi JVM chết hoặc treo thật |
| readiness | **`/actuator/health`** | composite. Dùng composite cho **readiness** là AN TOÀN: Redis chết thì pod bị rút khỏi Endpoints chứ **không bị restart** → không có cascade. |

> Điểm cốt lõi của rule chưa bao giờ là "phải dùng endpoint `/liveness`", mà là **liveness không được phụ thuộc datastore**. `/actuator/info` thoả điều đó còn chặt hơn.

**TODO (repo app, khi thuận tiện)**: thêm `/actuator/health/**` vào `permitAll` trong `SecurityConfig` (1 chỗ ở `common-security` là đủ cho cả 7), build lại 8 image, rồi đổi probe về đúng nhóm `liveness`/`readiness` của Spring Boot — nhóm đó lọc sẵn component không thiết yếu nên chính xác hơn composite.

## ⚠️ Vì sao KHÔNG dùng `/actuator/health` cho liveness

`/actuator/health` là **composite** gộp `db` + `redis` + `mongo` + `discoveryComposite` (Eureka). Redis hoặc Eureka nhấp nháy 3 nhịp → liveness fail → **K8s restart pod** → pod restart lại làm Redis/Eureka thêm tải → **cascade restart đúng giữa buổi demo**. Đây là anti-pattern K8s kinh điển, không phải chuyện "đủ cho demo".

Cách sửa tốn **0 dòng code, 0 dòng pom** — 1 biến env trong ConfigMap:
`MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED=true` → mở `/actuator/health/liveness` + `/readiness`.

```yaml
startupProbe:                    # cho JVM thời gian boot, tránh liveness giết sớm
  httpGet: { path: {{ .Values.livenessPath }}, port: {{ .Values.port }} }
  failureThreshold: 60           # 60×5s = 300s
  periodSeconds: 5
  timeoutSeconds: 5
livenessProbe:
  httpGet: { path: {{ .Values.livenessPath }}, port: {{ .Values.port }} }
  periodSeconds: 10
  failureThreshold: 3
  timeoutSeconds: 5
readinessProbe:
  httpGet: { path: {{ .Values.readinessPath }}, port: {{ .Values.port }} }
  periodSeconds: 10
  failureThreshold: 3
  timeoutSeconds: 5
```

### 🔴 `timeoutSeconds` phải khai tường minh — mặc định là 1 giây

Probe **timeout bị tính y hệt probe fail**. Actuator của Spring Boot dưới sức ép CPU/RAM thường trả lời chậm hơn 1s → K8s giết pod đang **khoẻ**, pod restart lại làm cụm thêm tải → đúng cái cascade mà việc tách liveness/readiness sinh ra để tránh.

**Đã dính thật ở Day 2** (kind): `eureka-server` và `api-gateway` bị giết với
`Liveness probe failed: context deadline exceeded (Client.Timeout exceeded while awaiting headers)` — chú ý là *timeout*, không phải *connection refused*, nên đừng đọc nhầm thành "app chưa lên".
Không phải chuyện riêng của máy yếu: node EKS `t3.xlarge` cũng gánh staging + prod + observability.

### `failureThreshold: 30` là quá ít cho JVM

Day 1 đo thật (`docker-compose.app.yml`): một Spring web context mất **128s** để khởi tạo, và compose phải đặt `start_period: 300s`. Trên kind đo lại: `Root WebApplicationContext: initialization completed in 124696 ms`. 30×5s = 150s sẽ giết pod giữa lúc boot hợp lệ → dùng **60** (300s).

### liveness `failureThreshold: 6`, readiness giữ `3`

Liveness trả lời câu hỏi *"app còn sống không"*, không phải *"app có nhanh không"*. 6×10s = **60s** im lặng mới restart — vẫn bắt được treo thật (deadlock, JVM đứng) nhưng không giết pod chỉ vì một đợt GC dài hoặc lúc node đang bận boot service khác. Với `3` (30s) đã thấy pod bị restart oan ngay cả sau khi đã nới `timeoutSeconds`.
Readiness thì **giữ nhạy**: rút pod chậm ra khỏi Service là đúng, và nó không giết pod.

### Đọc đúng triệu chứng probe — 2 lỗi khác hẳn nhau

| Message | Nghĩa | Sửa ở đâu |
|---|---|---|
| `connection refused` | cổng **chưa mở** — JVM còn đang boot | `startupFailureThreshold` (ngân sách boot) |
| `context deadline exceeded (Client.Timeout ...)` | cổng đã mở nhưng **trả lời chậm** | `probeTimeoutSeconds` / `livenessFailureThreshold` |

Đọc nhầm hai cái này là đi sai hướng cả buổi. Và để ý probe nào báo: `failed **startup** probe` khác hẳn `failed **liveness** probe`.

### Nút thắt trên kind là CPU, không phải RAM

Đo thật ở Day 2 (máy 8 CPU / Docker 5.78 GB): thả 4 service boot cùng lúc → CPU node **954-1298%** (trần 800%), trong khi RAM mới dùng **2.2/5.8 GB**. Mọi JVM chậm lại → không cái nào mở nổi cổng trong 300s → K8s giết pod đang boot **hợp lệ** → restart lại càng nặng thêm.

Hai hệ quả đã đưa vào repo: `values/<svc>-dev.yaml` dùng `startupFailureThreshold: 180` (900s, so với 60 ở staging/prod), và `scripts/kind-deploy.sh` deploy **tuần tự nghiêm ngặt** — Spring boot xong thì gần như không ăn CPU, nên tuần tự là cách duy nhất hội tụ được. Đừng "tối ưu" bằng cách chạy song song cho nhanh.

### `strategy: Recreate` cho posture 1 replica trên máy chật

`RollingUpdate` + `replicaCount: 1` ⇒ `maxUnavailable=0` ⇒ pod **cũ** phải sống tới khi pod **mới** Ready ⇒ **hai JVM cùng chạy** đúng lúc pod mới cần CPU nhất để boot. Trên kind điều này làm rollout không bao giờ hội tụ.
→ `dev`: `Recreate` (chấp nhận gián đoạn vài chục giây). `staging`/`prod`: giữ `RollingUpdate` để không gián đoạn trước mặt người dùng.

**Bằng chứng đã tách đúng** (làm trên kind, miễn phí): `kubectl scale --replicas=0` Redis → `/actuator/health` trả **503** nhưng `/actuator/health/liveness` **vẫn 200** → pod **không** restart.

## 🔴 `MaxRAMPercentage=75` + limit chật = OOMKilled (đo thật, Day 2)

Image bake sẵn `JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=75`. Heap lấy 75% limit, **phần còn lại phải đủ cho metaspace + thread stack + code cache + direct buffer** — Spring Boot cần khoảng **150–200Mi** cho phần đó.

| limit | % | heap | còn lại cho non-heap | kết quả |
|---|---|---|---|---|
| 448Mi | 75 | 336Mi | **112Mi** | ❌ OOMKilled |
| 448Mi | 55 | 248Mi | 200Mi | ❌ **vẫn** OOMKilled khi Redis chết |
| 640Mi | 55 | 352Mi | 288Mi | ổn |
| 768Mi | 70 | 538Mi | 230Mi | ổn (staging/prod) |

Hai lần chỉnh mới ra: hạ tỉ lệ **không đủ**, phải nâng cả limit. Lý do là kịch bản Redis chết làm request readiness tồn đọng (xem mục dưới) nên đỉnh RSS cao hơn hẳn lúc chạy bình thường. Đo lúc mọi thứ khoẻ rồi kết luận "448Mi là đủ" là sai — phải đo cả lúc datastore hỏng.

`values/<svc>-dev.yaml`: `limits.memory: 640Mi` + `env.JAVA_TOOL_OPTIONS: "-XX:MaxRAMPercentage=55"`. staging/prod: `768Mi` + `70`.

Verify nhanh trong container: `java -XX:+PrintFlagsFinal -version | grep MaxHeapSize`.

⚠️ Ghi đè `JAVA_TOOL_OPTIONS` **thay thế hoàn toàn** giá trị trong image, nên phải khai lại cả `-XX:+UseContainerSupport`.

### Composite `/actuator/health` KHÔNG trả 503 ngay — nó TREO

Khi Redis chết, đo được ở readiness probe theo đúng thứ tự này:

```
Readiness probe failed: ... EOF
Readiness probe failed: HTTP probe failed with statuscode: 503
Readiness probe failed: ... context deadline exceeded   (x24)
```

Health indicator của Redis **block tới khi hết timeout của chính nó**, dài hơn `timeoutSeconds` của probe. Kubelet bỏ cuộc nhưng request phía server vẫn chạy tiếp, và cứ 10s lại thêm một request nữa → tồn đọng thread + buffer → góp phần đẩy pod qua limit.

Hệ quả thực dụng: dùng composite cho readiness là **chấp nhận được** (không restart pod) nhưng **đừng đặt `periodSeconds` quá ngắn** và đừng để limit RAM sát mép. Nếu sau này permit được `/actuator/health/**` ở repo app thì nhóm `readiness` chuẩn của Spring Boot không có vấn đề này vì nó lọc sẵn component không thiết yếu.

## Graceful shutdown (Day 7)

`preStop` sleep + `terminationGracePeriodSeconds` là **bắt buộc**, không phải nice-to-have: Eureka `lease-expiration-duration-in-seconds: 30` nghĩa là bản ghi cũ còn sống 30s sau khi pod chết → gateway route vào pod đã chết = **5xx trước mặt khán giả**.

> ⚠️ **KHÔNG tạo `PodDisruptionBudget`** ở posture 1-replica: `minAvailable: 1` trên Deployment 1 replica **chặn vĩnh viễn mọi drain/eviction tự nguyện** (không thể có 1 pod available trong khi evict pod duy nhất). Với spot thì PDB cũng không bảo vệ được gì (interruption là *involuntary*). PDB chỉ có nghĩa khi scale ≥ 2.

## Verify chart trước khi commit

```bash
helm lint charts/service -f values/user-service-staging.yaml
helm template t charts/service -f values/frontend-staging.yaml     # FE: không envFrom Eureka, probePath /
helm template t charts/service -f values/eureka-server-staging.yaml
```

Render được **cả `frontend` lẫn `eureka-server`** bằng đúng chart này = chart đã đủ generic.
Liên quan: [`values-env-map.md`](values-env-map.md) · [`gitops-workflow.md`](gitops-workflow.md)
