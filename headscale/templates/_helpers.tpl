{{/*
Expand the name of the chart.
*/}}
{{- define "headscale.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "headscale.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "headscale.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "headscale.labels" -}}
helm.sh/chart: {{ include "headscale.chart" . }}
{{ include "headscale.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "headscale.selectorLabels" -}}
app.kubernetes.io/name: {{ include "headscale.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "headscale.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "headscale.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Validate server/client mode combinations. Each external-mode value is legal in
exactly one mode. Called from templates/validate.yaml so it always evaluates.
*/}}
{{- define "headscale.validate" -}}
{{- $c := .Values.client -}}
{{- if .Values.server.enabled -}}
  {{- if $c.loginServer -}}{{ fail "client.loginServer is only valid when server.enabled=false" }}{{- end -}}
  {{- if $c.authKey -}}{{ fail "client.authKey is only valid when server.enabled=false" }}{{- end -}}
  {{- if $c.authKeySecret.name -}}{{ fail "client.authKeySecret.name is only valid when server.enabled=false" }}{{- end -}}
  {{- if $c.caSecretName -}}{{ fail "client.caSecretName is only valid when server.enabled=false" }}{{- end -}}
{{- else -}}
  {{- if not $c.enabled -}}{{ fail "server.enabled=false requires client.enabled=true (nothing to deploy otherwise)" }}{{- end -}}
  {{- if not $c.loginServer -}}{{ fail "client.loginServer is required when server.enabled=false" }}{{- end -}}
  {{- if and (not $c.authKey) (not $c.authKeySecret.name) -}}{{ fail "a preauth key is required when server.enabled=false: set client.authKey or client.authKeySecret.name" }}{{- end -}}
  {{- if and $c.authKey $c.authKeySecret.name -}}{{ fail "set only one of client.authKey or client.authKeySecret.name" }}{{- end -}}
{{- end -}}
{{- end -}}
