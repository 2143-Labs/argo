{{- /* The game-server container, shared by the static StatefulSet
       (gameserver.yaml) and PodTemplate rots-gameserver (podtemplate.yaml), so
       probes, resources and env cannot drift between the two modes.
       The helper starts with the list marker, so callers use plain nindent:
       include "rots-web.gameserver-container" (dict "root" . "managed" false) | nindent 8 */}}
{{- define "rots-web.gameserver-container" -}}
{{- $root := .root }}
{{- $gs := $root.Values.gameserver -}}
- name: rots-gameserver
  image: "{{ $root.Values.image.repository }}:{{ required "gameserver.tag is required" $gs.tag }}"
  # gameserver-latest / gameserver-pr-<N> are moving tags that CI overwrites.
  imagePullPolicy: Always
  # Config::load_from_main_dir writes config.yaml into the cwd.
  workingDir: /data
  securityContext:
    runAsUser: 65534
    runAsGroup: 65534
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: ["ALL"]
  env:
    - name: ROTS_BIND_IP
      value: "0.0.0.0"
    - name: ROTS_PORT
      value: "25565"
    - name: ROTS_AUTH_URL
      value: "http://rots-authserver.{{ $root.Values.namespace }}.svc"
    - name: ROTS_TICKET_AUDIENCE
      value: {{ required "publicUrl is required" $root.Values.publicUrl | quote }}
{{- if .managed }}
    # Managed mode: the provisioner adds ROTS_SERVER_SLOT, ROTS_SERVER_GENERATION,
    # ROTS_SERVER_JOIN_CODE and ROTS_PUBLIC_UDP_PORT per instance. /data is that
    # instance's Longhorn volume; ROTS_IDLE_SECS is when it destroys itself.
    - name: ROTS_STATE_DIR
      value: "/data"
    - name: ROTS_IDLE_SECS
      value: {{ $gs.idleSecs | quote }}
{{- else }}
    # Slot = StatefulSet pod index; the coordinator gates every join and
    # receives the heartbeat roster through the authserver internal API.
    - name: ROTS_SERVER_SLOT
      valueFrom:
        fieldRef:
          fieldPath: metadata.labels['apps.kubernetes.io/pod-index']
{{- end }}
    - name: ROTS_COORDINATOR_URL
      value: "http://rots-authserver.{{ $root.Values.namespace }}.svc:8001"
    - name: ROTS_COORDINATOR_TOKEN
      valueFrom:
        secretKeyRef:
          name: rots-authserver-secret
          key: COORDINATOR_TOKEN
    - name: RUST_LOG
      value: info
  ports:
    - containerPort: 25565
      protocol: UDP
      name: game-udp
    - containerPort: 25565
      protocol: TCP
      name: game-ws
    - containerPort: 25566
      protocol: TCP
      name: health
  volumeMounts:
    - name: data
      mountPath: /data
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
    limits:
      cpu: "2"
      memory: 2Gi
  # The server retries the authserver public-key fetch for up to ~120s
  # before it starts listening; give it that long before liveness applies.
  startupProbe:
    httpGet:
      path: /healthz
      port: health
    periodSeconds: 5
    failureThreshold: 36
    # timeoutSeconds 3 on every probe: readiness gates the rots-gs-N-udp
    # LoadBalancer Service, so a 1 s timeout under node contention blackholes
    # native players.
    timeoutSeconds: 3
  livenessProbe:
    httpGet:
      path: /healthz
      port: health
    periodSeconds: 10
    failureThreshold: 6
    timeoutSeconds: 3
  readinessProbe:
    httpGet:
      path: /healthz
      port: health
    periodSeconds: 5
    failureThreshold: 3
    timeoutSeconds: 3
{{- end }}
