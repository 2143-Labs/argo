{{/*
Database env for every Odoo process. The image entrypoint (odoo/docker 18.0
entrypoint.sh) turns HOST/PORT/USER/PASSWORD into --db_host/--db_port/--db_user/
--db_password and waits for Postgres (wait-for-psql.py). CNPG renders Secret
odoo-db-app (username, password) for the bootstrap owner.
*/}}
{{- define "odoo.dbEnv" -}}
- name: HOST
  value: odoo-db-rw
- name: PORT
  value: "5432"
- name: USER
  valueFrom:
    secretKeyRef:
      name: odoo-db-app
      key: username
- name: PASSWORD
  valueFrom:
    secretKeyRef:
      name: odoo-db-app
      key: password
{{- end }}

{{/*
The three rules of one Odoo host. Argument: dict "bouncer" (the CrowdSec
middleware gating the public rules: "crowdsec-bouncer", which IP-bans, for the
back office, or "crowdsec-bouncer-appsec-only", which never IP-bans a client,
for the booking host; scripts/validations/booking-never-ban.sh requires the
latter on book.*) and "ns" (the namespace holding the Service).
*/}}
{{- define "odoo.routeRules" -}}
rules:
  # Rule 1: LAN and tailnet only.
  - matches:
      - path: { type: PathPrefix, value: /web/database }
      - path: { type: PathPrefix, value: /xmlrpc }
      - path: { type: PathPrefix, value: /jsonrpc }
    filters:
      - type: ExtensionRef
        extensionRef:
          group: traefik.io
          kind: Middleware
          name: lan-only
    backendRefs:
      - name: odoo
        namespace: {{ required "namespace is required" .ns }}
        port: 80
  # Rule 2: public, arbitrary bodies.
  - matches:
      - path: { type: PathPrefix, value: /web/dataset }
      - path: { type: PathPrefix, value: /web/action }
      - path: { type: PathPrefix, value: /web/binary }
      - path: { type: PathPrefix, value: /mail }
      - path: { type: PathPrefix, value: /discuss }
      - path: { type: PathPrefix, value: /im_livechat }
      - path: { type: PathPrefix, value: /html_editor }
      - path: { type: PathPrefix, value: /web_editor }
      - path: { type: PathPrefix, value: /websocket }
    filters:
      - type: ExtensionRef
        extensionRef:
          group: traefik.io
          kind: Middleware
          name: public-rate-limit
      - type: ExtensionRef
        extensionRef:
          group: traefik.io
          kind: Middleware
          name: public-inflight-limit
      - type: ExtensionRef
        extensionRef:
          group: traefik.io
          kind: Middleware
          name: {{ .bouncer }}
    backendRefs:
      - name: odoo
        namespace: {{ .ns }}
        port: 80
  # Rule 3: public, everything else.
  - matches:
      - path: { type: PathPrefix, value: / }
    filters:
      - type: ExtensionRef
        extensionRef:
          group: traefik.io
          kind: Middleware
          name: public-rate-limit
      - type: ExtensionRef
        extensionRef:
          group: traefik.io
          kind: Middleware
          name: public-inflight-limit
      - type: ExtensionRef
        extensionRef:
          group: traefik.io
          kind: Middleware
          name: {{ .bouncer }}
    backendRefs:
      - name: odoo
        namespace: {{ .ns }}
        port: 80
{{- end }}

{{/* Changes only with the image: odoo-init runs `-u all` when it does. */}}
{{- define "odoo.imageHash" -}}
{{ .Values.image | sha256sum | trunc 16 }}
{{- end }}

{{/*
Changes with anything odoo-init applies: image, module list, the init scripts,
host and the oidc flag. odoo-init does nothing when it matches the marker on the
filestore (files/init.sh).
*/}}
{{- define "odoo.initHash" -}}
{{ list .Values.image (join "," .Values.modules) (.Files.Get "files/init.sh") (.Files.Get "files/company.py") (.Files.Get "files/chart.py") (.Files.Get "files/setup.py") .Values.host (toString .Values.oidc) | join "|" | sha256sum | trunc 16 }}
{{- end }}

{{/*
Odoo pod placement. The image is amd64-only. closet has ~99% of its CPU
requested; arch looks empty by requests but runs at 100% CPU and ~146% memory in
actual use (kubectl top node, 2026-11-08). That leaves big and nas (office is
tainted, pite is arm64). Prefer big: the large image stays cached there.
*/}}
{{- define "odoo.affinity" -}}
nodeAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
      - matchExpressions:
          - key: kubernetes.io/arch
            operator: In
            values: [amd64]
          - key: kubernetes.io/hostname
            operator: NotIn
            values: [closet, arch]
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      preference:
        matchExpressions:
          - key: kubernetes.io/hostname
            operator: In
            values: [big]
{{- end }}
