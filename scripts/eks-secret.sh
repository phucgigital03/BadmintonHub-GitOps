#!/usr/bin/env bash
# Nạp 2 Secret cho một env trên EKS, LẤY GIÁ TRỊ TỪ SSM Parameter Store:
#   ns <env>        → app-secrets       (envFrom.secret của charts/service)
#   ns data-<env>   → datastore-secrets (existingSecret của Postgres/Mongo/RabbitMQ)
#
# ⚠️ ĐÂY LÀ CẦU TẠM CỦA DAY 4, KHÔNG PHẢI THIẾT KẾ CUỐI.
# Day 6 thay hẳn bằng External Secrets Operator + ClusterSecretStore đọc chính những param
# này — lúc đó pod tự có Secret sau mỗi rebuild mà không ai phải chạy script nào. Vì tên
# target Secret giữ nguyên (`app-secrets`, `datastore-secrets`) nên Day 6 KHÔNG phải sửa một
# dòng values nào.
#
# Vì sao vẫn đọc từ SSM chứ không từ .env local như kind:
#   1. Đó là nguồn sự thật mà Day 6 sẽ dùng → nếu SSM thiếu param, ta biết NGAY hôm nay,
#      chứ không phải lúc cài ESO.
#   2. Password ở SSM và password mà datastore dựng lên bằng phải là MỘT. Chart Bitnami trỏ
#      `existingSecret: datastore-secrets`, nên chỉ cần script này chạy TRƯỚC `helm install infra`.
#
# Dùng:  ./scripts/eks-secret.sh staging
set -uo pipefail
cd "$(dirname "$0")/.."

ENV="${1:-}"
case "$ENV" in
  staging|prod) ;;
  *) echo "Dùng: $0 <staging|prod>"; exit 2 ;;
esac

APP_NS="$ENV"
DATA_NS="data-$ENV"
SSM_PATH="/badminton/$ENV/"
REGION="${AWS_REGION:-ap-southeast-1}"

echo "==> Đọc param từ SSM $SSM_PATH (region $REGION)"
# --with-decryption: param là SecureString (mã hoá bằng KMS alias/aws/ssm). Thiếu cờ này
# giá trị trả về là ciphertext và pod sẽ boot bằng mật khẩu rác.
# --recursive: quét cả cây con nếu sau này chia nhóm param.
raw="$(aws ssm get-parameters-by-path \
        --path "$SSM_PATH" --recursive --with-decryption \
        --region "$REGION" \
        --query 'Parameters[].[Name,Value]' --output text 2>&1)" || {
  echo "❌ Không đọc được SSM. Kiểm: aws sts get-caller-identity  ·  quyền ssm:GetParametersByPath + kms:Decrypt"
  echo "$raw"; exit 1; }

[ -n "$raw" ] || { echo "❌ SSM $SSM_PATH RỖNG. Nạp 11 param trước (docs/MANUAL-SETUP.md §3)"; exit 1; }

# Nạp vào biến shell: /badminton/staging/JWT_SECRET → $JWT_SECRET
# Dùng tab làm dấu tách vì `--output text` phân cách bằng tab, còn giá trị (vd MONGODB_CHAT_URI)
# có thể chứa dấu cách/ký tự lạ.
while IFS=$'\t' read -r name value; do
  [ -n "$name" ] || continue
  key="${name##*/}"
  printf -v "$key" '%s' "$value"
done <<< "$raw"

# ---------------------------------------------------------------- guard trước khi tạo gì
missing=()
for k in JWT_SECRET POSTGRES_USERNAME POSTGRES_PASSWORD MONGODB_CHAT_URI RABBITMQ_PASS; do
  [ -n "${!k:-}" ] || missing+=("$k")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "❌ Thiếu param BẮT BUỘC ở SSM: ${missing[*]}"
  echo "   (6 param third-party CLOUDINARY_*/SENDGRID_API_KEY/GOOGLE_* được phép rỗng ở đây,"
  echo "    nhưng SPRING_PROFILES_ACTIVE=prod sẽ chặn boot payment/chat nếu thiếu CLOUDINARY_*)"
  exit 1
fi

# 🔴 Bẫy P0: root user của Bitnami MongoDB nằm ở db `admin`, không phải `chat_db`.
# Thiếu ?authSource=admin → chat-service fail auth NGAY LÚC BOOT, và log chỉ nói
# "Authentication failed" chứ không gợi ý gì về authSource.
case "$MONGODB_CHAT_URI" in
  *"authSource=admin"*) ;;
  *) echo "❌ MONGODB_CHAT_URI ở SSM thiếu ?authSource=admin — sửa param rồi chạy lại"; exit 1 ;;
esac

# Mật khẩu Mongo mà chart Bitnami dùng để KHỞI TẠO phải trùng mật khẩu nhúng trong URI mà
# chat-service dùng để KẾT NỐI. Tách ra từ chính URI để không có đường lệch.
#
# ⚠️ Regex phải neo vào dấu @ CUỐI CÙNG (`\(.*\)@[^@]*$`), không phải dấu @ đầu tiên.
# Password sinh bằng `openssl rand -base64 24` hoàn toàn có thể chứa '@' → dùng `[^@]*` thì
# password bị cắt cụt, Secret có giá trị SAI, và triệu chứng là "chat-service auth fail" —
# bạn sẽ đi soi authSource/quyền Mongo chứ không nghĩ tới cái regex này.
MONGO_ROOT_PASSWORD="$(printf '%s' "$MONGODB_CHAT_URI" | sed -n 's#^mongodb://[^:]*:\(.*\)@[^@]*$#\1#p')"
[ -n "$MONGO_ROOT_PASSWORD" ] || { echo "❌ Không tách được password từ MONGODB_CHAT_URI"; exit 1; }

