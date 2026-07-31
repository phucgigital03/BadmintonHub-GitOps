#!/usr/bin/env bash
# Deploy lên kind theo 3 lô. Chia lô KHÔNG phải cho đẹp: máy dev 8 GB / Docker ~6 GB,
# 9 JVM boot đồng thời sẽ OOM hoặc swap tới mức probe fail rồi K8s giết pod đang boot hợp lệ.
#
#   Lô 1  datastore (data-dev)   — app không boot nổi nếu DB/Kafka chưa sẵn sàng
#   Lô 2  platform + eureka      — service registry phải Ready trước mọi client
#   Lô 3  7 service còn lại + FE — rải ra, chờ từng cái Ready
set -euo pipefail
cd "$(dirname "$0")/.."

WAIT="${WAIT:-600s}"

echo "==> Lô 1: datastore"
helm dependency build infra/ >/dev/null
helm upgrade --install infra infra/ -n data-dev -f infra/values/infra-dev.yaml --wait --timeout "$WAIT"
kubectl -n data-dev get pods

echo "==> Lô 2: platform (ConfigMap) + eureka-server"
helm upgrade --install platform charts/platform -n dev -f infra/values/platform-dev.yaml
helm upgrade --install eureka-server charts/service -n dev -f values/eureka-server-dev.yaml
kubectl -n dev rollout status deploy/eureka-server --timeout="$WAIT"

echo "==> Lô 3: các service còn lại"
# api-gateway trước để Eureka có client đầu tiên; frontend cuối vì nhẹ nhất.
for s in api-gateway user-service court-service booking-service payment-service escrow-service chat-service frontend; do
  echo "--> $s"
  helm upgrade --install "$s" charts/service -n dev -f "values/$s-dev.yaml"
  kubectl -n dev rollout status "deploy/$s" --timeout="$WAIT"
done

kubectl -n dev get pods -o wide
echo
echo "✅ Xong. Mở e2e:  kubectl -n dev port-forward svc/frontend 8081:80  →  http://localhost:8081"
