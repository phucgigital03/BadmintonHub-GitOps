---
description: Secret = External Secrets Operator + SSM Parameter Store. Git chỉ ref tên param, không bao giờ chứa giá trị. Vì sao KHÔNG SealedSecrets.
globs: external-secrets/**/*.yaml, apps/**/*secret*.yaml
---

# Secrets — External Secrets Operator + SSM

## Luật tuyệt đối

**KHÔNG commit secret thô, ciphertext, `.env`, hay bất kỳ giá trị nào vào repo này.** Repo **PUBLIC**.
Git chỉ chứa `ExternalSecret` **ref tên param** SSM. Giá trị thật nạp **1 lần** vào SSM `SecureString`, sống **ngoài cụm** → `terraform destroy` không xoá → rebuild là có secret ngay, **0 thao tác tay**.

Trước khi commit bất cứ file nào có chữ `password`/`secret`/`key`/`token`: dừng lại, kiểm giá trị có phải placeholder không.

## Vì sao KHÔNG SealedSecrets

SealedSecrets controller sinh **keypair mới mỗi lần cài**. Mô hình này `terraform destroy` sau mỗi buổi → cụm mới = khoá mới → **mọi `SealedSecret` đã commit thành rác không giải mã được** → rebuild xong toàn bộ pod `CreateContainerConfigError`. Nó đánh thẳng vào tiêu chí vàng "0 thao tác tay" ([`ephemeral-cost.md`](ephemeral-cost.md)).
*(Chữa được bằng cách backup keypair vào SSM rồi seed lại trước khi cài — nhưng nếu đã phải dùng SSM thì dùng thẳng SSM gọn hơn.)*

## Cấu hình

```yaml
# ClusterSecretStore — 1 lần cho cả cụm (apps/ hoặc infra/)
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata: { name: aws-ssm }
spec:
  provider:
    aws:
      service: ParameterStore
      region: ap-southeast-1
      auth: { jwt: { serviceAccountRef: { name: external-secrets, namespace: external-secrets } } }
---
# external-secrets/app-staging.yaml — KHÔNG chứa giá trị, chỉ ref tên
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata: { name: app-secrets, namespace: staging }
spec:
  refreshInterval: 1h
  secretStoreRef: { name: aws-ssm, kind: ClusterSecretStore }
  target: { name: app-secrets }            # ← chính là Secret mà envFrom của chart dùng
  dataFrom:
    - find: { path: /badminton/staging/ }  # hút cả cây param thành 1 Secret
```

Đổi env = đổi `path: /badminton/prod/` + `namespace: prod`. Tên target Secret phải khớp `envFrom.secret` trong `values/<svc>-<env>.yaml`.

## Param cần có ở SSM (`/badminton/<env>/*`)

`JWT_SECRET` · `POSTGRES_USERNAME` · `POSTGRES_PASSWORD` · `MONGODB_CHAT_URI` (nhớ `?authSource=admin`) · `RABBITMQ_PASS` · `SENDGRID_API_KEY` · `CLOUDINARY_CLOUD_NAME` / `CLOUDINARY_API_KEY` / `CLOUDINARY_API_SECRET` · `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`.

Non-secret → **ConfigMap**, đừng nhét vào SSM: `RABBITMQ_USER=badminton` · mọi `*_HOST`/`*_URL` in-cluster · `CHAT_BROKER_RELAY` · `MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED`.
Danh sách biến đầy đủ = `application.yml` từng service ở `../badmintonHub` (xem [`values-env-map.md`](values-env-map.md)).

```bash
aws ssm put-parameter --type SecureString --name /badminton/staging/JWT_SECRET --value "$(openssl rand -hex 64)"
aws ssm get-parameters-by-path --path /badminton/staging/ --query 'Parameters[].Name'   # đối chiếu đủ chưa
```

## Thứ tự bootstrap có ràng buộc

**ESO + ClusterSecretStore phải Ready TRƯỚC khi ArgoCD sync app.** Không thì pod khởi động lúc `Secret` chưa tồn tại → `CreateContainerConfigError` (tự khỏi sau khi ESO sync, nhưng buổi demo trông như hỏng).

## Debug

```bash
kubectl get externalsecret -A                              # tất cả phải SecretSynced
kubectl describe externalsecret app-secrets -n staging     # xem Events khi không sync
kubectl -n external-secrets logs deploy/external-secrets --tail=100
kubectl get secret app-secrets -n staging -o jsonpath='{.data}' | tr ',' '\n' | cut -d'"' -f2   # CHỈ liệt kê KEY
```

| Triệu chứng | Nghi gốc |
|---|---|
| `SecretSyncedError` / `AccessDenied` | IRSA role của ServiceAccount `external-secrets` thiếu quyền `ssm:GetParameter*` / `kms:Decrypt` |
| Secret sync ra nhưng **rỗng key** | sai `path` (thiếu `/` cuối) hoặc param nằm ở env khác |
| Pod `CreateContainerConfigError` | Secret chưa tồn tại lúc pod start → thứ tự bootstrap, hoặc tên target Secret ≠ `envFrom.secret` |
| Pod boot fail vì thiếu `CLOUDINARY_*` | **by design** (`CloudinaryProdGuard` `@Profile("prod")`) — nạp param, đừng bỏ profile prod |

> ⚠️ Khi debug: **in ra KEY, không in VALUE.** Đừng `base64 -d` secret rồi để giá trị nằm trong transcript.
