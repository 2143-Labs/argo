# Exposing an unauthenticated app to the internet (humans + federated machines)

Use this guide when an app has **no authentication of its own**, already works on
the LAN as `<app>.ts.2143.me`, and must now be reachable from the internet by:

- **people**, who sign in with Pocket ID (`au.2143.me`) and get a role from their
  Pocket ID group, and
- **machines in another cluster** (another SPIFFE trust domain), which sign in with
  their own SPIRE-issued identity and get a role from a Pocket ID API permission.

The app itself stays unchanged. All authentication and role checks happen in two
oauth2-proxy instances and Traefik. That gives a basic RBAC model with no app code.

It does **not** apply to non-HTTP protocols (gRPC passthrough, raw TCP/UDP, mail).
Those never pass through oauth2-proxy and need native JWT or mTLS support in the app.

> Versions this guide was verified against: oauth2-proxy **v7.15.4**, Pocket ID
> **v2.14.0**, SPIRE **v1.15.3**, Traefik **3.7.8** (k3s). Several steps depend on
> specific behaviour of those versions. Re-check the [evidence list](#evidence)
> whenever one of them is upgraded.

---

## Worked example used throughout

| Placeholder | Example | Meaning |
|---|---|---|
| `<app>` | `some-temp-app` | app name = namespace = Argo Application |
| `<app-port>` | `8080` | the app's container port |
| LAN host | `some-temp-app.ts.2143.me` | existing, LAN/tailnet only, no auth |
| Human host | `some-temp-app.john2143.com` | public, Pocket ID login |
| Machine host | `api-some-temp-app.john2143.com` | public, bearer tokens only |
| API resource URI | `https://api-some-temp-app.john2143.com` | the `aud` machine tokens are minted for |
| Remote trust domain | `trust.remote-worker-domain.xyz` | the caller's SPIFFE trust domain |
| Remote OIDC issuer | `https://spiffe.remote-worker-domain.xyz` | the caller's SPIRE OIDC discovery provider |
| Remote workload | `remote-worker` (ns `default`, sa `remote-worker`, cluster `rw-prod`) | the caller |

Keep hostnames one label deep: `api-some-temp-app.john2143.com` is covered by the
`*.john2143.com` wildcard, while `api.some-temp-app.john2143.com` would need its own
certificate.

---

## 1. How it fits together

```text
                 ┌────────── LAN / tailnet only ──────────┐
 some-temp-app.ts.2143.me ── lan-only ─────────────────────┼──► app:<app-port>
                                                           │
 some-temp-app.john2143.com (people)                       │
   ── edge middlewares ── [admin paths: forwardauth-admins] ─► oauth2-proxy-<app>     ──► app
        session cookie from Pocket ID login; groups claim = Pocket ID user groups
                                                           │
 api-<app>.john2143.com (machines)                         │
   ── edge middlewares ── forwardauth-<role> on every rule ─► oauth2-proxy-<app>-api ──► app
        Authorization: Bearer <Pocket ID access token>; groups = token `scp` (API permissions)
```

Machine login sequence for `remote-worker`:

```text
remote-worker pod
  1. FetchJWTSVID(aud = https://au.2143.me)        → its own spire-agent
     iss=https://spiffe.remote-worker-domain.xyz
     sub=spiffe://trust.remote-worker-domain.xyz/cluster/rw-prod/ns/default/sa/remote-worker
  2. POST https://au.2143.me/api/oidc/token        → Pocket ID checks iss/sub/aud + signature (JWKS)
     grant_type=client_credentials + client_assertion=<SVID> + resource=<API resource URI>
     ← access token: sub=client-<client-id>, aud=[API resource URI], scp=[granted permissions]
  3. GET/POST https://api-some-temp-app.john2143.com/...   Authorization: Bearer <access token>
     → oauth2-proxy-<app>-api verifies signature + aud, maps scp → groups, Traefik ForwardAuth checks the role
```

Our home SPIRE server is **not involved**. Pocket ID trusts the remote trust domain
directly through a federated client credential. SPIFFE federation (bundle exchange)
is only needed for workload-to-workload mTLS, which this design does not use.

## 2. The RBAC model

One naming convention for both kinds of caller, so one `allowed_groups=` string
works on either host:

| Role | People: Pocket ID **user group** | Machines: Pocket ID **API permission** on the app's API resource | Used for |
|---|---|---|---|
| `<app>-users` | members who may use the UI | — | human floor (login allowed) |
| `<app>-admins` | members who may use admin paths | grant only to trusted callers | admin/power paths on either host |
| `<app>-api` | — | every machine caller | machine floor |
| `<app>-fed-<domain-slug>` | — | one per federated trust domain, e.g. `some-temp-app-fed-remote-worker-domain-xyz` | per-domain path rules |

Use lowercase letters, digits and `-` only. Pocket ID group names allow more
characters than this, but API permission keys must be valid OAuth scope tokens,
and the shared names need to work in both places.

How each claim becomes oauth2-proxy groups (verified in source):

- People: Pocket ID puts `groups: [<group.Name>, …]` in the ID token **only when
  the `groups` scope is requested**. oauth2-proxy's `--scope` defaults to empty, so
  the human proxy must set `--scope=openid email profile groups`.
- Machines: Pocket ID v2.14.0 emits machine-token scopes both as `scope` (a string)
  and as `scp` (an array). Setting `--oidc-groups-claim=scp` makes the granted API
  permissions the session's groups.

Where roles are enforced:

- **Floor:** oauth2-proxy `--allowed-group`, applied to every request. When it fails,
  oauth2-proxy also **clears the session cookie**. Only put the "may use this host
  at all" groups here.
- **Per path:** a Traefik ForwardAuth to `…/oauth2/auth?allowed_groups=<role>`.
  It returns `202` when allowed, `403` when the user is logged in but lacks the
  role (the session survives), and `401` when there is no session. Put admin and
  per-domain rules here, never in the floor.

## 3. Pocket ID objects

Pocket ID stores everything below in its database, **not in git**. Record what
you created in the [inventory](#11-inventory-fill-in-per-app) at the bottom of this
file's copy for the app, or the configuration will drift.

Each object can be created in the admin UI or through the admin API. The API
calls take `X-API-Key: $PID_KEY`. Load the key from OpenBao into the variable in
your shell; never paste it into a file or a command line that ends up in history.

### 3a. Human client (`<app>`)

UI: **Administration → OIDC Clients → Add**

- Name `some-temp-app`; client ID: let Pocket ID generate one, or set `some-temp-app`.
- Callback URL: exactly `https://some-temp-app.john2143.com/oauth2/callback`.
- Public client: **off**. PKCE: **on**.
- Group restricted: **on**. Allowed User Groups: `some-temp-app-users`,
  `some-temp-app-admins`. Without "Group restricted", Pocket ID ignores the list
  and lets every Pocket ID user log in.

API: `POST /api/oidc/clients` with `"isGroupRestricted": true`, then
`PUT /api/oidc/clients/{id}/allowed-user-groups` with `{"userGroupIds": ["<id>", …]}`.
Create the secret with `POST /api/oidc/clients/{id}/secrets`. The response contains
the secret, so send it straight to OpenBao and never print it.

### 3b. User groups

UI: **Administration → User Groups**. Create `some-temp-app-users` and
`some-temp-app-admins`, and add members. The `name` field is what appears in tokens.
API: `POST /api/user-groups` (`{friendlyName, name}`), then `PUT /api/user-groups/{id}/users`.

### 3c. API resource and permissions (the machine host's audience)

UI: **Administration → APIs**. API equivalents:

```text
POST /api/apis                       {"name":"some-temp-app","resource":"https://api-some-temp-app.john2143.com"}
PUT  /api/apis/{apiId}/permissions   {"permissions":[
                                        {"key":"some-temp-app-api","name":"machine floor"},
                                        {"key":"some-temp-app-admins","name":"admin paths"},
                                        {"key":"some-temp-app-fed-remote-worker-domain-xyz","name":"remote-worker-domain.xyz"}]}
```

The PUT **replaces** the whole permission list, so always send all of them.

### 3d. Machine proxy's own client (`<app>-api`)

oauth2-proxy refuses to start without a client, so the machine proxy gets its own:
client ID `some-temp-app-api`, public client off, a callback URL that is never used
(`https://api-some-temp-app.john2143.com/oauth2/callback`), and Group restricted
**on** with **no** Allowed User Groups, so no person can log in through it. Grant
API permissions only to clients (§3e), never to users or groups: a person's access
token with `some-temp-app-api` in `scp` would pass the machine floor.

Keep this client separate from the human client. Otherwise a person's ID token,
whose `aud` is the human client ID, would pass the machine host's audience check.

### 3e. One client per federated caller

Create one confidential client per (trust domain, workload). Choose a readable ID,
because the app sees it as the user: `sub = client-<client-id>`.

```json
POST /api/oidc/clients
{
  "id": "fed-remote-worker-domain-xyz-remote-worker",
  "name": "remote-worker @ remote-worker-domain.xyz",
  "isPublic": false,
  "isGroupRestricted": true,
  "callbackURLs": [],
  "credentials": {
    "federatedIdentities": [{
      "issuer":   "https://spiffe.remote-worker-domain.xyz",
      "subject":  "spiffe://trust.remote-worker-domain.xyz/cluster/rw-prod/ns/default/sa/remote-worker",
      "audience": "https://au.2143.me",
      "jwks":     "https://spiffe.remote-worker-domain.xyz/keys",
      "replayProtection": false
    }]
  }
}
```

Pocket ID compares every field **exactly** (no wildcards):

| Field | Rule |
|---|---|
| `issuer` | Must equal the remote SPIRE **server's** `jwt_issuer`. If that is unset, the SVID has no `iss` and is rejected. The remote OIDC discovery provider must advertise the same string. These are two separate settings. |
| `subject` | The SPIFFE ID exactly as the remote `ClusterSPIFFEID` template renders it. If left empty, Pocket ID expects `sub == client ID`, which an SVID can never satisfy. |
| `audience` | The string the caller passes to `FetchJWTSVID`. If left empty, it defaults to Pocket ID's `APP_URL` (`https://au.2143.me`). |
| `jwks` | Must be set to `<issuer>/keys`. Pocket ID's default, `<issuer>/.well-known/jwks.json`, returns **404** from SPIRE's OIDC discovery provider. |
| `replayProtection` | **Off**, unless the remote registration entry sets `jwt_svid_include_jti`. spire-agent caches the SVID for each (SPIFFE ID, audience) pair for about half its TTL, so the caller presents the same assertion twice. With replay protection on, the second exchange fails. |

Then grant it permissions **as itself** (rows with `subject_type=client`):

```text
PUT /api/apis/{apiId}/clients/fed-remote-worker-domain-xyz-remote-worker
{"clientAccess": true,
 "clientPermissionIds": ["<id of some-temp-app-api>", "<id of some-temp-app-fed-remote-worker-domain-xyz>"]}
```

Leave out `some-temp-app-admins` unless the caller really needs admin paths.

## 4. Argo manifests

Layout, all in the app's own namespace (`CreateNamespace=true` in the Application):

```text
apps/some-temp-app.yaml                       destination.namespace: some-temp-app, CreateNamespace=true
workloads/some-temp-app/
  app.yaml                                    the unauthenticated app (Deployment + Service)
  oauth2-proxy.yaml                           human proxy (Deployment + Service)
  oauth2-proxy-api.yaml                       machine proxy (Deployment + Service)
  middlewares.yaml                            forwardauth-* + per-namespace copies of edge/lan middlewares
  routes.yaml                                 three HTTPRoutes
workloads/network-policies/some-temp-app.yaml NetworkPolicies (see §6)
workloads/secrets/…                           two ExternalSecrets (see docs/adding-a-secret.md)
workloads/gateway/gateway.yaml                three listeners (see §5)
workloads/headscale/configmap.yaml            tailnet DNS for the .ts name (adding-a-workload.md §3c)
```

Use a dedicated namespace. `default` is deliberately left without NetworkPolicies
(see `workloads/network-policies/00-pattern.yaml`), so any pod there could call
the unauthenticated app directly and bypass both proxies.

### 4a. Proxies

Copy `workloads/oauth2-proxy-temporal/deployment.yaml` for the security context,
probes, resources and anti-affinity. The arguments are what differ.

**Human proxy (`oauth2-proxy-some-temp-app`)**

```yaml
args:
  - "--provider=oidc"
  - "--oidc-issuer-url=https://au.2143.me"
  - "--client-id=$(OAUTH2_PROXY_CLIENT_ID)"
  - "--client-secret=$(OAUTH2_PROXY_CLIENT_SECRET)"
  - "--cookie-secret=$(OAUTH2_PROXY_COOKIE_SECRET)"
  - "--redirect-url=https://some-temp-app.john2143.com/oauth2/callback"
  - "--upstream=http://some-temp-app:8080"
  - "--scope=openid email profile groups"          # without 'groups' the token has no groups claim
  - "--allowed-group=some-temp-app-users"          # floor; repeat for every group allowed to log in
  - "--allowed-group=some-temp-app-admins"
  - "--email-domain=*"
  - "--reverse-proxy=true"
  - "--http-address=0.0.0.0:4180"
  - "--cookie-domain=some-temp-app.john2143.com"
  - "--cookie-secure=true"
  - "--cookie-httponly=true"
  - "--cookie-samesite=lax"
  - "--cookie-expire=8h"
  - "--cookie-refresh=1h"
  - "--force-code-challenge-method=S256"
  - "--set-xauthrequest=true"
  - "--pass-authorization-header=false"            # never forward a client-supplied Authorization header
  - "--auth-logging=true"
  - "--request-logging=true"
```

**Machine proxy (`oauth2-proxy-some-temp-app-api`)**

```yaml
args:
  - "--provider=oidc"
  - "--oidc-issuer-url=https://au.2143.me"
  - "--client-id=$(OAUTH2_PROXY_CLIENT_ID)"        # some-temp-app-api, nobody can log in with it
  - "--client-secret=$(OAUTH2_PROXY_CLIENT_SECRET)"
  - "--cookie-secret=$(OAUTH2_PROXY_COOKIE_SECRET)"
  - "--upstream=http://some-temp-app:8080"
  - "--skip-jwt-bearer-tokens=true"                # accept Authorization: Bearer <JWT>
  - "--bearer-token-login-fallback=false"          # invalid token → 403, never a login redirect
  - "--api-route=^/"                               # no token at all → 401, never a login redirect
  - "--oidc-extra-audience=https://api-some-temp-app.john2143.com"   # the ONLY extra audience
  - "--oidc-groups-claim=scp"                      # granted API permissions become groups
  - "--allowed-group=some-temp-app-api"            # machine floor
  - "--email-domain=*"                             # machine tokens have no email; oauth2-proxy uses sub
  - "--reverse-proxy=true"
  - "--http-address=0.0.0.0:4180"
  - "--pass-authorization-header=false"            # the app never sees the bearer token
  - "--pass-access-token=false"
  - "--auth-logging=true"
  - "--request-logging=true"
```

`--oidc-extra-audience` must only ever contain this app's API resource URI. Never
add a client ID, and never reuse a URI across apps: the audience is what stops a
token minted for one app from being replayed against another.

Both proxies pass `X-Forwarded-User` / `-Email` / `-Groups` to the app by default
(`--pass-user-headers`). For machine callers, User and Email are
`client-<client-id>`. That identity reaches the app only through the proxies. The
LAN route goes straight to the app, so the app must never trust those headers for
anything that matters.

### 4b. Middlewares (`middlewares.yaml`)

An HTTPRoute ExtensionRef can only refer to a Middleware **in the route's own
namespace**. Copy the following into this namespace:

- `lan-only` from `workloads/gateway/lan-only-middleware.yaml`, and
  `auth-security-headers` (see `workloads/temporal-routes/middleware.yaml`).
- The edge gate per host class from [Public edge](public-edge.md): the human host
  is class A (`crowdsec-bouncer`); the machine host is class B
  (`crowdsec-bouncer-noappsec`), because AppSec body inspection misreads machine
  request bodies and bans the caller's address. Copy the definitions from
  `workloads/gateway/security-middlewares.yaml` into this namespace, as
  `workloads/pocket-id/security-middlewares.yaml` does. Board task #4 (public-edge
  reputation-primary gating) is changing this set; [Public edge](public-edge.md) is
  kept current.

The role checks:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: forwardauth-admins            # human host: admin paths
  namespace: some-temp-app
spec:
  forwardAuth:
    address: http://oauth2-proxy-some-temp-app.some-temp-app.svc.cluster.local:4180/oauth2/auth?allowed_groups=some-temp-app-admins
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: forwardauth-api-floor         # machine host: every rule
  namespace: some-temp-app
spec:
  forwardAuth:
    address: http://oauth2-proxy-some-temp-app-api.some-temp-app.svc.cluster.local:4180/oauth2/auth?allowed_groups=some-temp-app-api
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: forwardauth-fed-remote-worker # machine host: paths only this domain (or admins) may call
  namespace: some-temp-app
spec:
  forwardAuth:
    address: http://oauth2-proxy-some-temp-app-api.some-temp-app.svc.cluster.local:4180/oauth2/auth?allowed_groups=some-temp-app-fed-remote-worker-domain-xyz,some-temp-app-admins
```

`allowed_groups` is comma-separated and means **any of** the listed groups. To
require two roles together, chain two ForwardAuth middlewares.

### 4c. Routes (`routes.yaml`)

```yaml
# LAN: unchanged behaviour, straight to the app
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: some-temp-app-lan, namespace: some-temp-app}
spec:
  parentRefs: [{name: shared-gateway, namespace: default, sectionName: some-temp-app-ts-2143-https}]
  hostnames: [some-temp-app.ts.2143.me]
  rules:
    - matches: [{path: {type: PathPrefix, value: /}}]
      filters:
        - {type: ExtensionRef, extensionRef: {group: traefik.io, kind: Middleware, name: auth-security-headers}}
        - {type: ExtensionRef, extensionRef: {group: traefik.io, kind: Middleware, name: lan-only}}
      backendRefs: [{name: some-temp-app, port: 8080}]
