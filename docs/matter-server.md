# Matter server

Home Assistant's Matter controller: one `hostNetwork` pod pinned to `big`, `strategy: Recreate`, reachable by Home Assistant through the `matter-server` Service on port 5580. Manifests live in `workloads/home-assistant/matter-server-deployment.yaml` and `matter-server-service.yaml`.

The image is pinned by digest. A mutable tag is how a storage-format change arrives without review — never go back to `:stable`.

## The two files that are the whole state

`/data` holds exactly two things that matter:

- **`chip.json`** — CHIP's key/value store. Its top-level keys are always `sdk-config` and `repl-config`; the fabric lives *inside* `sdk-config` under `f/<fabric index>/…` (root key, fabric info, group key, per-node session entries). Reading only the top level shows two keys on a perfectly healthy store.
- **`<compressed_fabric_id>.json`** — the commissioned nodes, named after the fabric that produced them (`matter_server/server/storage.py`). It is unreachable unless `chip.json` still holds that exact fabric.

Losing the fabric does not delete the node file; it orphans it. The server then mints a new fabric, writes `<new id>.json`, and starts with zero devices while the old node file sits there intact. That is what happened on 2026-10-20.

## The fabric guard

An `initContainer` named `fabric-guard` runs before the server. It copies `chip.json` to `/tmp`, derives the fabric's `compressed_fabric_id` with the image's own CHIP library, and compares it against the node files on disk:

- any node file with devices, and the fabric's own file has them → `fabric-guard OK: fabric=<id> nodes=<n>`
- any node file with devices, but the fabric resolves elsewhere → prints `FATAL: this server's fabric is <a> but the commissioned nodes are in [...]` and exits 1, so the pod stays in `Init:Error` instead of silently running empty.

A key-count rule cannot do this job: the 2026-10-20 loss left a fresh fabric that also had `f/` keys, just no devices. Only the fabric identity distinguishes them.

`chip.json` is never modified by the guard (it works on a copy); CHIP does rewrite its own `chip_*.ini` counters in `/data`, which is expected.

## Checking it is healthy

After any image change, restart, or volume change, require a non-zero node count before calling it done:

```sh
kubectl -n default exec -i deploy/matter-server -- python - <<'PY'
import asyncio, json, aiohttp
async def main():
    async with aiohttp.ClientSession() as s:
        async with s.ws_connect("ws://127.0.0.1:5580/ws", max_msg_size=0) as ws:
            await ws.send_json({"message_id": "1", "command": "get_nodes"})
            while True:
                m = await asyncio.wait_for(ws.receive(), timeout=20)
                if m.type == aiohttp.WSMsgType.TEXT and json.loads(m.data).get("message_id") == "1":
                    print("node_count=", len(json.loads(m.data)["result"])); return
asyncio.run(main())
PY
```

The server also logs `Loaded N nodes from stored configuration` at startup, and `fabric-guard OK` on every boot. A restart that loses nodes is the failure this guard exists to make impossible to miss.

## Restoring from a backup

Longhorn has no in-place revert; a restore creates a new volume.

1. Declare a `longhorn.io/v1beta2` `Volume` with `spec.fromBackup` set to the backup's `status.url`, `spec.size` as the backup's `status.volumeSize` **quoted** (the webhook rejects `5Gi`), `numberOfReplicas: 3`, `frontend: blockdev`, `dataEngine: v1`, `accessMode: rwo`, and the label `recurring-job-group.longhorn.io/default: enabled`. Omit `spec.image` so the volume takes the cluster default engine.
2. Declare a static PV/PVC pair on the `longhorn-static` class with `csi.volumeHandle` equal to the volume name and `persistentVolumeReclaimPolicy: Retain`. Use the volume's exact byte count as capacity, not a rounded `5Gi`.
3. Prove the volume before cutting over: mount it read-only in a throwaway pod and run the same fabric-id computation the guard uses. A populated node file plus a fabric id that matches it is the gate; anything else means the backup predates the fabric.
4. Point `claimName` at the new PVC and let Argo sync.

The `Volume` CR keeps `fromBackup` in git permanently — it is only read at creation. Deleting and recreating the CR silently re-seeds the old backup, so repoint `fromBackup` at a current backup *before* any deliberate recreate.

Current chain: volume/PV/PVC `matter-server-data-oct17`, restored 2026-10-17. The previous chain — PVC `matter-server-data-aug7` → PV/volume `pvc-10554d43-5955-4cb3-875a-e9300e6800a6` — is retained as the rollback; rollback is a one-line `claimName` revert.

## Backups

The volume carries `recurring-job-group.longhorn.io/default: enabled`, which puts it in the `nightly-backup` RecurringJob (`0 3 * * *`, `retain: 30`) declared in `workloads/storage/longhorn-backup-job.yaml`. A volume without that label is outside every backup — check the label first if `lastBackupAt` stays empty.
