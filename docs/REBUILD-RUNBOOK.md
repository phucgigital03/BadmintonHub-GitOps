# Rebuild runbook — dựng cụm mỗi buổi rồi xoá sạch

> **File này = việc bạn làm MỖI BUỔI.** Khác với [`DAY6-EXPLAINED.md`](DAY6-EXPLAINED.md) (runbook **lần đầu**,
> có bước nạp SSM và cài ArgoCD lần đầu) và [`DAY4-EXPLAINED.md`](DAY4-EXPLAINED.md) (deploy tay, đường dự phòng
> khi ArgoCD hỏng).
>
> 📋 **Mọi khối lệnh dưới đây KHÔNG có comment `#`** — cố ý. zsh tương tác không bật
> `interactive_comments`, dán khối có `#` vào là gặp `command not found: #` hoặc `parse error near )`.
> Giải thích nằm ngoài khối lệnh.

---

## Đồng hồ tiền — đọc trước

| Giai đoạn | Thời gian | Tiền cộng dồn |
|---|---|---|
| Bước 0 (chuẩn bị) | ~2' | **$0** |
| Bước 1 `terraform apply` | ~15' | $0.06 |
| Bước 2 `bootstrap.sh` | ~4' | $0.08 |
| Bước 3–4 ArgoCD + bấm nút | ~3' | $0.09 |
| Bước 5 cụm tự lắp tới xanh | ~10' | **$0.14** |
| Demo | 10' | $0.18 |
| Bước 7–8 teardown | ~15' | **~$0.25** |

Cụm sống ≈ **$0.25/giờ** (đo thật). Buổi gọn ≈ **$0.25**; buổi vừa dựng vừa debug 2 giờ ≈ **$0.50**.
Quên tắt một tháng ≈ **$180**.

🔴 **Đặt hẹn giờ điện thoại "DESTROY" ở Bước 0**, trước khi gõ lệnh đầu tiên. Budget alert chỉ báo
*sau khi* đã tốn tiền; hẹn giờ mới là cái chặn.

---

## Bước 0 — Trước khi tốn đồng nào

```bash
cd ~/ClaudeCodeProjects/badmintonHub-gitops
git pull origin main
git status --short
```

Working tree phải **sạch** và `main` = `origin/main`. **ArgoCD đọc GitHub, không đọc ổ đĩa của bạn** —
có gì chưa push thì cụm không bao giờ thấy.

```bash
for ENV in staging prod; do
  echo "$ENV: $(aws ssm get-parameters-by-path --path /badminton/$ENV/ --query 'length(Parameters)' --output text) param"
done
```

Phải ra **10 và 10**. Param sống ngoài cụm nên `terraform destroy` không xoá — bình thường không phải
làm gì. Ra 0 thì xem [`MANUAL-SETUP.md`](MANUAL-SETUP.md) §3.

---

## Bước 1 — Hạ tầng (~15')

```bash
cd ~/ClaudeCodeProjects/badmintonHub/terraform
terraform apply -auto-approve
```

---

## Bước 2 — Add-on (~4')

```bash
cd ~/ClaudeCodeProjects/badmintonHub
./scripts/bootstrap.sh
```

Script tự nối `kubeconfig`, dựng StorageClass `gp3` (và hạ `gp2` khỏi default), cài AWS LB Controller
`3.5.0` + External Secrets `2.8.0` + ClusterSecretStore `aws-ssm`. Idempotent.

🔴 **Báo `Unauthorized` thì ĐỪNG destroy rồi dựng lại** — mất 30 phút và tiền. Cụm không hỏng, chỉ là
principal hiện tại chưa có access entry; `bootstrap.sh` in sẵn 2 lệnh `aws eks create-access-entry` +
`associate-access-policy` để vá nóng.

Chốt chặn trước khi đi tiếp:

```bash
kubectl get nodes -o wide
kubectl get storageclass
kubectl get clustersecretstore
```

