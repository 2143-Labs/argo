# Offsite database backups

Ransomware-resistant offsite backups for every production Postgres cluster and both
Seafile MariaDBs. Objects live in Backblaze B2 under a COMPLIANCE-mode Object Lock, so
nothing can delete them for 30 days — not the in-cluster key, not the account owner, not
Backblaze support.

This documents what is backed up, how it is protected, and how to restore. Everything here
was exercised against the real buckets before the first cluster was switched on.

## 1. What is backed up

Nine CloudNativePG clusters, via the Barman Cloud plugin (chart `0.9.0`, plugin
`v0.16.0`), with continuous WAL archiving plus a daily base backup:

| namespace | cluster | bucket | schedule (UTC) |
|---|---|---|---|
| `default` | `asciinema-db` | home | `04:00` |
| `default` | `pelican-db` | home | `04:10` |
| `steam-lobby` | `steam-lobby-db` | home | `04:20` |
| `mattermost` | `mattermost-db` | home | `04:30` |
| `odoo-aross` | `odoo-db` | business | `04:40` |
| `odoo-labs` | `odoo-db` | business | `04:40` |
| `rots-prod` | `rots-db` | home | `04:50` |
| `default` | `temporal-db` | home | `05:00` |
| `default` | `litellm-db` | home | `05:15` |

Two MariaDB dumps, via the `seafile-mariadb-offsite` CronJob:

| namespace | bucket | schedule (UTC) |
|---|---|---|
| `default` | home | `05:30` |
| `aross-files` | business | `05:45` |

Buckets, both in `us-east-005` but in **two different Backblaze accounts**:

- `j2143-argo-db-backups-home` — home apps and `default`'s Seafile dump
- `j2143-argo-db-backups` — business data: both Odoo databases, `aross-files`

Prefixes. Everything this system writes is under `databases/`, because the bucket root is
reserved for future Longhorn backups:

- Postgres: `databases/cnpg/<namespace>/<cluster>/` (base backups in `base/<id>/`, WAL in `wals/`)
- MariaDB: `databases/mariadb/<namespace>/seafile-mariadb/<timestamp>.sql.gz` + `.sha256`
- Gate artefacts: `databases/preflight/` (expire on the normal 31-day cycle)

**Not backed up here:** SQLite-backed apps and filestores. Those rely on Longhorn →
NAS, which is a different copy in the same building. This system exists so a database
does not depend on that.

## 2. Protection model

Three independent things have to all be defeated before a backup is lost:

1. **Object Lock, COMPLIANCE mode, 30 days** on both buckets. Applied as the *default
   bucket retention*, because barman sends no retention header of its own — a bucket with
   the lock on but no default retention silently uploads unlocked objects. Anyone with any
   key is refused: verified 2026-11-11 by attempting a delete with a key holding both
   `deleteFiles` and `bypassGovernance`, which returned `Access Denied`.
2. **A delete timer that nobody has to run.** Lifecycle rule on both buckets:
   `{prefix: databases/, daysFromUploadingToHiding: 31, daysFromHidingToDeleting: 1}`.
   Each object is hidden at day 31 and purged at day 32, which is legal only because the
   lock expired at day 30. The rule is scoped to `databases/` on purpose: a root-level
   rule would expire any future Longhorn prefix at day 31 too. **Never widen it.**
3. **A writer key that cannot do much.** The in-cluster key is scoped to one bucket with a
   `databases/` name prefix, so it cannot touch the bucket root.

### Known weakness: the writer key is not write-only

Backblaze's console can only create keys as `Read and Write`, `Read Only` or `Write Only`.
"Write Only" is unusable — barman must read for restores and for
`serverRecoveryWindow` — and a minimal capability list needs `writeKeys`, which the
operator's admin keys do not have. So the in-cluster key carries the full read/write set,
including `deleteFiles` and `writeBucketRetentions`.

What that means in practice:

- Objects already written are still safe. The COMPLIANCE lock is what protects them, and
  nothing can bypass it.
- A stolen writer key could lower the bucket's **default retention**, which would leave
  *future* uploads unlocked while uploads keep succeeding. That is the one real gap.
- It is watched: the `db-backup-bucket-check` CronJob (`workloads/db-backup-check/`, one
  per bucket, every 6 hours) asserts the lock config is still `COMPLIANCE/30d` and that the
  newest object is SSE-C and carries ~30 days of retention, exiting non-zero on drift,
  which fires `db-backup-config-drift`.
- It also **re-applies** `COMPLIANCE/30d` when it finds the default retention changed, so
  a weakened bucket heals within one run. If you ever change the retention on purpose,
  change the check's `EXPECT_DAYS` and the heal target in the same commit, or it will
  put the old value back.

If you ever want a genuinely write-only key: take the account's **master application key**
from the console, mint one with exactly `listBuckets,listFiles,readFiles,writeFiles` and
`--name-prefix databases/`, then stop using the master key again.

