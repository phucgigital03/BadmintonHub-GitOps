---
allowed-tools: Read, Grep, Glob, Bash(helm:*), Bash(kubectl explain:*)
argument-hint: [file / thư mục / khái niệm] (vd: charts/service/templates/deployment.yaml)
description: Giải thích manifest/chart/khái niệm GitOps trong đúng bối cảnh dự án này
---
Giải thích: **$ARGUMENTS**

Trả lời theo cấu trúc:

1. **Nó là gì, trong 2 câu** — bằng tiếng Việt, không copy nguyên doc chính thức.
2. **Nó làm gì TRONG DỰ ÁN NÀY** — trỏ đúng file/dòng thật ở repo, và nói nó nằm ở **Day mấy** của `Planning_CICD.md`.
3. **Dòng chảy**: cái gì gọi nó, nó tạo ra object K8s nào, ai đọc kết quả đó. Nếu liên quan vòng lặp GitOps thì vẽ: `git commit → ArgoCD sync → K8s object → pod`.
4. **Vì sao viết như vậy mà không viết cách khác** — nếu có ràng buộc đã chốt (probe tách liveness/readiness · 1 chart cho 9 svc · 2 công tắc ingress · ESO thay SealedSecrets · không cert-manager) thì nêu **lý do gốc**, đối chiếu `.claude/rules/`.
5. **Bẫy liên quan** — cái gì hỏng nếu sửa sai chỗ này, triệu chứng sẽ trông như thế nào (đặc biệt các bẫy **im lặng**: sai tên values, thiếu label ApplicationSet, thiếu `autoCreateTopicsEnable`).
6. **Muốn thử tay thì gõ gì** — 1–3 lệnh `helm template` / `kubectl` an toàn để tự nhìn thấy kết quả.

Ưu tiên **đọc file thật** trước khi giải thích. Không có file → nói rõ là chưa dựng (Day nào sẽ dựng) rồi giải thích theo thiết kế trong `Planning_CICD.md`.
Độ dài: đủ hiểu, không lan man. Có thể dùng bảng.