- 2 node `Ready` **và có cột EXTERNAL-IP** — mô hình này né NAT Gateway nên node ra Internet bằng
  public IP của chính nó. Không có IP = không pull được ECR = mọi pod `ImagePullBackOff`.
- `gp3 (default)`, `gp2` **không** còn `(default)`.
- `aws-ssm` **Valid**.

> ⚠️ `Valid` chỉ chứng minh ESO **xác thực được** với AWS, **không** chứng minh nó fetch được. Đường
> fetch sẽ được kiểm thật ở Bước 6 (4 ExternalSecret `SecretSynced`).

---

## Bước 3 — ArgoCD (~3')

```bash
cd ~/ClaudeCodeProjects/badmintonHub-gitops
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --version 10.2.3 --wait --timeout 10m
```

`bootstrap.sh` **không** cài ArgoCD — bước này luôn phải chạy.

🔴 **Ghim `10.2.3`** (→ ArgoCD `v3.5.0`). `apps/appset-services.yaml` dùng `goTemplate: true` với
`{{.svc}}`; cú pháp fasttemplate cũ `{{svc}}` đã bị gỡ ở ArgoCD 3.0, còn multi-source `$values` cần ≥ 2.6.
Để trống version = cụm hôm nay và cụm tuần sau có thể khác nhau mà không ai sửa dòng code nào.

*(Hoặc chạy `./scripts/argocd-install.sh` — nó làm Bước 3 + 4 một lượt và tự đối chiếu SSM.)*

---

## Bước 4 — Bấm nút

```bash
kubectl apply --server-side -f apps/root.yaml
```

Lệnh `apply` bằng tay **duy nhất** của cả mô hình. Sau nó ArgoCD dựng: 10 datastore, 18 service,
4 Secret kéo từ SSM, 1 ALB.

🔴 **`--server-side` không phải tuỳ chọn cho đẹp.** Client-side apply nhồi annotation
`kubectl.kubernetes.io/last-applied-configuration` vào object, và vì root **tự quản lý chính nó** nên
`kubectl` với `argocd-application-controller` sẽ giành quyền sở hữu field.

---

## Bước 5 — Xem nó tự lắp (~10')

```bash
kubectl get applications -n argocd -w
```

Mong đợi: `badmintonhub-root` → `infra-{staging,prod}` → `platform-{staging,prod}` → 18 app
`<svc>-<env>`. Tổng **23**.

### 🔴 Điều gần như chắc chắn sẽ thấy — ĐỪNG hoảng

Vài pod đứng ở **`Init:0/1`** và cột `RESTARTS` của **initContainer** nhích lên.

Đó là **hàng rào đang làm việc**, không phải hỏng. `platform` và service là hai Application sync song
song; nếu ConfigMap `app-config` tới sau thì initContainer thấy `DATASTORE_WAIT` rỗng và cố tình
`exit 1` để kubelet thử lại (thay vì âm thầm bỏ qua hàng rào). **Tự khỏi trong 1–2 phút.**

Xác nhận đang đi đúng đường:

```bash
kubectl -n staging logs deploy/user-service -c wait-datastores
```

Thấy `chờ postgresql.data-staging.svc.cluster.local:5432  ok` (đủ 5 dòng) là xong.

---

## Bước 6 — Nghiệm thu

```bash
kubectl get applications -n argocd -o custom-columns=N:.metadata.name,S:.status.sync.status,H:.status.health.status --no-headers | grep -v "Synced *Healthy"
```

**Không in gì** = 23/23 xanh.

```bash
kubectl get externalsecret -A
kubectl get pods -n staging
kubectl get pods -n prod
kubectl get pvc -A
```

4 ExternalSecret `SecretSynced` · 9 pod `Running` mỗi env · 8 PVC `Bound` trên `gp3`.

> 👉 **Nhìn cột `RESTARTS` của container chính.** `0` ⇒ initContainer đã thật sự chặn được cuộc đua
> service-trước-datastore. `1–3` ⇒ hàng rào chưa đủ, đọc log `wait-datastores` và báo lại.
> *(Đây là tiêu chí duy nhất của Day 6 chưa được nghiệm thu từ cụm trắng.)*

