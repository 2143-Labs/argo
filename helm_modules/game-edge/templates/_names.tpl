{{- /*
The HTTPRoute name of a game's main rule. Its `game-` prefix is what the CrowdSec
agent keys on (evt.Parsed.traefik_router_name startsWith 'httproute-default-game-'),
so a new game needs no change to the CrowdSec files.
*/}}
{{- define "game-edge.routeName" -}}
game-{{ required "routeName is required" .Values.routeName }}
{{- end }}
