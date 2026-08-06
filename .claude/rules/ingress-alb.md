---
description: Ingress ALB một bản duy nhất — 2 công tắc host/certificateArn cho Day 8, annotation group.name + idle_timeout, FE same-origin, và vì sao TUYỆT ĐỐI không cert-manager.
globs: infra/**/*ingress*.yaml, charts/**/*ingress*.yaml
---

# Ingress ALB + domain

**Một bản Ingress template hoá duy nhất** dùng cho mọi env và cho **cả trước lẫn sau khi có domain**. Rule: `/`→`frontend:80` · `/api`+`/ws`→`api-gateway:3000`.

## Ở đâu trong repo (chốt ở Day 4)

| Thứ | File |
|---|---|
| Template | `charts/platform/templates/ingress.yaml` — **cùng chart với ConfigMap `app-config`** |
| Default | `charts/platform/values.yaml` → block `ingress:` (`enabled: false` cho dev) |
| Công tắc theo env | `infra/values/platform-<env>.yaml` → block `ingress:` |

> Bản kế hoạch cũ ghi `infra/values/ingress-<env>.yaml` **riêng** — đã bỏ. Ingress nằm trong
> chart `platform`, mà chart đó cài bằng **một** release với **một** `-f`; tách file thứ hai
> chỉ tạo thêm một chỗ để quên.

## 2 công tắc — toàn bộ "đường may" của Day 8

```yaml
# infra/values/platform-staging.yaml  (và -prod.yaml)
ingress:
  enabled: true
  host: ""             # rỗng → KHÔNG render rules[].host → ALB nhận mọi Host header → dùng ALB DNS
  certificateArn: ""   # rỗng → chỉ listener 80, không ssl-redirect
```

| Trạng thái values | Kết quả render | Giai đoạn |
|---|---|---|
| cả hai rỗng | không host, listener **80** → `http://k8s-...elb.amazonaws.com` | **Day 4–7** |
| điền cả hai | + host + listener 443 + redirect 80→443 + record Route53 tự tạo | **Day 8** |

Template chỉ render `rules[].host` khi `host` ≠ "", và chỉ render nhóm `certificate-arn` + `listen-ports` + `ssl-redirect` khi `certificateArn` ≠ "".
→ **Day 8 = điền 2 dòng × 2 env + `FRONTEND_URL`, mở PR, ArgoCD sync. Rollback = `git revert`.**

🚩 **KHÔNG đưa domain/TLS vào bất kỳ Day nào trước 8.** Nhưng cũng **KHÔNG viết Ingress hardcode không-host** — mất đường may thì Day 8 phải viết lại manifest dưới áp lực T-2.

## 🔴 staging + prod cùng `group.name` mà cùng `host: ""` → một cái CHẾT IM LẶNG

AWS LB Controller gộp rule của mọi Ingress trong group thành **một** bộ listener rule (sắp theo
`group.order` rồi tới tên). Hai Ingress cùng `host: ""` sẽ cùng khai `/`, `/api`, `/ws` ⇒ rule
của cái đứng sau **không bao giờ khớp** — traffic prod lặng lẽ chảy vào staging. Không lỗi,
không event, `kubectl get ingress` cả hai đều có ADDRESS **giống hệt nhau**.

**Host header chính là thứ tách 2 env, mà host thì chỉ có từ Day 8.**
→ `infra/values/platform-prod.yaml` để **`ingress.enabled: false`** cho tới Day 8; trước đó
prod truy cập bằng `kubectl -n prod port-forward svc/frontend 8082:80`.
*(Đường khác: đổi `groupName` của prod → 2 ALB, +$0.0225/giờ. Không chọn.)*

## Annotation bắt buộc

