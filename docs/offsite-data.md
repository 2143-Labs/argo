# Offsite copies of irreplaceable data (immich, the `private` vault, tagged volumes)

**The vault's offsite copy is gocryptfs ciphertext. It is unreadable without the vault
passphrase, which lives in dotfiles as the agenix secret `gocryptfs-passphrase`, decrypted only
on `arch`, `office` and `closet`. If those hosts and the age keys that can decrypt the secret
are lost together, the B2 copy is worthless: keep an escrowed copy of the passphrase elsewhere.**

This is the companion to `docs/db-backups.md`, which covers the CNPG clusters and the Seafile
MariaDBs. It covers the data a database restore cannot bring back: photos, the personal vault,
and the file volumes behind Seafile, Odoo, mail, Home Assistant, the game servers and Matrix.
Nothing that can be rebuilt is copied (PBS/VM images, nix hosts, registries, observability,
frigate recordings, `tank/share`, `tank/private-local`).

## 1. What is copied

All jobs run on the NAS as systemd units defined in dotfiles `nixos/nas-configuration.nix`
(section "Offsite (B2)"). All three buckets are in the home account, region `us-east-005`.

| job | schedule (NAS local time, America/New_York) | source | destination | expires |
|---|---|---|---|---|
| `offsite-immich-db` | daily 05:30 | `pg_dump -Fc immich` (NAS Postgres, root SSD) | `j2143-argo-immich/db/<UTC stamp>.dump` | `db/`: hidden day 31, deleted day 32 |
| `offsite-immich-media` | Sun 05:00 | `/tank/immich` minus `thumbs/`, `encoded-video/` | `j2143-argo-immich/media/` (`rclone copy`) | never |
| `offsite-private` | Sun 04:00 | `zfs send -c tank/private@offsite-<week>` | `j2143-argo-private/zfs/<gen>/<week>[-full].zfs` | `zfs/`: hidden day 120, deleted day 121 |
| `offsite-volumes` | Sun 06:00 | Longhorn backupstore dirs of tagged PVCs | `j2143-argo-volumes/longhorn/<gen>/volumes/<xx>/<yy>/<pvc>/` | `longhorn/`: hidden day 60, deleted day 61 |

Each unit has `OnFailure=notify-failure@%n.service`, which pushes "`<unit>` failed on nas" to the
ntfy topic. `Persistent=true` on every timer re-runs a schedule missed while the NAS was down.

### Generations

Both the vault stream and the Longhorn mirror are *chains*: a vault incremental needs its full
stream, and a Longhorn backup needs blocks uploaded by earlier backups. A lifecycle rule ages
objects by upload date, not by whether anything still references them, so an append-only copy
under one fixed prefix would lose still-needed bases. Each job therefore starts a fresh,
self-contained generation on a fixed calendar:

- **Vault**: `gen-<ISO year>-<ISO week / 13>`. The first run of a generation sends a full stream,
  later runs send incrementals from the previous week's snapshot. 13 weeks (91 days) < 120 days,
  so a generation is complete for about four weeks after the next one starts.
- **Volumes**: `gen-<ISO year>-<ISO week / 4>`. Each generation re-uploads every block, so it is
  complete on its own. 28 days < 60 days, so every backup in a generation stays restorable for
  at least 32 days after the next generation starts.

The year boundary closes a generation early (weeks 52-53 form a short one). That only costs a
re-upload.

### Selecting volumes

A PVC is mirrored when it carries the annotation `offsite.backup/enabled: "true"`. The job
matches `namespace/name` pairs against Longhorn's `status.kubernetesStatus`, so two claims with
the same name in different namespaces are selected independently. Current set (9):

| namespace | PVC | declared in |
|---|---|---|
| `default`, `aross-files` | `seafile-data` | `workloads/seafile/templates/seafile-persistentvolumeclaim.yaml` |
| `odoo-aross`, `odoo-labs` | `odoo-filestore` | `workloads/odoo/templates/pvc.yaml` |
| `default` | `home-assistant-config-lh` | `workloads/home-assistant/home-assistant-pvc-lh.yaml` |
| `default` | `minecraft-data-lh` | `workloads/minecraft/pvc.yaml` |
| `default` | `factorio-saves-lh` | `workloads/factorio/pvc.yaml` |
| `stalwart` | `data-stalwart-stalwart-0` | `workloads/stalwart/pvc.yaml` |
| `matrix` | `tuwunel-conduwuit-data` | **live object only** (see `workloads/tuwunel/BACKUP.md`) |

