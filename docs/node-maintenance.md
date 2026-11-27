# Node maintenance: drain, return, add, remove

How a k3s node leaves and rejoins the edge without router edits and without dropping more connections than necessary. Background and verification: [2026-10-15-fungible-ingress.md](2026-10-15-fungible-ingress.md).

**Which node announces what right now:** [network-inventory.html](network-inventory.html) carries the per-VIP placement and the switch ports; this guide is the procedure.

## How traffic reaches a node

- Every k3s node except office (its `wifi` taint keeps the MetalLB DaemonSets off) runs a MetalLB speaker (`metallb-speaker` + `metallb-frr-k8s` DaemonSets) that peers with the MikroTik over BGP. The router has **one** listener, connection `metallb-speakers` for `192.168.5.0/24`; it accepts a session only from addresses in its firewall address-list `k8s-nodes`, only from AS 65000, and only service /32s and /128s (filter chain `metallb-in`).
- BFD (300 ms × 5) withdraws a dead or stalled node in ~1.5 s.
- The router ECMP-hashes each VIP across every node announcing it. RouterOS has no resilient hashing: whenever a node starts or stops announcing a VIP, 1/4–1/2 of that VIP's existing flows move to another node and break (TCP resets; UDP reaches the pod from a new source). HTTP clients reconnect transparently; long-lived flows do not.
- `externalTrafficPolicy: Local` Services are announced only by the node running a ready pod, so other nodes coming and going never touch them. Use it for long-lived flows (see [Adding a New Workload](adding-a-workload.md)). Draining the pod's own node still disconnects its users: the pod restarts elsewhere.
- `kubectl cordon` does **not** stop MetalLB from announcing. The label `node.kubernetes.io/exclude-from-external-load-balancers` does: MetalLB withdraws every route from that node while its BGP session stays up. Presence of the key is what counts; the value is ignored.
- pite carries that label permanently (MetalLB has no node selectors in `workloads/metallb/templates/bgpadvertisement.yaml`). **Never remove it from pite.**

## Drain a node

Reboot window: do not start between 08:11Z and 10:15Z, and not the same node twice in one day before
the next 09:00Z checksum pass — `nightly-backup` folds every snapshot at 08:00Z and the daily checksum
pass only reaches full coverage at 10:15Z (measured 2026-11-26), so a reboot inside that window costs a
630 s block-comparison rebuild instead of 180 s. Detail: `dotfiles/docs/fleet-patching.md`,
"Rebooting a k3s node".