```bash
ALB=$(kubectl -n staging get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "http://$ALB"
curl -s -o /dev/null -w '%{http_code}\n' "http://$ALB/"
curl -s -o /dev/null -w '%{http_code}\n' -X POST "http://$ALB/api/auth/login" -H 'Content-Type: application/json' -d '{"email":"x@y.z","password":"wrong"}'
```

`200` rồi `401` ⇒ chuỗi ALB → gateway → user-service → Postgres thông. Phải truy được DB mới biết user
không tồn tại.

🔴 **KHÔNG nghiệm thu bằng `/api/actuator/health`** — Ingress không rewrite path, gateway nhận nguyên
văn `/api/actuator/health` trong khi actuator của nó ở `/actuator/health` ⇒ **404** gây hiểu nhầm.

Đọc mã trả về: **502/503** = target group hỏng · **404** = đã tới gateway, sai path ·
**401/400/405** = đã tới service.

---

## Bước 7 — TEARDOWN (thứ tự là bắt buộc)

```bash
kubectl delete applicationset badmintonhub -n argocd
kubectl delete app -n argocd --all --timeout=300s
```

Lệnh thứ hai **sẽ timeout ở `badmintonhub-root`** — đã gặp thật, bình thường (finalizer chờ cascade).
Gỡ finalizer sau khi các app con đã biến mất:

```bash
kubectl -n argocd patch app badmintonhub-root -p '{"metadata":{"finalizers":null}}' --type merge
kubectl get app -n argocd
```

```bash
kubectl -n data-staging get pods
kubectl -n data-prod get pods
```

🔴 **PHẢI thấy RỖNG bằng mắt trước khi đi tiếp.** Xoá PVC khi pod còn mount thì finalizer
`pvc-protection` làm lệnh **treo vô hạn** — mà output vẫn in `deleted` cho từng cái, rất dễ Ctrl-C rồi
`terraform destroy` luôn ⇒ **EBS mồ côi vẫn tính tiền**.

```bash
kubectl delete pvc --all -n data-staging
kubectl delete pvc --all -n data-prod
kubectl get pvc -A
kubectl get pv
```

Hai lệnh cuối phải rỗng.

> 📌 **GitOps KHÔNG cứu bạn khỏi bước này.** 8 PVC sinh từ `volumeClaimTemplates` của StatefulSet không
> nằm trong manifest nào nên ArgoCD `prune` không đụng tới và `helm uninstall` cũng không xoá.
> (2 PVC `mongodb` là object thường trong chart nên ArgoCD tự prune — đó là lý do đếm ra 8 chứ không 10.)

```bash
kubectl get ingress -A
helm uninstall aws-lb-controller -n kube-system
```

Ingress phải đã rỗng (cascade ở trên đã xoá) — ALB chỉ được AWS LB Controller gỡ khi Ingress biến mất,
nên **phải xong việc này trước khi gỡ controller**.

```bash
cd ~/ClaudeCodeProjects/badmintonHub/terraform
terraform destroy -auto-approve
```

Kết thúc bằng `Destroy complete! Resources: 76 destroyed.`

---

## Bước 8 — Verify bill về 0 (chạy thật, đừng tin cảm giác)

```bash
R=ap-southeast-1
aws eks list-clusters --region $R --query 'clusters' --output text
aws ec2 describe-instances --region $R --filters Name=instance-state-name,Values=running,pending --query 'Reservations[].Instances[].InstanceId' --output text
aws ec2 describe-volumes --region $R --query 'Volumes[].VolumeId' --output text
aws elbv2 describe-load-balancers --region $R --query 'LoadBalancers[].LoadBalancerName' --output text
aws elb describe-load-balancers --region $R --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text
aws ec2 describe-nat-gateways --region $R --filter Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId' --output text
aws ec2 describe-addresses --region $R --query 'Addresses[?!AssociationId].PublicIp' --output text
aws ec2 describe-snapshots --region $R --owner-ids self --query 'Snapshots[].SnapshotId' --output text
aws ec2 describe-vpcs --region $R --query 'Vpcs[?IsDefault==`false`].VpcId' --output text
aws ec2 describe-network-interfaces --region $R --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
```

