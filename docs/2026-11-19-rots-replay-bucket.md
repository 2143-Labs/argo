# ROTS tutorial replays: the bucket, its identity, and retention

**Date:** 2026-11-19
**Status:** bucket and chart wiring landed; the identity still needs one `issue`/`propagate`
run with an admin token (see *Remaining*), so uploads answer 503 until then.
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

## Remaining

The bucket exists but the credential does not: `issue` and `propagate` need an
`openbao-admin` token, which is an interactive OIDC login.

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

Verify with a played tutorial in prod: the pod logs `recording stored in rots-sync`,
`rots-sync` logs `recording stored`, and the row appears:

```bash
kubectl -n rots-prod exec rots-db-2 -c postgres -- psql -U postgres -d rots \
  -c "select slot, generation, bytes, steps, truncated, created_at from social.instance_recordings order by created_at desc limit 3"
```

Until this runs, every finished tutorial logs `recording not stored` on the pod and
`replays_unconfigured` (503) in `rots-sync`; nothing else is affected, and the recording is
lost exactly as it was before the feature existed.

## Rollback

Delete `gameserver.replayUpload` from `apps/rots-web.yaml` and sync: the pod stops setting
`ROTS_REPLAY_UPLOAD`, `rots-sync` stops getting `ROTS_S3_*`, and no upload is attempted. The
bucket and the rows can stay.