# ⚠️ Prod profile bật CloudinaryProdGuard (@Profile("prod")) → payment-service và chat-service
# BẮT BUỘC có 3 biến CLOUDINARY_*. Cảnh báo chứ không chặn: có thể bạn đang cố tình test riêng
# phần khác trước khi nạp key Cloudinary.
for k in CLOUDINARY_CLOUD_NAME CLOUDINARY_API_KEY CLOUDINARY_API_SECRET; do
  [ -n "${!k:-}" ] || echo "⚠️  $k rỗng → payment-service và chat-service sẽ FAIL BOOT ở profile prod"
done

kubectl get namespace "$APP_NS"  >/dev/null 2>&1 || kubectl create namespace "$APP_NS"
kubectl get namespace "$DATA_NS" >/dev/null 2>&1 || kubectl create namespace "$DATA_NS"

# ------------------------------------------------------------------------ app-secrets
# MỌI key phải TỒN TẠI, kể cả rỗng: SENDGRID_API_KEY và CLOUDINARY_* không có default trong
# application.yml, thiếu hẳn key thì Spring không resolve được placeholder ${...} và fail
# context — lỗi lúc đó nói về "Could not resolve placeholder", không nói về Secret.
echo "==> app-secrets → ns $APP_NS"
kubectl -n "$APP_NS" create secret generic app-secrets \
  --from-literal=JWT_SECRET="$JWT_SECRET" \
  --from-literal=POSTGRES_USERNAME="$POSTGRES_USERNAME" \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=MONGODB_CHAT_URI="$MONGODB_CHAT_URI" \
  --from-literal=RABBITMQ_PASS="$RABBITMQ_PASS" \
  --from-literal=SENDGRID_API_KEY="${SENDGRID_API_KEY:-}" \
  --from-literal=CLOUDINARY_CLOUD_NAME="${CLOUDINARY_CLOUD_NAME:-}" \
  --from-literal=CLOUDINARY_API_KEY="${CLOUDINARY_API_KEY:-}" \
  --from-literal=CLOUDINARY_API_SECRET="${CLOUDINARY_API_SECRET:-}" \
  --from-literal=GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}" \
  --from-literal=GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null || exit 1

# -------------------------------------------------------------------- datastore-secrets
# 🔴 Erlang cookie: GIỮ CÁI CŨ nếu Secret đã tồn tại.
# RabbitMQ ghi cookie vào PVC lúc khởi tạo lần đầu. Chạy lại script mà sinh cookie MỚI trong
# khi PVC vẫn còn data cũ → node không nhận ra chính mình, boot fail với lỗi Erlang khó đọc.
# Chỉ sinh mới khi thật sự chưa có gì.
EXISTING_COOKIE="$(kubectl -n "$DATA_NS" get secret datastore-secrets \
  -o jsonpath='{.data.rabbitmq-erlang-cookie}' 2>/dev/null | base64 -d 2>/dev/null || true)"
if [ -n "$EXISTING_COOKIE" ]; then
  RABBITMQ_ERLANG_COOKIE="$EXISTING_COOKIE"
  echo "==> datastore-secrets → ns $DATA_NS (giữ nguyên erlang cookie đang có)"
else
  RABBITMQ_ERLANG_COOKIE="$(openssl rand -hex 16)"
  echo "==> datastore-secrets → ns $DATA_NS (sinh erlang cookie mới)"
fi

# Tên key do chart Bitnami quy định — ĐỪNG đổi:
#   postgres-password      ← postgresql.auth.secretKeys.adminPasswordKey
#   mongodb-root-password  ← quy ước của chart mongodb
#   rabbitmq-password      ← rabbitmq.auth.existingSecretPasswordKey
#   rabbitmq-erlang-cookie ← rabbitmq.auth.existingSecretErlangKey
kubectl -n "$DATA_NS" create secret generic datastore-secrets \
  --from-literal=postgres-password="$POSTGRES_PASSWORD" \
  --from-literal=mongodb-root-password="$MONGO_ROOT_PASSWORD" \
  --from-literal=rabbitmq-password="$RABBITMQ_PASS" \
  --from-literal=rabbitmq-erlang-cookie="$RABBITMQ_ERLANG_COOKIE" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null || exit 1

# ⚠️ CHỈ in TÊN KEY, không bao giờ in giá trị — transcript và ảnh chụp màn hình đều là nơi
# secret bị rò ra ngoài.
echo "✅ Xong. Key đã có (KHÔNG in giá trị):"
kubectl -n "$APP_NS"  get secret app-secrets       -o jsonpath='{.data}' | tr ',' '\n' | cut -d'"' -f2 | sed "s|^|   $APP_NS/app-secrets: |"
kubectl -n "$DATA_NS" get secret datastore-secrets -o jsonpath='{.data}' | tr ',' '\n' | cut -d'"' -f2 | sed "s|^|   $DATA_NS/datastore-secrets: |"
