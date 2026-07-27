---
allowed-tools: Bash(git:*), Bash(kubectl:*), Bash(argocd:*), Bash(gh:*), Read, Edit, Grep, Glob
argument-hint: [svc | all] (vd: booking-service, hoặc all)
description: Promote staging → prod bằng PR đổi image.tag sang đúng SHA đã verify
---
## SHA đang chạy ở staging
!`grep -rn "tag:" values/*-staging.yaml 2>/dev/null || echo "(values/ chưa dựng)"`
## SHA đang ở prod
!`grep -rn "tag:" values/*-prod.yaml 2>/dev/null`
## Trạng thái app staging
!`kubectl get applications -n argocd -l env=staging 2>/dev/null || echo "(chưa có ArgoCD / chưa kết nối cụm)"`

Promote **$ARGUMENTS** từ staging sang prod.

## Luật
- Promote = **PR sửa `values/<svc>-prod.yaml` sang đúng SHA đã verify ở staging**. **KHÔNG build lại image, KHÔNG tag mới** — cùng một image bit-for-bit đi lên, đó là toàn bộ ý nghĩa của promote.
- Chỉ promote SHA đã **thực sự verify** ở staging (app `Synced/Healthy` + smoke test qua). Chưa verify → nói rõ và **dừng lại hỏi**.

## Các bước
1. Đọc `values/<svc>-staging.yaml` lấy `image.tag` hiện tại; đối chiếu app `<svc>-staging` trong ArgoCD đang `Synced/Healthy` (nếu kết nối được cụm).
2. So với `values/<svc>-prod.yaml` — nếu **đã bằng nhau** thì báo "không có gì để promote", đừng tạo PR rỗng.
3. Sửa **duy nhất** dòng `image.tag` trong `values/<svc>-prod.yaml`. **Không** kèm thay đổi khác vào PR promote (env, resources, chart) — promote phải là diff tối thiểu để rollback sạch.
4. Tạo branch + PR:
   ```bash
   git checkout -b promote/<svc>-<sha>
   git commit -m "chore(promote): <svc> staging→prod @<sha>"
   gh pr create --title "..." --body "SHA <sha> đã verify ở staging: <bằng chứng>"
   ```
   Commit **KHÔNG** thêm `Co-Authored-By`.
5. Sau merge: ArgoCD tự sync ns `prod`. Verify `argocd app get <svc>-prod` → Synced/Healthy + smoke endpoint.
6. Rollback nếu hỏng: **`git revert` PR này** — không `argocd app rollback`, không `helm rollback`.

`all` → lặp cho cả 9 service, nhưng **1 PR chung** liệt kê rõ từng svc + SHA trong body.
