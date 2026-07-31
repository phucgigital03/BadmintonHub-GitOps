#!/usr/bin/env bash
# Các bẫy P0 — làm trên kind vì MIỄN PHÍ, đừng để lộ ra trên EKS.
# Không set -e: chạy hết mọi check rồi mới tổng kết, không dừng ở cái fail đầu tiên.
NS=dev; DNS=data-dev; pass=0; fail=0; skip=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
sk(){ echo "  ⏭️  $1"; skip=$((skip+1)); }
have(){ kubectl -n $NS get deploy "$1" >/dev/null 2>&1; }

echo "── A2 · Redis KHÔNG đòi auth ──────────────────────────────────────────"
# auth bật = NOAUTH; và vì gateway áp RequestRateLimiter cho MỌI route nên đó là
# toàn bộ request 500, không phải mất một tính năng.
r=$(kubectl -n $DNS exec statefulset/redis-master -- redis-cli ping 2>&1 | tr -d '\r')
[ "$r" = PONG ] && ok "redis-cli ping = PONG" || no "redis-cli ping = '$r'"

echo "── PostgreSQL · initdbScripts tạo đủ 5 DB ─────────────────────────────"
n=$(kubectl -n $DNS exec statefulset/postgresql -- sh -c \
      'PGPASSWORD=$(cat $POSTGRES_PASSWORD_FILE) psql -U postgres -tAc "SELECT count(*) FROM pg_database WHERE datname IN ('"'"'user_db'"'"','"'"'court_db'"'"','"'"'booking_db'"'"','"'"'payment_db'"'"','"'"'escrow_db'"'"')"' 2>/dev/null | tr -d ' \r')
[ "$n" = 5 ] && ok "có đủ 5 database" || no "chỉ có ${n:-0}/5 database"

echo "── A7 · Kafka auto-create topic ───────────────────────────────────────"
# code publish/consume ~17 topic theo tên ở runtime, không có bean NewTopic nào.
# Kiểm ở CONFIG THẬT trên broker chứ không phải YAML đã render — chart 32.x đổi key
# (bỏ autoCreateTopicsEnable) và Helm bỏ qua key sai trong im lặng.
c=$(kubectl -n $DNS exec statefulset/kafka-controller -c kafka -- \
      grep -h '^auto.create.topics.enable' /opt/bitnami/kafka/config/server.properties 2>/dev/null | tr -d ' \r')
[ "$c" = "auto.create.topics.enable=true" ] && ok "$c" || no "broker không bật auto-create ('$c')"
m=$(kubectl -n $DNS exec statefulset/kafka-controller -c kafka -- \
      grep -h '^listener.security.protocol.map' /opt/bitnami/kafka/config/server.properties 2>/dev/null)
case "$m" in *CLIENT:PLAINTEXT*) ok "listener CLIENT = PLAINTEXT (SASL đã tắt)";; *) no "listener chưa PLAINTEXT: $m";; esac

echo "── RabbitMQ · STOMP 61613 thông từ POD KHÁC ───────────────────────────"
# 5 chỗ phải đúng: plugin · containerPort · service port · username · NetworkPolicy.
# Cái thứ 5 mới là cái ẩn: NetworkPolicy mặc định của chart chỉ liệt kê 4369/5672/
# 5671/25672/15672 → 61613 bị chặn, và chặn bằng TIMEOUT chứ không phải refused.
kubectl -n $DNS exec statefulset/rabbitmq -c rabbitmq -- rabbitmq-plugins list -e 2>/dev/null \
  | grep -q rabbitmq_stomp && ok "plugin rabbitmq_stomp đã bật" || no "plugin rabbitmq_stomp chưa bật"
kubectl -n $DNS get networkpolicy rabbitmq -o jsonpath='{range .spec.ingress[*].ports[*]}{.port} {end}' 2>/dev/null \
  | grep -q 61613 && ok "NetworkPolicy cho phép 61613" || no "NetworkPolicy KHÔNG có 61613 → sẽ timeout"
if have chat-service; then
  kubectl -n $NS exec deploy/chat-service -- bash -c \
    "timeout 8 bash -c 'exec 3<>/dev/tcp/rabbitmq.$DNS.svc.cluster.local/61613'" >/dev/null 2>&1 \
    && ok "chat-service kết nối được rabbitmq:61613" || no "chat-service KHÔNG tới được 61613"
  kubectl -n $NS logs deploy/chat-service --tail=500 2>/dev/null | grep -q 'available=true' \
    && ok "BrokerAvailabilityEvent[available=true]" || no "relay chưa connected"
