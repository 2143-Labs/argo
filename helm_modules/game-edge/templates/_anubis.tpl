{{- /*
The Anubis policy, identical in every environment and loaded by both instances.

Order matters. (data)/meta/default-config.yaml imports Anubis's own bot rules
(Googlebot/Bingbot/… are ALLOWed from their published address ranges,
HeadlessChrome and the AI crawlers are DENYed, well-known/robots.txt are
ALLOWed) and it is imported first, so those verdicts win; embed-image keeps the
link-preview image fetchable from the target; and game-everyone is the
catch-all, so every client that is neither explicitly allowed nor denied is
challenged. Nothing depends on a challengeable client's user agent, which is
what makes the link preview deterministic.

The Open Graph block is the link-preview payload: Discord, Slack and Telegram
fetch the HTML without running JS and cannot solve a challenge, so the challenge
page carries the card instead. `override` returns before any target fetch
(internal/ogtags/cache.go), so a preview never wakes a scaled-to-zero game.
`ttl` is mandatory whenever `enabled` is true and `og:title` is mandatory inside
`override` (both are startup-fatal otherwise), and the key is
`considerHost` — the source's `yaml:"enabled"` tag on that field is dead, json
tags are what decode.

Anubis emits only the keys given here, and `og:image` must be a raster the
platform's image proxy can fetch on its own: that fetch does proxy to the
target, so the path is ALLOWed above — exactly the one file, quoted, so the hole
is that file and nothing beside it. Games without a raster get a
title+description card instead of a broken image.
*/}}
{{- define "game-edge.policy" }}
{{- $e := .root.Values.embed | default dict }}
{{- $title := required "embed.title is required" $e.title }}
{{- $desc := required "embed.description is required" $e.description }}
{{- $host := required "host is required" .root.Values.host }}
{{- with $e.image }}
{{- if and (not (hasPrefix "/icons/" .)) (ne . "/og.png") }}
{{- fail (printf "embed.image %q must be /og.png or live under /icons/ (the policy ALLOWs exactly that one file)" .) }}
{{- end }}
{{- end }}
bots:
  - import: (data)/meta/default-config.yaml
{{- with $e.image }}
  - name: embed-image
    path_regex: ^{{ regexQuoteMeta . }}$
    action: ALLOW
{{- end }}
  - name: game-everyone
    path_regex: .*
    action: CHALLENGE
    challenge:
      algorithm: fast
      difficulty: 4
openGraph:
  enabled: true
  considerHost: true
  ttl: 24h
  override:
    "og:type": "website"
    "og:site_name": {{ $e.siteName | default $title | quote }}
    "og:title": {{ $title | quote }}
    "og:description": {{ $desc | quote }}
    "description": {{ $desc | quote }}
    "og:url": {{ $e.url | default (printf "https://%s/" $host) | quote }}
    "twitter:card": {{ $e.twitterCard | default "summary" | quote }}
{{- with $e.image }}
    "og:image": {{ printf "https://%s%s" $host . | quote }}
    "og:image:type": "image/png"
    "og:image:width": {{ $e.imageWidth | default 512 | quote }}
    "og:image:height": {{ $e.imageHeight | default 512 | quote }}
    "og:image:alt": {{ $e.imageAlt | default $title | quote }}
{{- end }}
status_codes:
  CHALLENGE: 200
  DENY: 403
{{- end }}

{{- /*
Chart-embedded Anubis for the public games.

Anubis is the bot challenge in front of a game's page and assets
(docs/public-edge.md, "Anubis in front of an app", chart-embedded variant). The
HTTPRoute's / rule points at Service anubis; Anubis proxies to the chart's
`target` (the KEDA interceptor, or the app's Service when nothing scales to
zero) and keeps the inbound Host, so the InterceptorRoutes still match and page
views still wake the scale-to-zero pods.

Every environment loads the same policy, from one ConfigMap, and both instances
load identical text: the auth cookie is bound to the issuing rule's hash and the
cookie name hashes the cookie settings, so a cookie minted by the page instance
validates on anubis-ws only if the rules and HS512_SECRET match.

No failover: Traefik's kubernetescrd provider runs without allowCrossNamespace,
so a TraefikService in `default` cannot name this namespace's Service; with this
pod down the page answers 503 (open WebSockets are unaffected).

Sync waves: Namespace and signing key -2, the policy ConfigMap -2, Anubis and
the WebSocket checker -1, the HTTPRoute 0, so a route switches only after Anubis
is ready.

Persistent JWT signing key (HS512_SECRET), generated once in-cluster, so an
Anubis restart does not make every player solve the challenge again.
CreatedOnce = never rotated; deleting the Secret makes ESO generate a new one.
(Anubis refuses a key shorter than 64 bytes.)
*/}}
{{- define "game-edge.anubis" }}
{{- $root := .root }}
{{- $ns := required "namespace is required" $root.Values.namespace }}
{{- $target := required "target is required" .target }}
{{- $rd := required "redirectDomains is required" .redirectDomains }}
{{- $ws := .wsCheck }}
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata:
  name: anubis-signing-key
  namespace: {{ $ns }}
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  length: 128
  digits: 32
  symbols: 0
  noUpper: false
  allowRepeat: true
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: anubis-signing-key
  namespace: {{ $ns }}
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  refreshPolicy: CreatedOnce
  target:
    name: anubis-signing-key
    creationPolicy: Owner
  dataFrom:
    - sourceRef:
        generatorRef:
          apiVersion: generators.external-secrets.io/v1alpha1
          kind: Password
          name: anubis-signing-key