---
# People
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: some-temp-app-public, namespace: some-temp-app}
spec:
  parentRefs: [{name: shared-gateway, namespace: default, sectionName: some-temp-app-john2143-https}]
  hostnames: [some-temp-app.john2143.com]
  rules:
    - matches: [{path: {type: PathPrefix, value: /admin}}]      # one rule per admin prefix
      filters:
        # class A edge middlewares (crowdsec-bouncer) here, then:
        - {type: ExtensionRef, extensionRef: {group: traefik.io, kind: Middleware, name: forwardauth-admins}}
      backendRefs: [{name: oauth2-proxy-some-temp-app, port: 4180}]
    - matches: [{path: {type: PathPrefix, value: /}}]
      filters: []   # class A edge middlewares only; the proxy's floor does the rest
      backendRefs: [{name: oauth2-proxy-some-temp-app, port: 4180}]
---
# Machines
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: some-temp-app-api, namespace: some-temp-app}
spec:
  parentRefs: [{name: shared-gateway, namespace: default, sectionName: api-some-temp-app-john2143-https}]
  hostnames: [api-some-temp-app.john2143.com]
  rules:
    - matches: [{path: {type: PathPrefix, value: /api/remote-worker}}]
      filters:
        # class B edge middlewares (crowdsec-bouncer-noappsec) here, then:
        - {type: ExtensionRef, extensionRef: {group: traefik.io, kind: Middleware, name: forwardauth-fed-remote-worker}}
      backendRefs: [{name: oauth2-proxy-some-temp-app-api, port: 4180}]
    - matches: [{path: {type: PathPrefix, value: /}}]
      filters:
        # class B edge middlewares (crowdsec-bouncer-noappsec) here, then:
        - {type: ExtensionRef, extensionRef: {group: traefik.io, kind: Middleware, name: forwardauth-api-floor}}
      backendRefs: [{name: oauth2-proxy-some-temp-app-api, port: 4180}]
