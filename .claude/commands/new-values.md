---
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(helm:*), Bash(ls:*)
argument-hint: [service] (vd: chat-service) — sinh đủ 3 env dev/staging/prod
description: Sinh values/<svc>-{dev,staging,prod}.yaml đúng hợp đồng đặt tên, lấy env từ application.yml thật
---
## Values đã có
!`ls values/ 2>/dev/null || echo "(values/ chưa dựng)"`

Sinh values cho service **$ARGUMENTS**, đủ **3 env** (`dev`, `staging`, `prod`).

## Bước 1 — lấy sự thật, đừng suy đoán
1. Đọc `../badmintonHub/$ARGUMENTS/src/main/resources/application.yml` → liệt kê **mọi** biến `${...}`. Đây là **nguồn sự thật duy nhất** về tên biến; `.env.example` **KHÔNG đầy đủ** (thiếu `CHAT_BROKER_RELAY`, `BOOKING_MAX_HOLD_MINUTES`).
2. Đối chiếu `.claude/rules/values-env-map.md`: port, datastore, probe path của service này.
3. Mở 1 file values đã có (nếu có) làm khuôn — giữ nguyên cấu trúc key, đừng phát minh schema mới.

## Bước 2 — phân loại từng biến
| Loại | Đi đâu |
|---|---|
| Host/URL in-cluster, flag, profile | **ConfigMap** |
| Password, JWT secret, URI có creds, API key | **Secret** — chỉ ref qua `envFrom`, giá trị ở SSM `/badminton/<env>/*` |

**TUYỆT ĐỐI không ghi giá trị secret vào values.** Repo PUBLIC.

## Bước 3 — viết file
- Tên: **`values/$ARGUMENTS-dev.yaml`**, **`-staging.yaml`**, **`-prod.yaml`**. Không có ngoại lệ — sai tên = ArgoCD không đọc, deploy im lặng không xảy ra.
- `image.tag`: SHA thật nếu biết, nếu chưa có thì **SHA placeholder rõ ràng + ghi chú** — **KHÔNG để rỗng, KHÔNG `latest`**. `-prod.yaml` phải có tag hợp lệ ngay (ApplicationSet sinh app prod từ đầu).
- `port` + `livenessPath` + `readinessPath` theo bảng. `frontend` → `port: 80`, cả 2 path = `/`.
- `replicaCount: 1`, `resources.requests: {memory: 128Mi, cpu: 100m}`.
- `dev` trỏ ns `data` trên kind; `staging`/`prod` trỏ `data-staging`/`data-prod`.
- Service không dùng datastore nào thì **bỏ hẳn biến đó**, đừng để giá trị rỗng.

## Bước 4 — verify
```bash
helm lint charts/service -f values/$ARGUMENTS-staging.yaml
helm template t charts/service -f values/$ARGUMENTS-staging.yaml
```
Soi output: probe đúng path, port đúng, envFrom đúng tên, không có secret thô.
Báo lại **danh sách biến → ConfigMap/Secret**, ghi rõ biến nào **không có trong `.env.example`** để người dùng nhớ nạp SSM.
