---
allowed-tools: Read, Grep, Glob, Bash(git diff:*), Bash(git show:*), Bash(git grep:*), Bash(helm:*)
description: Tự review diff YAML/Helm khắt khe theo chuẩn GitOps của repo này
---
## Thay đổi chưa commit
!`git diff HEAD`

## Commit gần nhất (xem nếu phần trên rỗng)
!`git show HEAD --stat`

Review phần trên như một **senior Platform engineer khó tính**, bám `.claude/rules/`. Ưu tiên theo thứ tự:

1. **🔴 Secret leak** (chặn merge, không thương lượng): có giá trị thô nào lọt vào không (`password`, `JWT_SECRET`, `CLOUDINARY_*`, URI có creds, `.env`)? Repo này **PUBLIC**. Git chỉ được chứa `ExternalSecret` **ref tên param** SSM.
2. **8 rule Never-Violate** (`gitops-workflow.md`): image tag = **git SHA** không `latest` · tên file **`values/<svc>-<env>.yaml`** · không manifest sửa tay · rollback = `git revert` · promote = đổi SHA không build lại · `values/<svc>-prod.yaml` có tag hợp lệ · **1 chart cho cả 9 svc kể cả frontend**.
3. **Tiêu chí vàng 0 thao tác tay** (`ephemeral-cost.md`): diff này có làm rebuild cần thao tác tay không? Có **hardcode** ALB DNS / cert ARN / account ID / IP / hostname sinh ra lúc `apply` không? Có tạo AWS resource nào **sống sót sau `destroy` mà vẫn tính tiền** không?
4. **Đúng pattern hạ tầng**:
   - probe: `livenessPath`/`readinessPath` riêng, **KHÔNG** `/actuator/health` composite; có `startupProbe` cho JVM.
   - chart còn generic (`port`, `livenessPath`, `readinessPath`, `envFrom` optional) — chưa lén hardcode cho 1 service.
   - Ingress: 2 công tắc `host`/`certificateArn` vẫn template hoá + `group.name` + `idle_timeout=300` + TTL `60`; **không có cert-manager/Let's Encrypt** ở bất kỳ đâu.
   - ApplicationSet: `labels {env, svc}` + `CreateNamespace=true` + multi-source `$values`.
   - Bitnami: 5 override còn nguyên (Redis `auth.enabled=false` · Kafka `sasl=false`+`autoCreateTopicsEnable=true` · Mongo `authSource=admin` · RabbitMQ 3–4 chỗ STOMP · PG superuser) + chart version **đã ghim**.
5. **Correctness YAML/Helm**: indent, `{{- if }}` có đóng, quote số/bool đúng chỗ (`ttl: "60"`), ns đúng (`staging` vs `data-staging`), port khớp bảng service, tên Secret khớp `envFrom`.
6. **Ảnh hưởng cụm**: diff này khi ArgoCD sync sẽ làm gì? Có **prune** mất resource nào không? Có gây restart toàn bộ pod giữa buổi demo không?

Feedback **cụ thể, actionable, trỏ đúng `file:line`**. Thành thật về vấn đề thật, đừng khen xã giao. Không có vấn đề gì thì nói thẳng là sạch.