```

The LAN route skips both proxies, so anyone who passes `lan-only` (LAN clients and
every tailnet member the headscale ACL lets reach `192.168.6.0/24`, including
`group:home`) gets the whole app with no role check. Drop the LAN route if the
admin paths must stay restricted on the LAN.

The edge middlewares are written as comments above to keep the example short.
In the real file, put the full list on every public rule, before the ForwardAuth.

**Optional hardening: path allowlist for machines.** If the app has destructive
or admin endpoints that callers should never reach, replace the catch-all `/` rule
on the machine host with explicit rules: one `PathPrefix` (plus `method:` where it
matters) per allowed endpoint. Anything unmatched then gets a 404 from Traefik
before it reaches a proxy. Default: the whole app, gated by the floor.

> Traefik 3.7.8 gives a `PathPrefix` rule priority `10000 + 100 × len(path)` and
> `PathPrefix /` priority 1 (`pkg/provider/kubernetes/gateway/httproute.go`,
> `buildPathRule`), so every specific prefix wins over `/`.

## 5. Gateway listeners and DNS

Add three listeners to `workloads/gateway/gateway.yaml`. Routes live in another
namespace, so use a namespace selector, as the existing `au-2143-https` (pocket-id)
and `argocd-*` listeners do:

```yaml
- name: some-temp-app-ts-2143-https
  protocol: HTTPS
  port: 8443
  hostname: some-temp-app.ts.2143.me
  tls: {mode: Terminate, certificateRefs: [{kind: Secret, name: ts-2143-me-wildcard-tls}]}
  allowedRoutes: {namespaces: {from: Selector, selector: {matchLabels: {kubernetes.io/metadata.name: some-temp-app}}}}