else sk "chat-service chưa deploy — bỏ qua 2 check relay"; fi

echo "── A6 · MONGODB_CHAT_URI có ?authSource=admin ─────────────────────────"
# root user nằm ở db admin; thiếu authSource là chat-service fail auth ngay lúc boot.
if have chat-service; then
  u=$(kubectl -n $NS exec deploy/chat-service -- sh -c 'echo $MONGODB_CHAT_URI' 2>/dev/null)
  case "$u" in *"authSource=admin"*) ok "URI có authSource=admin";; *) no "URI thiếu authSource";; esac
  [ "$(kubectl -n $NS get pod -l app=chat-service -o jsonpath='{.items[0].status.containerStatuses[0].ready}')" = true ] \
    && ok "chat-service Ready ⇒ auth Mongo thành công" || no "chat-service chưa Ready"
else sk "chat-service chưa deploy"; fi

echo "── B1 · Redis chết thì pod KHÔNG restart ──────────────────────────────"
# Bằng chứng cho việc tách liveness (/actuator/info) khỏi readiness (/actuator/health).
# ⚠️ Đo bằng restartCount + ready flag, KHÔNG đo bằng mã HTTP: khi Redis chết thì
# composite /actuator/health TREO (health indicator của Redis block tới hết timeout
# của chính nó) và làm bão hoà thread pool, nên mọi phép đo qua `exec` đều không
# trả lời. restartCount và ready là hai dữ kiện ở tầng K8s, luôn đọc được.
if have user-service; then
  b=$(kubectl -n $NS get pod -l app=user-service -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
  kubectl -n $DNS scale statefulset/redis-master --replicas=0 >/dev/null
  kubectl -n $DNS wait --for=delete pod/redis-master-0 --timeout=120s >/dev/null 2>&1
  sleep 90   # > livenessFailureThreshold(6) × periodSeconds(10) = 60s
  a=$(kubectl -n $NS get pod -l app=user-service -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
  rd=$(kubectl -n $NS get pod -l app=user-service -o jsonpath='{.items[0].status.containerStatuses[0].ready}')
  rs=$(kubectl -n $NS get pod -l app=user-service -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}')
  echo "     restarts: $b → $a · ready=$rd · lastTerminated=${rs:-none}"
  [ "$a" = "$b" ] && ok "liveness giữ pod sống (không restart)" \
                  || no "pod bị restart ($b → $a, reason=${rs:-?})"
  [ "$rd" = false ] && ok "readiness fail ⇒ pod rời Endpoints (đúng thiết kế)" \
                    || no "readiness vẫn true dù Redis chết"
  kubectl -n $DNS scale statefulset/redis-master --replicas=1 >/dev/null
else sk "user-service chưa deploy"; fi

echo "── Bổ sung · user-service CÓ nhận KAFKA_BOOTSTRAP_SERVERS ─────────────"
if have user-service; then
  k=$(kubectl -n $NS exec deploy/user-service -- sh -c 'echo $KAFKA_BOOTSTRAP_SERVERS' 2>/dev/null)
  case "$k" in *kafka.$DNS*) ok "KAFKA_BOOTSTRAP_SERVERS=$k";; *) no "sai/thiếu: '$k'";; esac
else sk "user-service chưa deploy"; fi

echo "── Bổ sung · heap không chiếm hết limit (chống OOMKilled) ─────────────"
# Image bake MaxRAMPercentage=75 → ở limit 448Mi chỉ còn 112Mi cho non-heap, Spring
# Boot cần ~150-200Mi ⇒ OOMKilled. values dev hạ xuống 55%.
if have user-service; then
  # Retry: ngay sau check B1 thì thread pool còn đang tắc, lệnh java hay không trả lời.
  for i in 1 2 3 4 5; do
    h=$(kubectl -n $NS exec deploy/user-service -- bash -c \
          'java -XX:+PrintFlagsFinal -version 2>/dev/null | awk "/MaxHeapSize/ {print int(\$4/1024/1024)}"' 2>/dev/null | tr -d '\r')
    [ -n "$h" ] && break; sleep 10
  done
  lim=$(kubectl -n $NS get deploy user-service -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}')
  echo "     MaxHeapSize=${h}MB · limit=$lim"
  [ "${h:-999}" -le 280 ] && ok "heap chừa đủ chỗ cho non-heap" || no "heap ${h}MB quá sát limit $lim"
else sk "user-service chưa deploy"; fi

echo
echo "════ $pass pass · $fail fail · $skip skip ════"
[ $fail -eq 0 ]