---
# The policy: catch-all challenge plus this game's link-preview payload. Must be
# a block scalar (`|`), otherwise the value decodes to a YAML mapping and Argo's
# apply rejects the ConfigMap even though `helm template` succeeds.
apiVersion: v1
kind: ConfigMap
metadata:
  name: anubis-policy
  namespace: {{ $ns }}
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
data:
  policy.yaml: |
{{- include "game-edge.policy" . | trim | nindent 4 }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: anubis
  namespace: {{ $ns }}
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
  labels:
    app: anubis
spec:
  replicas: 1
  revisionHistoryLimit: 2
  selector:
    matchLabels:
      app: anubis
  template:
    metadata:
      labels:
        app: anubis
      annotations:
        # Rolls the pods when the policy changes (the ConfigMap is mounted, not
        # read through the API, so an edit alone would not).
        checksum/policy: {{ include "game-edge.policy" . | trim | sha256sum }}
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: workload-type
                    operator: In
                    values:
                      - general
      volumes:
        - name: policy
          configMap:
            name: anubis-policy
      containers:
        - name: anubis
          image: ghcr.io/techarohq/anubis:v1.28.2
          imagePullPolicy: IfNotPresent
          env:
            - name: BIND
              value: ":8080"
            - name: POLICY_FNAME
              value: /etc/anubis/policy.yaml
            - name: METRICS_BIND
              value: ":9090"
            - name: TARGET
              value: {{ $target | quote }}
            - name: REDIRECT_DOMAINS
              value: {{ $rd | quote }}
            - name: HS512_SECRET
              valueFrom:
                secretKeyRef:
                  name: anubis-signing-key
                  key: password
          volumeMounts:
            - name: policy
              mountPath: /etc/anubis
              readOnly: true
          ports:
            - name: http
              containerPort: 8080
            - name: metrics
              containerPort: 9090
          readinessProbe:
            httpGet:
              path: /healthz
              port: 9090
            initialDelaySeconds: 1
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: 9090
            initialDelaySeconds: 10
            periodSeconds: 20
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 500m
              memory: 128Mi
          securityContext:
            runAsUser: 1000
            runAsGroup: 1000
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
---
apiVersion: v1
kind: Service
metadata:
  name: anubis
  namespace: {{ $ns }}
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
  labels:
    app: anubis
spec:
  type: ClusterIP
  selector:
    app: anubis
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
---
# The HTTPRoute lives in `default`; this lets its / rule reach Service anubis.
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-httproute-to-anubis
  namespace: {{ $ns }}
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: default
  to:
    - group: ""
      kind: Service
      name: anubis
{{- if $ws }}
---
# The WebSocket check. Traefik's forwardAuth on the game's /ws rules asks this
# instance whether the handshake carries a valid cookie; the request is only the
# check URL, never the socket, so this instance never proxies anything:
# TARGET=" " (one space) trims to empty, which disables the reverse proxy while
# still loading the same policy and secret (Anubis demands a non-empty env
# value: `flagenv` skips empty ones, so TARGET="" would leave the default).
# With no PUBLIC_URL a failed check answers 401, which is what the browser sees.
# The label must not be `app: anubis`: it is not a game page and must not be
# admitted by the KEDA NetworkPolicy.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: anubis-ws
  namespace: {{ $ns }}
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
  labels:
    app: anubis-ws
spec:
  replicas: 1
  revisionHistoryLimit: 2
  selector:
    matchLabels:
      app: anubis-ws
  template:
    metadata:
      labels:
        app: anubis-ws
      annotations:
        checksum/policy: {{ include "game-edge.policy" . | trim | sha256sum }}
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: workload-type
                    operator: In
                    values:
                      - general
      volumes:
        - name: policy
          configMap:
            name: anubis-policy
      containers:
        - name: anubis
          image: ghcr.io/techarohq/anubis:v1.28.2
          imagePullPolicy: IfNotPresent
          env:
            - name: BIND
              value: ":8080"
            - name: POLICY_FNAME
              value: /etc/anubis/policy.yaml
            - name: METRICS_BIND
              value: ":9090"
            - name: TARGET
              value: " "
            - name: HS512_SECRET
              valueFrom:
                secretKeyRef:
                  name: anubis-signing-key
                  key: password
          volumeMounts:
            - name: policy
              mountPath: /etc/anubis
              readOnly: true
          ports:
            - name: http
              containerPort: 8080
            - name: metrics
              containerPort: 9090
          readinessProbe:
            httpGet:
              path: /healthz
              port: 9090
            initialDelaySeconds: 1
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: 9090
            initialDelaySeconds: 10
            periodSeconds: 20
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 500m
              memory: 128Mi
          securityContext:
            runAsUser: 1000
            runAsGroup: 1000
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
---
apiVersion: v1
kind: Service
metadata:
  name: anubis-ws
  namespace: {{ $ns }}
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
  labels:
    app: anubis-ws
spec:
  type: ClusterIP
  selector:
    app: anubis-ws
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
---
# In `default`, not {{ $ns }}: game HTTPRoutes live in `default` and an
# ExtensionRef only resolves a Middleware in the route's own namespace. One per
# environment (the name carries the route name), shared by every /ws rule.
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: {{ include "game-edge.routeName" $root }}-anubis-ws
  namespace: default
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  forwardAuth:
    address: http://anubis-ws.{{ $ns }}.svc.cluster.local/.within.website/x/cmd/anubis/api/check
{{- end }}
{{- end }}
