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

Ngoài `env`/`svc`, mọi Application trong `apps/` còn mang **`tier: service | infra | platform`**:

| Selector | Ra | Dùng khi |
|---|---|---|
| `-l env=staging` | **11** | teardown **cả môi trường** — 9 service + infra + platform |
| `-l env=staging,tier=service` | **9** | chỉ động vào service |
| `-l '!env'` | **1** | `badmintonhub-root` (không thuộc env nào) |

> ⚠️ Bản kế hoạch ghi `-l env=staging` **phải ra 9**. Sai — và sai theo hướng nguy hiểm: nếu selector chỉ khớp 9 app service thì `argocd app delete -l env=staging` để **datastore ở lại**, PVC không bị xoá và **EBS tiếp tục tính tiền** sau teardown. 11 mới là con số đúng.

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

## 🔴 Sync-wave giữa các Application là BEST-EFFORT, KHÔNG phải hàng rào — đã đo, đã bác bỏ

**Đừng dựa vào nó để đảm bảo thứ tự.** Đo thật trên EKS ở Day 6:

| Nhóm pod | Giờ tạo |
|---|---|
| 18 pod service (wave 3) | `02:33:31` – `02:33:34` |
| 10 pod datastore (wave 1) | `02:36:03` – `02:36:14` |

Service sinh ra **trước datastore 2 phút 30 giây** — wave chạy **ngược**. Hậu quả: 6/9 service mỗi env chết lúc boot với `java.net.UnknownHostException: postgresql.data-staging.svc.cluster.local` (DNS chưa có, **không phải** connection refused) rồi restart 1–3 lần.

**Vì sao nó không giữ:** ArgoCD mở cổng wave khi resource của wave trước **Healthy**. Một `Application` vừa được tạo thì chưa kịp reconcile, **chưa quản lý resource nào** — mà app không có resource nào được chấm là **Healthy**. Cổng mở ngay trong ~3 giây. Không có gì hỏng, không có lỗi, wave chỉ đơn giản là vô hiệu.

→ **Hàng rào thật nằm ở tầng kubelet**: `initContainer` trong `charts/service` chờ mọi datastore mở cổng (`waitForDatastores`, xem [`helm-chart.md`](helm-chart.md)). Pod đứng ở `Init`, không boot, không chết, không đốt CPU.

Vẫn **giữ** sync-wave vì nó miễn phí và có tác dụng phụ tốt (Ingress tạo sớm ⇒ ALB provision song song với lúc JVM boot), nhưng đọc nó như *gợi ý thứ tự*, không phải *bảo đảm*:

| Wave | Ai | Tác dụng thật |
|---:|---|---|
| **-1** | `ExternalSecret` (trong chart `platform` và `infra`) | ✅ **có hiệu lực** — cùng một Application nên đây là wave thật |
| **1** | `infra-staging`, `infra-prod` | ⚠️ gợi ý |
| **2** | `platform-staging`, `platform-prod` | ⚠️ gợi ý |
| **3** | `appset-services` | ⚠️ gợi ý |

📌 Bài học tổng quát: **sync-wave chỉ là hàng rào thật khi các resource nằm trong CÙNG một Application.** Qua ranh giới Application thì nó chỉ còn là thứ tự tạo object.

## 🔴 ĐỪNG khai field bằng ĐÚNG giá trị mặc định — `OutOfSync` vĩnh viễn

Đo thật ở Day 6. `apps/root.yaml` viết:

```yaml
source:
  directory:
    recurse: false        # ⬅ đúng bằng default
```

`false` là giá trị mặc định, mà API server áp `omitempty` cho boolean `false` nên field **bị loại bỏ** khỏi object đã lưu. ArgoCD so Git (**có** field) với live (**không có** field) ⇒ `badmintonhub-root` đứng **OutOfSync vĩnh viễn** trong khi cả 22 app con đều Synced/Healthy. Bấm sync bao nhiêu lần cũng vô ích: lần nào ghi xuống cũng bị lược đi.

Không hỏng gì về vận hành, nhưng làm hỏng thứ đắt hơn: **tín hiệu**. Từ đó "có app OutOfSync" không còn nghĩa là "có gì đó sai".

→ **Quy tắc: đừng khai tường minh field bằng đúng default (`false` / `0` / `""`) trong manifest mà chính ArgoCD quản lý.** Muốn ghi lại chủ ý thì dùng comment.

⚠️ Đây là loại lỗi khó truy vì nó **chỉ xuất hiện ở object ArgoCD tự quản lý**. Cách khoanh vùng nhanh — so trực tiếp:
```bash
kubectl -n argocd get app <name> -o jsonpath='{.spec}' | python3 -m json.tool
```
rồi đối chiếu từng field với file trong Git. Field nào **có trong Git mà vắng ở live** chính là thủ phạm.

*(Nghi can thường bị đổ oan: `kubectl.kubernetes.io/last-applied-configuration`. Đã kiểm — ArgoCD **có** normalize annotation đó, gỡ nó đi không làm `OutOfSync` biến mất. Đừng mất thời gian ở đó.)*

## Bấm nút bằng `kubectl apply --server-side`

```bash
kubectl apply --server-side -f apps/root.yaml
```

Không bắt buộc để hết `OutOfSync` (xem mục trên), nhưng đúng hơn cho object mà **root tự quản lý chính nó**: server-side apply ghi quyền sở hữu field vào `metadata.managedFields` thay vì nhồi thêm annotation, nên `kubectl` và `argocd-application-controller` không giành field của nhau.

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
argocd app list                                              # tất cả phải Synced/Healthy
kubectl get applications -n argocd                           # 23 = 18 service + 2 infra + 2 platform + root
kubectl get applications -n argocd -l env=staging             # 11 — CẢ môi trường
kubectl get applications -n argocd -l env=staging,tier=service # 9  — chỉ service
kubectl get applications -n argocd -l '!env'                  # 1  — chỉ badmintonhub-root
kubectl get applications -n argocd -o wide                   # cột SYNC/HEALTH + message
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
