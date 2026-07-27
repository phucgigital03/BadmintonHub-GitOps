---
description: Luật lõi của repo GitOps — quan hệ 2 repo, ai sở hữu gì, hợp đồng tên values, image tag, promote, rollback, 8 never-violate.
alwaysApply: true
---

# GitOps Workflow — luật lõi

Repo này = **desired state**. Không có source code app. Đổi gì ở đây = đổi cụm EKS.
Nguồn thiết kế đầy đủ: `Planning_CICD.md` · tổng quan: `CLAUDE.md`.

## Quan hệ 2 repo

| Repo | Sở hữu | Vai trò trong vòng lặp |
|---|---|---|
| `badmintonHub` (sibling `../badmintonHub`) | `*/Dockerfile` · `docker-compose.app.yml` · `terraform/` · `.github/workflows/` · source Java/React | CI build image → push ECR → **ghi** `image.tag` vào `values/*` của repo NÀY |
| `badmintonHub-gitops` (repo này) | `charts/service/` · `values/` · `apps/` · `external-secrets/` · `infra/` | ArgoCD **đọc** repo này → sync cụm |

Vòng lặp: **CI (app repo) ghi tag → ArgoCD (đọc repo này) sync.** Không có CI ở repo này trigger ngược lại app repo — tách 2 repo chính là để chặn vòng lặp CI-trigger-CI.

## Day nào làm ở repo nào

| Day | Repo | Deliverable |
|---|---|---|
| 1 | app | 8 Dockerfile Java + FE nginx + `docker-compose.app.yml` |
| **2** | **gitops** | `charts/service/` + `values/<svc>-<env>.yaml` (9 svc × 3 env) + `values/infra.yaml` → test kind |
| 3 | app | `terraform/bootstrap/` + `terraform/` (VPC/EKS/IRSA) + add-on |
| **4** | **gitops** | Deploy EKS `staging` + Ingress ALB (http) + FE same-origin |
| 5 | app | `.github/workflows/ci.yml` + `terraform.yml` |
| **6** | **gitops** | `apps/` ApplicationSet + ArgoCD + External Secrets + promote |
| **7** | **cả 2** | Observability (gitops) + teardown/rebuild (`terraform destroy` ở app) |
| **8** | **cả 2** | Domain + HTTPS: zone/ACM ở app · 2 values ingress + `FRONTEND_URL` ở đây |

Việc thuộc Day 1/3/5 → **dừng lại và nói người dùng mở Claude Code ở `../badmintonHub`**, đừng tạo Dockerfile/Terraform/workflow ở repo này.

## 8 rule — Never Violate

1. **Image tag = git SHA.** Bất biến. **KHÔNG `latest`**, không tag theo branch. CI của app repo tự bump.
2. **Tên file values = `values/<svc>-<env>.yaml`**, `env ∈ {dev, staging, prod}`. Đây là **hợp đồng với CI + ApplicationSet**. Đặt sai tên = CI vẫn xanh, commit vẫn vào repo, ArgoCD không đọc → **không deploy gì và không báo lỗi ở đâu**. Đây là lỗi tốn nhiều thời gian nhất của mô hình này.
3. **Không commit secret thô.** Git chỉ chứa `ExternalSecret` **ref tên param** SSM (`/badminton/<env>/*`). Repo PUBLIC. Xem [`secrets-eso.md`](secrets-eso.md).
4. **Không `kubectl edit` / `kubectl apply` tay lên cụm.** `selfHeal: true` sẽ ghi đè → sửa tay là mất công vô ích và làm sai lệch nhận thức về trạng thái thật. Sửa = commit vào repo này.
5. **Rollback = `git revert`**, không phải `helm rollback` / `argocd app rollback`. Cụm phải luôn khớp `main`.
6. **Promote staging → prod = PR sửa `values/<svc>-prod.yaml` sang đúng SHA đã verify ở staging.** KHÔNG build lại image, KHÔNG tag mới.
7. **`values/<svc>-prod.yaml` phải tồn tại + có `image.tag` hợp lệ ngay từ Day 2** — ApplicationSet sinh app `prod` ngay từ đầu; để rỗng → 9 app prod `ImagePullBackOff` và `argocd app list` đỏ dù chưa promote gì.
8. **1 chart `charts/service/` cho CẢ 9 service, kể cả `frontend`.** Viết chart riêng cho FE/eureka là phá ApplicationSet matrix của Day 6.

## Quy ước commit

- Commit message **KHÔNG** thêm `Co-Authored-By` (giống repo app).
- Prefix theo Day/scope: `feat(chart):` · `feat(values):` · `feat(argocd):` · `fix(ingress):` · `chore(promote):` · `docs(gitops):`.
- Đổi values ảnh hưởng cụm → **PR**, không push thẳng `main` (trừ giai đoạn Day 2 chưa có ArgoCD).

## Kiểm tra trước khi nói "xong"

```bash
helm lint charts/service -f values/<svc>-staging.yaml
helm template test charts/service -f values/<svc>-staging.yaml | head -50   # render ra được YAML hợp lệ
ls values/ | wc -l                                                          # 9 svc × 3 env = 27 file (+ infra.yaml)
```

Liên quan: [`helm-chart.md`](helm-chart.md) · [`argocd-appset.md`](argocd-appset.md) · [`ephemeral-cost.md`](ephemeral-cost.md)
