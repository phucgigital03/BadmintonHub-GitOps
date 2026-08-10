# Day 6 giải thích cho người mới — để Git trở thành nút bấm deploy

> Cùng lối viết với [`DAY2-EXPLAINED.md`](DAY2-EXPLAINED.md) và [`DAY4-EXPLAINED.md`](DAY4-EXPLAINED.md):
> khái niệm trước, **runbook lệnh rời để gõ tay** sau, cuối cùng là bảng triệu chứng → nghi gốc.

---

## §0 — Day 6 là gì, và KHÔNG phải gì

**Là**: cài ArgoCD, cho nó đọc repo này, và chuyển việc nạp Secret từ script tay sang ESO đọc SSM.

**Không phải**: viết thêm chart, sửa values service, hay đụng tới code app. Chart và 27 file values đã xong từ Day 2/4 và **không sửa một dòng nào** ở Day 6 — đó chính là bằng chứng thiết kế cũ đúng.

### Trước và sau

| Việc | Day 4 | Day 6 |
|---|---|---|
| Nạp Secret | `./scripts/eks-secret.sh staging` | ESO tự đọc SSM |
| Deploy | `./scripts/eks-deploy.sh staging` (11 lần `helm install`) | ArgoCD tự sync |
| CI bump tag | file đổi trong Git, **nằm im** | ~1 phút sau lên cụm |
| Sửa tay bằng `kubectl` | cụm lệch Git, không ai biết | `selfHeal` kéo về |
| Deploy prod | chưa từng chạy | tự chạy cùng staging |
| Rollback | nhớ lại đã làm gì | `git revert` |

Sau Day 6, lệnh **duy nhất** phải gõ tay để dựng lại toàn bộ ứng dụng là:

```bash
kubectl apply -f apps/root.yaml
```

---

## §1 — Bốn khái niệm mới

### 1.1 App-of-apps: một Application quản lý các Application khác

`Application` là một **CRD** — một object Kubernetes bình thường. Nên một Application hoàn toàn có thể "deploy" ra… các Application khác.

```
apps/root.yaml  ─(đọc thư mục apps/)─┬─ apps/infra-staging.yaml      → 5 datastore @ data-staging
                                     ├─ apps/infra-prod.yaml         → 5 datastore @ data-prod
                                     ├─ apps/platform-staging.yaml   → ConfigMap + Ingress + Secret @ staging
                                     ├─ apps/platform-prod.yaml      → ConfigMap + Secret @ prod
                                     └─ apps/appset-services.yaml    → ApplicationSet
                                                                          └→ 18 Application service
```

Root nằm **trong chính thư mục nó quản lý**, nên sau lần `kubectl apply` đầu tiên nó tự quản lý luôn bản thân: sửa `root.yaml` rồi push là ArgoCD tự áp dụng.

🔴 Hệ quả quan trọng cho teardown: **xoá child app là vô nghĩa**, ApplicationSet controller sinh lại ngay. Phải xoá **root**.

### 1.2 ApplicationSet: một khuôn, 18 bản

Matrix generator nhân 2 danh sách với nhau: 9 service × 2 env = 18 Application, tất cả cùng một khuôn. Đây là lý do Day 2 bắt buộc **một chart `charts/service` cho cả 9 service kể cả `frontend`** — có chart riêng cho FE thì matrix không dùng được và phải quay lại viết tay 18 file.

**🔴 Cú pháp đã đổi ở ArgoCD 3.0.** Có 2 engine template:

| Engine | Cú pháp | Tình trạng |
|---|---|---|
| fasttemplate (cũ) | `{{svc}}` — **không** dấu chấm | **ĐÃ BỊ GỠ ở ArgoCD 3.0** |
| Go template | `{{.svc}}` — **có** dấu chấm, cần `goTemplate: true` | dùng cái này |

`Planning_CICD.md` §Day 6 và gần như mọi blog trên mạng vẫn viết kiểu cũ. Repo này ghim ArgoCD **v3.5.0** nên bắt buộc dùng Go template.