### SSE-C

Every object is encrypted with a 32-byte customer key. Backblaze stores only a hash of it,
so it cannot decrypt anything and cannot help you if the key is lost.

- One key serves both buckets. The per-bucket boundary that matters is the writer key.
- It is **never rotated in place.** A new key requires a new `destinationPath`; existing
  objects stay readable only with the old key.
- Escrowed in the password manager entry **`Backblaze argo-db-backups`**.
- In OpenBao at `john2143-com/default/db-backup-s3` (home) and
  `john2143-com/default/db-backup-s3-biz` (business), rendered into Secret `db-backup-s3`
  by ESO in each namespace.

## 3. Restore a CNPG cluster

Restore **beside** production, under a new name, and never over the live Cluster.

Create a throwaway namespace and copy the credential Secret into it:

```bash
kubectl create namespace db-restore-drill
kubectl -n <source-ns> get secret db-backup-s3 -o json \
  | jq '{apiVersion:"v1",kind:"Secret",type:.type,metadata:{name:"db-backup-s3",namespace:"db-restore-drill"},data:.data}' \
  | kubectl apply -f -
```

Apply an ObjectStore pointing at the source prefix — the `destinationPath` names the bucket
explicitly, and barman appends `serverName`:

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata: {name: drill-source, namespace: db-restore-drill}
spec:
  configuration:
    destinationPath: s3://j2143-argo-db-backups-home/databases/cnpg/default
    endpointURL: https://s3.us-east-005.backblazeb2.com
    s3Credentials:
      accessKeyId:     {name: db-backup-s3, key: ACCESS_KEY_ID}
      secretAccessKey: {name: db-backup-s3, key: ACCESS_SECRET_KEY}
      region:          {name: db-backup-s3, key: REGION}
      sseCustomerKey:  {name: db-backup-s3, key: SSE_CUSTOMER_KEY}
```

Then the recovery Cluster. No `plugins` block, so it does not archive:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: asciinema-db-drill, namespace: db-restore-drill}
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16.6
  storage: {size: 10Gi, storageClass: local-path}
  bootstrap:
    recovery:
      source: origin
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters: {barmanObjectName: drill-source, serverName: asciinema-db}
```

For point-in-time recovery, add `bootstrap.recovery.recoveryTarget.targetTime` (RFC3339)
or `targetName: <backup-id>`. Without it you get the latest recoverable state.

Watch the recovery, then verify:

```bash
kubectl -n db-restore-drill get jobs                     # <cluster>-1-full-recovery
kubectl -n db-restore-drill logs -f job/<that-job> --all-containers > /tmp/drill.log
kubectl -n db-restore-drill wait --for=condition=Ready cluster/asciinema-db-drill --timeout=30m
```

Pass criteria, in order of strength:

- the log contains `restored log file` — WAL was fetched and decrypted from the bucket;
- per-table row counts match production (drill counts may be lower, from an older base,
  but the table list must be identical):

```sql
SELECT format('%I.%I',schemaname,relname),
       (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I',schemaname,relname),
        false, true, '')))[1]::text::bigint
FROM pg_stat_user_tables ORDER BY 1;
```

Clean up with `kubectl delete namespace db-restore-drill` — `local-path` PVs go with it.

### Replacing production data

Never point production at a restored Cluster. Instead: scale the app to 0, `pg_dump -Fc`
from the restored cluster, then `pg_restore --clean --if-exists` into the production
database, and scale the app back up.

## 4. Disaster restore (cluster or OpenBao gone)

1. Recreate the credential Secret from the password manager, without writing plaintext to disk:

```bash
W=$(mktemp -d /dev/shm/dbrestore-XXXXXX)
printf '%s' '<ACCESS_KEY_ID from manager>'     > $W/ACCESS_KEY_ID
printf '%s' '<ACCESS_SECRET_KEY from manager>' > $W/ACCESS_SECRET_KEY
printf '%s' '<SSE_CUSTOMER_KEY from manager>'  > $W/SSE_CUSTOMER_KEY
printf 'us-east-005' | head -c -1              > $W/REGION
kubectl -n <ns> create secret generic db-backup-s3 --from-file=$W/ACCESS_KEY_ID \
  --from-file=$W/ACCESS_SECRET_KEY --from-file=$W/SSE_CUSTOMER_KEY --from-file=$W/REGION
shred -u $W/*
```

2. Ensure the plugin is installed (`apps/plugin-barman-cloud.yaml`), then apply the
   ObjectStore and the recovery Cluster from §3. Nothing else is needed: the bucket,
   the lock and the lifecycle are server-side.

## 5. Tampered or overwritten objects

The lock prevents overwriting a locked version, so tampering means "a *newer* version was
written over an older key, or objects were added". Backblaze's versioning is hide-based, so
`rclone --s3-version-at` does not apply; use the B2 CLI.

