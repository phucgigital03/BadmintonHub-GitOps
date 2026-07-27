---
allowed-tools: Bash(helm:*), Bash(kubectl:*), Bash(argocd:*), Bash(curl:*), Bash(aws:*), Bash(git:*), Bash(ls:*), Read, Grep, Glob
argument-hint: [số Day 1-8] (vd: 4)
description: Chạy Definition of Done của một Day — verify bằng lệnh thật, không suy đoán
---
## Bối cảnh cụm hiện tại
!`kubectl config current-context 2>/dev/null || echo "(chưa có kubecontext — chưa dựng cụm)"`
!`kubectl get pods -A --no-headers 2>/dev/null | awk '{print $1"/"$2"\t"$4}' | head -30 || echo "(không kết nối được cụm)"`
!`kubectl get applications -n argocd 2>/dev/null || echo "(chưa có ArgoCD — Day 6 chưa làm)"`
!`ls values/ 2>/dev/null | head -40 || echo "(values/ chưa dựng)"`

Verify **Day $ARGUMENTS** đã "Done" thật chưa.

1. Đọc `Planning_CICD.md` §**Day $ARGUMENTS** — lấy **✅ Check** và mục **DoD** trong khối prompt paste-ready. **Chạy ĐÚNG các lệnh ở đó**, không tự nghĩ tiêu chí thay thế.
2. Nếu Day đó có phần ở app repo → nêu rõ phần nào **không kiểm được từ repo này**, đừng đánh dấu xanh hộ.
3. Kiểm thêm các bẫy im lặng đặc trưng của repo này (áp dụng phần nào liên quan tới Day $ARGUMENTS):
   - **Tên values**: mọi file phải đúng `values/<svc>-<env>.yaml`, đủ **9 svc × 3 env**. Sai tên = CI xanh, ArgoCD không đọc, **deploy im lặng không xảy ra**.
   - **`values/<svc>-prod.yaml` có `image.tag` hợp lệ** (không rỗng, không `latest`) — nếu rỗng, 9 app prod `ImagePullBackOff`.
   - **Chart render được cho CẢ `frontend` lẫn `eureka-server`** bằng cùng `charts/service` → chart đủ generic cho ApplicationSet.
   - **Probe** không dùng `/actuator/health` composite cho liveness.
   - **ApplicationSet** có `labels {env, svc}` + `syncOptions: [CreateNamespace=true]`.
   - **`kubectl get externalsecret -A`** toàn bộ `SecretSynced`.
   - **Không có secret thô** trong git: `git grep -nEi '(password|secret|api[_-]?key|token)\s*:\s*["'\'']?[A-Za-z0-9+/=]{12,}' -- '*.yaml'` phải rỗng.
4. Báo cáo **✅/❌ từng tiêu chí kèm output thật**. ❌ → chỉ rõ nguyên nhân (pod log, `argocd app get`, `describe externalsecret`) rồi **HỎI trước khi sửa rộng** — không tự ý refactor chart/values.

Không chạy được lệnh nào (chưa có cụm) → ghi **"chưa verify — cần cụm"**, tuyệt đối không suy ra "đạt" từ việc file đã tồn tại.