Kèm `goTemplateOptions: [missingkey=error]`: gõ nhầm `{{.service}}` thì ApplicationSet **báo lỗi** thay vì đẻ ra một app tên `-staging`.

### 1.3 Sync-wave: thứ tự, và vì sao thiếu nó là cả một cơn bão

ArgoCD mặc định apply mọi thứ **song song**. Với hệ này thì sai: 18 JVM boot lúc Postgres/Kafka/Secret chưa tồn tại ⇒ crash ⇒ restart ⇒ **mỗi vòng restart lại boot thêm một JVM** ⇒ CPU node bốc lên và bạn sẽ đi đổ lỗi cho RAM. Đây đúng là bài học đắt nhất của Day 2 (`.claude/rules/helm-chart.md` §"Cụm chậm" gần như luôn là VÒNG LẶP RESTART).

Annotation `argocd.argoproj.io/sync-wave` xếp thứ tự; ArgoCD **chờ wave trước Healthy** rồi mới sang wave sau.

| Wave | Ai | Vì sao |
|---:|---|---|
| **-1** | `ExternalSecret` | Secret phải có trước pod |
| **1** | `infra-staging`, `infra-prod` | 5 datastore, PVC bind EBS thật — chậm nhất (~3-5') |
| **2** | `platform-staging`, `platform-prod` | ConfigMap + Ingress. Đặt trước service để ALB provision **song song** với lúc JVM boot |
| **3** | `appset-services` | 18 app service |

⚠️ Có một cái bẫy về **phạm vi**: ApplicationSet sinh 18 app con **độc lập** với root. Wave chỉ chặn được thời điểm *ApplicationSet được tạo ra*; sau đó 18 app con tự chạy. Vì vậy wave 3 phải nằm trên **ApplicationSet**, không phải trên từng app con.

### 1.4 ESO thay script: cùng một Secret, khác cách sinh ra

`scripts/eks-secret.sh` và ExternalSecret cho ra **cùng tên Secret** (`app-secrets`, `datastore-secrets`) → 27 file values không cần biết mình đang được nạp bằng cách nào. Đó là lý do Day 6 không sửa values.

Nhưng ESO **không chạy được script**, và script Day 4 làm 2 việc "thông minh" mà giờ phải chuyển thành param thật:

| Việc script làm | Day 6 làm sao |
|---|---|
| tách password Mongo khỏi `MONGODB_CHAT_URI` bằng `sed` | param mới `MONGODB_ROOT_PASSWORD` |
| sinh erlang cookie bằng `openssl rand` | param mới `RABBITMQ_ERLANG_COOKIE` |

Đổi lại được một thứ: con regex "neo vào dấu `@` **cuối cùng**" từng cắn ở Day 4 biến mất hẳn.

---

## §2 — Runbook: bạn gõ tay từng lệnh

> Giả định cụm đã dựng xong (`terraform apply` + `bootstrap.sh` ở repo app) và `kubectl` đang trỏ đúng cụm.

### Phần A — một lần duy nhất, không cần cụm

```bash
# ─── A1. Nạp 4 param SSM MỚI của Day 6 (2 tên × 2 env) ────────────────────────────
# Param sống NGOÀI cụm nên chỉ làm một lần trong đời, terraform destroy không xoá.
#
# 🔑 Sinh MỘT password Mongo rồi dùng lại cho CẢ HAI param — đây là cách duy nhất bảo đảm
#    MONGODB_ROOT_PASSWORD và password nhúng trong MONGODB_CHAT_URI không bao giờ lệch.
#    Lệch nhau = Mongo dựng bằng mật khẩu A, chat-service kết nối bằng mật khẩu B, và log chỉ
#    nói "Authentication failed" nên bạn sẽ đi soi ?authSource=admin (vốn đang đúng).
#
# ⚠️ Nếu MONGODB_CHAT_URI đã tồn tại từ Day 4 thì ĐỪNG sinh password mới — lấy đúng password
#    đang nằm trong URI đó ra rồi put vào MONGODB_ROOT_PASSWORD.

for ENV in staging prod; do
  aws ssm put-parameter --type SecureString --overwrite \
    --name "/badminton/$ENV/RABBITMQ_ERLANG_COOKIE" --value "$(openssl rand -hex 16)"

  # đọc lại password Mongo từ URI đã có (in ra để tự nhìn, KHÔNG paste vào chat/screenshot)
  URI="$(aws ssm get-parameter --name "/badminton/$ENV/MONGODB_CHAT_URI" \
          --with-decryption --query 'Parameter.Value' --output text)"
  PASS="$(printf '%s' "$URI" | sed -n 's#^mongodb://[^:]*:\(.*\)@[^@]*$#\1#p')"
  [ -n "$PASS" ] || { echo "❌ không tách được password cho $ENV"; continue; }

  aws ssm put-parameter --type SecureString --overwrite \
    --name "/badminton/$ENV/MONGODB_ROOT_PASSWORD" --value "$PASS"
done

# ─── A2. Đối chiếu — phải ra ĐÚNG 10 tên cho mỗi env ──────────────────────────────
for ENV in staging prod; do
  echo "── $ENV"
  aws ssm get-parameters-by-path --path "/badminton/$ENV/" --recursive \
    --query 'Parameters[].Name' --output text | tr '\t' '\n' | sed 's|.*/||' | sort
done
# Mong đợi (10): CLOUDINARY_API_KEY CLOUDINARY_API_SECRET CLOUDINARY_CLOUD_NAME JWT_SECRET
#                MONGODB_CHAT_URI MONGODB_ROOT_PASSWORD POSTGRES_PASSWORD POSTGRES_USERNAME
#                RABBITMQ_ERLANG_COOKIE RABBITMQ_PASS
# KHÔNG có SENDGRID_API_KEY / GOOGLE_CLIENT_* là ĐÚNG — SSM từ chối giá trị rỗng, chart tự
# bơm key rỗng vào Secret (xem charts/platform/values.yaml → externalSecret.optionalKeys).
```

### Phần B — trên cụm

```bash
# ─── B0. Tiền đề: 3 thứ mà nếu thiếu thì mọi bước sau "chạy được" nhưng kết quả sai ──

kubectl get crd externalsecrets.external-secrets.io \
  -o jsonpath='{.spec.versions[*].name}{"\n"}'
# 🔴 Phải thấy "v1". Repo này khai apiVersion: external-secrets.io/v1.
#    v1beta1 đã bị GỠ ở ESO 0.17.0; còn ở 0.16.x thì webhook tự chuyển v1beta1 → v1 và ArgoCD
#    sẽ OutOfSync VĨNH VIỄN vì desired ≠ live (external-secrets#5478).
#    Chỉ thấy v1beta1 (ESO < 0.16) → sửa 1 dòng externalSecret.apiVersion ở 2 file values.

kubectl get clustersecretstore aws-ssm
# Phải Valid. Không có → ESO/IRSA chưa xong ở bootstrap.sh (Day 3), dừng lại xử cái đó trước.

kubectl get ingressclass alb          # Ingress cần cái này mới sinh ra ALB
kubectl get storageclass gp3          # PVC cần cái này mới bind được EBS


# ─── B0.5. SMOKE TEST ESO — 30 giây, đừng bỏ qua ──────────────────────────────────
# 🔴 `ClusterSecretStore = Valid` KHÔNG chứng minh đường fetch chạy được — nó chỉ chứng minh
#    ESO xác thực được với AWS. Day 4 có ESO Valid suốt mà không phát hiện bug nào, vì lúc đó
#    Secret nạp bằng eks-secret.sh (gọi thẳng AWS CLI) và CHƯA CÓ ExternalSecret nào tồn tại.
# Test này bắt cùng lúc 3 thứ: IRSA đủ quyền GetParametersByPath · apiVersion đúng ·
# và find/rewrite render ra thứ ESO thật sự chấp nhận.
kubectl apply -f - <<'EOF'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: eso-smoke, namespace: default }
spec:
  refreshInterval: 1h
  secretStoreRef: { name: aws-ssm, kind: ClusterSecretStore }
  target: { name: eso-smoke, creationPolicy: Owner }
  dataFrom:
    - find:
        path: /badminton/staging/
        name: { regexp: ".*" }
      rewrite:
        - regexp: { source: "^.*/([^/]+)$", target: "${1}" }
EOF
sleep 10
kubectl get externalsecret eso-smoke -n default          # STATUS phải = SecretSynced
kubectl get secret eso-smoke -n default -o jsonpath='{.data}' \
  | tr ',' '\n' | cut -d'"' -f2 | sort                   # 10 key, KHÔNG key nào có dấu "/"
kubectl delete externalsecret eso-smoke -n default       # Owner ⇒ Secret biến mất theo


# ─── B1. Cài ArgoCD (ghim version) ────────────────────────────────────────────────
# Chart 10.2.3 → ArgoCD v3.5.0. Đừng hạ dưới 3.0: ApplicationSet dùng goTemplate.
# bootstrap.sh của Day 3 CÓ THỂ đã cài rồi — `upgrade --install` nên chạy lại vô hại.
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  --version 10.2.3 --wait --timeout 10m

kubectl -n argocd get pods            # tất cả Running


# ─── B2. BẤM NÚT — lệnh apply tay duy nhất của cả mô hình ─────────────────────────
kubectl apply -f apps/root.yaml


# ─── B3. Xem nó tự dựng ───────────────────────────────────────────────────────────
kubectl get applications -n argocd -w
# Thứ tự mong đợi:
#   1. badmintonhub-root xuất hiện
#   2. infra-staging + infra-prod        (wave 1) — CHẬM NHẤT, ~3-5' vì PVC bind EBS thật
#   3. platform-staging + platform-prod  (wave 2)
#   4. 18 app <svc>-<env>                (wave 3)
#
# 🔴 Trong lúc wave 1 chạy mà CHƯA thấy app service nào là ĐÚNG THIẾT KẾ, không phải treo.
#    Ngược lại, nếu 18 app hiện ra NGAY LẬP TỨC thì sync-wave không ăn → xem §4.

kubectl get externalsecret -A
# Cả 4 phải SecretSynced (app-secrets @ staging/prod, datastore-secrets @ data-staging/data-prod)


# ─── B4. Nghiệm thu ───────────────────────────────────────────────────────────────
kubectl get applications -n argocd -l env=staging      # ĐÚNG 9
kubectl get applications -n argocd -l env=prod         # ĐÚNG 9
kubectl get applications -n argocd -o wide             # tất cả Synced / Healthy

# Chỉ in TÊN KEY, KHÔNG BAO GIỜ in giá trị — transcript và ảnh chụp màn hình đều là nơi rò secret
kubectl -n staging get secret app-secrets -o jsonpath='{.data}' \
  | tr ',' '\n' | cut -d'"' -f2 | sort
# Phải có đủ 13 key: 10 từ SSM + 3 key rỗng do template bơm
#   (SENDGRID_API_KEY, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET)
# 🔴 Thấy key dạng "/badminton/staging/JWT_SECRET" (có dấu /) → thiếu `rewrite` trong dataFrom.

kubectl -n data-staging get secret datastore-secrets -o jsonpath='{.data}' \
  | tr ',' '\n' | cut -d'"' -f2
# 4 key: postgres-password mongodb-root-password rabbitmq-password rabbitmq-erlang-cookie

kubectl -n staging get pods                            # 9/9 Running, RESTARTS 0
ALB="$(kubectl -n staging get ingress badminton -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
curl -s -o /dev/null -w '%{http_code}\n' "http://$ALB/"                       # 200
curl -s -o /dev/null -w '%{http_code}\n' -X POST "http://$ALB/api/auth/login" \
  -H 'Content-Type: application/json' -d '{"email":"x@y.z","password":"wrong"}'   # 401
# 🔴 KHÔNG nghiệm thu bằng /api/actuator/health — Ingress không rewrite path (xem DAY4-EXPLAINED).
```

### Phần C — chứng minh vòng lặp đã đóng

```bash
# ─── C1. CI → staging (làm ở repo app) ────────────────────────────────────────────
# Sửa 1 dòng bất kỳ ở ../badmintonHub → push main → CI build + push ECR + bump
# values/<svc>-staging.yaml của repo NÀY → ArgoCD tự sync trong ~1-3'.
kubectl -n staging get deploy <svc> -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'


# ─── C2. Promote staging → prod (làm ở repo này) ──────────────────────────────────
# KHÔNG build lại. Chỉ đổi tag sang đúng SHA đã verify ở staging.
git checkout -b promote/<svc>-<sha>
# sửa values/<svc>-prod.yaml: image.tag → <sha>
git commit -am "chore(promote): <svc> prod <cũ> -> <sha> (SHA đã verify ở staging)"
# → PR → merge → ArgoCD sync ns prod


# ─── C3. Rollback ─────────────────────────────────────────────────────────────────
git revert <commit>        # KHÔNG dùng `helm rollback` / `argocd app rollback`
```

### Phần D — teardown (thứ tự đã đổi so với Day 4)

```bash
# 1. Xoá ROOT, --cascade kéo theo tất cả (18 service + Ingress ⇒ ALB + datastore)
argocd app delete badmintonhub-root --cascade
#    hoặc không có CLI argocd:
#    kubectl delete applicationset badmintonhub -n argocd && kubectl delete app -n argocd --all

# 2. 🔴 ĐỢI POD BIẾN MẤT THẬT — "đã ra lệnh xoá" ≠ "đã xoá xong".
kubectl -n data-staging get pods && kubectl -n data-prod get pods     # phải RỖNG

# 3. Xoá PVC KHI CỤM CÒN SỐNG. PVC do volumeClaimTemplates sinh ra KHÔNG bị ArgoCD prune
#    và cũng không bị helm uninstall xoá — bước này không bao giờ bỏ được.
kubectl delete pvc --all -n data-staging
kubectl delete pvc --all -n data-prod

# 4. Còn lại theo .claude/rules/ephemeral-cost.md §7.1
```

---

## §3 — Tự kiểm tra

Trả lời được không nhìn tài liệu thì bạn đã nắm Day 6:

1. Vì sao xoá `user-service-staging` bằng `argocd app delete` thì nó mọc lại?
2. `apps/platform-staging.yaml` dùng multi-source còn `apps/infra-staging.yaml` thì không — vì sao?
3. Nếu bỏ `rewrite` khỏi `dataFrom`, ExternalSecret hỏng ở đâu và triệu chứng là gì?
4. `mergePolicy: Merge` khiến cái gì thắng cái gì? Điều đó tạo ra landmine nào?
5. Vì sao `ingress.enabled` của prod vẫn `false` sau Day 6?
6. Sync-wave 3 phải đặt trên ApplicationSet chứ không phải trên 18 app con — vì sao?

<details>
<summary>Đáp án</summary>

1. ApplicationSet controller sinh lại child ngay. Phải xoá root hoặc chính ApplicationSet.
2. Chart `platform` ở `charts/platform` nhưng values ở `infra/values/` — **ngoài** `source.path`, mà ArgoCD chặn `valueFiles` ngoài app path. Chart `infra` thì values nằm ngay trong `infra/values/` nên single-source đủ.
3. ESO trả key kèm nguyên path `/badminton/staging/JWT_SECRET`; key của K8s Secret không được chứa `/` → ExternalSecret không sync → mọi pod `CreateContainerConfigError`.
4. Template **thắng** provider. Landmine: nạp giá trị thật vào SSM mà quên xoá tên khỏi `optionalKeys` thì bị ghi đè rỗng trong im lặng, ExternalSecret vẫn báo `SecretSynced`.
5. staging + prod chung `group.name` mà cùng `host: ""` ⇒ AWS LB Controller gộp rule, cái đứng sau không bao giờ khớp, traffic prod lặng lẽ chảy vào staging. Host header mới tách được 2 env, mà host chỉ có từ Day 8.
6. Vì 18 app con do ApplicationSet controller đẻ ra, **không** phải do root sync — root không xếp wave cho chúng được. Chặn được duy nhất ở thời điểm ApplicationSet được tạo.
</details>

---

## §4 — Bảng tra nhanh: triệu chứng → nghi gốc (riêng Day 6)

| Triệu chứng | Nghi gốc |
|---|---|
| App tên **`{{svc}}-{{env}}`** hoặc `-staging` | thiếu `goTemplate: true`, hoặc còn viết `{{svc}}` không dấu chấm trên ArgoCD 3.x |
| 18 app service hiện ra **ngay**, pod restart hàng loạt | sync-wave không ăn — kiểm annotation trên `apps/appset-services.yaml`, đọc log `argocd-application-controller` |
| `infra-*` `ComparisonError: found in Chart.yaml, but missing in charts/ directory` | repo-server không ra được `charts.bitnami.com` → bỏ `infra/charts/` khỏi `.gitignore`, commit 5 `.tgz` (~490 KB) |
| App **OutOfSync vĩnh viễn**, sync mãi không hết | `apiVersion: v1beta1` trên ESO 0.16.x (webhook tự chuyển sang `v1`) |
| Key trong Secret có dấu `/` | thiếu `rewrite` trong `dataFrom` |
| `SecretSyncedError` + `unexpected find operator` | `find.path` viết trần — **thiếu `find.name.regexp`**, `path` không phải toán tử tìm kiếm |
| `SecretSyncedError` / `AccessDenied` | IRSA của SA `external-secrets` thiếu `ssm:GetParameter*` / `kms:Decrypt` |
| Secret sync ra nhưng **rỗng key** | sai `ssmPath` (thiếu `/` cuối) |
| SSM **có** giá trị thật mà pod nhận **rỗng** | tên đó còn nằm trong `externalSecret.optionalKeys` |
| Pod `CreateContainerConfigError` | Secret chưa tồn tại lúc pod start → thiếu `sync-wave: "-1"` |
| Mongo/chat-service `Authentication failed` lúc boot | `MONGODB_ROOT_PASSWORD` lệch password trong `MONGODB_CHAT_URI` |
| RabbitMQ boot fail bằng lỗi Erlang khó đọc | `RABBITMQ_ERLANG_COOKIE` đổi trong khi PVC còn data cũ |
| `valueFiles must be within the app path` | dùng Application đơn thay vì multi-source `$values` |
| Child app `namespace not found` | thiếu `CreateNamespace=true` |
| `argocd app delete -l env=staging` không xoá gì | thiếu `labels` trong template ApplicationSet |
| Sửa `kubectl edit` xong bị mất | `selfHeal: true` — đúng thiết kế, sửa vào Git |
| ALB còn sống sau khi xoá app | Application thiếu finalizer `resources-finalizer.argocd.argoproj.io` |

---

## §5 — Day 6 để lại gì cho Day 7 và Day 8

- **Day 7 (observability)**: thêm `kube-prometheus-stack` + Loki = thêm 1-2 file vào `apps/` với wave phù hợp. Không phải dựng cơ chế mới.
- **Day 8 (domain + HTTPS)**: sửa **2 dòng values × 2 env** + `frontendUrl`, mở PR, merge. ArgoCD lo phần còn lại. Rollback = `git revert`.
- **Tiêu chí vàng đã đóng**: `destroy` → `apply` → `bootstrap.sh` → `kubectl apply -f apps/root.yaml` → e2e xanh, **không** phải nạp lại secret, **không** build lại image FE, **không** sửa ConfigMap theo ALB DNS mới.
