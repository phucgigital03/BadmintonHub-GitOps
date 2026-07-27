---
allowed-tools: Bash(kubectl:*), Bash(helm:*), Bash(argocd:*), Bash(curl:*), Bash(aws:*), Bash(git:*), Read, Edit, Write, Grep, Glob
argument-hint: [mô tả triệu chứng] (vd: chat-service CrashLoopBackOff ở staging)
description: Fix sự cố cụm có kỷ luật — reproduce → root cause → fix trong Git → verify
---
Fix sự cố bằng **systematic debugging** — không đoán mò, không vá triệu chứng: **$ARGUMENTS**

## Nghi can thay đổi gần đây
!`git log --oneline -6`
!`git status --short`

## Trạng thái cụm
!`kubectl get pods -A --no-headers 2>/dev/null | grep -Ev 'Running|Completed' | head -20 || echo "(không kết nối được cụm)"`
!`kubectl get applications -n argocd 2>/dev/null | head -25 || echo "(chưa có ArgoCD)"`
!`kubectl get externalsecret -A 2>/dev/null || echo "(chưa có ESO)"`

## Quy trình — đi tuần tự, KHÔNG nhảy bước

1. **Chốt triệu chứng CHÍNH XÁC.** `kubectl get pod` (STATUS + RESTARTS), `kubectl describe pod` (Events — thường câu trả lời nằm ở đây), `kubectl logs --previous` khi CrashLoop. Lấy nguyên văn message, đừng diễn giải lại.
2. **Xác định TẦNG bị lỗi trước khi sửa gì.** Đây là bước hay bị bỏ nhất:
   | Tầng | Câu hỏi | Lệnh |
   |---|---|---|
   | Git/desired state | file values có đúng tên, đúng nội dung? | `git show HEAD -- values/` |
   | ArgoCD | app có Synced không, sync có lỗi không? | `argocd app get <svc>-<env>` |
   | K8s object | Deployment/Secret/ConfigMap render ra đúng chưa? | `kubectl get deploy -o yaml` |
   | Container | image pull được? boot được? | `describe pod` · `logs --previous` |
   | App runtime | app kết nối được datastore? | `logs` · `exec` test kết nối |
   | AWS | ALB/IRSA/SSM/ECR? | `aws elbv2 ...` · `aws ssm ...` |
3. **Một giả thuyết root-cause chứng minh được.** Phân biệt **triệu chứng** (pod đỏ) vs **gốc** (thiếu env / Secret chưa sync / arch sai / probe sai). Đối chiếu bảng dưới.
4. **Kiểm chứng — đổi MỘT biến**, chưa sửa gì cả. Sai giả thuyết → quay lại bước 2, KHÔNG chồng fix lên nhau.
5. **Fix ĐÚNG TẦNG — và fix trong Git.** `kubectl edit`/`patch` chỉ được dùng để **chẩn đoán tạm**; `selfHeal: true` sẽ ghi đè. Fix thật = sửa `values/`/`charts/`/`apps/` rồi commit.
6. **Verify bằng cách tái hiện LẠI**: pod Ready, `argocd app get` Synced/Healthy, `curl` endpoint thật. **Chưa verify thì KHÔNG nói "đã fix".**
7. **Phòng tái phát**: thêm 1 dòng vào rule tương ứng trong `.claude/rules/` nếu đây là bẫy sẽ lặp lại ở buổi rebuild sau.

## Failure-mode map (BadmintonHub GitOps)

| Triệu chứng | Nghi gốc | Soi ở |
|---|---|---|
| `exec format error` / CrashLoop ngay khi start | image build **arm64** trên máy dev, node là **amd64** | `docker inspect <img> --format '{{.Architecture}}'` phải = `amd64` |
| `CreateContainerConfigError` | Secret chưa tồn tại — ESO chưa sync, hoặc tên target Secret ≠ `envFrom.secret` | `secrets-eso.md` |
| `ImagePullBackOff` | `image.tag` rỗng/sai SHA (hay gặp ở `values/<svc>-prod.yaml`), hoặc chưa push ECR | `values/<svc>-<env>.yaml` |
| Pod restart liên tục nhưng app vẫn boot được | liveness trỏ `/actuator/health` composite — Redis/Eureka blip là bị giết | `helm-chart.md` |
| **Toàn bộ request 500** | Redis `NOAUTH` (Bitnami `auth.enabled=true`) + gateway rate-limit áp mọi route | `bitnami-datastores.md` |
| Đặt sân xong slot không cập nhật, **không lỗi ở đâu** | Kafka `autoCreateTopicsEnable=false` → `UNKNOWN_TOPIC_OR_PARTITION` im lặng | `bitnami-datastores.md` |
| chat-service fail boot | `MONGODB_CHAT_URI` thiếu `?authSource=admin` | `bitnami-datastores.md` |
| chat kết nối STOMP thất bại | RabbitMQ thiếu 1 trong 4: plugin / containerPort / service port / `auth.username=badminton` | `bitnami-datastores.md` |
| payment/chat fail boot khi `SPRING_PROFILES_ACTIVE=prod` | thiếu `CLOUDINARY_*` — **by design**, nạp param, đừng bỏ profile | `values-env-map.md` |
| Ingress không ra `ADDRESS` | subnet tag (Day 3) hoặc ALB controller chưa cài | `ingress-alb.md` |
| WebSocket chat rớt sau ~60s | thiếu `idle_timeout.timeout_seconds=300` | `ingress-alb.md` |
| Commit vào repo nhưng **không có gì đổi trên cụm** | sai tên file values → ArgoCD không đọc, **không báo lỗi ở đâu** | `gitops-workflow.md` rule 2 |
| Child app tự mọc lại sau khi xoá | đang xoá child thay vì root/ApplicationSet | `argocd-appset.md` |
| Sửa tay trên cụm bị mất | `selfHeal: true` — đúng thiết kế | `gitops-workflow.md` rule 4 |

## Luật cứng
- KHÔNG shotgun: sửa **1 thứ / lần**, có bằng chứng mới sửa.
- KHÔNG vá ở tầng sai (sửa `kubectl` khi gốc nằm ở `values/`).
- KHÔNG tuyên bố "fixed" nếu chưa tái hiện lại và thấy hết lỗi.
- **KHÔNG in giá trị secret** ra transcript — chỉ in tên key.
- Báo cáo trung thực: **gốc là gì · sửa file nào · verify thế nào** (kèm output).
