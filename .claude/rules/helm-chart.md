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

### 🔴 "Cụm chậm" gần như luôn là VÒNG LẶP RESTART, không phải thiếu phần cứng

Đây là bài học đắt nhất của Day 2 — tôi đã chẩn đoán nhầm một lượt trước khi tìm ra.

Quan sát ban đầu: CPU node **954–1298%** (trần 800%), load average **61**, `kubectl exec` fail với `ttrpc: closed`, `helm` fail với `TLS handshake timeout`. Kết luận vội: "máy 8 GB không đủ".

Kết luận đó **sai**. Nguyên nhân thật là hai bug ở trên — probe 403 và OOMKilled — làm pod chết đi sống lại liên tục, và **mỗi vòng restart lại boot thêm một JVM**. Chính đống JVM boot chồng lên nhau tạo ra cơn bão CPU, chứ không phải workload ở trạng thái ổn định.

Sau khi sửa hai bug: **3 service Ready trong dưới 60 giây, boot song song, 0 restart**, load average từ 61 xuống **3.67**.

**Cách phân biệt** — nhìn `RESTARTS` trước khi đổ lỗi cho phần cứng:

| Dấu hiệu | Nghĩa |
|---|---|
| `RESTARTS` tăng đều ở nhiều pod | vòng lặp restart — đi tìm **nguyên nhân** (probe? OOM?), đừng nới timeout |
| `RESTARTS` = 0 mà vẫn chậm | thật sự thiếu tài nguyên |
| Nhiều pod restart **cùng một thời điểm** | sự kiện tầng node (hết RAM), không phải lỗi từng service |

Chỉ khi `RESTARTS` đã sạch mà vẫn chậm thì mới nói tới ngân sách boot và tuần tự hoá.

### Trần thật của kind trên máy 8 GB: ~6 service

Sau khi hết vòng lặp restart, đo lại: cả **9/9 service đều Ready được** (đủ để chứng minh chart + values + wiring đúng cho cả 9), nhưng node còn **95 MB free** → probe timeout → kubelet giết 6 pod **cùng lúc** với `exit=137`.

Ngân sách: 9 × 640Mi limit = 5.76 GB trên node 5.9 GB — vừa khít, không còn biên. Thực tế chạy ổn định được **~6 service + 5 datastore**.

Hệ quả cho Day 2: chạy **2 lượt** — lượt 1 đường lõi (`eureka` `gateway` `user` `court` `booking` `frontend`) cho e2e login→đặt sân; lượt 2 gỡ bớt rồi dựng `chat-service` để verify Mongo `authSource` + STOMP relay. `scripts/kind-verify.sh` có `have()` nên tự bỏ qua check của service chưa deploy.

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

## 🔴 Hàng rào khởi động — `initContainer` chờ datastore (Day 6)

**Đây là thứ chặn "vòng lặp restart" ở tầng đúng.** Đo thật trên EKS: ArgoCD tạo 18 pod service lúc `02:33:31` còn 10 pod datastore mãi `02:36:03` — sớm hơn **2 phút rưỡi**. Spring chết ngay lúc boot:

```
Caused by: java.net.UnknownHostException: postgresql.data-staging.svc.cluster.local
```

Chú ý: **`UnknownHostException`, không phải `Connection refused`** — Service còn chưa tồn tại nên DNS trả NXDOMAIN. Hai thông báo này chỉ tới hai thế giới khác nhau:

| Message | Nghĩa | Đi tìm ở đâu |
|---|---|---|
| `UnknownHostException` | Service **chưa tồn tại** | thứ tự deploy |
| `Connection refused` | Service có, pod **chưa nghe cổng** | pod datastore đang boot |
| `ConnectTimeoutException` | có thứ gì đó **nuốt gói tin** | NetworkPolicy ([`bitnami-datastores.md`](bitnami-datastores.md)) |

`sync-wave` của ArgoCD **không** chặn được (xem [`argocd-appset.md`](argocd-appset.md) — app vừa tạo chưa có resource nên được chấm Healthy ngay). Nên hàng rào nằm ở kubelet:

```yaml
# charts/service/values.yaml
waitForDatastores: true                                     # default an toàn
waitImage: public.ecr.aws/docker/library/busybox:1.36        # ECR Public, né rate-limit Docker Hub
waitTimeoutSeconds: 300
```

initContainer đọc `DATASTORE_WAIT` từ ConfigMap `app-config` (chuỗi `host:port` do `charts/platform` ghép sẵn theo `dataNamespace`) rồi `nc -z` từng cái. **Đổi env chỉ là đổi 1 dòng values, không phải sửa 18 file.**

- **`false` cho `eureka-server` và `frontend`.** Eureka không chạm datastore nào mà 7 service Java lại đăng ký vào nó lúc boot ⇒ bắt nó xếp hàng sau Postgres/Kafka là tự kéo dài đường găng. Frontend là nginx tĩnh, không có `envFrom.configMap` nên cũng không đọc được biến đó.
- 🔴 **Timeout là bắt buộc, không phải phòng xa.** Hết ngân sách thì initContainer `exit 0` và để app tự thử (lùi về đúng hành vi cũ). Không có timeout thì một cổng bị NetworkPolicy chặn — **đã xảy ra thật với RabbitMQ 61613 ở Day 2** — làm pod kẹt `Init:0/1` **vĩnh viễn**. Đó là hỏng nặng hơn crashloop: crashloop ít ra còn tự khỏi và còn log của app để đọc.

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