```yaml
# spec.ingressClassName: alb   ⇦ dùng cái này, KHÔNG dùng annotation kubernetes.io/ingress.class
#                                 (deprecated ở aws-load-balancer-controller v2).
#                                 Verify trước: kubectl get ingressclass alb
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/group.name: badminton                      # staging + prod CHUNG 1 ALB
alb.ingress.kubernetes.io/load-balancer-attributes: idle_timeout.timeout_seconds=300
{{- if .Values.ingress.certificateArn }}
alb.ingress.kubernetes.io/certificate-arn: {{ .Values.ingress.certificateArn }}
alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
alb.ingress.kubernetes.io/ssl-redirect: '443'
{{- end }}
{{- if .Values.ingress.host }}
external-dns.alpha.kubernetes.io/hostname: {{ .Values.ingress.host }}
external-dns.alpha.kubernetes.io/ttl: "60"
{{- end }}
```

- `group.name` — gộp `staging` + `prod` vào **một** ALB thay vì hai: tiết kiệm $0.0225/giờ và ~2' provisioning mỗi `apply`. ⚠️ đọc mục 🔴 ngay trên trước khi bật cả 2 env.
- `idle_timeout=300` — mặc định ALB là **60s**, đủ để **ngắt WebSocket chat** khi người dùng ngồi im giữa buổi demo. Rất khó quy trách nhiệm lúc đang demo.
- **TTL = `60`, đặt ngay từ bản template.** Mặc định ExternalDNS là 300s; cụm rebuild mỗi buổi ra ALB mới mà record cũ còn trong cache resolver 5' → URL chết đúng đầu buổi demo và bạn sẽ nghĩ là cụm hỏng.

## 🔴 Health-check của ALB là tầng THỨ HAI, và mặc định của nó sai với api-gateway

ALB tự probe target group, mặc định path **`/`** + mã **200**. `frontend` (nginx) trả 200 ở `/`
nên qua. Nhưng Spring Cloud Gateway **không có route cho `/`** → **404** → ALB đánh dấu mọi
target unhealthy → **`/api` trả 502 trong khi `kubectl get pods` xanh 100%**.

Khai đè **trên chính Service** (controller ưu tiên annotation ở Service hơn ở Ingress) —
`charts/service` có sẵn `service.annotations`:

```yaml
# values/api-gateway-<env>.yaml
service:
  annotations:
    alb.ingress.kubernetes.io/healthcheck-path: /actuator/info
    alb.ingress.kubernetes.io/success-codes: "200"
```

Vì sao `/actuator/info` chứ không `/actuator/health`: readiness của K8s đã gác composite rồi, mà
pod chưa Ready thì **không được đăng ký** vào target group. Cho ALB dùng composite nữa = một
nhịp Redis nhấp nháy bị phạt **hai** lần. Cùng logic đã chốt ở [`helm-chart.md`](helm-chart.md).

## 🔴 TUYỆT ĐỐI KHÔNG cert-manager / Let's Encrypt

ALB terminate TLS ở **tầng AWS** và chỉ nhận cert từ **ACM/IAM** — **không đọc được K8s Secret** nơi cert-manager cất cert. Gắn vào là **im lặng không có HTTPS**, không có lỗi rõ ràng để lần ra.
*(Phụ: LE giới hạn 5 cert/tuần cùng hostname, mà cụm này rebuild mỗi buổi.)*
HTTPS = **ACM wildcard `*.badminton.<domain>`** ở `terraform/bootstrap/` (stack không bao giờ destroy) + **ExternalDNS** giữ record tự động.
Stack ephemeral đọc cert bằng `data "aws_acm_certificate"` lọc `statuses=["ISSUED"]` — **KHÔNG hardcode ARN**.

## FE same-origin — 1 image cho mọi env

FE gọi `/api` **tương đối** và derive WS từ `window.location`:
```ts
const BASE_URL = import.meta.env.VITE_API_URL || '';   // '' → /api/... tương đối
const WS_URL = import.meta.env.VITE_CHAT_WS_URL
  ?? `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`;
```
Hệ quả: ALB DNS đổi sau mỗi `apply` **không cần build lại FE, không cần sửa ConfigMap** · CORS thành same-origin · **và hôm bật HTTPS ở Day 8, FE tự chuyển `ws://`→`wss://`** (bake cứng `ws://` thì chat chết vì mixed content, phát hiện đúng lúc T-2).

⚠️ `FRONTEND_URL` sau same-origin **không còn là CORS origin của gateway**, nhưng **vẫn còn 2 chỗ dùng** — đừng coi nó là biến vô hại:

