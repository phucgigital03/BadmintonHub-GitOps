#!/usr/bin/env bash
# Tạo cụm kind + nạp 9 image local vào node.
# kind KHÔNG dùng được image trong docker daemon của host: node là container riêng, có
# containerd riêng. Thiếu bước `kind load` thì pod ErrImagePull dù `docker images` thấy image.
set -euo pipefail

CLUSTER="${CLUSTER:-badminton-dev}"
TAG="${TAG:-dev}"
SERVICES=(eureka-server api-gateway user-service court-service booking-service
          payment-service escrow-service chat-service frontend)

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "==> Tạo cụm kind: $CLUSTER"
  kind create cluster --name "$CLUSTER"
else
  echo "==> Cụm $CLUSTER đã có, bỏ qua"
fi

kubectl config use-context "kind-$CLUSTER"
kubectl get ns dev      >/dev/null 2>&1 || kubectl create ns dev
kubectl get ns data-dev >/dev/null 2>&1 || kubectl create ns data-dev

missing=()
for s in "${SERVICES[@]}"; do
  docker image inspect "badmintonhub/$s:$TAG" >/dev/null 2>&1 || missing+=("$s")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "❌ Thiếu image local: ${missing[*]}"
  echo "   Build ở repo app trước:"
  echo "   cd ../badmintonHub && docker compose -f docker-compose.yml -f docker-compose.app.yml build"
  exit 1
fi

for s in "${SERVICES[@]}"; do
  echo "==> kind load badmintonhub/$s:$TAG"
  kind load docker-image "badmintonhub/$s:$TAG" --name "$CLUSTER"
done

echo "✅ Cụm sẵn sàng. Bước tiếp: scripts/kind-secret.sh"
