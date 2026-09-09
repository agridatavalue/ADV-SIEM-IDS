{{/*
Image reference. Prefers an immutable digest when one is set, falling back to the
tag. A tag can be re-published under the same name; a digest cannot, so pinning by
digest is what actually guarantees the running image never changes.
*/}}
{{- define "adv.image" -}}
{{- if .digest -}}
{{ .repository }}@{{ .digest }}
{{- else -}}
{{ .repository }}:{{ .tag }}
{{- end -}}
{{- end -}}
