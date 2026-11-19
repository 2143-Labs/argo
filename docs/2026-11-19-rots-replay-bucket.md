# ROTS tutorial replays: the bucket, its identity, and retention

**Date:** 2026-11-19
**Status:** live in prod since 2026-11-19 06:53Z, and a played tutorial went through it at 07:02Z
(see *Verified*).
**Scope:** bucket `rots4-replays`, identity `rots-sync`, `apps/rots-web.yaml`,
`workloads/rots-web` (templates `_gameserver.tpl`, `sync.yaml`, `values.yaml`),
`workloads/network-policies/seaweedfs.yaml`.

## What it is

When a **tutorial** world ends cleanly, the game pod posts its recording to `rots-sync`
(`POST /internal/v1/sync/recording`, bearer `COORDINATOR_TOKEN`), and `rots-sync` signs a
path-style S3 `PUT` into `s3://rots4-replays/replays/<slot>-<generation>-<boot_id>.rotsrec`
plus one row in `social.instance_recordings` (rots4's `docs/netcode.md` and
`docs/design.html` describe the flow; `docs/decisions.md` records why the upload lives in
`rots-sync` and not in the pod).

Towns, every other world, and instances without `ROTS_REPLAY_UPLOAD` upload nothing: the
chart sets that flag from `gameserver.replayUpload`, which is `true` only in
`apps/rots-web.yaml` (prod). A preview leaves it false, so it has no S3 configuration and no
warnings.

## The bucket

Created 2026-11-19 in the filer (`weed shell` on `default/seaweedfs-filer`):

```
s3.bucket.create -name rots4-replays
```

It is private - no anonymous read or write - and path-style only, like every bucket here:
`http://seaweedfs-s3.default.svc:8333`, region `us-east-1`, bucket in the path, never in the
host. `rots-sync` learns the endpoint and bucket from `ROTS_S3_ENDPOINT` / `ROTS_S3_BUCKET`
(set in `sync.yaml`), and the keys from the authserver secret (below).

## The identity

`rots-sync` in `scripts/seaweedfs-rotate.py`:

| Identity | Buckets | Consumer |
|---|---|---|
| `rots-sync` | `rots4-replays` | OpenBao `john2143-com/rots-prod/rots-authserver-secret`, keys `ROTS_S3_ACCESS_KEY` / `ROTS_S3_SECRET_KEY`, ExternalSecret `rots-prod/rots-authserver-secret` |

`Read:`/`Write:`/`List:` on that one bucket, nothing else. The keys ride on the authserver's
existing secret because `rots-sync` already consumes it with `envFrom`; the authserver and
the game pods never read them. Game pods therefore still hold no S3 credential at all - the
recording travels over the internal HTTP route.

`propagate` reads the existing OpenBao entry and writes it back with the two keys added, so
`TICKET_SIGNING_KEY`, `COORDINATOR_TOKEN` and the rest survive; it never replaces the entry.

## Retention

Seven days, twice over:

- `social.instance_recordings` rows older than seven days are deleted on every claim (rots4's
  `authserver/src/sync.rs`).
- The object behind a deleted row is deleted with it, so the bucket cannot outlive the table.

There is deliberately **no bucket lifecycle rule**: the workstation has no `aws` CLI, and the
lifecycle configuration is itself a signed S3 call. Deleting from `rots-sync` keeps the
object and the row on exactly the same clock, which a lifecycle rule cannot do (the rule
would fire up to a day late, leaving rows pointing at missing objects).

## Issuing the identity

`issue` and `propagate` need an `openbao-admin` token, which is an interactive OIDC login.

```bash
cd ~/repos/argo
bao login -method=oidc
scripts/seaweedfs-rotate.py issue rots-sync --apply      # one s3.json write, one filer restart
scripts/seaweedfs-rotate.py propagate rots-sync --apply  # keys onto the authserver secret
```

Then force the ExternalSecret (10 minute refresh otherwise) and restart `rots-sync`, which
reads the store at boot:

```bash
kubectl -n rots-prod annotate externalsecret rots-authserver-secret force-sync=$(date +%s) --overwrite
kubectl -n rots-prod rollout restart deploy/rots-sync
```

`rots-sync` logs `replay store ready endpoint=... ` once all four variables are set; before
that it logs one `replay store half-configured` warning and answers 503.

## Verified 2026-11-19 06:53Z

Prod rolled `authserver-1070262` and `gameserver-1070262`; `rots-sync` logged `replay store
ready`, and a live instance carried `ROTS_REPLAY_UPLOAD=1`.

A throwaway `curlimages/curl` pod in `rots-prod` (the store is ClusterIP-only, so the probe had
to run in-cluster, with `COORDINATOR_TOKEN` from `secretKeyRef` rather than read anywhere)
posted a 21-byte recording for slot 999:

- `POST /internal/v1/sync/recording` → `204`, so SeaweedFS **accepted the hand-rolled SigV4
  `PUT`** — the one thing neither PR could test locally.
- `rots-sync` logged `recording stored key=replays/999-1-probe-20261119.rotsrec`.
- The row appeared (`bytes=21, steps=42, truncated=f`), and `s3.bucket.list` went from 0 to
  144 bytes with one chunk.
- Backdating the row to eight days and issuing a `claim` swept it: `expired recordings removed
  recordings=1`, the row count went to 0, and the bucket's chunk count returned to 0 — the
  signed `DELETE` works too, and the object went with the row.

The probe pods, its snapshot row and its recording are gone.

### A real tutorial, 07:02Z

Then a tutorial was actually played on prod (slot 875, generation 169):

- `101716` bytes / `2701` steps, `truncated=false` — about 38 B/tick, so the 8 MiB body limit is
  roughly 200× a tutorial like this one (the v1 estimate of 23-52 min was pessimistic, not wrong
  in kind).
- `rots-sync` logged `recording stored key=replays/875-169-ca209fca88d390cb.rotsrec`; the bucket
  went to 101816 bytes / 1 chunk and `fs.ls /buckets/rots4-replays/replays/` lists the file.
- The instance workflow's own `server` query carried
  `"recording":{"boot_id":"ca209fca88d390cb","bytes":101716,"object_key":"replays/875-169-ca209fca88d390cb.rotsrec","steps":2701,"truncated":false}`,
  so the signal lands before the workflow ends.
- The instance's pod was already gone (a tutorial completes and the instance is destroyed), so its
  own `recording stored in rots-sync` line could not be read after the fact; the row and the object
  are the authority, which is the design.

Not exercised: the rollback (clearing `gameserver.replayUpload`), which is the argo parameter and a
unit test, and reading a stored object back — `rots-sync` signs `PUT` and `DELETE` only, so there is
no GET to fetch one for `server --replay`.

```bash
kubectl -n rots-prod logs deploy/rots-sync --since=5m | grep "recording stored"
kubectl -n rots-prod exec rots-db-2 -c postgres -- psql -U postgres -d rots \
  -c "select slot, generation, bytes, steps, truncated, created_at from social.instance_recordings order by created_at desc limit 3"
```

## Rollback

Delete `gameserver.replayUpload` from `apps/rots-web.yaml` and sync: the pod stops setting
`ROTS_REPLAY_UPLOAD`, `rots-sync` stops getting `ROTS_S3_*`, and no upload is attempted. The
bucket and the rows can stay.
