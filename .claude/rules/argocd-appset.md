---
description: ArgoCD app-of-apps + ApplicationSet matrix (9 svc × 2 env) — multi-source $values, labels bắt buộc, CreateNamespace, và vì sao xoá child app là vô nghĩa.
globs: apps/**/*.yaml
---

# ArgoCD — app-of-apps + ApplicationSet

Cấu trúc: **1 root `Application`** trỏ `apps/` → chứa **ApplicationSet** matrix (9 svc × 2 env = **18 child**) + 1 app infra (Bitnami) + 1 app ingress.
Dùng ApplicationSet thay vì viết tay 18 manifest. ArgoCD **≥ 2.8** (multi-source `$values` cần ≥ 2.6) — **ghim version khi cài**.

## 4 điều BẮT BUỘC trong template

```yaml
spec:
  template:
    metadata:
      name: '{{svc}}-{{env}}'
      labels:                                   # ① BẮT BUỘC
        env: '{{env}}'
        svc: '{{svc}}'
    spec:
      sources:                                  # ② multi-source $values
        - repoURL: https://github.com/phucgigital03/BadmintonHub-GitOps
          targetRevision: main
          ref: values
        - repoURL: https://github.com/phucgigital03/BadmintonHub-GitOps
          path: charts/service                  # ③ CẢ 9 svc kể cả frontend → MỘT chart
          helm: { valueFiles: [ '$values/values/{{svc}}-{{env}}.yaml' ] }
      destination: { server: https://kubernetes.default.svc, namespace: '{{env}}' }
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
| `valueFiles must be within the app path` | dùng Application đơn thay vì multi-source `$values` |
| Child app `Error: namespace not found` | thiếu `CreateNamespace=true` |
| `argocd app delete -l ...` không xoá gì | thiếu `labels` trong template |
| Child app tự mọc lại sau khi xoá | đang xoá child thay vì root/ApplicationSet |
| `ComparisonError` / không tìm thấy values | sai tên file `values/<svc>-<env>.yaml` |
| App `Synced` nhưng pod đỏ | không phải lỗi ArgoCD → xem [`bitnami-datastores.md`](bitnami-datastores.md) / [`secrets-eso.md`](secrets-eso.md) |
| Manifest sửa tay bị mất | `selfHeal: true` — đúng như thiết kế, sửa vào Git |

Liên quan: [`gitops-workflow.md`](gitops-workflow.md) · [`secrets-eso.md`](secrets-eso.md)
