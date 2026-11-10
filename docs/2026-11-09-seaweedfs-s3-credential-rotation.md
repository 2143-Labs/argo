# SeaweedFS S3 identities: rotation, least privilege, and orphan cleanup

**Date:** 2026-11-09
**Status:** implemented and verified. Seven identities, each scoped to the buckets its
consumers actually read; every key held only by its intended consumer.
**Scope:** `default` and `observability` namespaces, the SeaweedFS filer/S3 gateway
(`workloads/seaweedfs/`), the OpenBao entry at
`consumers/data/john2143-com/default/seaweedfs-s3-config`, and the two edge slots.

## Why

The whole `s3.json` identity file — nine credentials across eight identities — was printed
into a session transcript by a `jq` error, revealing every `accessKey` and `secretKey`. It was
never committed to this repository (`git log --all -- '*s3.json*'` is empty) but the live
`Secret/default/seaweedfs-s3-config` was identical to the leaked copy, so the only exposure
path was the transcript and the values must be treated as disclosed.

The audit that came with the leak found three separate problems worth fixing in the same pass:

- **Six of eight identities were effectively global.** Five declared `actions: ["Admin"]`;
  `rain-marvel` declared a `resources` list that does not restrict at all — its key listed all
  17 buckets and read 182,042 objects in `litellm-spend-logs`, a bucket unrelated to it.
- **A dead identity with a dead key.** `john2143-worker` had no live consumer and
  `matrix/seaweedfs-s3-creds` held a 4-character access key that returned `InvalidAccessKeyId`.
- **Orphans.** Two ExternalSecrets and one unmanaged Secret rendered credentials nothing read,
  and one empty bucket nobody had written to.

## 1. Inventory

Seven identities remain. Each is scoped with one `Read:`/`Write:`/`List:` triple per bucket.

| Identity | Buckets | Consumer Secret |
|---|---|---|
| `observability` | `mimir-alertmanager`, `mimir-blocks`, `mimir-rules`, `loki-admin`, `loki-chunks`, `loki-ruler`, `tempo-blocks` | `observability/o11y-rustfs-buckets` |
| `litellm` | `litellm-spend-logs` | `default/litellm-s3-creds` |
| `seaweedfs-frigate-genai` | `frigate-genai` | `default/frigate-genai-worker-creds` |
| `john2143-worker-home` | `imagehost-files` | `default/minio-creds` |
| `rots4-ci` | `rots4-releases` | GitHub Actions secret (outside this checkout) |
| `edge-tofu` | `edge-tofu-state` | OpenBao `consumers/edge/s3` (read per command) |
| `rain-marvel` | `marvel3-logs` | consumer unlocated; keep both credentials |

The identity file itself is `consumers/data/john2143-com/default/seaweedfs-s3-config`, key
`s3.json`, rendered by `workloads/secrets/default-seaweedfs-s3-config.yaml` into
`Secret/default/seaweedfs-s3-config`. The filer and the S3 gateway read it
(`workloads/seaweedfs/filer.yaml`), and a Reloader annotation on that Deployment makes a
config change restart them.

## 2. Rotation procedure

SeaweedFS accepts **several credentials per identity**, which is what makes this
zero-downtime for consumers: issue the new credential while the old one still works, move the
consumers, then retire the old one. The only outage is the filer restart that each config
write costs — `seaweedfs-filer` is a single replica with `Recreate`.

```bash
cd ~/repos/argo
bao login -method=oidc
scripts/seaweedfs-rotate.py audit            # baseline: scope, holders, reachability

scripts/seaweedfs-rotate.py issue --all --apply       # one write: new creds + tighter scope
scripts/seaweedfs-rotate.py verify --all              # overlap: old and new both work
scripts/seaweedfs-rotate.py propagate --all --apply   # consumers pick up the new credential
scripts/seaweedfs-rotate.py verify --all              # new credential in use everywhere
scripts/seaweedfs-rotate.py retire --all --apply      # one write: drop the old credentials
```