- name: some-temp-app-john2143-https
  protocol: HTTPS
  port: 8443
  hostname: some-temp-app.john2143.com
  tls: {mode: Terminate, certificateRefs: [{kind: Secret, name: john2143-com-wildcard-tls}]}
  allowedRoutes: {namespaces: {from: Selector, selector: {matchLabels: {kubernetes.io/metadata.name: some-temp-app}}}}
- name: api-some-temp-app-john2143-https
  protocol: HTTPS
  port: 8443
  hostname: api-some-temp-app.john2143.com
  tls: {mode: Terminate, certificateRefs: [{kind: Secret, name: john2143-com-wildcard-tls}]}
  allowedRoutes: {namespaces: {from: Selector, selector: {matchLabels: {kubernetes.io/metadata.name: some-temp-app}}}}
```

`scripts/validate-gateway-certs.sh` (CI) checks that each hostname is covered by
the certificate its listener uses.

DNS: public `*.john2143.com` already resolves to the home WAN through the wildcard.
For the `.ts.2143.me` name, add the headscale `extra_records` entry
(`adding-a-workload.md` §3c). LAN clients resolve all three names to the gateway
automatically ([lan-dns.md](lan-dns.md)); only the `.ts` name needs the headscale
record.

## 6. NetworkPolicy

Add `workloads/network-policies/<app>.yaml`, following
`workloads/network-policies/00-pattern.yaml` exactly, and run its **safety gate**
first. For this layout, the ingress allow list is:

- Traefik (`kube-system`, `app.kubernetes.io/name: traefik`) → container ports `4180`
  (both proxies) and `<app-port>` (the LAN route goes straight to the app).
- Same namespace (`podSelector: {}`); this is how the proxies reach the app.
- `observability` only if the app or the proxies are scraped.
- **No** SNAT-gateway ipBlocks: nothing here is a LoadBalancer or NodePort.

Egress uses the template's B1 tier unchanged. The proxies need `au.2143.me` for
OIDC discovery and JWKS, which B1 covers whether it resolves to the WAN or a VIP.

Then add the namespace to the "covered" list in `00-pattern.yaml`. Without these
policies, any pod in another namespace can reach the app directly.

Pocket ID itself must be able to reach `https://spiffe.remote-worker-domain.xyz/keys`
over the internet. The `pocket-id` namespace has no NetworkPolicy today; if one is
ever added, it needs internet egress for every federated issuer.

