# Documentation

## Guides

Current instructions. They must always be correct: fix them in the same commit as the change that makes them wrong.

- [Adding a New Workload](adding-a-workload.md)
- [Adding a Secret](adding-a-secret.md)
- [Adding a CNPG Database](adding-a-cnpg-database.md)
- [LAN and cluster DNS (lan-dns)](lan-dns.md)
- [Internet edge: Verizon → MikroTik → MetalLB (port forwards, router recovery)](network-edge.md)
- [Network inventory: every subnet and host, with diagrams](network-inventory.html)
- [Expanded port-level diagram (Graphviz source)](network-diagram.dot) · [rendered](network-diagram.svg)
- [Node maintenance: drain, return, add, remove](node-maintenance.md)
- [Public edge: gating public routes](public-edge.md)
- [Exposing an Unauthenticated App (humans + federated machines)](exposing-an-unauthenticated-app.md)
- [Longhorn iSCSI Recovery](longhorn-iscsi-recovery.md)
- [Matter server: fabric, restore and the start-up guard](matter-server.md)
- [k3s store paths: why GC must not break a node](k3s-store-paths.md)
- [Multi-cluster: prod + bigp nonprod, ApplicationSet cutover](multi-cluster.md)

## Records

Files named `YYYY-MM-DD-*.md`, plus `worker-deployment-handoff.md`, record what was done, why, and how it was verified. Do not rewrite them. When one goes stale, add one line directly under its title:

- `> **Superseded <date>.** <what replaced it>. See [guide](guide.md).`
- `> **Correction <date>:** <the corrected fact>.`

## Facts that change

Versions, IP addresses, middleware values and route lists belong in the manifests (or the one guide that owns them). A doc names the file to read instead of copying the value.
