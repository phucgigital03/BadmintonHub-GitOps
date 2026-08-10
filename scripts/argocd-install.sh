#!/usr/bin/env bash
# Cài ArgoCD rồi bấm nút khởi động app-of-apps. Sau script này, mọi thứ còn lại là ArgoCD lo.
#
# 📌 LẦN ĐẦU THÌ ĐỪNG CHẠY SCRIPT NÀY — gõ tay theo `docs/DAY6-EXPLAINED.md` §runbook.
# Script chỉ là bản ghi lại đúng những lệnh trong runbook, dành cho lần rebuild thứ 2-3.
# Nó `echo` mọi lệnh trước khi chạy để không thành hộp đen.
#
# IDEMPOTENT: `helm upgrade --install` nên chạy lại khi ArgoCD đã có sẵn cũng không sao —
# hữu ích vì `bootstrap.sh` của Day 3 (repo app) CÓ THỂ đã cài ArgoCD rồi.
#
# Dùng:  ./scripts/argocd-install.sh
#        DRY_RUN=1 ./scripts/argocd-install.sh      # chỉ in lệnh, không chạy
set -uo pipefail
cd "$(dirname "$0")/.."

# ⚠️ GHIM VERSION. Chart 10.2.3 → ArgoCD v3.5.0.
# Hai thứ trong repo này phụ thuộc version ArgoCD, đừng hạ xuống dưới 3.0:
#   - ApplicationSet dùng `goTemplate: true` ({{.svc}} có dấu chấm). Cú pháp fasttemplate cũ
#     ({{svc}}) đã BỊ GỠ ở ArgoCD 3.0 — dùng bản < 2.x với manifest này thì ngược lại, goTemplate
#     chưa có và app sẽ mang tên literal.
#   - Multi-source `$values` cần >= 2.6.
CHART_VERSION="${CHART_VERSION:-10.2.3}"
NS="${NS:-argocd}"
DRY_RUN="${DRY_RUN:-0}"

run() {
  echo "   \$ $*"
  [ "$DRY_RUN" = "1" ] && return 0
  "$@"
}

echo "════ Cài ArgoCD (chart $CHART_VERSION) vào ns $NS"
[ "$DRY_RUN" = "1" ] && echo "     DRY_RUN=1 — chỉ in lệnh"

# ── Tiền đề ────────────────────────────────────────────────────────────────────────────
# 3 thứ mà nếu thiếu thì ArgoCD vẫn cài xong, vẫn báo Synced, nhưng pod không bao giờ chạy.
echo
echo "── Tiền đề"

kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1 \
  && echo "   ✅ CRD ExternalSecret · apiVersion phục vụ: $(kubectl get crd externalsecrets.external-secrets.io -o jsonpath='{.spec.versions[*].name}')" \
  || echo "   ❌ CHƯA có External Secrets Operator. Cài ESO trước (bootstrap.sh của Day 3)."

# ⚠️ Đối chiếu với `externalSecret.apiVersion` trong charts/platform/values.yaml + infra/values.yaml.
# Repo này khai `external-secrets.io/v1`. v1beta1 đã bị gỡ ở ESO 0.17.0; còn ở 0.16.x thì webhook
# tự chuyển v1beta1 → v1 và ArgoCD sẽ OutOfSync VĨNH VIỄN vì desired ≠ live.
kubectl get clustersecretstore aws-ssm >/dev/null 2>&1 \
  && echo "   ✅ ClusterSecretStore aws-ssm · status: $(kubectl get clustersecretstore aws-ssm -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null)" \
  || echo "   ❌ CHƯA có ClusterSecretStore 'aws-ssm' → mọi ExternalSecret sẽ SecretSyncedError."

kubectl get ingressclass alb >/dev/null 2>&1 \
  && echo "   ✅ IngressClass alb" \
  || echo "   ⚠️  KHÔNG có IngressClass 'alb' → Ingress nằm im, không ai tạo ALB."

