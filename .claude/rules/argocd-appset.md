---
description: ArgoCD app-of-apps + ApplicationSet matrix (9 svc × 2 env) — multi-source $values, labels bắt buộc, CreateNamespace, và vì sao xoá child app là vô nghĩa.
globs: apps/**/*.yaml
---

# ArgoCD — app-of-apps + ApplicationSet

Cấu trúc thật ở `apps/` (chốt Day 6): **1 root `Application`** trỏ `apps/` → 2 app `infra-<env>` (wave 1) + 2 app `platform-<env>` (wave 2) + **1 ApplicationSet** matrix 9 svc × 2 env = **18 child** (wave 3).
Dùng ApplicationSet thay vì viết tay 18 manifest. Ghim ArgoCD khi cài — repo này dùng chart **`argo/argo-cd 10.2.3` → ArgoCD `v3.5.0`** (`scripts/argocd-install.sh`).

## 5 điều BẮT BUỘC trong template

```yaml
spec:
  goTemplate: true                              # ⑤ BẮT BUỘC từ ArgoCD 3.0
  goTemplateOptions: [ missingkey=error ]
  template:
    metadata:
      name: '{{.svc}}-{{.env}}'
      labels:                                   # ① BẮT BUỘC
        env: '{{.env}}'
        svc: '{{.svc}}'
    spec:
      sources:                                  # ② multi-source $values
        - repoURL: https://github.com/phucgigital03/BadmintonHub-GitOps
          targetRevision: main
          ref: values
        - repoURL: https://github.com/phucgigital03/BadmintonHub-GitOps
          path: charts/service                  # ③ CẢ 9 svc kể cả frontend → MỘT chart
          helm: { valueFiles: [ '$values/values/{{.svc}}-{{.env}}.yaml' ] }
      destination: { server: https://kubernetes.default.svc, namespace: '{{.env}}' }
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [ CreateNamespace=true ]   # ④ BẮT BUỘC
```

| # | Bỏ đi thì sao |
|---|---|
| ① `labels` | Runbook teardown chạy `argocd app delete -l env=staging` → **match 0 app**, lệnh "thành công" mà không xoá gì |
| ② multi-source | `valueFiles: ["../../values/..."]` nằm ngoài `source.path` → ArgoCD **chặn**: `valueFiles must be within the app path` |
| ③ 1 chart | Chart riêng cho FE/eureka → matrix generator không dùng được, phải viết tay 18 Application |
| ④ `CreateNamespace=true` | Cụm vừa `apply` **chưa có** ns `staging`/`prod` → cả 18 child app Error `namespace not found` — và vì đây là đường rebuild nên nó **vỡ mỗi buổi demo** |
| ⑤ `goTemplate` | Cú pháp fasttemplate cũ `{{svc}}` **ĐÃ BỊ GỠ ở ArgoCD 3.0** |

### 🔴 ⑤ `goTemplate: true` — mọi ví dụ cũ trên mạng đều sai với ArgoCD 3.x

ApplicationSet có 2 engine template. Bản cũ (fasttemplate, `{{svc}}` **không dấu chấm**) bị gỡ ở **ArgoCD 3.0**; bản mới là Go template, `{{.svc}}` **có dấu chấm**. `Planning_CICD.md` §Day 6 và gần như mọi blog đều còn viết kiểu cũ.

Kèm theo `goTemplateOptions: [ missingkey=error ]` — gõ nhầm tên biến (vd `{{.service}}`) thì ApplicationSet **báo lỗi** thay vì render ra chuỗi rỗng và sinh ra app tên `-staging`. Đúng tinh thần repo này: mọi bug đắt nhất ở đây đều là bug im lặng.

## 🔴 Sync-wave GIỮA các Application — không có thì mỗi buổi rebuild là một cơn bão restart

ApplicationSet sinh 18 app service **độc lập** với root: root chỉ tạo *ApplicationSet*, còn 18 app con thì controller đẻ ra ngay lập tức, không chờ ai. Không chặn ⇒ 18 JVM boot lúc Postgres/Kafka/Secret chưa tồn tại ⇒ `RESTARTS` tăng đều ở mọi pod ⇒ đúng cái **"vòng lặp restart"** mà [`helm-chart.md`](helm-chart.md) gọi là bài học đắt nhất của Day 2 — và bạn sẽ đi đổ lỗi cho RAM node thay vì cho thứ tự deploy.

