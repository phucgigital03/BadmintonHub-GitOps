{{/*
Tên object = nameOverride, KHÔNG phải .Release.Name.
Xem lý do ở đầu values.yaml — release name của ArgoCD là <svc>-<env>, dùng nó sẽ phá
DNS in-cluster (EUREKA_URL), nginx proxy của FE, và backend của Ingress.
*/}}
{{- define "service.name" -}}
{{- required "nameOverride là BẮT BUỘC — tên Service phải khớp đúng chữ với EUREKA_URL / nginx proxy / Ingress backend" .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "service.labels" -}}
app.kubernetes.io/name: {{ include "service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* Selector KHÔNG được chứa .Release.Name: nó immutable, mà release name đổi giữa
     helm install (Day 2) và ArgoCD (Day 6) → upgrade sẽ fail "field is immutable". */}}
{{- define "service.selectorLabels" -}}
app: {{ include "service.name" . }}
{{- end -}}
