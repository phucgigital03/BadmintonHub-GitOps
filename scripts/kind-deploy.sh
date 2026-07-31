#!/usr/bin/env bash
# Deploy lên kind TUẦN TỰ NGHIÊM NGẶT — mỗi service phải Ready rồi mới tới service sau.
#
# Vì sao không song song, và vì sao không chỉ "chia 3 lô":
# Node kind trên máy dev có 8 CPU. Một JVM Spring lúc boot ăn gần trọn 1-2 CPU trong ~2 phút.
# Đo thật khi thả 4 service cùng lúc: CPU node **954-1298%** (trần là 800%) → mọi JVM chậm lại,
# không cái nào mở nổi cổng trong ngân sách startup probe → K8s giết pod đang boot HỢP LỆ,
# restart lại càng làm cụm nặng hơn. Triệu chứng là `connection refused` ở startup probe
# (KHÔNG phải `context deadline exceeded` của liveness — hai lỗi khác nhau, đừng đọc nhầm).
# RAM không phải nút thắt: lúc đó mới dùng 2.2/5.8 GB.
#
# Boot xong thì Spring gần như không ăn CPU, nên tuần tự là cách duy nhất hội tụ được.
set -uo pipefail
cd "$(dirname "$0")/.."

NS=dev
TIMEOUT="${TIMEOUT:-900s}"
ORDER=(eureka-server api-gateway user-service court-service booking-service
       payment-service escrow-service chat-service frontend)

echo "==> Lô 1: datastore (data-dev)"
helm dependency build infra/ >/dev/null
helm upgrade --install infra infra/ -n data-dev -f infra/values/infra-dev.yaml --wait --timeout "$TIMEOUT" || exit 1

echo "==> Lô 2: platform (ConfigMap app-config)"
helm upgrade --install platform charts/platform -n $NS -f infra/values/platform-dev.yaml || exit 1

echo "==> Lô 3: 9 service, từng cái một"
failed=()
for s in "${ORDER[@]}"; do
  printf '%s  --> %-16s ' "$(date '+%H:%M:%S')" "$s"
  helm upgrade --install "$s" charts/service -n $NS -f "values/$s-dev.yaml" >/dev/null 2>&1 || {
    echo "❌ helm fail"; failed+=("$s"); continue; }
  # KHÔNG pipe qua tail: exit code của pipeline là của tail, nuốt mất lỗi timeout và
  # vòng lặp sẽ đi tiếp trong khi service trước còn chưa lên.
  if kubectl -n $NS rollout status "deploy/$s" --timeout="$TIMEOUT" >/dev/null 2>&1; then
    echo "✅ Ready"
  else
    echo "❌ KHÔNG Ready trong $TIMEOUT"; failed+=("$s")
    kubectl -n $NS describe pod -l app="$s" 2>/dev/null | grep -E 'Unhealthy|Killing|OOM' | tail -2
  fi
done

echo
kubectl -n $NS get pods
if [ ${#failed[@]} -gt 0 ]; then
  echo "❌ Không lên được: ${failed[*]}"
  exit 1
fi
echo "✅ 9/9 Ready. e2e:  kubectl -n $NS port-forward svc/frontend 8081:80  →  http://localhost:8081"
