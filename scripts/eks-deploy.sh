#!/usr/bin/env bash
# Deploy một env lên EKS: 5 datastore + ConfigMap/Ingress + 9 service.
#
# 🔴 ĐÃ BỊ THAY THẾ Ở DAY 6 — ĐỪNG CHẠY TRÊN CỤM CÓ ARGOCD.
# Đường deploy chính thức bây giờ là `kubectl apply -f apps/root.yaml` (xem
# docs/DAY6-EXPLAINED.md §2). ArgoCD với `selfHeal: true` sở hữu mọi object mà script này tạo;
# chạy song song hai đường chỉ tạo ra tranh chấp và hiểu nhầm về trạng thái thật của cụm.
#
# Giữ lại cho đúng một tình huống: ArgoCD hỏng/chưa cài mà vẫn cần dựng cụm để debug.
#
# 📌 LẦN ĐẦU THÌ ĐỪNG CHẠY SCRIPT NÀY — gõ tay theo `docs/DAY4-EXPLAINED.md` §runbook.
# Script chỉ là bản ghi lại đúng những lệnh trong runbook, dành cho lần rebuild thứ 2-3 khi
# bạn đã hiểu từng bước. Nó `echo` mọi lệnh trước khi chạy để không thành hộp đen.
#
# Dùng:  ./scripts/eks-deploy.sh staging
#        DRY_RUN=1 ./scripts/eks-deploy.sh staging     # chỉ in lệnh, không chạy
set -uo pipefail
cd "$(dirname "$0")/.."

ENV="${1:-}"
case "$ENV" in
  staging|prod) ;;
  *) echo "Dùng: $0 <staging|prod>   (dev dùng scripts/kind-deploy.sh)"; exit 2 ;;
esac

APP_NS="$ENV"
DATA_NS="data-$ENV"
TIMEOUT="${TIMEOUT:-900s}"
DRY_RUN="${DRY_RUN:-0}"

# Eureka đứng riêng và đi TRƯỚC: 7 service Java đăng ký vào nó lúc boot. Eureka chưa có thì
# chúng vẫn boot được nhưng phải chờ retry, kéo dài thời gian Ready một cách vô ích.
# frontend không phụ thuộc ai nên nằm chung lô cuối.
REST=(api-gateway user-service court-service booking-service
      payment-service escrow-service chat-service frontend)

run() {
  echo "   \$ $*"
  [ "$DRY_RUN" = "1" ] && return 0
  "$@"
}

echo "════ Deploy env=$ENV  (app ns: $APP_NS · data ns: $DATA_NS)"
[ "$DRY_RUN" = "1" ] && echo "     DRY_RUN=1 — chỉ in lệnh"

# ── Tiền đề ────────────────────────────────────────────────────────────────────────────
# Kiểm 3 thứ mà nếu thiếu thì mọi bước sau đều "chạy được" nhưng kết quả sai/treo.
echo
echo "── Tiền đề"
kubectl get ingressclass alb >/dev/null 2>&1 \
  && echo "   ✅ IngressClass alb" \
  || echo "   ⚠️  KHÔNG có IngressClass 'alb' → Ingress sẽ nằm im, không ai tạo ALB (kiểm aws-load-balancer-controller)"
kubectl get storageclass gp3 >/dev/null 2>&1 \
  && echo "   ✅ StorageClass gp3" \
  || echo "   ⚠️  KHÔNG có StorageClass 'gp3' → PVC kẹt Pending, 5 datastore không boot"
kubectl -n "$DATA_NS" get secret datastore-secrets >/dev/null 2>&1 \
  && echo "   ✅ datastore-secrets" \
  || { echo "   ❌ Chưa có datastore-secrets ở ns $DATA_NS — chạy ./scripts/eks-secret.sh $ENV TRƯỚC"; exit 1; }
kubectl -n "$APP_NS" get secret app-secrets >/dev/null 2>&1 \
  && echo "   ✅ app-secrets" \
  || { echo "   ❌ Chưa có app-secrets ở ns $APP_NS — chạy ./scripts/eks-secret.sh $ENV TRƯỚC"; exit 1; }

