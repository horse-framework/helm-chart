{{/* All namespaced resources share this value; empty uses helm --namespace. */}}
{{- define "horse.namespace" -}}
{{- default .Release.Namespace .Values.deployment.namespace -}}
{{- end -}}

{{- define "horse.headlessName" -}}
{{- printf "%s-headless" .Release.Name -}}
{{- end -}}

{{/* Normalize both paths before checking directory boundaries. */}}
{{- define "horse.mountPath" -}}
{{- if not (isAbs .Values.mount.path) -}}
{{- fail "mount.path must be an absolute container path" -}}
{{- end -}}
{{- clean .Values.mount.path -}}
{{- end -}}

{{- define "horse.dataPath" -}}
{{- $mount := include "horse.mountPath" . -}}
{{- $configured := .Values.server.dataPath -}}
{{- if and $configured (not (isAbs $configured)) -}}
{{- fail "server.dataPath must be empty or an absolute path within mount.path" -}}
{{- end -}}
{{- $data := clean (default (printf "%s/data" $mount) $configured) -}}
{{- $prefix := printf "%s/" (trimSuffix "/" $mount) -}}
{{- if not (or (eq $data $mount) (hasPrefix $prefix $data)) -}}
{{- fail "server.dataPath must be within mount.path; leave server.dataPath empty to use <mount.path>/data" -}}
{{- end -}}
{{- $data -}}
{{- end -}}

{{- define "horse.podDnsSuffix" -}}
{{- printf "%s.%s.svc.%s" (include "horse.headlessName" .) (include "horse.namespace" .) .Values.cluster.dnsDomain -}}
{{- end -}}

{{- define "horse.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
{{- end -}}

{{/* Service ports map to the image's fixed, named container ports. */}}
{{- define "horse.servicePorts" -}}
{{- $root := .root -}}
- name: horse-messaging
  protocol: TCP
  {{- /* Peer discovery uses the fixed messaging port on per-pod DNS names. */}}
  port: {{ ternary 2626 (int $root.Values.server.port) .perPod }}
  targetPort: horse-messaging
{{- if $root.Values.jockey.enabled }}
- name: horse-jockey
  protocol: TCP
  port: {{ $root.Values.jockey.port }}
  targetPort: horse-jockey
{{- end }}
{{- if ne (int $root.Values.server.websocketPort) 0 }}
- name: websocket
  protocol: TCP
  port: {{ $root.Values.server.websocketPort }}
  targetPort: websocket
{{- end }}
{{- end -}}
