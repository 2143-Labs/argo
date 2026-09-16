# Adding a Secret

Application secrets live in OpenBao and are rendered into ordinary Kubernetes
`Secret`s by External Secrets Operator (ESO). Workloads reference the rendered
`Secret` by name, exactly as before — nothing in a Deployment, StatefulSet or
chart needs to change. Adding a secret is three steps: seed it, declare an
`ExternalSecret`, verify.

## 1. Where secrets live

KV v2 mount **`consumers`**. Keys are namespaced by the consuming cluster and
then mirror the Kubernetes identity, so the vault path and the cluster object
correlate trivially:

```
consumers/data/john2143-com/<namespace>/<secret-name>
```

For the home cluster the scope segment is `john2143-com`, so
`default/frigate-creds` lives at `consumers/data/john2143-com/default/frigate-creds`.

The mount's other scope is `hero-rehab`, consumed by an out-of-repo sync in the
**timestone** cluster. That scope has a different shape — `hero-rehab/<name>`,
with no namespace segment — because it mirrors that deployment's own identities
rather than this cluster's. Do not invent a namespace segment there.

## 2. Seed the value

Never commit a value, never pass one as a CLI argument (it lands in shell
history), and never echo one to a terminal.

The file passed to `@` must be **JSON** — `@` is parsed as JSON, not as
`key=value` lines, and a plain `KEY=value` file fails with
`Failed to parse K=V data: invalid character 'A' looking for beginning of value`.
Build the JSON in a file on tmpfs so the value never reaches the repo, and shred
it afterwards:

```fish
set -l f (mktemp /dev/shm/seed-XXXXXX)
printf '{"KEY":"value"}' > $f        # or edit $f directly, so the value stays out of argv
bao kv put -mount=consumers john2143-com/<ns>/<name> @$f
shred -u $f
```

JSON also handles values that a `key=value` file could not carry — newlines and
non-UTF8 bytes go in as `\n` and `\uXXXX` escapes:

```fish
printf '{"CERT":"-----BEGIN CERTIFICATE-----\\nMIIB...\\n-----END CERTIFICATE-----\\n"}' > $f
```

If the value already exists as a Kubernetes `Secret`, re-encode it instead of
retyping it — this is how the original migration seeded all 26:

```fish
kubectl get secret -n <ns> <name> -o json | jq '.data | map_values(@base64d)' > $f
bao kv put -mount=consumers john2143-com/<ns>/<name> @$f
shred -u $f
```

**The `-mount=` form is not optional decoration.** The `kv` CLI appends `data/`
itself, so `bao kv put consumers/data/<key>` writes one level too deep to
`consumers/data/data/<key>` — where ESO will never read it and where the value
silently becomes a dead copy.

## 3. Declare the ExternalSecret

Add one file per secret at `workloads/secrets/<ns>-<name>.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <name>
  namespace: <ns>
spec:
  refreshInterval: 10m
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: <name>
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: john2143-com/<ns>/<name>
```

`target.name` **must** equal the Secret name the workload already consumes —
that is what keeps the migration invisible to the workload. The `secrets`
Application (`apps/secrets.yaml`) owns the whole `workloads/secrets/` directory
as a single app; that is deliberate, because some secret names exist in more
than one namespace and per-workload apps would let one app's prune delete a
Secret a neighbour still reads.

## 4. Verify before trusting it

**`creationPolicy: Owner` makes ESO replace the target Secret**, so a partial or
empty KV entry silently destroys keys the workload still needs. Compare the key
sets before trusting the rendered `Secret`:

```fish
kubectl get secret -n <ns> <name> -o json | jq -r '.data|keys[]' | sort
bao kv get -mount=consumers -format=json data/john2143-com/<ns>/<name> | jq -r '.data.data|keys[]' | sort
```

The two lists must be identical. Check key sets only — **do not** print values.

## 5. Make rotation reach the pod

Add the Reloader annotation to the **pod template** of every consumer:

```yaml
spec:
  template:
    metadata:
      annotations:
        reloader.stakater.com/auto: "true"
```

`spec.template.metadata.annotations` — *not* the workload's top-level
`metadata.annotations`, which is inert and was a live bug in `listen-brick`. For
a Helm-managed consumer, set it through the chart's `podAnnotations` value
rather than editing a rendered file.

## 6. Rules

- Never commit a secret value. This repository is **public**.
- Never pass a value as a CLI argument or echo one to the terminal.
- Always use the `-mount=` form of `bao kv put`.
- Always verify key parity before trusting a rendered Secret, and always put the
  Reloader annotation on the pod template.

See `2026-09-13-secrets-inventory.md` §6 for the design record: the store and
policy as built, what is deliberately *not* in OpenBao (CNPG credentials,
cert-manager TLS, OpenBao's own bootstrap secrets), and the known gaps —
including that `refreshInterval: 10m` means a changed value reaches the rendered
Secret within about ten minutes and the workload on the next Pod restart, and
that every rotation currently rolls a workload twice.