## 7. The remote side (what the caller's cluster must do)

Give this section to whoever runs `trust.remote-worker-domain.xyz`.

1. Set the SPIRE **server's** `jwt_issuer` to `https://spiffe.remote-worker-domain.xyz`,
   and the OIDC discovery provider's issuer to the **same** string. Serve the discovery
   provider publicly; it exposes `/.well-known/openid-configuration` and `/keys`.
2. Register the workload so its SPIFFE ID is exactly the `subject` from §3e, using a
   `ClusterSPIFFEID` with an explicit `className` and a namespace-scoped selector (the
   timestone pattern in `timestone-argo/base/spire/identities.yaml`).
3. In the workload, fetch a token from Pocket ID and refresh it before it expires:

```sh
# 1) SVID from the local agent (SDKs do this in-process)
SVID=$(spire-agent api fetch jwt -audience https://au.2143.me -socketPath "$SPIFFE_ENDPOINT_SOCKET" ... )
# 2) exchange it; client_id is REQUIRED (without it, Pocket ID tries to look up a client named after the spiffe:// URI)
curl -sS https://au.2143.me/api/oidc/token \
  -d grant_type=client_credentials \
  -d client_id=fed-remote-worker-domain-xyz-remote-worker \
  -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \
  -d client_assertion="$SVID" \
  -d resource=https://api-some-temp-app.john2143.com
# 3) call the app
curl -sS https://api-some-temp-app.john2143.com/api/remote-worker/... -H "Authorization: Bearer $ACCESS_TOKEN"
```

