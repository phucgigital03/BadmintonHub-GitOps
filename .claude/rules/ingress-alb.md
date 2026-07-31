---
description: Ingress ALB một bản duy nhất — 2 công tắc host/certificateArn cho Day 8, annotation group.name + idle_timeout, FE same-origin, và vì sao TUYỆT ĐỐI không cert-manager.
globs: infra/**/*ingress*.yaml, charts/**/*ingress*.yaml
---

# Ingress ALB + domain

**Một bản Ingress template hoá duy nhất** dùng cho mọi env và cho **cả trước lẫn sau khi có domain**. Rule: `/`→`frontend:80` · `/api`+`/ws`→`api-gateway:3000`.

## 2 công tắc — toàn bộ "đường may" của Day 8

```yaml
# infra/values/ingress-staging.yaml  (và -prod.yaml)
ingress:
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

## Annotation bắt buộc

```yaml
kubernetes.io/ingress.class: alb
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

- `group.name` — gộp `staging` + `prod` vào **một** ALB thay vì hai: tiết kiệm $0.0225/giờ và ~2' provisioning mỗi `apply`.
- `idle_timeout=300` — mặc định ALB là **60s**, đủ để **ngắt WebSocket chat** khi người dùng ngồi im giữa buổi demo. Rất khó quy trách nhiệm lúc đang demo.
- **TTL = `60`, đặt ngay từ bản template.** Mặc định ExternalDNS là 300s; cụm rebuild mỗi buổi ra ALB mới mà record cũ còn trong cache resolver 5' → URL chết đúng đầu buổi demo và bạn sẽ nghĩ là cụm hỏng.

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
2. 🔴 **allowed-origin của WebSocket handshake** (`chat-service`: `app.frontend-url` → `WebSocketConfig.setAllowedOrigins(...)`). Sai giá trị = **chat chết trong khi mọi luồng khác vẫn xanh**, rất khó truy ra.

Chỗ (2) **đe doạ trực tiếp tiêu chí vàng "0 thao tác tay"**: ALB DNS đổi sau mỗi `apply`, nên nếu `setAllowedOrigins` không nhận wildcard thì mỗi buổi demo lại phải sửa ConfigMap. **Việc của Day 4**: đọc `chat-service/.../WebSocketConfig.java`, xem đổi được sang `setAllowedOriginPatterns("*")` không (đây là thứ Spring hỗ trợ cho trường hợp origin động). Nếu không đổi được thì phải chấp nhận 1 bước sửa values sau mỗi `apply` — và phải biết trước, đừng phát hiện lúc T-2.

Day 8 có domain thì set 1 lần là đúng vĩnh viễn, cả (1) lẫn (2).

## Check

```bash
kubectl get ingress -A                                              # phải có ADDRESS; không có → kiểm subnet tag (Day 3)
curl -s http://<ALB-DNS>/api/actuator/health                        # 200
helm template t <chart> -f infra/values/ingress-staging.yaml \
  --set ingress.certificateArn=arn:aws:acm:... | grep -c "ssl-redirect"   # = 1 → đường may Day 8 dùng được
# Day 8:
curl -sI https://staging.badminton.$DOMAIN/api/actuator/health      # 200
curl -sI http://staging.badminton.$DOMAIN                           # 301 → https
```

> ⚠️ Trước Day 8 (http): ở màn thanh toán **đọc/gõ tay số tài khoản, ĐỪNG bấm nút copy** — `navigator.clipboard` là secure-context-only nên trên http không copy gì, nhưng toast **vẫn báo "Đã copy"** (`PaymentScreen.tsx`). Hết ngay sau Day 8, không cần sửa code.
