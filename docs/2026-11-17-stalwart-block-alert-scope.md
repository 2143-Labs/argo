# Stalwart blocked-address alert: scope it to internal sources (2026-11-17)

`stalwart-ip-blocked` (`workloads/observability/grafana-dashboards/alert-rules.yaml`) was added
2026-09-17 with the rule "alert on Stalwart restarts and blocked addresses". Its purpose was the
regression that had gone unnoticed for months: a permanent block-list record covering the
cluster's own pod IPs, which crashlooped the mail server. It fired on **any** `security.ip-blocked`
line, and that produced roughly 1.4 ntfy pushes a day for two months — every one of them a bot that
Stalwart had already refused.

## What the events actually are

IP banning is automatic. A client that sends an invalid SMTP command is banned on the spot
(`security.scan-ban`, whose only reason in 30 days was `Invalid SMTP command`), and every further
connection from that address is refused with `security.ip-blocked`:

```
06:45:03  INFO SMTP EHLO command (smtp.ehlo) listenerId = "smtp", localPort = 25,
            remoteIp = 128.14.225.253, domain = "108.56.153.222"
06:45:03  INFO SPF EHLO check failed (smtp.spf-ehlo-fail) … result = No SPF record (spf.none)
06:45:03  INFO Authentication not allowed (smtp.auth-not-allowed) …
06:45:06  INFO Banned due to scan (security.scan-ban) … reason = "Invalid SMTP command"
06:45:06  INFO Blocked IP address (security.ip-blocked) …   ×5, the bot's parallel retries
```

Measured over 2026-10-18..2026-11-17 with `count_over_time` against Loki (`192.168.6.24:3100`):

| signal | 30d |
|---|---|
| `security.scan-ban` | 48 (all `Invalid SMTP command`) |
| `security.ip-blocked` | 153 |
| distinct blocked addresses | 37, all public |
| private/cluster addresses blocked | 0 |
| firing windows (Grafana `ngalert` log, 7d) | 10 |

Every blocked address was a scanner or a spam bot, not a correspondent:

- 7 × `66.132.*` and `167.94.146.52` = Censys, 2 × `71.6.*` = Shodan, `185.242.226.19` =
  CriminalIP, `3.130.168.2` = `scan.visionheight.com` — PTR records.
- ~20 DigitalOcean/Cloudie/Alibaba VPS ranges with no PTR, most of them sending the same forged
  `EHLO 108.56.153.222` — one scanner fleet.
- `217.76.139.77` was the loudest (24 blocked connections): 84 `MAIL FROM`, 132
  `relay-not-allowed`, 3 `security.abuse-ban` — a relay attempt, not a sender.

Cross-checks: no external address authenticated successfully in 30 days (`auth.success` is 100%
pod IPs), and the only blocked address that ever reached `MAIL FROM` is the relay bot above.
Legitimate senders (Google `209.85.*`, SES `54.240.*`, Microsoft `52.101.*`) were never blocked.

## The change

The rule now counts only private sources:

```logql
sum(count_over_time({cluster="home", namespace="stalwart"} |= "security.ip-blocked"
  |~ "remoteIp = (10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|f[cd][0-9a-f][0-9a-f]:|fe80:)" [15m]))
```

The ranges it covers, from live cluster state: pods `10.42.0.0/16` + `fd42:42:42::/48`, services
`10.43.0.0/16` + `fd00:6::/64`, nodes and LAN `192.168.5-7/24` + `fd00:1::/64`, and IPv6
link-local. Matching private rather than enumerating our own prefixes means a new subnet is covered
without touching the rule. Title, summary and description now say "internal address", so a push
means what it says.

Verified: the expression returns no series over 30d or in the current 15m window, while
`remoteIp = 128\.14\.` over 7d returns the events above. After the sync Grafana logged
`Clearing the state of the rule because it was updated`.

## Re-auditing

The block list itself lives in the RocksDB store, not in git, and is reached only through the admin
JMAP API (`x:BlockedIp/get`, `x:AllowedIp/get`) — the pod carries no admin credential, so read it
from the Stalwart admin UI rather than expecting an env var. To re-check whether blocks are still
benign, group the events by source address and listener and compare against successful
authentications:

```logql
sum by (remoteIp, listenerId) (count_over_time({cluster="home", namespace="stalwart"}
  |= "security.ip-blocked" | pattern "<_> listenerId = \"<listenerId>\", localPort = <_>, remoteIp = <remoteIp>," [30d]))
```

A private address in that result is the actual incident. Public addresses are expected.

## Not changed

`stalwart-pod-restarts` still fires on any restart, which is correct for a single-replica mail
server — but see the 2026-11-17 restart episode: a graceful `SIGTERM` at 05:10:02 was followed by
three failed starts (`Startup failed: Failed to open database … LOCK: Resource temporarily
unavailable`) before the new container came up at 05:11:51. That is a real ~2 minute outage, not
alert noise, and it needs its own fix.