The SVID is only needed for the exchange. Its default TTL is 5 minutes, set per
entry with `jwt_svid_ttl`. The Pocket ID access token is what goes on every call;
cache it and re-exchange before `exp`. A cached SVID is fine (replay protection is
off, §3e).

The calls go through the public edge. A badly behaved caller can be banned by
CrowdSec like any other client.

## 8. Trust model and revocation

**Who you are trusting.** A federated credential trusts *the issuer's operator*.
Whoever runs `trust.remote-worker-domain.xyz` can mint **any** SPIFFE ID in that
domain. Pinning the exact `subject` stops lateral movement *inside* their domain,
but it is not a defence *against* the operator of that domain.

- **If the trust domain is a third party's** (a friend or partner): this is a
  trust decision about that party. Give them the narrowest permission set, one
  client per workload, and the machine-host path allowlist (§4c) for anything
  sensitive. Write down who the contact is.
- **If it is one of ours**: the mechanics are identical. Keep the same structure
  anyway (one client per workload, no shared clients) so attribution and
  revocation stay per workload.

**Revoking a caller** (in order of speed):

1. Remove its permissions from the API resource (`PUT /api/apis/{apiId}/clients/{clientId}`
   with an empty grant), or delete the client. No new token can be minted.
2. Tokens **already issued stay valid until `exp`**. oauth2-proxy checks the
   signature and expiry only; it does not ask Pocket ID about revocation. For an
   immediate cut-off, also drop the caller's `fed-*` role from the ForwardAuth
   rules, or block its source IP at the edge.