```bash
# list every version of a prefix, newest first
b2 ls --versions b2://<bucket>/databases/cnpg/<ns>/<cluster>/wals/0000000100000000/

# pull a specific good version by id (needs an admin key; writer keys can read)
b2 download-file-by-id <fileId> /tmp/<name>
```

Recover into a new prefix (for example `databases/cnpg/<ns>/<cluster>-recovered/`), point
a drill ObjectStore at it, and restore as in §3. Versions written before the tampering stay
available until they expire at day 31, so act inside that window.

## 6. Seafile MariaDB restore

```bash
# download the newest pair for a namespace (home bucket shown; business uses the other)
rclone copy hz:j2143-argo-db-backups-home/databases/mariadb/default/seafile-mariadb/ /tmp/seafile/ --max-age 48h
cd /tmp/seafile && sha256sum -c *.sha256
```

Then load into an empty MariaDB 11.4:

```bash
podman run -d --name dbb-mariadb -e MARIADB_ROOT_PASSWORD=drill -v /tmp/seafile:/w:ro mariadb:11.4
podman exec dbb-mariadb sh -c 'gunzip -c /w/<file>.sql.gz | mariadb -uroot -pdrill'
podman exec dbb-mariadb mariadb -uroot -pdrill -e \
  "SELECT table_schema, COUNT(*) FROM information_schema.tables
   WHERE table_schema IN ('ccnet_db','seafile_db','seahub_db') GROUP BY 1"
podman rm -f dbb-mariadb
```

Expected table counts: `ccnet_db` 13, `seafile_db` 46, `seahub_db` 127. A restore is only
proven when those match.

## 7. WAL-archive outage lever

Every cluster switches WAL segments every 5 minutes (`archive_timeout`). While archiving
fails, segments accumulate at roughly 4.6 GB/day per cluster, so the 4 Gi WAL volume fills
in about 18–21 hours and Postgres stops accepting writes.

The alerts give you the countdown:

- `db-wal-archive-backlog` — more than 12 ready segments, about an hour of backlog.
- `db-wal-volume-filling` — WAL volume over 70% full. This is the hard deadline.

If the object store is unreachable and the volume is filling, set `isWALArchiver: false`
on the affected Clusters via PR (this restarts them, one switchover each) and re-enable it
afterwards. The first scheduled backup after re-enabling starts a fresh chain; the old
objects expire on their normal timer, so there is nothing to clean up.

## 8. Writer-key rotation

The in-cluster key can be replaced without touching backups:

1. Create the new key in the console: same bucket, `databases/` prefix, `Read and Write`.
2. Update the OpenBao entry (`db-backup-s3` or `db-backup-s3-biz`) with the new
   `ACCESS_KEY_ID`/`ACCESS_SECRET_KEY`.
3. Wait for ESO (`refreshInterval: 10m`), or bounce the ExternalSecret:

```bash
kubectl -n <ns> annotate externalsecret db-backup-s3 force-sync=$(date +%s) --overwrite
```

4. Restart nothing — the plugin sidecar re-reads credentials per operation.
5. Delete the old key in the console once the next backup completes.

The SSE-C key is a different matter: rotating it requires a new `destinationPath` and
starts a fresh history (§2).

## 9. Housekeeping

`retentionPolicy` is deliberately unset: the writer key cannot delete, so CNPG never
removes `Backup` objects. One object per cluster per day accumulates. Objects older than
32 days point at data that the lifecycle rule has already expired, so they are safe to
remove monthly:

```bash
kubectl get backups.postgresql.cnpg.io -A -o json \
  | jq -r '.items[] | select(.metadata.creationTimestamp < (now - 35*86400 | todate))
           | "\(.metadata.namespace) \(.metadata.name)"' \
  | while read -r ns n; do kubectl -n "$ns" delete backups.postgresql.cnpg.io "$n"; done
```

Deleting a `Backup` object never touches the bucket.

## 10. Rollback

Each phase is its own PR. To undo one, revert its merge commit on a fresh branch:

```bash
git revert -m 1 <merge-sha>   # on a new worktree branch, then PR
```

Revert in reverse order (the Seafile PR first). Revert the plugin PR
(`cnpg: barman-cloud plugin, ...`) only after every Cluster PR is reverted — a Cluster
whose plugin is missing stops archiving and fills its WAL volume. Reverting a Cluster PR
restarts that cluster once more.

Argo prunes the ObjectStore and ScheduledBackup; the `Backup` objects go with the
ScheduledBackup (`backupOwnerReference: self`). Objects already in the bucket stay locked
and expire on their own — there is nothing to delete, and nothing that can be deleted.

To abandon the bucket entirely: delete the writer keys, delete the OpenBao entries, and
delete the buckets after ~32 days once the lifecycle rule has emptied them.
