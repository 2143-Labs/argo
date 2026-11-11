# ntfy alert formatting (2026-11-09)

Both alert senders used to POST their raw webhook JSON to the ntfy topic, so a push
showed a JSON blob, and any body over ntfy's 4 096-byte message limit arrived as an
attachment instead of a message. Two config changes fixed it. No alert rules,
grouping, severities or routing were touched.

| Sender | File | Change |
|---|---|---|
| Grafana | `workloads/secrets/observability-grafana-alert-contactpoint.yaml` | `<topic>?template=grafana`, plus `settings.title` and `settings.message` |
| pite Alertmanager | `dotfiles:nixos/pite-canary.nix` (`preStart`) | `<topic>?template=alertmanager` |

## Why ntfy templates

`?template=<name>` makes ntfy parse the JSON body with a pre-defined template
(`docs.ntfy.sh/publish`, §Pre-defined templates). `grafana` prefixes the title with
🚨/✅ and prints `<message>` cut at 2 000 characters; `alertmanager` prints
Status/Receiver plus per-alert Instance/Severity/Summary/Description/Source.

Pre-defined templates need ntfy ≥ 2.14. Gate before shipping: publish a JSON body
with `?template=grafana` to a scratch topic and confirm the title comes back
prefixed with 🚨.

## Why not a provisioned Grafana template

Grafana can also take `templates.yaml` through alerting file provisioning, but a
notification that references a template which failed to register fails for every
alert — one bad file would blackout all Grafana alerting. The inline `title` /
`message` fields are ordinary webhook-v1 settings (accepted and validated by
Grafana's contact-point provisioning), so the blast radius of a mistake is one
contact point plus a visible provisioning warning.

## Why pite would not work the same way

Alertmanager cannot template a webhook body (its `webhook_configs` send a fixed
schema), and ntfy.sh exposes no custom-template directory. The built-in
`alertmanager` layout — several labelled lines per alert — is the most readable
format available without self-hosted ntfy.

## The ESO escaping that makes this work

The Grafana contact point is rendered by external-secrets (`engineVersion: v2`),
which evaluates `{{ … }}` itself, so Grafana's own template syntax is emitted from
Go raw-string literals:

```yaml
title: {{ `'{{ .CommonLabels.alertname }}{{ if gt (len .Alerts.Firing) 1 }} ×{{ len .Alerts.Firing }}{{ end }}'` }}
```

Two details that are easy to get wrong: the value must stay a YAML *single-quoted*
scalar (double quotes turn `{{ "\n" }}` into a real newline and break the Go
literal), and the template text must contain no `'` characters.

The URL parameter is appended conditionally, so it works whether or not the stored
topic URL already carries a query string:

```yaml
url: {{ printf "%s%stemplate=grafana" .url (ternary "&" "?" (contains "?" .url)) | quote }}
```

## Known limits

- Messages are cut at 2 000 characters; a group with dozens of alerts loses the tail.
- `DatasourceError` / `DatasourceNoData` alerts carry no `summary`; their bullet
  falls back to the alert name.
- `X-Template` and `?tpl=` are aliases for `?template=`; unused here.

## Verification

Read the rendered secret, never the manifest, and never print the topic URL:

```sh
kubectl -n observability get secret grafana-alert-contactpoint \
  -o jsonpath='{.data.contactpoints\.yaml}' | base64 -d
```

A real push confirms the rest: the topic's own cache shows the rendered titles
(`🚨 Pod running but not Ready ×7`, `✅ …` with a `Resolved:` block). Extract the
topic URL into a shell variable if a check needs it.

## What this did not fix

Most of the notification volume in November came from ROTS PR previews, not from
formatting: preview images that predate the `rots-sync` feature crashloop, and
preview applications for merged PRs were not pruned. Those are tracked on the
board, not here.
