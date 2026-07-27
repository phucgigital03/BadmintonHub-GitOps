---
allowed-tools: Bash(kubectl:*), Bash(argocd:*), Bash(curl:*), Bash(aws:*), Bash(helm:*), Read, Grep
description: Warm-up trước demo §7.3 — kiểm cụm sẵn sàng đón người dùng thật trong 5–10 phút
---
## Trạng thái cụm
!`kubectl config current-context 2>/dev/null || echo "(chưa có kubecontext)"`
!`kubectl get externalsecret -A 2>/dev/null || echo "(chưa có ESO)"`
!`kubectl get applications -n argocd 2>/dev/null || echo "(chưa có ArgoCD)"`
!`kubectl get pods -n staging 2>/dev/null | head -15`
!`kubectl get pods -n data-staging 2>/dev/null | head -15`
!`kubectl get ingress -A 2>/dev/null`

Chạy checklist warm-up **§7.3 A** của `Planning_CICD.md` — đúng thứ tự này, vì thứ tự phản ánh phụ thuộc thật:

1. **`kubectl get externalsecret -A` → tất cả `SecretSynced`.** Kiểm **TRƯỚC** khi xem app: Secret chưa có thì pod `CreateContainerConfigError` và bạn sẽ đi debug nhầm hướng.
2. **`argocd app list` → tất cả `Synced/Healthy`** (18 child + infra + ingress). `kubectl get applications -n argocd -l env=staging` phải ra đúng **9**.
3. **Pod**: `staging` (9 pod) + `data-staging` (5 datastore) đều `Running/Ready`. Chú ý pod `Running` nhưng `0/1 READY` = readiness fail, chưa nhận traffic.
4. **Lấy URL live**: `kubectl get ingress -A` → ADDRESS (ALB DNS **đổi sau mỗi `apply`**). *Sau Day 8: bỏ bước này, URL cố định `https://staging.badminton.<domain>`.*
5. **Smoke**: `curl -s <URL>/api/actuator/health` = 200.
6. **E2E 1 lượt trước khán giả**: login → đặt sân → thanh toán → chat. Đây là bước duy nhất chứng minh URL live thật sự dùng được — **đừng bỏ để tiết kiệm thời gian**.

## Nhắc trước khi mời người thật vào
- ⏱ Cửa sổ demo **5–10'** rồi teardown ngay (`/teardown-check`). Hẹn giờ điện thoại "DESTROY".
- 📹 **Quay màn hình / chụp làm bằng chứng** — cụm sẽ bị xoá, data **không giữ** (`ddl-auto` tạo schema rỗng mỗi lần).
- ⚠️ **Trước Day 8 (http)**: ở màn thanh toán **đọc/gõ tay số tài khoản, ĐỪNG bấm nút copy** — `navigator.clipboard` là secure-context-only nên trên http không copy gì nhưng toast **vẫn báo "Đã copy"** → khán giả paste ra rỗng.
- 🔀 Không có domain thì link email verify/reset trỏ ALB buổi trước — **không chặn demo** (login email/password không gate theo `emailVerified`).

Báo ✅/❌ từng mục kèm output. ❌ ở mục nào → dừng lại xử lý mục đó trước (`/debug`), **đừng mời người dùng vào khi còn ❌**.