The job only mirrors what Longhorn has already backed up to the NAS (`RecurringJob/nightly-backup`),
so a tagged volume must also be in that job's group. If no PVC is tagged, or no Longhorn volume
matches, the job logs that and exits 0; if a tagged PVC has no volume or no backupstore
directory, it mirrors the rest and fails (alert).

**A restored or recreated PVC loses a live-only annotation.** Re-apply it before the next Sunday.

## 2. How it is protected

- **Object Lock**: every bucket has default retention COMPLIANCE, 30 days. Nothing, including
  the account owner, can delete an object version for 30 days. Default retention can be set on an
  existing lock-enabled bucket (`b2v4 bucket update --default-retention-mode compliance
  --default-retention-period "30 days" <bucket> allPrivate`); it only applies to uploads made
  after it is set. Check it with `aws s3api get-object-lock-configuration --bucket <bucket>`
  (endpoint `https://s3.us-east-005.backblazeb2.com`): a response with no `Rule` locks nothing.
- **Lifecycle**: one rule per bucket, always scoped to the prefix in the table, never the bucket
  root. `media/` has no rule: originals are written once and kept.
- **Credentials**: one bucket-scoped `Read and Write` application key per bucket, and one SSE-C
  key per bucket. Backblaze never stores SSE-C keys. Both live in the password-manager entry
  `Backblaze argo-db-backups` (`<bucket>-appkey`, `<bucket>-sse`) and in dotfiles
  `secrets/rclone-{immich,private,volumes}.env.age`, which the NAS decrypts to
  `/run/agenix/rclone-<x>-env` (root, 0400). Each file defines the rclone remote `hz` through
  `RCLONE_CONFIG_HZ_*` variables, the same names as `workloads/seafile-db/offsite-backup.yaml`.
- **SSE-C keys cannot be rotated in place.** A new key needs a new prefix and starts a fresh
  history. Losing a key makes that bucket permanently unreadable.
- **Caps**: B2 *enforces* Caps & Alerts (`403 cap_exceeded`). The home account's storage and
  Class B caps must stay well above this footprint, or a sync stops partway and a restore cannot
  start. The values in force are recorded on ai_tasks card #349.

## 2a. Operating the jobs

```bash
ssh nas 'systemctl list-timers --all | grep offsite-'                       # next/last run of each
ssh nas 'systemctl show offsite-volumes -p Result -p ExecMainStatus'        # last result
ssh nas 'sudo journalctl -u offsite-volumes -n 40 --no-pager -o cat'        # rclone summary at the end
ssh nas 'sudo journalctl -u offsite-immich-media -u offsite-private -u offsite-volumes --since -30d | grep -c cap_exceeded'
ssh nas 'sudo systemctl start --no-block offsite-immich-media'              # run one now
```

- A failed run pushes "`<unit>` failed on nas" to ntfy; the unit's journal has the cause.
- `offsite-immich-media` and `offsite-volumes` are plain `rclone copy`: re-running after a failure
  resumes and never duplicates. `offsite-immich-db` and `offsite-private` stream with `rcat`, so a
  re-run writes a new object (harmless, expires with its prefix).
- `offsite-private` keeps its state in `/var/lib/offsite/private.{last,gen}` and sends nothing if
  this ISO week was already sent. Deleting both files forces a full stream on the next run.
- Timers are `Persistent=true`: a run missed while the NAS was down happens at the next boot.

## 2b. Shrinking what gets uploaded

`offsite-private` sends whatever is in `tank/private`. Directories that should never leave the
building are moved to the second vault root, `tank/private-local`, which the job never reads. Each
100 GB left behind saves roughly $11/year, so this is worth doing before the first send — and it can
be done over weeks, with the job held throughout.

The obvious route — `rsync` between the two mounted views on `arch`/`office` — crosses CIFS twice
and encrypts on the client: it was measured at **13.94 MB/s**, about 21 hours for 1.09 TB. Do it on
the NAS instead, in ciphertext space:

- Both roots share one master key (`gocryptfs.conf` was copied, never re-initialised) and a
  byte-identical root `gocryptfs.diriv`, so **a given plaintext name has the same ciphertext name in
  both roots**; every directory also carries its own `.diriv` (32,355 directories = 32,355 dirivs).
- Copying a directory ciphertext-for-ciphertext is therefore self-consistent — no re-encryption, and
  mtimes, xattrs and sparse layout are preserved byte for byte.

Mapping the plaintext name to its ciphertext name needs a control socket, so mount with `-ctlsock`
once:

```fish
fusermount -u ~/private-local
gocryptfs -ctlsock $XDG_RUNTIME_DIR/pvl.sock /mnt/nas/private-local/john ~/private-local

set CIPHER (printf '%s\n' '<dirname>' | gocryptfs-xray -encrypt-paths $XDG_RUNTIME_DIR/pvl.sock)
ssh nas "sudo rsync -aHAX --info=progress2 /tank/private/john/$CIPHER/ /tank/private-local/john/$CIPHER/"
```

`sudo` is not optional: the destination root already holds ciphertext owned by `root`, left by an
earlier copy that did not preserve ownership (`find /tank/private-local/john -type f ! -user john`
as root shows it; as `john` those entries are simply invisible). `rsync` as `john` skips what it
cannot read on *either* side and reports success, and the dry-run afterwards then looks clean
because both sides are equally blind. `-a` preserves uid/gid, and since the source is wholly
`john`-owned, copying as root also repairs the ownership of the earlier copies.

Then gate the delete — the count first, because it is the only check that sees what `rsync` could
not:

```fish
ssh nas "sudo find /tank/private/john/$CIPHER -type f | wc -l"
ssh nas "sudo find /tank/private-local/john/$CIPHER -type f | wc -l"
# these must be equal, then:
ssh nas "sudo rsync -aHAX --dry-run -i --stats /tank/private/john/$CIPHER/ /tank/private-local/john/$CIPHER/"
# exit 0, "Number of regular files transferred: 0", and no -i output lines
ssh nas "sudo rm -rf /tank/private/john/$CIPHER"
```

- Only run this when nothing is writing to that directory. A copy taken mid-write is stale, and the
  dry-run cannot tell a stale copy from a fresh one if sizes and mtimes happen to match.
- The `rm` is ciphertext-side and instantaneous — no FUSE traversal.
- Deleting does not free pool space while `tank/private`'s snapshots still reference it (89
  snapshots, oldest 2026-04). At 13.2 T free this affects the monthly bill, not capacity — but
  `zfs list -o space tank/private` is the honest number, not `du`.
- Leave `/var/lib/offsite/hold` in place for the whole migration; `offsite-private.timer` logs
  `skipped, unmet condition check` every week and uploads nothing.

## 3. Using the remote

On the NAS, as root, load the bucket's env file first:

```bash
sudo bash -c 'set -a; . /run/agenix/rclone-private-env; rclone lsl hz:j2143-argo-private/zfs/'
```

`rclone` lists and reads with the bucket's SSE-C key automatically. Without the key, objects
list but every read fails.

## 4. Restore

### immich database

```bash
sudo bash -c 'set -a; . /run/agenix/rclone-immich-env; rclone lsl hz:j2143-argo-immich/db/ | sort -k4 | tail -3'
sudo bash -c 'set -a; . /run/agenix/rclone-immich-env; rclone copyto hz:j2143-argo-immich/db/<stamp>.dump /dev/shm/immich.dump'
sudo systemctl stop immich-server immich-machine-learning
sudo runuser -u postgres -- dropdb immich
# -T template0: template1 on the NAS carries a glibc collation-version mismatch
# (created under 2.42, OS now 2.44), and createdb from it fails outright.
sudo runuser -u postgres -- createdb -T template0 -O immich immich
# As the superuser and without --no-owner, so objects keep their `immich` owner.
sudo runuser -u postgres -- pg_restore -d immich --exit-on-error /dev/shm/immich.dump
sudo systemctl start immich-server immich-machine-learning
sudo rm /dev/shm/immich.dump
```