**Where the audit trail is.** Pocket ID v2.14.0 writes **no** audit event when it
authenticates a federated assertion or issues a `client_credentials` token. The
only record of machine access is the machine proxy's `--auth-logging` /
`--request-logging` output (user `client-<client-id>`), plus the app's own logs.
Keep those logs.

## 9. Verification checklist

Machine host (`api-…`):

- No `Authorization` header → **401** (not a redirect).
- A person's Pocket ID ID token sent as a bearer → **403** (wrong `aud`).
- A valid machine token without `some-temp-app-api` → **401** from the ForwardAuth
  (the floor fails inside `getAuthenticatedSession`, which `AuthOnly` reports as 401).
- A valid machine token for `remote-worker` → **200** on `/` and on `/api/remote-worker/...`;
  **403** on any path gated to another domain or to admins.
- The app sees `X-Forwarded-User: client-fed-remote-worker-domain-xyz-remote-worker`
  (check with a debug echo if the app doesn't log headers).

Human host:

- Anonymous → **403** oauth2-proxy sign-in page ("Sign in with OpenID Connect"),
  whose button goes to `au.2143.me`.
- A Pocket ID user in neither group → refused at Pocket ID login.
- Member of `-users` → **200** on `/`, **403** on `/admin`. Reloading `/` afterwards
  must still work without a new login, which proves the 403 did not clear the session.
- With a `-users` (non-admin) session, none of `/ADMIN`, `//admin`, `/x/../admin`,
  `/%61dmin`, `/admin/` nor any other admin alias the app serves returns 200; each
  must give 403 or 404. Repeat on the machine host for every per-domain prefix.
- Member of `-admins` → **200** on `/admin`.
- Opening `/admin` with no session → **401** (see limits below).

Isolation:

- A pod in another namespace cannot connect to `some-temp-app:8080` (NetworkPolicy).
- `some-temp-app.ts.2143.me` from the internet → refused by `lan-only`.

## 10. Known limits

- **Route-level only.** A role grants a path, not a field or a record. If the app
  needs finer control than that, the app needs real authentication.
- **`/admin` without a session returns `401`, not a login redirect.** ForwardAuth
  passes the auth response through unchanged. Admins sign in through `/` first.
- **Role checks are by path prefix.** An app that serves the same handler under
  another path or casing bypasses them; the §9 variants catch that.
- **Pocket ID is a hard dependency for machine callers.** Each caller needs a fresh
  token at least once per token lifetime. People retry; automation does not.
- **`scp`-as-groups relies on a Pocket ID implementation detail**
  (`JWTScopeFieldBoth`), not a standard. Re-run the machine checks in §9 after
  every Pocket ID upgrade.
- **Per-app Pocket ID state is not in git.** Use §11.

## 11. Inventory (fill in per app)

| Object | Value |
|---|---|
| Human client ID | |
| Machine-proxy client ID | `<app>-api` |
| API resource | `https://api-<app>.john2143.com` |
| Permissions | `<app>-api`, `<app>-admins`, `<app>-fed-…` |
| User groups | `<app>-users`, `<app>-admins` |
| Federated clients | client ID · issuer · subject · granted permissions · owner/contact |
| OpenBao paths | human proxy secret · machine proxy secret |

## Teardown

Delete the Argo Application, the three listeners, the headscale record and the
NetworkPolicy file. In Pocket ID, delete the federated clients, the machine-proxy
client, the human client, the API resource and the two groups. Then remove the
OpenBao entries and this app's inventory row.

## Evidence

Behaviour this guide depends on, with the source it was read from:

- oauth2-proxy v7.15.4: bearer sessions (`skip-jwt-bearer-tokens`, `oauthproxy.go`
  `buildSessionChain`); `--bearer-token-login-fallback` default **true**; `--api-route`
  returns 401; `--oidc-extra-audience` widens audience verification; groups come
  from `--oidc-groups-claim` via `buildSessionFromClaims` / `CoerceClaim` (arrays
  supported); `AuthOnly` returns 401 / 403 / 202; `checkAllowedGroups` reads the
  `allowed_groups` query parameter (comma-separated, any-of); a failed floor
  (`provider.Authorize`) clears the session cookie; `--scope` defaults to empty.
- Pocket ID v2.14.0: `client_credentials` yields `sub=client-<id>` with identity
  scopes stripped and no extra claims; `resource=` sets `aud` to the API URI and
  limits scopes to client-subject grants; scopes are emitted as `scp` (array) and
  `scope` (string); the federated credential's iss/sub/aud are exact matches, and
  `jwks` defaults to `<issuer>/.well-known/jwks.json`; the groups claim uses group
  `name` and is present only with the `groups` scope; admin clients may choose
  their client ID (`^[a-zA-Z0-9._-]+$`); admin API key header is `X-API-Key`; no
  audit events for machine tokens; Allowed User Groups apply only when
  `isGroupRestricted` is true; allowed-user-groups body is `{userGroupIds}`.
- SPIRE v1.15.3: `iss` is emitted only when the server's `jwt_issuer` is set; `aud`
  is always an array; `jti` only with `jwt_svid_include_jti`; the agent caches SVIDs
  per (SPIFFE ID, audience) until about half the TTL; default JWT-SVID TTL is 5m;
  the OIDC discovery provider serves `/.well-known/openid-configuration` and `/keys`
  only.
- Traefik v3.7.8: ForwardAuth sends the configured `address` including its query
  string (`pkg/middlewares/auth/forward.go:166`); path-rule priority as in §4c.