# ── Lô 1 · datastore ───────────────────────────────────────────────────────────────────
# --wait: pod app khởi động khi Postgres chưa sẵn sàng sẽ fail rồi restart, và RESTARTS tăng
# là thứ dễ làm ta chẩn đoán nhầm sang "thiếu tài nguyên" (bài học đắt nhất của Day 2).
# PVC phải bind EBS thật nên lô này chậm nhất, ~3-5 phút.
echo
echo "── Lô 1 · 5 datastore → $DATA_NS"
run helm dependency build infra/ || exit 1
run helm upgrade --install infra infra/ -n "$DATA_NS" --create-namespace \
    -f infra/values/infra-$ENV.yaml --wait --timeout "$TIMEOUT" || exit 1

# ── Lô 2 · platform ────────────────────────────────────────────────────────────────────
# ConfigMap app-config + Ingress. Ingress tạo ở đây → AWS bắt đầu provision ALB NGAY,
# chạy song song với lúc 9 service đang boot (~2-3 phút, vừa khớp).
echo
echo "── Lô 2 · platform (ConfigMap app-config + Ingress ALB) → $APP_NS"
run helm upgrade --install platform charts/platform -n "$APP_NS" --create-namespace \
    -f infra/values/platform-$ENV.yaml || exit 1

# ── Lô 3 · eureka ──────────────────────────────────────────────────────────────────────
echo
echo "── Lô 3 · eureka-server (chờ Ready rồi mới tới các service khác)"
run helm upgrade --install eureka-server charts/service -n "$APP_NS" \
    -f "values/eureka-server-$ENV.yaml" --wait --timeout "$TIMEOUT" || exit 1

# ── Lô 4 · 8 service còn lại, song song ────────────────────────────────────────────────
# Khác kind (tuần tự nghiêm ngặt vì máy 8GB nghẹt CPU lúc boot JVM): node EKS 2× t3.xlarge
# = 8 vCPU / 32 GB, đủ chỗ cho 8 JVM boot cùng lúc. Cài không --wait rồi chờ MỘT LẦN ở cuối.
echo
echo "── Lô 4 · 8 service còn lại (song song)"
failed=()
for s in "${REST[@]}"; do
  run helm upgrade --install "$s" charts/service -n "$APP_NS" -f "values/$s-$ENV.yaml" \
    || failed+=("$s helm")
done

if [ "$DRY_RUN" != "1" ]; then
  echo
  echo "── Chờ tất cả Deployment available (tối đa $TIMEOUT)"
  kubectl -n "$APP_NS" wait --for=condition=available deploy --all --timeout="$TIMEOUT" \
    || failed+=("rollout")
fi

# ── Tổng kết ───────────────────────────────────────────────────────────────────────────
echo
[ "$DRY_RUN" = "1" ] && { echo "DRY_RUN xong."; exit 0; }
kubectl -n "$APP_NS" get pods
echo
if [ ${#failed[@]} -gt 0 ]; then
  echo "❌ Có vấn đề: ${failed[*]}"
  echo "   Nhìn cột RESTARTS TRƯỚC khi đổ lỗi cho tài nguyên (xem .claude/rules/helm-chart.md):"
  echo "     RESTARTS tăng đều  → vòng lặp restart, đi tìm nguyên nhân (probe? OOM? thiếu env?)"
  echo "     RESTARTS = 0       → mới thật sự là thiếu tài nguyên / còn đang boot"
  echo "   kubectl -n $APP_NS describe pod -l app=<svc> | grep -E 'Unhealthy|Killing|OOM'"
  exit 1
fi

echo "✅ 9/9 Ready."
ALB="$(kubectl -n "$APP_NS" get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
if [ -n "$ALB" ]; then
  echo "   URL: http://$ALB"
  echo "   Kiểm:  curl -s -o /dev/null -w '%{http_code}\\n' http://$ALB/api/actuator/health   # mong đợi 200"
else
  echo "   ⏳ Ingress chưa có ADDRESS. Đợi thêm 1-2' rồi: kubectl -n $APP_NS get ingress"
  echo "      Quá 5' vẫn rỗng → kubectl -n $APP_NS describe ingress   (thường là thiếu tag subnet"
  echo "      kubernetes.io/role/elb=1 → 'couldn't auto-discover subnets')"
fi