Each `--apply` prints what it did; without it every command is a dry run. `issue --all` and
`retire --all` are deliberately batched: each costs exactly one config version and one filer
restart, so rotating everything at once is one 5–20 s S3 outage rather than seven.

Escape hatch, for the whole run:

```bash
bao kv rollback -mount=consumers -version=<V0> john2143-com/default/seaweedfs-s3-config
kubectl --context closet-as-admin annotate externalsecret seaweedfs-s3-config -n default \
  force-sync=$(date +%s) --overwrite
```

`<V0>` is the value from
`bao kv metadata get -mount=consumers -format=json john2143-com/default/seaweedfs-s3-config | jq -r '.data.current_version'`
recorded before the first write.

## 3. Propagation

Two mechanisms, and it matters which one applies:

- **Reloader restarts these automatically**, because they carry
  `reloader.stakater.com/auto: "true"`: `default/litellm`, the six `default/frigate-genai-*`
  workloads, `default/john2143-com-worker-220`. ESO rewrites the Secret, Reloader notices.
- **`observability` also reloads itself**, but the recovery is slower and worth expecting:
  `statefulset/mimir`, `tempo`, `loki-write` and `loki-backend` all carry the annotation
  (verified 2026-11-09), and the StatefulSet controller brings them back one pod at a time.
  `tempo` has a single replica, so its restart is a ~20–40 s trace gap with in-flight spans
  lost; `mimir` and `loki-*` have two each. Never restart the whole StatefulSet at once.

`edge-tofu` needs no propagation step: it reads `consumers/edge/s3` per command, so writing
that path is the propagation. `rots4-ci` reads `consumers/john2143-com/default/rots4-ci-s3` at
build time (§7), so the same applies. `rain-marvel` is `MANUAL` — its consumer is unknown.

## 4. Verification checklist

`verify` proves three things per identity: the consumer Secret holds the newest access key,
every in-scope bucket accepts a **write and a delete** (not merely a list), and an out-of-scope
bucket returns `AccessDenied`. The write probe matters: mimir and tempo write blocks on flush
and the Loki compactor deletes chunks, so a scope that lists but cannot write fails hours later,
silently.

After every rotation, confirm the consumers are actually healthy:

```bash
kubectl --context closet-as-admin -n default rollout status deploy/litellm \
  deploy/john2143-com-worker-220 deploy/frigate-genai-dashboard \
  deploy/frigate-genai-mqtt deploy/frigate-genai-triggers-v288 --timeout=300s
kubectl --context closet-as-admin -n observability rollout status \
  statefulset/mimir statefulset/tempo statefulset/loki-write statefulset/loki-backend --timeout=300s
kubectl --context closet-as-admin -n <ns> logs <pod> --since=15m | grep -c AccessDenied   # want 0
curl -s 'http://loki-gateway.observability.svc/loki/api/v1/labels'                        # non-empty
```

Then the data proof — a bucket that takes writes today must still take them:

```bash
rclone lsf rot:frigate-genai --max-depth 1 --format "tp" | tail -3
```

## 5. Scope syntax — the trap that made `rain-marvel` global

Two forms exist and only one restricts:

```json
{"actions": ["Read", "Write", "List"], "resources": ["buckets/marvel3-logs/"]}   // does NOT restrict
{"actions": ["Read:marvel3-logs", "Write:marvel3-logs", "List:marvel3-logs"]}     // restricts
```

The `resources` list is not consulted for permissions; the identity keeps global reach. The
`Read:<bucket>` form is what `edge-tofu` and `rots4-ci` were already using, and it is the form
this repository should use everywhere. Note also that a global `List` action is what made every
bucket *visible* — bucket visibility follows ownership or `List`.

SeaweedFS's action vocabulary is `Read`, `Write`, `List`, `Tagging`, `Admin`. There is no
`Delete`: object deletion rides on `Write`, which is why the scoped triples above are
sufficient for bucket lifecycle work such as the Loki compactor's.

## 6. Rotating without the script

The script is a convenience. Every step is a small set of commands, and this is the path to use
if it is unavailable:

```bash
umask 077; work=$(mktemp -d /dev/shm/seaweedfs-rotate.XXXXXX)

# 1. read the config out of OpenBao (note: -mount= takes no data/ prefix)
bao kv get -mount=consumers -format=json john2143-com/default/seaweedfs-s3-config \
  | jq -r '.data.data["s3.json"]' > "$work/s3.json"

# 2. issue: append a credential to the identity and replace its actions with the bucket triples
jq --arg name litellm \
   --arg ak "$(openssl rand -hex 10)" --arg sk "$(openssl rand -hex 20)" \
   '(.identities[] | select(.name == $name)) |= (
      .credentials += [{"accessKey": $ak, "secretKey": $sk}]
      | .actions = ["Read:litellm-spend-logs","Write:litellm-spend-logs","List:litellm-spend-logs"]
      | del(.resources))' "$work/s3.json" > "$work/new.json"

# 3. one config version; the filer restarts and both credentials are valid
bao kv put -mount=consumers john2143-com/default/seaweedfs-s3-config s3.json=@"$work/new.json"
kubectl --context closet-as-admin annotate externalsecret seaweedfs-s3-config -n default \
  force-sync=$(date +%s) --overwrite
kubectl --context closet-as-admin -n default rollout status deploy/seaweedfs-filer --timeout=240s

# 4. propagate: write the newest credential into the consumer path under the names it expects
bao kv get -mount=consumers -format=json john2143-com/default/litellm-s3-creds \
  | jq '.data.data | .S3_ACCESS_KEY = $ak | .S3_SECRET_KEY = $sk' \
      --arg ak "$NEW_AK" --arg sk "$NEW_SK" > "$work/holder.json"
# then write it back field-by-field with @file (never on the command line):
#   bao kv put -mount=consumers john2143-com/default/litellm-s3-creds S3_ACCESS_KEY=@"$work/ak" ...
kubectl --context closet-as-admin annotate externalsecret litellm-s3-creds -n default \
  force-sync=$(date +%s) --overwrite

# 5. verify, then retire: drop every credential except the newest and re-write
# 6. shred the workdir
shred -u "$work"/* 2>/dev/null; rm -rf "$work"
```

Never pass a credential as a bare argument — `bao kv put path KEY=value` puts it in `ps`.
Always `KEY=@file` with the file at mode 0600.

## 7. What remains unresolved

- **`rots4-ci`** does not use a GitHub secret. `.github/workflows/build_nix.yml` in
  `2143-Labs/rots4` fetches its key at run time from OpenBao
  `john2143-com/default/rots4-ci-s3` through `scripts/ci-openbao-read.sh` (role
  `rots4-ci-releases`) and reads the fields **`access_key_id`** and **`secret_access_key`**.
  Propagation for this identity is therefore just a write to that path; a rotation that leaves
  it stale breaks the release build with `InvalidAccessKeyId`.
- **`rain-marvel` is gone** (2026-11-10). Its bucket `marvel3-logs` held a single 25-byte file,
  `test_from_py.txt`, whose content was `hello from python script` — a smoke test, never a
  consumer. No workflow, manifest, ConfigMap or repo in the org referenced either name. Identity
  and bucket both deleted, and both are out of the tool's maps now.
- **`shares` is gone** (2026-11-10), along with the `bigjuush` uploader that fed it
  (`fish_functions/bigjuush.fish` and `.config/nas-share.sh` in `John2143/dotfiles`; `juush`
  accepts large files and Seafile covers the rest). The bucket held 13 uploads totalling
  **10.8 GB**, last written 2026-06-25, and anonymous access had already returned 403 — the
  links were dead before the retirement.
- **`tuwunel-media` is gone** (2026-11-10). It was empty, and its S3 backend was deleted in
  `a8dd50d` during the matrix remediation, so nothing could have written to it.
- **`history-old` is kept deliberately.** 5,000+ directories from a single burst on 2026-10-20
  (10:01–10:57), each `<epoch.micros>-<rand>/agent/{messages.json,trace.txt,summary.txt,
  differences.json,display_*.jpg}`: frigate-genai's pre-cutover run archive, superseded the same
  evening by `frigate-genai/history/` with identical naming. No identity can read or write it.

