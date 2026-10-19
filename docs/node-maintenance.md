# Node maintenance: drain, return, add, remove

How a k3s node leaves and rejoins the edge without router edits and without dropping more connections than necessary. Background and verification: [2026-10-15-fungible-ingress.md](2026-10-15-fungible-ingress.md).

## How traffic reaches a node

- Every k3s node except office (its `wifi` taint keeps the MetalLB DaemonSets off) runs a MetalLB speaker (`metallb-speaker` + `metallb-frr-k8s` DaemonSets) that peers with the MikroTik over BGP. The router has **one** listener, connection `metallb-speakers` for `192.168.5.0/24`; it accepts a session only from addresses in its firewall address-list `k8s-nodes`, only from AS 65000, and only service /32s and /128s (filter chain `metallb-in`).
- BFD (300 ms × 5) withdraws a dead or stalled node in ~1.5 s.
- The router ECMP-hashes each VIP across every node announcing it. RouterOS has no resilient hashing: whenever a node starts or stops announcing a VIP, 1/4–1/2 of that VIP's existing flows move to another node and break (TCP resets; UDP reaches the pod from a new source). HTTP clients reconnect transparently; long-lived flows do not.
- `externalTrafficPolicy: Local` Services are announced only by the node running a ready pod, so other nodes coming and going never touch them. Use it for long-lived flows (see [Adding a New Workload](adding-a-workload.md)). Draining the pod's own node still disconnects its users: the pod restarts elsewhere.
- `kubectl cordon` does **not** stop MetalLB from announcing. The label `node.kubernetes.io/exclude-from-external-load-balancers` does: MetalLB withdraws every route from that node while its BGP session stays up. Presence of the key is what counts; the value is ignored.
- pite carries that label permanently (MetalLB has no node selectors in `workloads/metallb/bgpadvertisement.yaml`). **Never remove it from pite.**

## Drain a node

1. Storage pre-check. If either command lists anything, **stop: this node cannot be drained yet** (follow-up work in ai_tasks project 11). The drain would hang on a PodDisruptionBudget, and forcing it risks data loss.
   - CNPG primaries on the node: `ssh 192.168.5.36 'kubectl get pods -A -l cnpg.io/instanceRole=primary --field-selector spec.nodeName=<node> -o name'`
   - Longhorn volumes whose only replica is on the node (Longhorn's `node-drain-policy` is `block-if-contains-last-replica`): `ssh 192.168.5.36 'kubectl get replicas.longhorn.io -n longhorn-system -l longhornnode=<node> -o custom-columns=VOLUME:.spec.volumeName --no-headers'`. For each listed volume, `ssh 192.168.5.36 'kubectl get volumes.longhorn.io -n longhorn-system <volume> -o jsonpath={.spec.numberOfReplicas}'` → `1` means it blocks.
2. See what will move: `ssh 192.168.5.36 'kubectl get pods -A -o wide --field-selector spec.nodeName=<node>'`. Any `externalTrafficPolicy: Local` Service whose only ready pod is on this node (games, TeamSpeak, stalwart, headscale-stun, …) goes unreachable from step 4 until its pod is Ready elsewhere. Warn players first.
3. `ssh 192.168.5.36 'kubectl cordon <node>'`
4. Withdraw the node from the edge while it is still healthy: `ssh 192.168.5.36 'kubectl label node <node> node.kubernetes.io/exclude-from-external-load-balancers=true'`
5. Confirm on the router: `mikrotik-connect r '/routing bgp session print proplist=remote.address,prefix-count where remote.address=<node-ip>'` → still established, `prefix-count=0`. Do not continue until it is 0.
6. `ssh 192.168.5.36 'kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=15m'`, then do the maintenance. If it times out on a PodDisruptionBudget, do not force it: uncordon, remove the label ("Return a node" steps 2–3), and report the blocking pod.

## Return a node

1. `ssh 192.168.5.36 'kubectl get node <node>'` → `Ready`; its `metallb-speaker` and `metallb-frr-k8s` pods are `Running`; the router session for `<node-ip>` is established with `prefix-count=0`.
2. `ssh 192.168.5.36 'kubectl uncordon <node>'`
3. `ssh 192.168.5.36 'kubectl label node <node> node.kubernetes.io/exclude-from-external-load-balancers-'` → `prefix-count` rises within seconds. This re-hashes multi-announcer flows once; pick a quiet moment.

An unplanned failure needs nothing for routing: BFD withdraws the node, and when it comes back its speaker re-announces on its own.

## Add a node

1. Router: a static DHCP lease for the node's NIC, and admit it to BGP: `mikrotik-connect r '/ip firewall address-list add list=k8s-nodes address=<node-ip> comment=<node>'`.
2. NixOS: import `nixos/modules/k3s-server.nix` (control plane) or `nixos/modules/k3s-agent.nix` (worker) in `~/dotfiles`; both open TCP 179 and UDP 3784. Unless the node carries a taint the MetalLB DaemonSets do not tolerate (they tolerate only control-plane and `pi`), the speaker pods land on it, FRR dials `192.168.5.1`, the listener accepts, BFD comes up — no MetalLB or router BGP edit.
3. Lists that still name nodes: the per-node SNAT gateway ipBlocks (MAINTENANCE in `workloads/network-policies/00-pattern.yaml`) and, for a control-plane node, the endpoints in `workloads/metallb/kubernetes-api-lb.yaml`.
4. Check: router session for `<node-ip>` established, BFD up (`/routing bfd session print`), `prefix-count` > 0.

## Remove a node for good

1. Drain it (above), then `ssh 192.168.5.36 'kubectl delete node <node>'`.
2. Router: `mikrotik-connect r '/ip firewall address-list remove [find list=k8s-nodes and comment=<node>]'` and remove its static DHCP lease.
3. Update the lists in "Add a node" step 3.
