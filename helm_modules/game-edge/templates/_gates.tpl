{{- /*
Edge gates for game HTTPRoutes. The routes live in `default` (the wildcard
listeners only admit default/argocd/kube-system), so these Middlewares live there
too: a Gateway API ExtensionRef only resolves a Middleware in the route's own
namespace.

gates     - rate/inflight limits plus crowdsec-bouncer-game (IP bans only, no
            AppSec body inspection: the rules misfire on a game's asset load and
            would ban every outside player).
urlGates  - the same, but with the AppSec-enabled crowdsec-bouncer. For a
            credential/API rule (rots /auth: OAuth callbacks, Steam tickets) that
            deserves the rules; not for the page.
wsGates   - gates plus <routeName>-anubis-ws, the forwardAuth check that every
            WebSocket handshake carries a valid Anubis cookie.
*/}}
{{- define "game-edge.filters" }}
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
{{- end }}

{{- define "game-edge.gates" }}
{{- include "game-edge.filters" (dict "bouncer" "crowdsec-bouncer-game") }}
{{- end }}

{{- define "game-edge.urlGates" }}
{{- include "game-edge.filters" (dict "bouncer" "crowdsec-bouncer") }}
{{- end }}

{{- define "game-edge.wsGates" }}
{{- include "game-edge.gates" . }}
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: {{ include "game-edge.routeName" . }}-anubis-ws
{{- end }}
