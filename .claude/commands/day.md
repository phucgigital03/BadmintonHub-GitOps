---
allowed-tools: Read, Grep, Glob, Edit, Write, Bash(helm:*), Bash(kubectl:*), Bash(kind:*), Bash(git:*), Bash(ls:*)
argument-hint: [số Day 1-8] (vd: 2)
description: Đọc §Day N của Planning_CICD.md rồi thực thi đúng prompt paste-ready của Day đó
---
Thực thi **Day $ARGUMENTS** của lộ trình CI/CD.

## Bước 1 — kiểm Day này có thuộc repo NÀY không
| Day | Repo |
|---|---|
| 1, 3, 5 | `badmintonHub` (**app repo**) — **KHÔNG** làm ở đây |
| 2, 4, 6 | `badmintonHub-gitops` (repo này) |
| 7, 8 | **cả 2** — chỉ làm phần gitops ở đây |

Nếu Day $ARGUMENTS thuộc app repo → **dừng lại**, báo người dùng mở Claude Code ở `../badmintonHub` và paste prompt §Day $ARGUMENTS của `Planning_CICD.md`. Không tạo Dockerfile/Terraform/workflow ở repo này.

## Bước 2 — đọc nguồn thiết kế (đọc THẬT, đừng làm từ trí nhớ)
1. `Planning_CICD.md` §**Day $ARGUMENTS** — toàn bộ mục: **Việc làm** + mọi khối ⚠️/🔴 + **✅ Check** + khối **📋 Prompt paste-ready**.
2. `CLAUDE.md` (repo này).
3. Rule liên quan trong `.claude/rules/`: `gitops-workflow.md` + `ephemeral-cost.md` (luôn), cộng thêm theo Day —
   - Day 2 → `helm-chart.md`, `values-env-map.md`, `bitnami-datastores.md`
   - Day 4 → `ingress-alb.md`, `values-env-map.md`
   - Day 6 → `argocd-appset.md`, `secrets-eso.md`
   - Day 7 → `helm-chart.md`, `ephemeral-cost.md`
   - Day 8 → `ingress-alb.md`
4. Nếu Day đó cần tên biến env thật → đọc `../badmintonHub/<svc>/src/main/resources/application.yml`. **`.env.example` KHÔNG đầy đủ**, chỉ để đối chiếu.

## Bước 3 — plan trước, làm sau
Khối **📋 Prompt paste-ready** của Day đó đã ghi sẵn mục *"Plan-mode trước"* — làm đúng mục đó trước, trình bày plan, rồi mới viết file.

## Bước 4 — thực thi theo đúng "Chốt-cứng"
Mọi dòng trong mục **Chốt-cứng** của prompt paste-ready là ràng buộc **không thương lượng**, kể cả khi có cách khác trông gọn hơn. Thấy chốt-cứng nào có vẻ sai → **nêu ra và hỏi**, đừng tự đổi.

## Bước 5 — DoD
Chạy đúng các lệnh ở mục **DoD** của prompt paste-ready + **✅ Check** của Day đó. Báo ✅/❌ **từng tiêu chí kèm output thật**.
**Chưa chạy được lệnh nào thì ghi rõ "chưa verify"** — không suy ra từ việc file đã được tạo.

Commit: KHÔNG thêm `Co-Authored-By`. Chỉ commit khi được yêu cầu.
