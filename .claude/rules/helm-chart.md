---
description: Chart charts/service/ dùng chung cho cả 9 service — template generic, probe liveness/readiness tách rời, resources, envFrom optional.
globs: charts/**/*.yaml, charts/**/*.tpl, values/*.yaml
---

# Helm chart `charts/service/`

**MỘT chart tái sử dụng cho CẢ 9 service, kể cả `frontend`.** Day 6 ApplicationSet matrix trỏ cả 9 vào chart này — viết chart riêng cho FE/eureka là phá luôn ApplicationSet.

## Chart phải generic thật

| Values key | Ý nghĩa | Vì sao phải template hoá |
|---|---|---|
| `image.repository` / `image.tag` | ECR URL + **git SHA** | CI bump `image.tag`; không bao giờ `latest` |
| `port` | container + Service port | 9 service 9 port khác nhau |
| `livenessPath` / `readinessPath` | **path đầy đủ**, không tự nối chuỗi | FE nginx dùng `/`, Java dùng `/actuator/health/liveness` |
| `envFrom.configMap` / `envFrom.secret` | **optional** | FE không có env Eureka/DB; bật/tắt bằng `{{- if }}` |
| `replicaCount` | mặc định **1** | demo ephemeral |
| `resources` | requests `128Mi/100m` | node `t3.xlarge` phải gánh staging + prod + obs |

Template tối thiểu: `Deployment` + `Service` (ClusterIP) + `_helpers.tpl`. Ingress **không** nằm trong chart này (xem [`ingress-alb.md`](ingress-alb.md)).

## ⚠️ Probe — KHÔNG dùng `/actuator/health` cho liveness

`/actuator/health` là **composite** gộp `db` + `redis` + `mongo` + `discoveryComposite` (Eureka). Redis hoặc Eureka nhấp nháy 3 nhịp → liveness fail → **K8s restart pod** → pod restart lại làm Redis/Eureka thêm tải → **cascade restart đúng giữa buổi demo**. Đây là anti-pattern K8s kinh điển, không phải chuyện "đủ cho demo".

Cách sửa tốn **0 dòng code, 0 dòng pom** — 1 biến env trong ConfigMap:
`MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED=true` → mở `/actuator/health/liveness` + `/readiness`.

```yaml
startupProbe:                    # cho JVM thời gian boot, tránh liveness giết sớm
  httpGet: { path: {{ .Values.livenessPath }}, port: {{ .Values.port }} }
  failureThreshold: 30
  periodSeconds: 5               # tối đa 150s để boot
livenessProbe:
  httpGet: { path: {{ .Values.livenessPath }}, port: {{ .Values.port }} }
  periodSeconds: 10
readinessProbe:
  httpGet: { path: {{ .Values.readinessPath }}, port: {{ .Values.port }} }
  periodSeconds: 10
```

**Bằng chứng đã tách đúng** (làm trên kind, miễn phí): `kubectl scale --replicas=0` Redis → `/actuator/health` trả **503** nhưng `/actuator/health/liveness` **vẫn 200** → pod **không** restart.

## Graceful shutdown (Day 7)

`preStop` sleep + `terminationGracePeriodSeconds` là **bắt buộc**, không phải nice-to-have: Eureka `lease-expiration-duration-in-seconds: 30` nghĩa là bản ghi cũ còn sống 30s sau khi pod chết → gateway route vào pod đã chết = **5xx trước mặt khán giả**.

> ⚠️ **KHÔNG tạo `PodDisruptionBudget`** ở posture 1-replica: `minAvailable: 1` trên Deployment 1 replica **chặn vĩnh viễn mọi drain/eviction tự nguyện** (không thể có 1 pod available trong khi evict pod duy nhất). Với spot thì PDB cũng không bảo vệ được gì (interruption là *involuntary*). PDB chỉ có nghĩa khi scale ≥ 2.

## Verify chart trước khi commit

```bash
helm lint charts/service -f values/user-service-staging.yaml
helm template t charts/service -f values/frontend-staging.yaml     # FE: không envFrom Eureka, probePath /
helm template t charts/service -f values/eureka-server-staging.yaml
```

Render được **cả `frontend` lẫn `eureka-server`** bằng đúng chart này = chart đã đủ generic.
Liên quan: [`values-env-map.md`](values-env-map.md) · [`gitops-workflow.md`](gitops-workflow.md)
