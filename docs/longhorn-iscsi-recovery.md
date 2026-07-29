# Longhorn iSCSI Recovery — Troubleshooting Guide

## Symptom

Longhorn engine pods crash-looping with `iscsiadm` errors. Volumes stuck in `attaching` state, pods unable to start.

The engine's init sequence calls `iscsiadm --logout` on old sessions before creating new ones. When that logout fails, the engine exits.

## Root Causes (check in this order)

### 1. Missing Kernel Modules

The iSCSI target kernel modules (`target_core_mod`, `iscsi_target_mod`) are not loaded. This happens after a kernel update or on nodes where they aren't configured to load at boot.

**Check:**
```bash
lsmod | grep iscsi_target
```

If output is empty, modules are missing.

**Fix:**
```bash
sudo modprobe target_core_mod iscsi_target_mod
```

**Verify:**
```bash
lsmod | grep target
# Should show iscsi_target_mod with 1 user, target_core_mod with 2 users
```

After loading modules, restart the instance-manager:
```bash
kubectl -n longhorn-system delete pod \
  $(kubectl -n longhorn-system get pods \
    -l longhorn.io/component=instance-manager \
    --field-selector spec.nodeName=<node> -o name)
```

### 2. Stale iSCSI File Database

Orphaned entries in `/etc/iscsi/nodes/` cause the engine to try logging out of sessions whose targets no longer exist.

**Check:**
```bash
ls /etc/iscsi/nodes/
```

**Fix:**
```bash
sudo iscsiadm -m node --logoutall=all
sudo iscsiadm -m node --op=delete
```

Then restart the instance-manager (see above).

### 3. Stuck Kernel iSCSI Sessions

`iscsiadm -m node --logoutall=all` + `--op=delete` only cleans the file-based node database (`/etc/iscsi/nodes/`). Sessions that are already active in the kernel (`/sys/class/iscsi_session/`) survive database wipes. If the target IP for a kernel session is dead, `iscsiadm --logout` on that session fails (error 32: "target likely not connected"), and the engine crashes.

**Check:**
```bash
sudo iscsiadm -m session
```

Sessions to dead IPs (targets that no longer exist) will show up here.

**Fix — force-logout individual dead sessions:**
```bash
sudo iscsiadm -m session -r <sid> -u
```

If `iscsiadm -u` fails with "target likely not connected" (error 32), use sysfs to force-delete:
```bash
echo 1 | sudo tee /sys/class/iscsi_session/session<N>/device/delete
```

**Fix — nuclear option (reboot the node):**

If there are many stuck sessions or sysfs delete paths don't exist, the simplest fix is a node reboot. All kernel iSCSI state is cleared, and Longhorn recreates connections after k3s restarts.

Make sure `boot.kernelModules` is configured (see Prevention below) so modules load on boot.

After any fix, restart the instance-manager.

## Prevention

Add kernel modules to the NixOS configuration so they persist across reboots:

```nix
boot.kernelModules = [
  "target_core_mod"
  "iscsi_target_mod"
];
```

This is already applied on `closet`, `nas`, and `arch`.

## Recovery Order

1. **Load modules** — `modprobe target_core_mod iscsi_target_mod`
2. **Clean file database** — `iscsiadm -m node --logoutall=all && iscsiadm -m node --op=delete`
3. **Clean kernel sessions** — `iscsiadm -m session -r <sid> -u` (or sysfs, or reboot)
4. **Restart instance-manager** — `kubectl -n longhorn-system delete pod <instance-manager-pod>`
5. **Verify** — volume transitions to `attached`/`healthy`, pods start

## Notes

- The `iscsiadm -m session -r <sid> -u` force-logout and sysfs device deletion approaches were confirmed working during recovery from the Jul 28, 2026 NAS outage.
- A node reboot is the cleanest recovery when many sessions are stuck — it clears all kernel state and avoids per-session wrestling.
- `iscsiadm -m node --logoutall=all` only affects sessions tracked in the node database (`/etc/iscsi/nodes/`). Active kernel sessions (`/sys/class/iscsi_session/`) are NOT affected.