Cách chặn: annotation trên **chính các Application con của root** (root sync theo wave và **chờ wave trước Healthy** mới sang wave sau).

| Wave | Ai | Vì sao ở đó |
|---:|---|---|
| **-1** | `ExternalSecret` (trong chart `platform` và `infra`) | Secret phải có trước pod |
| **1** | `infra-staging`, `infra-prod` | 5 datastore, PVC bind EBS thật — chậm nhất (~3-5') |
| **2** | `platform-staging`, `platform-prod` | ConfigMap + Ingress. Đặt trước service để ALB provision **song song** lúc JVM đang boot |
| **3** | `appset-services` | 18 app service |

⚠️ Cơ chế này dựa vào việc ArgoCD đánh giá **health của Application con**. Sau lần dựng đầu tiên, xác nhận bằng mắt: trong lúc wave 1 chạy thì `kubectl get applications -n argocd` **chưa** được có app service nào. Nếu 18 app xuất hiện ngay lập tức thì wave không ăn — quay lại đọc log `argocd-application-controller`.

## ⚠️ Xoá child app là vô nghĩa

ApplicationSet controller **sinh lại ngay**. Muốn hạ cả cụm phải xoá **root Application / ApplicationSet**:
```bash
argocd app delete badmintonhub-root --cascade
# hoặc: kubectl delete applicationset badmintonhub -n argocd
```

## Vòng lặp đã đóng

1. CI (app repo) bump `values/<svc>-staging.yaml` → ArgoCD auto-sync ns `staging`.
2. Promote: PR sửa `values/<svc>-prod.yaml` sang **đúng SHA** đã verify ở staging → merge → sync ns `prod`. KHÔNG build lại.
3. Rollback: `git revert` PR ở repo này.

> ⚠️ ApplicationSet sinh app `prod` **ngay từ đầu** → `values/<svc>-prod.yaml` phải tồn tại + `image.tag` hợp lệ từ Day 2, nếu không 9 app prod `ImagePullBackOff` và `argocd app list` đỏ dù chưa promote gì.

## Debug — đọc theo thứ tự này

```bash
argocd app list                                          # tất cả phải Synced/Healthy
kubectl get applications -n argocd -l env=staging        # phải ra ĐÚNG 9 app
kubectl get applications -n argocd -o wide               # cột SYNC/HEALTH + message
argocd app get <svc>-<env>                               # xem condition/lỗi cụ thể
kubectl -n argocd logs deploy/argocd-applicationset-controller --tail=100
```

| Triệu chứng | Nghi gốc |
|---|---|
| App sinh ra tên **`{{svc}}-{{env}}`** hoặc `-staging` (thiếu phần đầu) | thiếu `goTemplate: true`, hoặc còn dùng `{{svc}}` không dấu chấm trên ArgoCD 3.x |
| 18 app service xuất hiện **ngay lập tức**, pod restart hàng loạt | sync-wave không ăn — xem §sync-wave |
| App `infra-*` `ComparisonError: found in Chart.yaml, but missing in charts/` | repo-server không ra được `charts.bitnami.com` → commit 5 `.tgz` (bỏ `infra/charts/` khỏi `.gitignore`) |
| `valueFiles must be within the app path` | dùng Application đơn thay vì multi-source `$values` |
| Child app `Error: namespace not found` | thiếu `CreateNamespace=true` |
| `argocd app delete -l ...` không xoá gì | thiếu `labels` trong template |
| Child app tự mọc lại sau khi xoá | đang xoá child thay vì root/ApplicationSet |
| `ComparisonError` / không tìm thấy values | sai tên file `values/<svc>-<env>.yaml` |
| App `Synced` nhưng pod đỏ | không phải lỗi ArgoCD → xem [`bitnami-datastores.md`](bitnami-datastores.md) / [`secrets-eso.md`](secrets-eso.md) |
| Manifest sửa tay bị mất | `selfHeal: true` — đúng như thiết kế, sửa vào Git |

Liên quan: [`gitops-workflow.md`](gitops-workflow.md) · [`secrets-eso.md`](secrets-eso.md)