1. **link email verify/reset** (`user-service` `EmailServiceImpl`). Chưa có domain thì link trỏ ALB buổi trước — **chấp nhận được**, đã verify login email/password không gate theo `emailVerified`.
2. ~~allowed-origin của WebSocket handshake~~ → **ĐÃ ĐÓNG ở Day 4**, xem dưới.

### ✅ Chỗ (2) đã đóng — nhưng bằng ĐỦ HAI NỬA ở HAI repo

`WebSocketConfig.java` ban đầu dùng `setAllowedOrigins(frontendUrl)` — so khớp chuỗi **CHÍNH XÁC**, không nhận wildcard ⇒ thao tác tay mỗi lần rebuild ⇒ vi phạm tiêu chí vàng.

**Nửa 1 — repo app:**
```java
@Value("${app.frontend-url:*}")  private String frontendUrl;      // default "*"
registry.addEndpoint("/ws").setAllowedOriginPatterns(frontendUrl.split(","));
// application.yml:  frontend-url: ${FRONTEND_URL:*}
```
**KHÔNG** dùng `setAllowedOrigins("*")` — Spring ném exception lúc khởi động khi `allowCredentials` bật.

**Nửa 2 — repo này:** `values/chat-service-{staging,prod}.yaml` → `env: { FRONTEND_URL: "*" }`

🔴 **Nửa 2 bắt buộc dù image đã default `*`.** `charts/platform/templates/configmap.yaml` phát `FRONTEND_URL` cho **mọi** service vô điều kiện (user-service cần nó cho link email), mà **env tường minh luôn thắng default của image** ⇒ pattern thành ALB DNS ⇒ 403. Tức là **chính ConfigMap của ta vô hiệu hoá default đã đúng sẵn trong image** — cả hai repo đều làm đúng phần mình mà hệ thống vẫn hỏng.

**Đừng** sửa `frontendUrl` ở `platform-*.yaml` thành `*`: user-service dựng `${FRONTEND_URL}/verify-email?token=…` từ cùng biến đó.

- Bảo mật: chấp nhận được vì auth STOMP là **JWT ở header CONNECT**, không phải cookie.
- ⚠️ Chỉ hiệu lực với image chat-service **build sau khi patch** — values còn trỏ SHA cũ thì bẫy vẫn nguyên.
- 💡 Day 8: `.split(",")` nhận nhiều origin → `"https://staging.badminton.<domain>,https://www.badminton.<domain>"`, siết lại được mà không sửa code.

🔴 Bẫy đi kèm: **Origin header không bao giờ có `/` cuối** — `http://host` ≠ `http://host/`, nhìn giống nhau nhưng so khớp fail.

Sau 2 nửa, `FRONTEND_URL` ở platform values chỉ còn dùng cho chỗ (1) → **không phải chạy theo ALB DNS nữa**.

### Cách ĐO handshake WS cho đúng (đã dùng ở Day 4)

🔴 **Đừng đo bằng `/ws/info`** — endpoint đó chỉ tồn tại khi bật SockJS. chat-service dùng
**WebSocket thuần**, nên `/ws/info` rơi xuống static resource handler và `GlobalExceptionHandler`
gói thành **500** — dễ đọc nhầm thành "WS hỏng". Phải làm **handshake thật**:

```bash
KEY=$(openssl rand -base64 16)
curl -s -i -m 5 -N -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: $KEY" \
  -H "Origin: http://$ALB" "http://$ALB/ws" | head -1     # → HTTP/1.1 101 Switching Protocols
```
*(Không có `-m` thì lệnh **treo** — và treo chính là dấu hiệu 101 thành công, vì kết nối WS mở và
giữ. 403 trả về ngay lập tức.)*

**Kết quả đo được ở Day 4 — hai origin, hai tầng khác nhau:**

| Origin gửi lên | Mã | Tầng nào quyết định |
|---|---|---|
| chính ALB host (kịch bản thật, FE same-origin) | **101** | Spring coi là *same-origin* → **bỏ qua CORS**; qua tầng WS nhờ `setAllowedOriginPatterns("*")` |
| `http://evil.example` | **403** | thật sự cross-origin → `CorsFilter` của Spring Security chặn trước |

