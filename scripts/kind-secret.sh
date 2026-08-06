#!/usr/bin/env bash
# Sinh 2 Secret trên kind từ .env local (KHÔNG commit .env):
#   ns dev       → app-secrets       (envFrom.secret của charts/service)
#   ns data-dev  → datastore-secrets (existingSecret của Postgres/Mongo/RabbitMQ)
#
# Chỉ dùng cho dev. Day 6 thay hẳn bằng ExternalSecret đọc SSM — target.name giữ nguyên
# `app-secrets` nên values/<svc>-<env>.yaml không phải sửa dòng nào.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "❌ Chưa có .env — copy từ .env.example rồi điền"; exit 1; }
set -a; . ./.env; set +a

: "${JWT_SECRET:?JWT_SECRET không được rỗng — openssl rand -hex 64}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD không được rỗng}"
: "${RABBITMQ_PASS:?RABBITMQ_PASS không được rỗng}"

# ⚠️ Neo vào dấu @ CUỐI CÙNG. `[^@]*` sẽ cắt cụt password có chứa '@' (rất dễ gặp với
# `openssl rand -base64 24`) → Secret sai giá trị mà triệu chứng lại là "Mongo auth fail",
# dẫn bạn đi soi authSource thay vì soi regex. Cùng lỗi này đã sửa ở scripts/eks-secret.sh.
MONGO_ROOT_PASSWORD="$(printf '%s' "${MONGODB_CHAT_URI:-}" | sed -n 's#^mongodb://[^:]*:\(.*\)@[^@]*$#\1#p')"
[ -n "$MONGO_ROOT_PASSWORD" ] || { echo "❌ Không tách được password từ MONGODB_CHAT_URI"; exit 1; }
case "$MONGODB_CHAT_URI" in
  *"?authSource=admin"*) ;;
  # Bẫy P0: root user nằm ở db admin, thiếu authSource là chat-service fail auth ngay lúc boot.
  *) echo "❌ MONGODB_CHAT_URI thiếu ?authSource=admin"; exit 1 ;;
esac

# --- app-secrets: mọi key PHẢI tồn tại, kể cả rỗng ---
# SENDGRID_API_KEY và CLOUDINARY_* không có default trong application.yml / bị Guard kiểm;
# thiếu hẳn key thì Spring không resolve được placeholder và fail context.
kubectl -n dev create secret generic app-secrets \
  --from-literal=JWT_SECRET="$JWT_SECRET" \
  --from-literal=POSTGRES_USERNAME="${POSTGRES_USERNAME:-postgres}" \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=MONGODB_CHAT_URI="$MONGODB_CHAT_URI" \
  --from-literal=RABBITMQ_PASS="$RABBITMQ_PASS" \
  --from-literal=SENDGRID_API_KEY="${SENDGRID_API_KEY:-}" \
  --from-literal=CLOUDINARY_CLOUD_NAME="${CLOUDINARY_CLOUD_NAME:-}" \
  --from-literal=CLOUDINARY_API_KEY="${CLOUDINARY_API_KEY:-}" \
  --from-literal=CLOUDINARY_API_SECRET="${CLOUDINARY_API_SECRET:-}" \
  --from-literal=GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}" \
  --from-literal=GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- datastore-secrets: tên key do chart Bitnami quy định, đừng đổi ---
#   postgres-password       auth.secretKeys.adminPasswordKey
#   mongodb-root-password   quy ước của chart mongodb
#   rabbitmq-password       auth.existingSecretPasswordKey
kubectl -n data-dev create secret generic datastore-secrets \
  --from-literal=postgres-password="$POSTGRES_PASSWORD" \
  --from-literal=mongodb-root-password="$MONGO_ROOT_PASSWORD" \
  --from-literal=rabbitmq-password="$RABBITMQ_PASS" \
  --from-literal=rabbitmq-erlang-cookie="${RABBITMQ_ERLANG_COOKIE:-$(openssl rand -hex 16)}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ app-secrets (dev) + datastore-secrets (data-dev) đã sẵn sàng"
kubectl -n dev      get secret app-secrets       -o jsonpath='{.data}' | tr ',' '\n' | cut -d'"' -f2 | sed 's/^/   dev\/app-secrets key: /'