The dump carries the `vchord`/`vector` extensions; both the scratch-database variant
(`--no-owner --no-privileges`) and the owner-preserving commands above restored with
`--exit-on-error` and no errors in the 2026-11-19 drill, with every table owned by `immich`.
If a future restore fails only on `CREATE EXTENSION` or `ALTER ... OWNER`, compare
`select count(*) from asset` against what you expect before deciding it failed.

### immich media

```bash
sudo bash -c 'set -a; . /run/agenix/rclone-immich-env; rclone copy hz:j2143-argo-immich/media /tank/immich --transfers 8'
sudo chown -R immich:immich /tank/immich
```

`thumbs/` and `encoded-video/` are not copied; regenerate them from the immich admin jobs page.

### Vault (`tank/private`)

1. Pick the newest complete generation: `rclone lsf hz:j2143-argo-private/zfs/`.
2. In it, start from the **newest** `*-full.zfs`, then apply every later object of the same
   generation in name order (ISO week names sort chronologically):

   ```bash
   gen=gen-YYYY-NN
   sudo bash -c "set -a; . /run/agenix/rclone-private-env; rclone lsf hz:j2143-argo-private/zfs/$gen/" | sort
   # full first, receiving into a new dataset:
   sudo bash -c "set -a; . /run/agenix/rclone-private-env; rclone cat hz:j2143-argo-private/zfs/$gen/<week>-full.zfs" \
     | sudo zfs receive -F tank/private-restored
   # then each later incremental, in order:
   sudo bash -c "set -a; . /run/agenix/rclone-private-env; rclone cat hz:j2143-argo-private/zfs/$gen/<week>.zfs" \
     | sudo zfs receive -F tank/private-restored
   ```

3. If `tank/private` itself is gone, `zfs rename tank/private-restored tank/private`, set
   `mountpoint=/tank/private`, and the existing `private` Samba share serves it again. Mount it on
   `arch`/`office` as usual (`gocryptfs /mnt/nas/private ~/private`). The stream contains
   `john/gocryptfs.conf`; a copy also lives in dotfiles `secrets/gocryptfs-john.conf`.
4. Reset the job's state so the next run sends a fresh full stream:
   `sudo rm /var/lib/offsite/private.last /var/lib/offsite/private.gen`.

### Longhorn volume

Copy the mirrored directory into a backupstore layout, keeping the hashed `<xx>/<yy>/` path
(Longhorn derives it from the volume name). For a restore next to the live target, use a
subdirectory of the existing NFS export: the export is the NFSv4 pseudo-root (`fsid=0`) at
`/tank/longhorn-backups`, so `/tank/longhorn-backups/<dir>` is `nfs://192.168.5.175:/<dir>`.

```bash
v=pvc-...; rel=<xx>/<yy>/$v; gen=gen-YYYY-NN
ssh nas "sudo bash -c 'set -a; . /run/agenix/rclone-volumes-env; \
  rclone copy hz:j2143-argo-volumes/longhorn/$gen/volumes/$rel /tank/longhorn-backups/offsite-restore/backupstore/volumes/$rel'"
kubectl --context closet-as-admin apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: BackupTarget
metadata: {name: offsite-restore, namespace: longhorn-system}
spec: {backupTargetURL: "nfs://192.168.5.175:/offsite-restore", pollInterval: "2m"}
EOF
kubectl --context closet-as-admin -n longhorn-system get backups.longhorn.io \
  -l backup-volume=$v -o custom-columns=NAME:.metadata.name,TARGET:.status.backupTargetName,URL:.status.url,CREATED:.status.backupCreatedAt
```

Wait until `backuptargets.longhorn.io/offsite-restore` reports available, then read the volume's
registry entry (it holds the newest backup id, read straight out of the staged files):

```bash
kubectl --context closet-as-admin -n longhorn-system get backupvolumes.longhorn.io -o json \
  | jq -r '.items[]|select(.spec.backupTargetName=="offsite-restore")
           | "\(.metadata.name) last=\(.status.lastBackupName) at=\(.status.lastBackupAt)"'
```