Hai kết quả này **không mâu thuẫn** và là cấu hình đúng: trang lạ không mở trộm được WS, còn FE
same-origin thì luôn qua **bất kể ALB DNS đổi bao nhiêu lần**.

🔑 Bằng chứng dòng values đã ăn: ALB host **không được khai ở đâu cả** (`platform-staging.yaml`
vẫn là `http://REPLACE-WITH-ALB-DNS`) mà handshake vẫn `101` ⇒ chỉ có thể do `FRONTEND_URL: "*"`.

Day 8 có domain thì set 1 lần là đúng vĩnh viễn, cả (1) lẫn (2).

## Check

```bash
kubectl get ingressclass alb                                        # phải có TRƯỚC khi cài platform
kubectl get ingress -A                                              # phải có ADDRESS; không có → kiểm subnet tag (Day 3)
curl -s -o /dev/null -w '%{http_code}\n' http://<ALB-DNS>/          # 200 (frontend)
# 🔴 KHÔNG nghiệm thu bằng /api/actuator/health — Ingress không rewrite path, gateway nhận
#    nguyên văn "/api/actuator/health" nhưng actuator của nó ở "/actuator/health" → 404.
#    Dùng route nghiệp vụ thật (đo ở Day 4): POST /api/auth/login sai mật khẩu → 401 + JSON.
#    Đọc mã: 502/503 = target group hỏng · 404 = đã tới gateway, sai path · 401/400/405 = đã tới service.
# target group phải healthy — đây là chỗ lộ ra lỗi healthcheck-path ở trên
aws elbv2 describe-target-health --target-group-arn <arn> --query 'TargetHealthDescriptions[].TargetHealth.State'
helm template t charts/platform -f infra/values/platform-staging.yaml \
  --set ingress.certificateArn=arn:aws:acm:... \
  | grep -cE 'certificate-arn|listen-ports|ssl-redirect'            # = 3 → đường may Day 8 dùng được
# Day 8:
curl -sI https://staging.badminton.$DOMAIN/api/actuator/health      # 200
curl -sI http://staging.badminton.$DOMAIN                           # 301 → https
```

## 🔴 Web API "secure-context-only" — cả một LỚP lỗi của giai đoạn http (Day 4–7)

Trình duyệt khoá một số API chỉ cho `https://` hoặc `localhost`. Trên ALB DNS thô (`http://k8s-...`)
chúng **biến mất** — và triệu chứng luôn là *im lặng hoặc sai chỗ*, không bao giờ nói "vì bạn đang
dùng http". Đã đo **2 ca thật ở Day 4**:

| API | Ở đâu | Triệu chứng trên http |
|---|---|---|
| `navigator.clipboard` | `PaymentScreen.tsx` — nút copy số tài khoản | không copy gì, nhưng toast **vẫn báo "Đã copy"** |
| **`crypto.randomUUID()`** | luồng gửi tin nhắn chat | `TypeError: crypto.randomUUID is not a function` → **nút Gửi không làm gì**, dễ đổ oan cho WebSocket/origin |

**Cách nhận ra**: mở DevTools Console. Lỗi kiểu `X is not a function` với một Web API chuẩn, trên
http, gần như luôn là secure context — **đừng đi soi hạ tầng**.

- **Day 8 (HTTPS) sửa cả lớp này miễn phí**, 0 dòng code.
- Cần chạy trước Day 8 → repo app phải tự fallback (vd `crypto.randomUUID?.() ?? <polyfill>`).
- ⚠️ Không test được bằng `localhost` port-forward vào `frontend`: nginx trong image FE dùng
  `resolver 127.0.0.11` (DNS của Docker, không có trong K8s) nên `/api` trả 502.

> ⚠️ Vì vậy trước Day 8: ở màn thanh toán **đọc/gõ tay số tài khoản, ĐỪNG bấm nút copy**, và biết trước rằng **chat có thể không gửi được tin** — cả hai đều hết sau Day 8.
