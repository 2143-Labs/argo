# Private webmail UIs, Bulwark, and a mail-only `m.2143.me`

`m.2143.me` used to serve the Stalwart admin SPA to the public internet. It now
carries mail protocols only, and the two web UIs live on the `ts.` tier, which
is reachable from the LAN and the tailnet and from nowhere else.

## What serves what

| Hostname | Serves | Reachable from |
|---|---|---|
| `stalwart.ts.2143.me` | Stalwart admin portal (`HTTPRoute stalwart/stalwart` → `stalwart-stalwart-web:8080`) | LAN + tailnet |
| `mail.ts.2143.me` | Bulwark webmail (`HTTPRoute default/bulwark` → `bulwark:3000`) | LAN + tailnet |
| `m.2143.me` | no HTTP listener at all; SMTP 25, submission 587, IMAPS 993 on `192.168.6.13` | mail clients |
| `<service>.john2143.com` | inbound mail for registered subdomains; senders are signed by SES | mail |

Both UIs sit behind the `lan-only` Middleware. It must exist **in the route's own
namespace** — an `ExtensionRef` resolves only there — so there is one copy in
`namespace: default` for Bulwark and one in `namespace: stalwart` for the portal
(`workloads/stalwart/security-middlewares.yaml`). The portal's three former
public filters (rate limit, in-flight cap, CrowdSec bouncer) are gone with the
public host: they were replaced, not supplemented.

## A `ts.` name needs three resolvers, and never a public record

`.ts.2143.me` is a headscale MagicDNS zone. Every name in it is enumerated:

1. **Tailnet clients** — `workloads/headscale/configmap.yaml`, `dns.extra_records`
   (a `# <host>` comment above an `A` record, no `AAAA`). Live entries start at
   line 161 and now include `stalwart.ts.2143.me` and `mail.ts.2143.me`.
2. **LAN clients** — per-name split-horizon entries on the router at
   `192.168.6.1`, exactly like `home.ts.2143.me` and `argocd.ts.2143.me`. This is
   router configuration, outside this repository.
3. **Cluster workloads** — `hosts.split-horizon` in
   `dotfiles/nixos/closet-configuration.nix`, which becomes the
   `coredns-custom` ConfigMap's hosts file.

**There is deliberately no public DNS record.** The `2143.me` zone's wildcard
`* CNAME 2143.me` would otherwise answer for these names and send them to
`174.138.108.28`, a host that refuses their SNI. A name that resolves publicly is
a name that has been published.

Adding a listener without adding all three leaves the UI unreachable from the
resolver you did not update, and the symptom is a silent fall-through to public
DNS — not an error.

## CORS, and why the JMAP origin must match the browser's

Bulwark's browser talks JMAP **directly**: its server hands same-origin JS the
decrypted credentials, so the browser then makes cross-origin requests to
Stalwart. `usePermissiveCors: true` on the `x:Http` singleton is what makes that
work, and it emits exactly three headers:
`Access-Control-Allow-Origin: *`, `Access-Control-Allow-Headers: Authorization,
Content-Type, Accept, X-Requested-With`, `Access-Control-Allow-Methods: POST,
GET, PATCH, PUT, DELETE, HEAD, OPTIONS`.

What that exposes: any origin may *read* a JMAP response. It does not
authenticate anything — a request still needs a valid `Authorization` header, so
the exposure is that a hostile page the user visits could replay requests with
credentials it does not have. Nothing else in this cluster needs cross-origin
JMAP, so this is set **for Bulwark alone**; turn it off if Bulwark goes away.

## `STALWART_PUBLIC_URL` is not cosmetic

The chart value `hostname` (`charts/stalwart/values.yaml`) is the only input to
`STALWART_PUBLIC_URL`, which drives `apiUrl`, `downloadUrl`, `uploadUrl`,
`eventSourceUrl` **and** the WebSocket URL the server hands to browsers. It must
be the origin the browser actually reaches — `stalwart.ts.2143.me`. It is *not*
the mail domain: mail identities keep `usernameDomain: m.2143.me` in the OIDC
directory and in RocksDB, and the mixed-case account mechanism depends on that.
Changing only the chart value is enough to roll the pod, because the env changed.

## OIDC

The portal's Pocket ID client (`0fa8f57e-dc4a-45bf-bda0-540552f0caaf`, "Email")
keeps both `m.2143.me` redirect URIs and gained
`https://stalwart.ts.2143.me/account/oauth/callback` — the old ones stay
registered so the move remains reversible.

Bulwark is a **second** OIDC client, and its access tokens carry a different
`aud`. Stalwart's OIDC directory pinned `requireAudience` to the portal's client
id, which would reject them. That property is optional and has no fallback
default, so it was **cleared** rather than widened — one change that helps every
client instead of a list that rots.

To restore it (do this whenever no second OIDC client remains; it is what keeps
any other Pocket ID client from obtaining JMAP access):

```sh
# inside the pod, so the recovery credential never reaches argv
x:Directory/set  {"update":{"iuukp10iaaqa":{"requireAudience":"0fa8f57e-dc4a-45bf-bda0-540552f0caaf"}}}
```

