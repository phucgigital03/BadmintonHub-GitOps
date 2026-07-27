---
allowed-tools: Bash(helm:*), Bash(ls:*), Bash(git grep:*), Read, Grep, Glob
argument-hint: [svc-env] (tuỳ chọn, vd: chat-service-staging — bỏ trống = kiểm cả 9 svc × 3 env)
description: Lint + render chart/values, bắt lỗi trước khi ArgoCD sync
---
## Values hiện có
!`ls values/ 2>/dev/null || echo "(values/ chưa dựng)"`

Verify chart + values: **$ARGUMENTS** (bỏ trống = toàn bộ).

1. **Hợp đồng đặt tên** — mọi file phải khớp `values/<svc>-<env>.yaml`, `env ∈ {dev,staging,prod}`, `svc ∈ {eureka-server, api-gateway, user-service, court-service, booking-service, payment-service, escrow-service, chat-service, frontend}`. Liệt kê file **thiếu** và file **thừa/sai tên**.
   > Sai tên là bẫy đắt nhất của repo này: CI vẫn xanh, commit vẫn vào, ArgoCD không đọc → deploy im lặng không xảy ra.
2. **Lint + render**:
   ```bash
   helm lint charts/service -f values/<svc>-<env>.yaml
   helm template t charts/service -f values/<svc>-<env>.yaml
   ```
   Bắt buộc render được **cả `frontend`** (nginx `:80`, probe `/`, không envFrom Eureka) **lẫn `eureka-server`** bằng **cùng** chart → bằng chứng chart đủ generic cho ApplicationSet Day 6.
3. **Soi output render**, không chỉ nhìn exit code:
   - `image.tag` = **git SHA**, không `latest`, không rỗng — kiểm **cả `-prod.yaml`**.
   - `livenessProbe`/`readinessProbe` **không** trỏ `/actuator/health` trần; có `startupProbe`.
   - `port` khớp bảng service (`values-env-map.md`).
   - `replicas: 1`, `resources.requests` có mặt.
   - `envFrom` trỏ đúng tên ConfigMap/Secret (`app-secrets` khớp `ExternalSecret.target`).
   - Không có giá trị secret thô nào trong output.
4. **Ingress** (nếu có trong scope): render với `certificateArn` rỗng → chỉ listener 80, **không** có `rules[].host`; render với `certificateArn` điền tay → đủ **3 annotation** `certificate-arn` + `listen-ports` + `ssl-redirect`. Đây là bài kiểm "đường may Day 8 còn dùng được".
5. **Quét secret leak**:
   ```bash
   git grep -nEi '(password|secret|api[_-]?key|token)\s*:\s*["'\'']?[A-Za-z0-9+/=]{12,}' -- '*.yaml'
   ```
   Phải rỗng.

Báo ✅/❌ từng mục kèm output. ❌ → chỉ rõ `file:line` và fix tối thiểu, hỏi trước khi đổi cấu trúc chart.
