---
allowed-tools: Read, Edit, Grep, Glob, Bash(git log:*), Bash(git status:*), Bash(git diff:*), Bash(ls:*)
description: Cập nhật CLAUDE.md với tiến độ phiên làm việc hiện tại (repo gitops)
---
## Trạng thái repo hiện tại (đừng tin snapshot cũ trong CLAUDE.md — verify bằng git)
!`git log --oneline -8`
!`git status --short`
!`ls charts values apps external-secrets infra 2>/dev/null || echo "(các thư mục chart/values/apps chưa dựng)"`

Hãy cập nhật file `CLAUDE.md` (repo này) với tiến độ phiên làm việc hiện tại.

Thực hiện các bước sau:
1. Đọc nội dung `CLAUDE.md` hiện tại — đặc biệt mục **## Session Progress**.
2. **Đối chiếu với git thật ở trên trước khi ghi**: commit mới nhất là gì, thư mục nào đã thực sự tồn tại, còn gì đang dở trong working tree. Bài học của chính file này: *đừng tin snapshot handoff của phiên trước*.
3. Cập nhật **✅ Đã hoàn thành** với những task vừa xong trong phiên này — ghi rõ **Day mấy** và **deliverable nào** (`charts/service/`, `values/<svc>-<env>.yaml`, `apps/`, `external-secrets/`, `infra/`).
4. Cập nhật **🔄 Đang làm** — xoá những gì đã xong, thêm gì đang dở (kèm file đang sửa).
5. Cập nhật **📋 Việc tiếp theo** theo thứ tự ưu tiên. Nếu việc kế thuộc **Day 1/3/5** thì ghi rõ **"mở Claude Code ở `../badmintonHub` (app repo)"** + tên prompt paste-ready tương ứng trong `Planning_CICD.md`.
6. Ghi lại bất kỳ **quyết định kỹ thuật** quan trọng nào vừa chốt vào **🧠 Quyết định kỹ thuật đã chốt** — kèm **lý do**, vì phiên sau sẽ không nhớ.
7. Cập nhật dòng **Cập nhật lần cuối** với ngày hôm nay + tóm tắt 1 câu trong ngoặc.
8. Ghi tóm tắt 2–3 câu về phiên này vào **💬 Claude đã làm trong phiên này**.

Ràng buộc:
- Chỉ sửa `CLAUDE.md`, **KHÔNG commit** trừ khi được yêu cầu rõ.
- Ghi trung thực: việc chưa verify thì ghi "chưa verify", đừng ghi là xong.
- Kế hoạch chưa động tới thì để trong `Planning_CICD.md`, **đừng chiếm chỗ** ở CLAUDE.md — file này chỉ phản ánh việc đang thực sự làm.

Sau khi cập nhật xong, xác nhận bằng cách liệt kê những thay đổi vừa ghi vào file.
