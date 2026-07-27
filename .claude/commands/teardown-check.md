---
allowed-tools: Bash(kubectl:*), Bash(helm:*), Bash(argocd:*), Bash(aws:*), Read, Grep
description: Chạy/kiểm runbook teardown §7.1 đúng thứ tự và verify bill về ~0
---
## Tài nguyên còn sống
!`kubectl get applications -n argocd 2>/dev/null | head -25 || echo "(không kết nối cụm — có thể đã destroy)"`
!`kubectl get pvc -A 2>/dev/null || echo "(không có PVC / không kết nối cụm)"`
!`kubectl get ingress -A 2>/dev/null || echo "(không có ingress)"`
!`aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' 2>/dev/null || echo "(aws cli không sẵn sàng)"`
!`aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId' 2>/dev/null`

Teardown theo **`Planning_CICD.md` §7.1** — đúng thứ tự, không bỏ bước.

```bash
# 1. Xoá ROOT app (KHÔNG phải child — ApplicationSet controller sinh lại child ngay)
argocd app delete badmintonhub-root --cascade
#    hoặc: kubectl delete applicationset badmintonhub -n argocd

# 2. Xoá PVC KHI CỤM CÒN SỐNG  ← bước hay bị quên nhất, và tốn tiền âm thầm
kubectl delete pvc --all -n data-staging
kubectl delete pvc --all -n data-prod

# 3. Xoá ingress để AWS LB Controller tự gỡ ALB (PHẢI trước khi gỡ controller)
kubectl delete ingress --all -A

# 4. Gỡ add-on tạo AWS resource ngoài
helm uninstall aws-lb-controller -n kube-system

# 5. Huỷ hạ tầng — ở APP REPO
cd ../badmintonHub/terraform && terraform destroy
```

## Vì sao thứ tự này quan trọng
- **Xoá child app là vô nghĩa** — controller sinh lại ngay. Phải xoá root/ApplicationSet.
- **PVC phải xoá khi cụm còn sống**: reclaim policy `Delete` chỉ chạy lúc PVC bị xoá. Destroy thẳng cụm → **~40 GB EBS mồ côi ≈ $3.2/tháng** chảy âm thầm, không ai nhìn thấy.
- **Ingress trước controller**: gỡ controller trước thì không còn ai gỡ ALB → ALB sống tiếp.

## Verify bill ≈ 0 (chạy thật, đừng tin cảm giác)
```bash
aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'   # phải RỖNG
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'                   # phải RỖNG
```
Console: EC2 = 0 instance · EKS = 0 cluster · ALB = 0 · NAT = 0 · EBS = 0 volume `available`.

## PHẢI giữ lại — đừng xoá nhầm
**S3** (tf state) · **DynamoDB** (lock) · **ECR** (9 image) · **SSM param** (`/badminton/*`) · **Route53 zone + ACM cert** (Day 8).
Xoá nhầm mấy cái này = buổi sau phải build lại image / nạp lại secret / xin lại cert → **phá tiêu chí "0 thao tác tay"**.

Bước 5 chạy ở `../badmintonHub` — nếu đang ở repo này thì báo người dùng, đừng tự `cd` sang chạy `terraform destroy` mà không xác nhận.
Báo cáo: bước nào đã chạy, output thật, và **danh sách tài nguyên còn sót** (nếu có) kèm lệnh dọn.
