{{/*
Helpers for the parent infisical chart. Prefixed "infisical-pg" to avoid
colliding with the wrapped infisical-standalone subchart's global "infisical.*"
helper definitions.
*/}}

{{/*
Chart name and version as used by the chart label.
*/}}
{{- define "infisical-pg.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "infisical-pg.labels" -}}
helm.sh/chart: {{ include "infisical-pg.chart" . }}
{{ include "infisical-pg.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "infisical-pg.selectorLabels" -}}
app: infisical-postgres
app.kubernetes.io/name: infisical
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
