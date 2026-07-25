{{- /*
Notes Buddy standard labels, names, and selectors.
All templates use these helpers — never hardcode names or labels.
*/}}

{{- /* Expand the name of the chart. Keep under 63 chars (K8s DNS limit). */}}
{{- define "notes-buddy.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- /* Fully qualified app name. Used for Deployment, Service, HPA names. */}}
{{- define "notes-buddy.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- /* Chart label — used in ALL selectors and metadata labels. */}}
{{- define "notes-buddy.labels" -}}
helm.sh/chart: {{ include "notes-buddy.name" . }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "notes-buddy.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- /* Selector labels — must not change between versions. */}}
{{- define "notes-buddy.selectorLabels" -}}
app.kubernetes.io/name: {{ include "notes-buddy.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- /* Namespace — prefers .Values.namespaceOverride, falls back to .Release.Namespace. */}}
{{- define "notes-buddy.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride }}
{{- end }}

{{- /* Docker image reference. Supports global registry override. */}}
{{- define "notes-buddy.image" -}}
{{- $registry := default .Values.image.registry .Values.global.imageRegistry }}
{{- $repository := .Values.image.repository }}
{{- $tag := default .Chart.AppVersion .Values.image.tag }}
{{- printf "%s/%s:%s" $registry $repository $tag }}
{{- end }}

{{- /* ConfigMap name — respects existingConfigMap override. */}}
{{- define "notes-buddy.configmap" -}}
{{- default (printf "%s-config" (include "notes-buddy.fullname" .)) .Values.existingConfigMap }}
{{- end }}

{{- /* Secret name — respects existingSecret override. */}}
{{- define "notes-buddy.secret" -}}
{{- default (printf "%s-secret" (include "notes-buddy.fullname" .)) .Values.existingSecret }}
{{- end }}
