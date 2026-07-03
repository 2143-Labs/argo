# Tuwunel Matrix Stack — Backup & Recovery

## Automated Backups

### RocksDB (Longhorn)
- **Schedule**: Daily at 3am (UTC), via `nightly-backup` RecurringJob in `longhorn-system`
- **Retention**: 30 backups
- **Volume**: `tuwunel-conduwuit-data` (4Gi, Longhorn StorageClass)
- **Recurring Job Group**: `default` (label: `recurring-job.longhorn.io/default=enabled`)
- **Note**: The backup label is applied via `kubectl label pvc -n matrix tuwunel-conduwuit-data recurring-job.longhorn.io/default=enabled`
  - ArgoCD selfHeal may remove this label. If re-adding, run:
    ```
    kubectl label pvc -n matrix tuwunel-conduwuit-data recurring-job.longhorn.io/default=enabled --overwrite
    ```

### Media (SeaweedFS)
- Media is stored in the `tuwunel-media` S3 bucket at `files.john2143.com`
- SeaweedFS has its own replication/backup strategy (managed separately)
- No additional backup needed from the Matrix side

### Configuration (ArgoCD GitOps)
- All Kubernetes manifests and Helm values are in `2143-Labs/argo` repo
- ArgoCD manages sync automatically
- Recovery: ArgoCD will restore the entire stack from the git state

## Manual Backup Procedures

### Critical: Tuwunel Signing Key
The signing key is stored in the RocksDB database on the Longhorn PVC.
- If the full RocksDB database is restored from backup, the signing key is preserved
- If restoring to a fresh database, a new signing key is generated (invalidates all existing sessions)

### Longhorn Snapshot Recovery
1. Open Longhorn UI (longhorn.ts.2143.me)
2. Navigate to Volume → `pvc-8f90af86-480f-46af-8067-18228b3539c4`
3. Select the snapshot/backup to restore
4. Click "Restore to new volume"
5. Create a new PVC from the restored volume
6. Update the Tuwunel StatefulSet to use the new PVC

### Full Disaster Recovery
1. ArgoCD syncs the entire stack from the argo repo
2. Longhorn volume restores from backup
3. Update the StatefulSet to point at the restored volume
4. Tuwunel will start with the restored RocksDB

## Cleanup Notes
- Stale PVs from chart redeploys should be cleaned up periodically
- Current PV cleanup command:
  ```
  kubectl get pv | grep Released | grep tuwunel | awk '{print $1}' | xargs kubectl delete pv
  ```