**Tất cả phải rỗng.**

### Còn lại có chủ ý — và giá thật

| Còn gì | Tiền | Vì sao giữ |
|---|---|---|
| **ECR ~4.7 GB** (9 repo) | **~$0.46/tháng** | image bất biến để rollback + rebuild không phải build lại. Có lifecycle policy: xoá untagged sau 1 ngày, giữ 20 image gần nhất |
| S3 state + DynamoDB lock | ~vài cent | mất là Terraform không dựng lại được |
| **20 SSM param** | **$0** | standard tier free — chính là thứ khiến rebuild = 0 thao tác tay |
| KMS key `PendingDeletion` | **$0** | mỗi `apply` tạo 1 key, `destroy` chỉ hẹn xoá 30 ngày nên chúng tích lại. AWS pricing: *"There is no charge for customer managed KMS keys that you manage and are scheduled for deletion."* Không cần dọn tay |

**Thường trực ≈ $0.46/tháng.**

---

## Bảng tra nhanh: triệu chứng → nghi gốc

| Triệu chứng | Nghi gốc |
|---|---|
| `bootstrap.sh` báo `Unauthorized` | thiếu access entry — **vá nóng, đừng dựng lại cụm** |
| node **không có EXTERNAL-IP** | `map_public_ip_on_launch` ở `terraform/vpc.tf` → mọi pod `ImagePullBackOff` |
| Pod kẹt `Init:0/1` **dưới 2 phút** | bình thường — hàng rào đang chờ ConfigMap/datastore |
| Pod kẹt `Init:0/1` **quá 5 phút** | một cổng không bao giờ mở (NetworkPolicy?). Sau `waitTimeoutSeconds` initContainer tự bỏ qua |
| Container chính `RESTARTS` 1–3, log `UnknownHostException` | hàng rào không ăn — kiểm `DATASTORE_WAIT` trong `app-config` |
| App `infra-*` `ComparisonError: missing in charts/ directory` | repo-server không ra được `charts.bitnami.com` → bỏ `infra/charts/` khỏi `.gitignore`, commit 5 `.tgz` |
| `ExternalSecret` `SecretSyncedError` + `unexpected find operator` | `find.path` thiếu `find.name.regexp` |
| `ExternalSecret` `AccessDenied` | IRSA thiếu `ssm:GetParametersByPath` / `kms:Decrypt` |
| App **OutOfSync vĩnh viễn** | manifest khai field bằng **đúng giá trị mặc định** (`false`/`0`/`""`) → API server lược đi |
| `/api` trả **502** dù pod xanh | ALB health-check — kiểm `service.annotations` ở `values/api-gateway-*.yaml` |
| Ingress không có ADDRESS quá 5' | thiếu tag subnet `kubernetes.io/role/elb=1` |
| Sửa `kubectl edit` xong bị mất | `selfHeal: true` — đúng thiết kế, sửa vào Git |
| `kubectl delete pvc` treo | pod còn mount — quay lại đợi pod biến mất |
| Nút copy số tài khoản không copy | Web API secure-context-only trên `http` — Day 8 (HTTPS) sửa miễn phí |

---

## Nhắc cuối

- Rollback = **`git revert`**. Không `helm rollback`, không `argocd app rollback` — cụm phải luôn khớp `main`.
- Promote staging → prod = PR đổi `values/<svc>-prod.yaml` sang **đúng SHA đã verify ở staging**. Không build lại.
- Không `kubectl edit` lên cụm. `selfHeal` ghi đè trong ~3 phút và làm bạn hiểu sai trạng thái thật.
- **Tag lệch nhau giữa các service là bình thường.** Mỗi service có vòng đời riêng — đừng build lại cho đều.