Either way, `x:Directory/set` only *stores* the value — the running server keeps
validating with the config it loaded at startup until you send `ReloadSettings`
(the same action step 1 uses for CORS). Reading it back with `x:Directory/get`
proves the stored value and nothing else: `requireAudience` read back as `null`
while Stalwart still rejected Bulwark's tokens with `JWT validation failed:
InvalidAudience` (`crates/directory/src/core/dispatch.rs`), and every webmail
login failed at `/api/auth/token` with `401` until the reload landed. Reload the
settings, then verify by *using* the thing — a read-back is not proof.

Bulwark's client is `bulwark-webmail` at Pocket ID, confidential, with **one
redirect URI per UI locale** (`https://mail.ts.2143.me/<locale>/auth/callback`,
24 of them): Bulwark's callback path always contains the locale segment, so
registering only `en` works until a browser picks a different one. Its
`SESSION_SECRET`, `OAUTH_CLIENT_ID` and `OAUTH_CLIENT_SECRET` live in OpenBao at
`consumers/data/john2143-com/default/bulwark-session` and are rendered by
`workloads/secrets/default-bulwark-session.yaml`. The Deployment carries
`reloader.stakater.com/auto` on the pod template, as `docs/adding-a-secret.md`
requires. Know what it does not cover, though: Reloader does roll workloads for
ConfigMap *changes* (observed: a `headscale-config` edit rolled headscale, and it
acted on other Secrets in this namespace), but it did **not** roll this
Deployment when the Secret was first created. A first seed is a create, not a
change, so it needs one `kubectl rollout restart deploy/bulwark` — without it the
pod keeps its empty env and the login silently cannot work even though vault and
Secret are both correct.

## `m.2143.me` answers from the mail LB now

Removing the HTTP listener makes the name mail-only, which makes the old
answer — the web LB, `192.168.6.11`, which serves only 443 — wrong:

- **Cluster** (`dotfiles/nixos/closet-configuration.nix`): move `m.2143.me` from
  the `192.168.6.11` line to the `192.168.6.13` line that already holds
  `imap.m.2143.me smtp.m.2143.me`.
- **Router** (`192.168.6.1`): the same move for LAN clients.

Off-LAN clients are unaffected either way: they reach `108.56.153.222`, where
the router's port-forwards send mail ports to the mail Service.

## `*.john2143.com`

`john2143.com` itself stays at Google Workspace. The subdomains are handled here.

**Sending** is covered by the single SES identity for the **apex**
`john2143.com`: it authorises every subdomain, signs as `d=john2143.com`, and
relaxed DMARC alignment accepts that for a subdomain `From`. No per-service DKIM
records, no per-service identity. Stalwart's own `dkimManagement` for these
domains stays `Manual` for the same reason — SES holds the only signing key.

**Inbound** needs the wildcard record replaced, which is a DNS change with three
constraints that are easy to get wrong:

- A `CNAME` cannot coexist with an `MX` at the same name (RFC 1034 §3.6.2,
  RFC 2181 §10.1), and per RFC 1912 §5.3 a wildcard `MX` applies only to names
  that do not otherwise exist — so the `CNAME` must be deleted, not kept
  alongside.
- `prod.john2143.com` is an explicit `CNAME 2143.me`, and an explicit record
  outranks a wildcard, so its mail keeps following Proton's MX and will not
  arrive here.
- No wildcard `TXT`: it would also answer `_dmarc.john2143.com` and
  `_acme-challenge.john2143.com`.

A subdomain is only reachable once it is **registered in Stalwart** — there is no
wildcard domain, and the domain cache is exact-name. `terminals.john2143.com`
exists as domain id `c` with `catchAllAddress: all@terminals.john2143.com`; that
address is alias index 3 on the admin account. An unregistered subdomain is
refused at `RCPT TO` with a clean `550`, so nothing is accepted and bounced later.

**This state lives in RocksDB, not in this repository.** Registering a new
subdomain is a runtime change: `x:Domain/set` create, then one alias write that
re-sends every surviving index, because `aliases` is a map that replaces
wholesale.

## Reaching the UIs

- Portal: `https://stalwart.ts.2143.me/account/`, Pocket ID SSO.
- Webmail: `https://mail.ts.2143.me/`, Pocket ID SSO, `OAUTH_ONLY` (no password
  form). Mail clients use `m.2143.me` for IMAP/SMTP — the `*.2143.me` wildcard
  certificate covers that name and *not* the two-label `imap.m.2143.me`, which
  fails hostname validation despite having a DNS record.

## Checking it still works

```sh
curl -sk -o /dev/null -w '%{http_code}\n' https://stalwart.ts.2143.me/account/   # 200
curl -sk -o /dev/null -w '%{http_code}\n' https://mail.ts.2143.me/api/health     # 200
curl -sk -o /dev/null -w '%{http_code}\n' https://m.2143.me/                     # 404, no SPA
dig +short A stalwart.ts.2143.me @192.168.6.1    # 192.168.6.11 -- a 174.138.108.28 answer means the router entry is missing
dig +short A m.2143.me @192.168.6.1              # 192.168.6.13 after the resolver move
dig +short A stalwart.ts.2143.me @100.100.100.100  # tailnet MagicDNS, from extra_records
```

The Stalwart doorbell that says the JMAP origin is right: the `.well-known/jmap`
response must advertise `https://stalwart.ts.2143.me/jmap/`, or the browser is
being told to POST somewhere that no longer exists.

## Rollback

- `git revert` the UI commit: the HTTPRoute returns to `m.2143.me`/`m-2143-https`
  and `hostname` returns to `m.2143.me`. Restore the `m-2143-https` listener
  first if the revert is not a clean single commit — it was deleted in a separate
  commit.
- Re-set `requireAudience` (above), turn `usePermissiveCors` off, delete
  `apps/bulwark.yaml`, and delete the Pocket ID client `bulwark-webmail`.
- No mail data is at risk in any of this: Stalwart's RocksDB is untouched apart
  from the CORS flag, the audience field and the domains added deliberately.