# ── SSM: 13 param × 2 env ──────────────────────────────────────────────────────────────
# Day 6 thêm 2 param so với Day 4: MONGODB_ROOT_PASSWORD và RABBITMQ_ERLANG_COOKIE
# (eks-secret.sh trước đây tự chế ra chúng bằng sed/openssl — ESO không chạy script được).
# 3 param optional cố tình KHÔNG tạo: SSM từ chối giá trị rỗng, và chart bơm sẵn key rỗng.
echo
echo "── SSM param (chỉ in TÊN, không bao giờ in giá trị)"
REQUIRED_SSM=(JWT_SECRET POSTGRES_USERNAME POSTGRES_PASSWORD MONGODB_CHAT_URI
              MONGODB_ROOT_PASSWORD RABBITMQ_PASS RABBITMQ_ERLANG_COOKIE
              CLOUDINARY_CLOUD_NAME CLOUDINARY_API_KEY CLOUDINARY_API_SECRET)
for env in staging prod; do
  names="$(aws ssm get-parameters-by-path --path "/badminton/$env/" --recursive \
            --query 'Parameters[].Name' --output text 2>/dev/null | tr '\t' '\n' | sed 's|.*/||')"
  if [ -z "$names" ]; then
    echo "   ❌ /badminton/$env/ RỖNG hoặc không đọc được (kiểm: aws sts get-caller-identity)"
    continue
  fi
  miss=()
  for k in "${REQUIRED_SSM[@]}"; do
    grep -qx "$k" <<< "$names" || miss+=("$k")
  done
  if [ ${#miss[@]} -eq 0 ]; then
    echo "   ✅ /badminton/$env/ đủ ${#REQUIRED_SSM[@]} param bắt buộc"
  else
    echo "   ❌ /badminton/$env/ THIẾU: ${miss[*]}"
    echo "      → docs/MANUAL-SETUP.md §3. MONGODB_ROOT_PASSWORD phải TRÙNG password nhúng"
    echo "        trong MONGODB_CHAT_URI của cùng env, không thì Mongo auth fail lúc boot."
  fi
done

# ── Cài ArgoCD ─────────────────────────────────────────────────────────────────────────
echo
echo "── ArgoCD"
run helm repo add argo https://argoproj.github.io/argo-helm
run helm repo update argo
run helm upgrade --install argocd argo/argo-cd -n "$NS" --create-namespace \
    --version "$CHART_VERSION" --wait --timeout 10m || exit 1

# ── Bấm nút ────────────────────────────────────────────────────────────────────────────
# Đây là lệnh apply BẰNG TAY duy nhất của cả mô hình. Sau nó, root đọc apps/ và dựng
# 2 app infra (wave 1) → 2 app platform (wave 2) → ApplicationSet 18 app service (wave 3).
echo
echo "── Bấm nút app-of-apps"
# 🔴 --server-side là BẮT BUỘC (đo thật ở Day 6). Client-side apply nhét annotation
# `kubectl.kubernetes.io/last-applied-configuration` vào object; annotation đó không có trong
# Git, mà root tự quản lý chính nó ⇒ ArgoCD thấy desired ≠ live ⇒ badmintonhub-root đứng
# OutOfSync VĨNH VIỄN dù 22 app con đều xanh. Server-side apply ghi vào metadata.managedFields
# thay vì annotation nên không lệch.
run kubectl apply --server-side -f apps/root.yaml || exit 1

echo
[ "$DRY_RUN" = "1" ] && { echo "DRY_RUN xong."; exit 0; }

echo "✅ Đã cài. Theo dõi:"
echo "     kubectl get applications -n $NS -w"
echo "     kubectl get externalsecret -A"
echo
echo "   UI (không expose ra ngoài — cụm ephemeral, đừng tạo thêm ALB cho ArgoCD):"
echo "     kubectl -n $NS port-forward svc/argocd-server 8080:443"
echo "     user: admin"
echo "     pass: kubectl -n $NS get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo
echo "   ⏱ Wave 1 (5 datastore × 2 env, PVC bind EBS thật) là bước chậm nhất, ~3-5'."
echo "     Trong lúc đó 18 app service CHƯA được sinh ra — đó là đúng thiết kế, không phải treo."