## Gotchas for the next operator

- **`-mount=consumers` takes no `data/` prefix.** `bao kv get -mount=consumers data/john2143-com/…`
  silently resolves to `consumers/data/data/…` and returns nothing, which reads exactly like an
  empty secret. Metadata is `kv metadata get -mount=consumers john2143-com/…`.
- **Deleting a bucket needs no S3 key.** The filer's own API does it:
  `kubectl -n default exec deploy/seaweedfs-filer -- curl -X DELETE
  'http://localhost:8888/buckets/<bucket>/?recursive=true'` returns 204, and a follow-up GET of
  any object inside returns 404. That is how a bucket is removed once its credentials are gone —
  useful for retiring dead buckets without first rotating or reviving a key.
- **A filer restart is the whole outage.** The S3 API, and therefore image serving on 2143.me,
  log/metric/trace writes and CI release pushes, are unavailable for 5–20 s per config write.
  Consumers retry; nothing is lost. Do not start consumer restarts while the filer is still
  restarting, or the two windows combine.
- **`nas` is the single failure domain, so check it before blaming a config write.** Both the
  filer pod (its PVC is a single-replica Longhorn volume pinned to nas) and the volume server's
  `/tank/seaweedfs-data` live there. If nas is unhealthy, a filer rollout cannot schedule or
  attach at all: endpoints stay `ready=false`, `192.168.6.31:8333` refuses connections, and the
  outage lasts until the host is power-cycled. On 2026-11-10 nas stopped heartbeating at
  08:22:48 while still answering ping and with *every* TCP port closed (22, 10250, 2379, 8333) —
  a wedged userland, not a crashed kubelet. Because nas is also an etcd voter, the API VIP
  flaps throughout (quorum holds at 2/3). Diagnostic order: `kubectl get node nas`, then the
  filer's endpoints, then the Longhorn volume's `state/robustness` — the config write is the
  last suspect, not the first.
- **Tempo does not retry its store at startup.** Its init calls `ListObjects` on `tempo-blocks`,
  so any S3 unavailability — a routine filer restart is enough — puts it into
  `CrashLoopBackOff` with `dial tcp …:8333: connect: connection refused`, and the backoff keeps
  growing after the store is healthy again. Delete the pod once S3 answers; it recovers in about
  a minute. It is never a credential problem when the message says `connection refused`.
  If tempo is *still* not ready with S3 healthy, grep the filer log for
  `first read of tempo-blocks/single-tenant/<block>/meta.json`: a failed read there means that
  block's chunk is gone. On 2026-11-10 two such blocks (written 2026-11-04) held `/ready` at 503
  through 213 restarts. The block is unreadable for good — tempo cannot compact or query it —
  so delete it with the same filer `DELETE …?recursive=true` used for buckets; tempo went ready
  40 s after the two were removed.
- **S3 `InternalError` (HTTP 500) is the filer's disk, not the credentials.** When the filer's
  `/data` mount is an ext4 filesystem in the `shutdown` state (visible as `rw,...,shutdown` in
  `/proc/mounts`, with `input/output error` on `filerldb2/*` in the filer log), every metadata
  operation fails with HTTP 500 while some reads still succeed, which looks like a permission
  bug. The metadata lives on a single-replica Longhorn volume; confirm
  `volumes.longhorn.io/<pvc>` is `attached` and `healthy` before restarting the filer, since
  restarting into a broken mount is what turns one bad service into a crashloop.
- **`issue` and `retire` must be batched.** Rotating identity-by-identity multiplies filer
  restarts by seven for no benefit; the overlap window is what makes batching safe.
- **Listing is not writing.** Any future scope change must be verified with a write and a
  delete, not with `ls`.
- **`aws` is not installed on the workstation.** The script and this doc use `rclone` with an
  `RCLONE_CONFIG_ROT_*` environment remote, which keeps keys out of argv and off disk. A remote
  defined in `~/.config/rclone/rclone.conf` is never consulted.
