---
description: Nguyên tắc vàng "0 thao tác tay" khi rebuild, runbook teardown đúng thứ tự, và kỷ luật chi phí (PVC mồ côi, ALB, NAT).
alwaysApply: true
---

# Ephemeral & Cost — lý do tồn tại của toàn bộ thiết kế

Cụm **chỉ sống đúng buổi demo**: `terraform apply` (~15') → người thật dùng **5–10'** → `terraform destroy` (~10') → bill ≈ **vài xu/buổi**.

## 🎯 Tiêu chí vàng: rebuild = 0 THAO TÁC TAY

`destroy` → `apply` → `bootstrap.sh` → e2e xanh mà **KHÔNG** phải làm 1 trong 4 việc sau:

| Việc tay bị cấm | Cái gì chặn nó |
|---|---|
| Nạp lại / re-seal secret | **ESO đọc SSM** (param sống ngoài cụm) — xem [`secrets-eso.md`](secrets-eso.md) |
| Build lại image FE | **FE same-origin** (gọi `/api` tương đối, derive WS từ `window.location`) |
| Sửa ConfigMap theo ALB DNS mới | same-origin → `FRONTEND_URL` không còn là CORS origin |
| Sửa DNS / xin lại cert tay | **ExternalDNS + ACM wildcard** ở `bootstrap/` (Day 8) |

**Bất cứ thiết kế nào buộc làm 1 trong 4 việc đó là SAI với repo này** — kể cả khi nó "chạy được". Khi đề xuất giải pháp, tự hỏi trước: *sau `destroy` → `apply`, cái này còn tự đứng dậy không?*

Hệ quả cụ thể: **KHÔNG dùng SealedSecrets** (keypair khoá theo cụm) · **KHÔNG cert-manager** (xem [`ingress-alb.md`](ingress-alb.md)) · **KHÔNG hardcode ALB DNS / cert ARN / account ID** vào manifest.

## Dữ liệu: KHÔNG giữ lâu dài

`ddl-auto=update` tạo schema rỗng mỗi lần dựng. Không seed data, không backup, không PV giữ lại. Muốn onboard user thật giữ data → **Phụ lục B** `Planning_CICD.md` (RDS + Flyway + không teardown) — **ngoài scope**, đừng tự ý kéo vào.

## Runbook teardown §7.1 — ĐÚNG THỨ TỰ

```bash
# 1. Xoá ROOT app, KHÔNG phải child — ApplicationSet controller sinh lại child ngay lập tức
argocd app delete badmintonhub-root --cascade
#    (hoặc: kubectl delete applicationset badmintonhub -n argocd)

# 2. Xoá PVC KHI CỤM CÒN SỐNG — reclaim policy Delete chỉ chạy lúc PVC bị xoá.
#    Destroy thẳng cụm thì không ai gọi nó → EBS mồ côi VẪN TÍNH TIỀN.
kubectl delete pvc --all -n data-staging
kubectl delete pvc --all -n data-prod

# 3. Xoá ingress để AWS LB Controller tự gỡ ALB (PHẢI trước khi gỡ controller)
kubectl delete ingress --all -A

# 4. Gỡ add-on tạo AWS resource ngoài
helm uninstall aws-lb-controller -n kube-system

# 5. Huỷ hạ tầng (ở app repo)
cd ../badmintonHub/terraform && terraform destroy
```

**Giữ lại**: S3 (state) · DynamoDB (lock) · ECR (image) · **SSM param** · Route53 zone + ACM cert (Day 8). Đó là lý do rebuild chỉ mất ~15'.

### Verify bill về 0 — chạy thật, đừng tin cảm giác

```bash
aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'   # phải RỖNG
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'                   # phải RỖNG
```

Bỏ bước 2 → ~40 GB volume mồ côi (5 datastore × 2 env × 8 Gi) ≈ **$3.2/tháng chảy âm thầm**, không ai nhìn thấy.

## Thứ tự rebuild có ràng buộc

`bootstrap.sh`: EBS CSI + gp3 → ALB controller → **ESO + ClusterSecretStore** → ArgoCD + root app.
**ESO + ClusterSecretStore phải xong TRƯỚC khi ArgoCD sync app** — không thì pod khởi động lúc `Secret` chưa tồn tại → `CreateContainerConfigError` (tự khỏi sau khi ESO sync, nhưng buổi demo trông như hỏng).

## Chi phí

| Kịch bản | Tiền |
|---|---|
| 1 buổi trọn gói (apply + demo + destroy) | ≈ **$0.15** |
| Quên tắt 1 ngày | vài $ |
| Quên tắt 1 tháng | **≈ $150–200** |

Kỷ luật: AWS Budget alert (email khi > $5) + hẹn giờ điện thoại "DESTROY" ngay sau demo.
Khi đề xuất thêm bất kỳ AWS resource nào → nêu luôn **nó có bị `destroy` xoá không** và **nó có tính tiền lúc cụm đã tắt không**.