1. Storage pre-check. If the command lists anything, **stop: this node cannot be drained yet** (follow-up work in ai_tasks project 11). The drain would hang on a PodDisruptionBudget, and forcing it risks data loss. A CNPG primary on the node is not a stop — step 2 promotes it off.
   - Longhorn volumes whose only replica is on the node (Longhorn's `node-drain-policy` is `block-if-contains-last-replica`): `ssh 192.168.5.36 'kubectl get replicas.longhorn.io -n longhorn-system -l longhornnode=<node> -o custom-columns=VOLUME:.spec.volumeName --no-headers'`. For each listed volume, `ssh 192.168.5.36 'kubectl get volumes.longhorn.io -n longhorn-system <volume> -o jsonpath={.spec.numberOfReplicas}'` → `1` means it blocks.
2. Promote every CNPG primary off the node, before cordoning. A primary's PDB is `minAvailable: 1` over `cnpg.io/instanceRole=primary` and a cluster has one primary, so `status.disruptionsAllowed` is 0 (`kubectl get pdb -A | grep -- -db-primary`) and a drain of that node waits out the full `--timeout`; a replica needs no promotion. This is the same step the kured path documents (`dotfiles/docs/fleet-patching.md`, "Rebooting a k3s node", step 2):

   `ssh 192.168.5.36 'nix run nixpkgs#kubectl-cnpg -- promote <cluster> <instance-on-other-node> -n <namespace>'`

   Then confirm the node holds no primary: `ssh 192.168.5.36 'kubectl get pods -A -l cnpg.io/instanceRole=primary --field-selector spec.nodeName=<node>'` prints nothing. Measured 2026-11-26: all eight clusters promoted in 71.5 s, a few seconds of failed connections each (litellm `P1001` ~6 s).
3. See what will move: `ssh 192.168.5.36 'kubectl get pods -A -o wide --field-selector spec.nodeName=<node>'`. Any `externalTrafficPolicy: Local` Service whose only ready pod is on this node (games, TeamSpeak, stalwart, headscale-stun, …) goes unreachable from step 5 until its pod is Ready elsewhere. Warn players first.
4. `ssh 192.168.5.36 'kubectl cordon <node>'`
5. Withdraw the node from the edge while it is still healthy: `ssh 192.168.5.36 'kubectl label node <node> node.kubernetes.io/exclude-from-external-load-balancers=true'`
6. Confirm on the router: `mikrotik-connect r '/routing bgp session print proplist=remote.address,prefix-count where remote.address=<node-ip>'` → still established, `prefix-count=0`. Do not continue until it is 0.
7. `ssh 192.168.5.36 'kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=15m --pod-selector="!cnpg.io/cluster,longhorn.io/component!=instance-manager,app notin (home-assistant,minecraft,frigate,matter-server),app.kubernetes.io/name notin (za-mullvad,ee-mullvad,tempo),statefulset.kubernetes.io/pod-name notin (loki-write-0,loki-write-1,mimir-1,loki-chunks-cache-0,loki-results-cache-0)"'`, then do the maintenance. This is kured's own `drainPodSelector` (`apps/kured.yaml:47`) copied verbatim — a copy, not a reference, so **if that selector changes, this line changes in the same commit** — and it is not optional: a bare drain fails on the instance-manager PodDisruptionBudget after 15 minutes (measured 2026-11-26), and it evicts the instance-manager, which kills every replica on the node at drain time instead of at the reboot. Pods the selector leaves behind are killed by the reboot and return on the node. `openbao-0` is not in the selector and is still evicted. If it times out on a PodDisruptionBudget, do not force it: uncordon, remove the label ("Return a node" steps 2–3), and report the blocking pod.

A PDB is only a backstop when the workload's replicas are *required* to sit on different nodes: with two replicas on one node, `minAvailable: 1` leaves zero allowed disruptions and the drain above hangs. Every stateless two-replica workload gets the required hostname anti-affinity first and the PDB second — `litellm`, the four `oauth2-proxy-*` front doors, `lan-dns`, `wkd` and `rots-replays` are in that state; `rots-sync` is not, and has no PDB for that reason. Rule, evidence and the litellm no-surge trade-off: [2026-11-23-replica-spread-and-pdbs.md](2026-11-23-replica-spread-and-pdbs.md).

## Move a CNPG instance off a node

Needed when a cluster's placement rule must change — for example, to stop a database landing on a
node that is being reduced to storage only (2026-11-13, `nas`). Editing `spec.affinity` on a
`Cluster` is **not** future-only, and an existing volume cannot be moved:

1. **Every instance pod rolls, the primary included.** The affinity block is part of the pod
   template, so the operator recreates all instances. With the default `primaryUpdateStrategy:
   unsupervised` the primary is restarted **without a switchover** — expect a few seconds of failed
   connections (litellm logged `P1001` for ~6 s). The instance-manager gives a shutting-down primary
   a 1800 s grace period; if postgres has already stopped and the pod stays `Terminating` (readiness
   "server is alive but rejecting connections"), it will sit until its grace period expires. A drain
   never reaches that point — the PDB blocks it first — and when pods did terminate under a
   promote-then-drain they took 9.8 s, 92 s and 187 s (measured 2026-11-26). Force it:

   `ssh 192.168.5.36 'kubectl -n <ns> delete pod <instance> --grace-period=0 --force'` — WAL is on
   disk, so the replacement starts with ordinary crash recovery.
2. **A replica whose volume is pinned to the now-forbidden node goes `Pending`**, with
   `N node(s) didn't match PersistentVolume's node affinity`. `longhorn-cnpg` is single-replica, so
   an existing volume attaches only on the node holding its replica; only a *new* volume can be
   placed elsewhere.
3. **Recreate the replica rather than moving it.** Confirm it is not the primary first
   (`-o jsonpath='{.status.currentPrimary}'`), then in this order:
   - delete the pod — a `Pending` pod blocks the next step, because the operator recreates a missing
     PVC only once no pod exists for that instance;
   - delete **both** PVCs: `<instance>` and `<instance>-wal` (WAL is its own volume whenever
     `walStorage` is set; leaving it behind keeps the pod pinned to the old node);
   - wait. The operator creates fresh PVCs and a `<instance>-join-*` pod runs `pg_basebackup` from
     the primary. 25 GiB took ~5 min; the application keeps serving from the primary throughout.
4. **Verify**: `status.readyInstances == spec.instances`, every instance `2/2 Running` on an allowed
   node, and no `Pending` pods. `.status.currentPrimary` may have moved — failover to the promoted
   instance is normal and needs no correction.

Scaling `instances` down and back up achieves the same result for the highest index (CNPG deletes
that instance *with* its PVCs), but it cannot move instance 1 — the PVC path above is the general
case, and it is the only one available when the instance to move is the lowest number.

## Return a node

1. `ssh 192.168.5.36 'kubectl get node <node>'` → `Ready`; its `metallb-speaker` and `metallb-frr-k8s` pods are `Running`; the router session for `<node-ip>` is established with `prefix-count=0`.
2. `ssh 192.168.5.36 'kubectl uncordon <node>'`
3. `ssh 192.168.5.36 'kubectl label node <node> node.kubernetes.io/exclude-from-external-load-balancers-'` → `prefix-count` rises within seconds. This re-hashes multi-announcer flows once; pick a quiet moment.

An unplanned failure needs nothing for routing: BFD withdraws the node, and when it comes back its speaker re-announces on its own.

## Add a node

1. Router: a static DHCP lease for the node's NIC, and admit it to BGP: `mikrotik-connect r '/ip firewall address-list add list=k8s-nodes address=<node-ip> comment=<node>'`.
2. NixOS: import `nixos/modules/k3s-server.nix` (control plane) or `nixos/modules/k3s-agent.nix` (worker) in `~/dotfiles`; both open TCP 179 and UDP 3784. Unless the node carries a taint the MetalLB DaemonSets do not tolerate (they tolerate only control-plane and `pi`), the speaker pods land on it, FRR dials `192.168.5.1`, the listener accepts, BFD comes up — no MetalLB or router BGP edit.
3. Lists that still name nodes: the per-node SNAT gateway ipBlocks (MAINTENANCE in `workloads/network-policies/00-pattern.yaml`) and, for a control-plane node, the endpoints in `workloads/metallb/templates/kubernetes-api-lb.yaml`.
4. Check: router session for `<node-ip>` established, BFD up (`/routing bfd session print`), `prefix-count` > 0.

## Remove a node for good

1. Drain it (above), then `ssh 192.168.5.36 'kubectl delete node <node>'`.
2. Router: `mikrotik-connect r '/ip firewall address-list remove [find list=k8s-nodes and comment=<node>]'` and remove its static DHCP lease.
3. Update the lists in "Add a node" step 3.
