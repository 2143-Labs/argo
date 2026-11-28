# AppSec out-of-band CRS banned a paying customer (2026-11-28)

A customer editing tasks saved the same Vikunja task six times in 19.5 seconds. Vikunja answered every
request 200; the edge IP-banned them for 4 hours on 45 hostnames anyway, and the ban ran until it was deleted
by hand 3 h 06 m later. The trigger was the out-of-band OWASP Core Rule Set pass on the gateway's AppSec
component, which scores ordinary `PATCH` requests on CRS defaults and turns six scores in 30 seconds into a
ban no internal client can observe.

## Timeline (UTC)

| Time | Event |
|---|---|
| 05:52:52 | Ban created by `crowdsecurity/crowdsec-appsec-outofband` for `50.117.148.31` (decision 18891127, alert 57515), duration 4 h, scope `Ip`. |
| 05:52:52–08:58:45 | 35 requests denied (28 on `tasks.2143.me`, 7 on `au.2143.me`). |
| ~08:52 | Owner deletes the decision by hand: `cscli decisions delete --ip 50.117.148.31` — "1 decision(s) deleted", no active decisions left. |
| 08:58:45 | Customer's first 200 through the edge again; 127 requests served in the next minutes. |
| 2026-11-28 | Root cause removed: `outofband_rules` dropped from both appsec configs in this repo. |

Ban served: 3 h 05 m 53 s.

## Cause chain

1. `workloads/crowdsec/values-prod.yaml` (and `-nonprod`) load the whole CRS as **out-of-band** rules:
   `outofband_rules: [crowdsecurity/crs]`.
2. The image's `crs-setup.conf` is a 196-byte stub, so CRS runs on its defaults: `tx.allowed_methods =
   GET HEAD POST OPTIONS` (rule 901160), paranoia level 1, inbound anomaly threshold 5.
3. A Vikunja autosave is `PATCH /api/v2/...` with `Content-Type: application/json-patch+json`. Each one
   scores twice — `911100` (method not allowed by policy) and `920420` (content type not allowed) — with
   `901340`, `949110` and `980170` recording the method and the anomaly total.
4. Scenario `crowdsecurity/crowdsec-appsec-outofband` is leaky with capacity 5, leak speed 30 s, grouped by
   source IP only and with no `distinct`. Six scores in 19.5 s overflow the bucket: one 4 h IP ban.
5. `profiles.yaml` in the LAPI image applies a flat 4 h ban to any IP-scoped alert and notifies nobody.
6. The bouncer skips every household, tailnet and cluster address (`clientTrustedIps`), so nothing the owner
   does at home can see the ban, and nothing alerts.

## Why the ban was not doing useful work

Seven days of LAPI retention, all 41 out-of-band bans:

- 37 happened within 1 s of an independent ban on the same address from another detector — the IP-reputation
  scenarios, the CAPI community blocklist or `http-probing`. The WAF added a duplicate, not a detection.
- 2 of the remaining 4 were real people (this customer, and the owner's own second line on 2026-11-23, which
  was patched by moving `/dav` to class B — the ban five days later came from `/`).
- 0 requests were stopped that no other detector would have stopped.

The same false positive had been recorded ten times since 2026-08-09, each time by exempting one host or one
path prefix. Removing the out-of-band pass is the fix that ends the class.

## Fix

- `workloads/crowdsec/values-prod.yaml` and `values-nonprod.yaml`: `outofband_rules` removed. The config keeps
  `inband_rules` (`crowdsecurity/base-config`, `crowdsecurity/vpatch-*`), so CVE signatures still produce a 403
  for the offending request; they no longer produce a ban.
- `scripts/validations/appsec-no-outofband.sh`: CI fails any appsec config in this repo that names
  `outofband_rules`. Wired automatically — `validate-policies.yml` runs every script in `scripts/validations/`.
- `docs/public-edge.md`: the class-B rule no longer describes a WAF pass that bans; it states that AppSec is
  in-band only, and that a detector may create a ban only after a 7-day back-test, an external probe, and an
  alert that names the client.

## Verification

- `cscli alerts list --scenario crowdsecurity/crowdsec-appsec-outofband --since 24h` is empty after the
  change; the 7-day baseline was 41.
- `cs_sum(increase(cs_appsec_reqs_total[30m])) > 0` (in-band inspection continues) while
  `cs_appsec_outband_parsing_time_seconds_count` stops increasing.
- `bash scripts/validations/appsec-no-outofband.sh` passes on the merged tree and fails when
  `outofband_rules: [crowdsecurity/crs]` is re-added to one values file.