Restore. **`frontend: blockdev` is mandatory** — omitting it is rejected with
`invalid volume frontend specified`, and with no consumer the volume attaches, finds nothing to
rebuild into, and detaches as `detached/unknown` with `Restore=False`. The volume only rebuilds
from B2 while something mounts it, so create the PV/PVC/pod in the same step:

```bash
kubectl --context closet-as-admin apply -f - <<YAML
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata: {name: restore-drill-vol, namespace: longhorn-system}
spec:
  size: "<volume.cfg Size>"
  numberOfReplicas: 1
  frontend: blockdev
  backupTargetName: offsite-restore
  fromBackup: "nfs://192.168.5.175:/offsite-restore?backup=<backup-id>&volume=<pvc-uuid>"
  accessMode: rwo
---
apiVersion: v1
kind: PersistentVolume
metadata: {name: restore-drill-pv}
spec:
  capacity: {storage: "<volume.cfg Size>"}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: restore-drill-vol
    volumeAttributes: {numberOfReplicas: "1", staleReplicaTimeout: "30"}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: restore-drill-pvc, namespace: offsite-drill}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ""
  volumeName: restore-drill-pv
  resources: {requests: {storage: "<volume.cfg Size>"}}
---
apiVersion: v1
kind: Pod
metadata: {name: restore-drill-pod, namespace: offsite-drill}
spec:
  restartPolicy: Never
  containers:
  - {name: c, image: busybox:1.36, command: ["sh","-c","sleep 3600"],
     volumeMounts: [{name: d, mountPath: /data}]}
  volumes: [{name: d, persistentVolumeClaim: {claimName: restore-drill-pvc}}]
YAML
kubectl --context closet-as-admin -n offsite-drill wait --for=condition=Ready pod/restore-drill-pod --timeout=300s
kubectl --context closet-as-admin -n longhorn-system get volume restore-drill-vol \
  -o jsonpath='{.status.state}/{.status.robustness}{"\n"}'      # attached/healthy
```

Read the data *before* deleting anything — health alone is not proof of content:

```bash
kubectl --context closet-as-admin -n offsite-drill exec restore-drill-pod -- \
  sh -c 'du -sh /data; ls -la /data/data/db | grep -E "CURRENT|MANIFEST"; ls /data/data/db/*.sst | wc -l'
```

Every application keeps its own layout, so verify against that app's expectations rather than
file counts alone. Tuwunel's real database is `/data/data/db`, not `/data/db`: the latter is a
stale pre-migration directory, and reading it first looks like corruption (`CURRENT` absent).
A restored RocksDB is consistent when `CURRENT`, `MANIFEST-*` and the `.sst` files carry
timestamps matching the backup's `lastBackupAt`.

Then delete, in this order: pod, PVC, PV, `Volume`, `BackupTarget`, the `offsite-drill`
namespace, and `/tank/longhorn-backups/offsite-restore`. Re-apply
`offsite.backup=enabled=true` to the real PVC if it was restored in place.


If the NAS itself is gone, rebuild it from dotfiles, recreate `tank/longhorn-backups`, copy the
generation into `backupstore/volumes/` there, and the default target sees it directly.

## 5. Drills

Each class was restored from B2 before this was called done. Record each future drill here.

| date | class | what was restored | result |
|---|---|---|---|
| 2026-11-19 | immich database | first dump `20261119T054248Z.dump` (95 MiB, 663 TOC entries) into scratch `immich_drill`, both variants | `asset` 22388 = live 22388; 86 = 86 tables; all tables owned by `immich` |
| 2026-11-19 | immich media | `upload/…/abc1b60d-….JPG` (4,270,080 B) fetched with `rclone cat` from `media/` using the SSE-C key | sha256 identical to the local file; full `rclone check --size-only` 35,335 match, 2 diffs both in rotating `backups/` |
| 2026-11-19 | Longhorn volume | `tuwunel-conduwuit-data` (4 GiB, 30 restore points) staged from `longhorn/gen-2026-11` into a scratch NFS backupstore, restored `fromBackup` | `attached/healthy`; `/data/data/db` held `CURRENT`, `MANIFEST-002330`, 95 `.sst` files, timestamps matching `lastBackupAt` 2026-11-11T08:01:42Z |
