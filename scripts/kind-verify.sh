#!/usr/bin/env bash
# 4 bẫy P0 + 2 check bổ sung. Làm trên kind vì MIỄN PHÍ — đừng để lộ ra trên EKS.
# Không set -e: muốn chạy hết mọi check rồi mới tổng kết, không dừng ở cái fail đầu tiên.
NS=dev; DNS=data-dev; pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }

echo "── A2 · Redis KHÔNG đòi auth ──────────────────────────────────────────"
# auth bật = NOAUTH; và vì gateway áp RequestRateLimiter cho MỌI route nên đó là
# toàn bộ request 500, không phải mất một tính năng.
r=$(kubectl -n $DNS exec statefulset/redis-master -- redis-cli ping 2>&1 | tr -d '\r')
[ "$r" = PONG ] && ok "redis-cli ping = PONG" || no "redis-cli ping = '$r'"

echo "── A6 · MONGODB_CHAT_URI có ?authSource=admin ─────────────────────────"
# root user nằm ở db admin; thiếu authSource là chat-service fail auth ngay lúc boot.
u=$(kubectl -n $NS exec deploy/chat-service -- sh -c 'echo $MONGODB_CHAT_URI' 2>/dev/null)
case "$u" in *"authSource=admin"*) ok "URI có authSource=admin";; *) no "URI thiếu authSource";; esac

echo "── A7 · Kafka tự tạo topic ────────────────────────────────────────────"
# code publish/consume ~17 topic theo tên ở runtime, không có bean NewTopic nào.
c=$(kubectl -n $DNS exec statefulset/kafka-controller -- \
      kafka-configs.sh --bootstrap-server localhost:9092 --entity-type brokers --entity-default --describe 2>/dev/null)
t=$(kubectl -n $DNS exec statefulset/kafka-controller -- \
      kafka-topics.sh --list --bootstrap-server localhost:9092 2>/dev/null | grep -c .)
kubectl -n $DNS exec statefulset/kafka-controller -- \
  kafka-topics.sh --create --if-not-exists --topic __autocreate_probe \
  --bootstrap-server localhost:9092 >/dev/null 2>&1
# Bằng chứng trực tiếp: consume một topic CHƯA tồn tại; auto-create bật thì nó được sinh ra.
kubectl -n $DNS exec statefulset/kafka-controller -- timeout 20 \
  kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic booking.slot.changed --from-beginning --timeout-ms 8000 >/dev/null 2>&1
kubectl -n $DNS exec statefulset/kafka-controller -- \
  kafka-topics.sh --list --bootstrap-server localhost:9092 2>/dev/null \
  | grep -q 'booking.slot.changed' \
  && ok "topic booking.slot.changed tự sinh khi được truy cập" \
  || no "topic KHÔNG tự sinh — kiểm controller.overrideConfiguration"

echo "── B1 · Probe tách đúng: Redis chết thì pod KHÔNG restart ─────────────"
# Đây là bằng chứng cho việc KHÔNG dùng /actuator/health composite làm liveness.
before=$(kubectl -n $NS get pod -l app=user-service -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
kubectl -n $DNS scale statefulset/redis-master --replicas=0 >/dev/null
sleep 75    # > livenessFailureThreshold(6) × periodSeconds(10) = 60s
h=$(kubectl -n $NS exec deploy/user-service -- sh -c \
      'wget -qO- -S http://localhost:3001/actuator/health 2>&1 | head -1' 2>/dev/null | grep -o '[0-9]\{3\}')
l=$(kubectl -n $NS exec deploy/user-service -- sh -c \
      'wget -qO- -S http://localhost:3001/actuator/health/liveness 2>&1 | head -1' 2>/dev/null | grep -o '[0-9]\{3\}')
after=$(kubectl -n $NS get pod -l app=user-service -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
echo "     /actuator/health=$h  /actuator/health/liveness=$l  restarts: $before → $after"
[ "$after" = "$before" ] && ok "pod KHÔNG restart dù Redis chết" || no "pod BỊ restart ($before → $after)"
[ "$l" = 200 ] && ok "liveness vẫn 200 khi Redis chết" || no "liveness = $l"
kubectl -n $DNS scale statefulset/redis-master --replicas=1 >/dev/null

echo "── Bổ sung 1 · user-service CÓ nhận KAFKA_BOOTSTRAP_SERVERS ───────────"
k=$(kubectl -n $NS exec deploy/user-service -- sh -c 'echo $KAFKA_BOOTSTRAP_SERVERS' 2>/dev/null)
case "$k" in *kafka.$DNS*) ok "KAFKA_BOOTSTRAP_SERVERS=$k";; *) no "sai/thiếu: '$k'";; esac

echo "── Bổ sung 2 · Eureka đã nhận đủ 8 client ─────────────────────────────"
n=$(kubectl -n $NS exec deploy/eureka-server -- sh -c \
      'wget -qO- http://localhost:8761/eureka/apps' 2>/dev/null | grep -c '<application>')
[ "${n:-0}" -ge 8 ] && ok "Eureka có $n application" || no "Eureka chỉ có ${n:-0}/8 application"

echo
echo "════ $pass pass · $fail fail ════"
[ $fail -eq 0 ]
