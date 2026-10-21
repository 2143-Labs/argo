# Adding a CNPG Database

CloudNativePG is already installed cluster-wide (`apps/cnpg-operator.yaml`). Adding a
database means adding a `Cluster` object — never a StatefulSet, never a chart's bundled
Postgres. This guide covers picking the replica count, the manifest to copy, and the
placement rules the cluster already imposes.

For the surrounding workload (Deployment, Service, HTTPRoute) read
[Adding a New Workload](adding-a-workload.md). For the password, read
[Adding a Secret](adding-a-secret.md).

## 1. Choose the instance count

| `instances` | Use when | Survives a node loss | Nodes consumed |
|---|---|---|---|
| `1` | data is re-derivable, or the workload is disposable | no | 1 |
| `2` | **the default** — anything you would miss | yes, after a promotion | 2 |
| `3+` | you genuinely need quorum or read fan-out | yes | one per instance |

Three hard limits decide this, and none are negotiable at the manifest level:

- **`longhorn-cnpg` is `numberOfReplicas: "1"` + `dataLocality: strict-local`.** Every
  instance gets its own volume, pinned to the node it was provisioned on. There is no
  second copy inside Longhorn, so the *database* redundancy comes from Postgres, not
  from storage. It also means a volume cannot follow its pod to another node.
- **Anti-affinity is `required` on `kubernetes.io/hostname`.** N instances therefore
  need N distinct nodes that can provision storage.
- **Only three nodes can provision today: `big`, `closet`, `nas`.** `arch` carries a
  required `NotIn` term because its disk sits below the 25% floor and is deliberately
  reserved; `office` is wifi-only and tainted `wifi=no-network-storage:NoSchedule`, so
  storage pods never land there. Prefer `big`/`nas` for new replicas, and check current
  per-node requests (§7) before adding one — free capacity, not CPU, has been the
  binding constraint.

**Consequence:** `instances: 3` consumes all three usable nodes. `4+` is impossible
until arch's disk is freed. If you think you need 3, confirm the workload really needs
a third copy rather than a better backup.

## 2. Files to add

| File | Purpose |
|---|---|
| `workloads/<name>-db/cnpg-cluster.yaml` | the `Cluster` |
| `workloads/secrets/<namespace>-<name>-db-password.yaml` | `ExternalSecret` rendering the role's password |
| `apps/<name>-db.yaml` | Argo `Application` pointing at `workloads/<name>-db` |

Existing examples: `workloads/asciinema/` (cluster colocated with its app),
`workloads/temporal-db/` (DB in its own directory, extra database via `postInitSQL`),
`workloads/llm-proxy/cnpg-cluster.yaml` (managed roles + `pg_hba`).

## 3. The Cluster manifest

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: <name>-db
  namespace: default
  annotations:
    # An Argo prune must never delete a database. Remove it only by hand.
    argocd.argoproj.io/sync-options: Prune=false,Delete=false
spec:
  instances: 2
  # Promote a replica before touching the primary; `restart` deletes it in place
  # and forces a Longhorn detach/attach.
  primaryUpdateMethod: switchover
  # Copy this line from an existing cluster — do not invent a tag, and never use
  # the upstream `postgres` image (CNPG needs its own build).
  imageName: ghcr.io/cloudnative-pg/postgresql:<as deployed elsewhere>
  affinity:
    enablePodAntiAffinity: true
    podAntiAffinityType: required
    topologyKey: kubernetes.io/hostname
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: kubernetes.io/hostname
                operator: NotIn
                values: [arch]
      # Preferred, not required: a required "big or closet" rule would stop the
      # operator from recreating a lost instance on nas.
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - key: kubernetes.io/hostname
                operator: In
                values: [big, nas]
  resources:
    # request = limit (Guaranteed QoS). Keeps the DB from being an eviction
    # candidate and keeps node accounting honest.
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 1Gi
  storage:
    size: 10Gi
    storageClass: longhorn-cnpg
  walStorage:
    size: 4Gi
    storageClass: longhorn-cnpg
  bootstrap:
    initdb:
      database: <dbname>
      owner: <role>
  managed:
    roles:
      - name: <role>
        ensure: present
        login: true
        passwordSecret:
          name: <name>-db-password
  postgresql:
    pg_hba:
      - host all all 0.0.0.0/0 scram-sha-256
```

Notes:

- **`storage` is data, `walStorage` is WAL.** Keeping WAL on its own volume stops a WAL
  spike from filling the data volume. Existing sizes: 10Gi/4Gi for small apps,
  25Gi/8Gi for larger ones.
- **`managed.roles` + `passwordSecret`** is how the app's role is created. The secret
  name must be exactly what the `ExternalSecret` renders (section 4).
- **Extra databases** (Temporal's `temporal_visibility`, for example) go in
  `bootstrap.initdb.postInitSQL`.
- **Namespace:** the `Cluster` must live in the namespace the app runs in. `default` is
  the norm; `mattermost-db` and `steam-lobby` are the exceptions.

## 4. The password secret

An `ExternalSecret` renders an ordinary `Secret` from OpenBao. The target name must
equal the `passwordSecret.name` above:

```yaml
# workloads/secrets/default-<name>-db-password.yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <name>-db-password
  namespace: default
spec:
  refreshInterval: 10m
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: <name>-db-password
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: john2143-com/default/<name>-db-password
```

The key must exist in OpenBao at `consumers/data/john2143-com/<namespace>/<name>-db-password`.
Seed it per [Adding a Secret](adding-a-secret.md) — the value is the password only, in
JSON.

## 5. The Argo Application

```yaml
# apps/<name>-db.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <name>-db
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/2143-Labs/argo.git
    targetRevision: HEAD
    path: workloads/<name>-db
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

The app-of-apps Application in `main.yaml` picks up new files in `apps/` automatically.
Ordering does not matter in practice, but the role cannot be reconciled before its
secret exists — if the app cannot authenticate, check
`kubectl get secret <name>-db-password` first.

## 6. Connect the workload

CNPG publishes three services in the cluster's namespace:

| Service | Points at |
|---|---|
| `<name>-db-rw` | the primary (read/write) |
| `<name>-db-ro` | replicas (read-only) |
| `<name>-db-r` | any instance |

Consume the password from the rendered secret rather than inlining it:

```yaml
env:
  - name: PGHOST
    value: <name>-db-rw
  - name: PGDATABASE
    value: <dbname>
  - name: PGUSER
    value: <role>
  - name: PGPASSWORD
    valueFrom:
      secretKeyRef:
        name: <name>-db-password
        key: password
```

## 7. Verify

Pods are readable with `closet-as-developer`, but `Cluster` objects are not: listing
`clusters.postgresql.cnpg.io` is `Forbidden` even inside a namespace. Run the
`Cluster`/`exec` checks over SSH to a control-plane node, or with `closet-as-admin`.

```bash
# Instances exist and are on distinct nodes
kubectl get pods -n default -l cnpg.io/cluster=<name>-db -o wide

# Cluster converged
kubectl get cluster -n default <name>-db

# Replication live: primary reports pg_is_in_recovery()=f and one streamer per replica
kubectl exec -n default <name>-db-1 -c postgres -- \
  psql -U postgres -tAc "select pg_is_in_recovery(), (select count(*) from pg_stat_replication)"

# Requests still fit the nodes
kubectl describe node big | sed -n '/Allocated resources/,/^Events/p' | grep -E '^  (cpu|memory) '
```

Expected for `instances: 2`: two pods on two different nodes, one primary (`f`) with
`1` streamer, and no node above 100% of allocatable.

## 8. Changing the replica count later

Edit `instances:` and commit — the operator adds or removes instances and promotes via
switchover when the primary changes. Two consequences:

- **Scaling down leaves volumes behind.** `longhorn-cnpg` is `reclaimPolicy: Retain`, so
  the departed instance's PVC stays `Released` and still consumes the node's capacity.
  Delete the PVC by hand once you are sure.
- **New instances need a free node.** Going from 1 to 2 requires a second node that can
  provision; going to 3 uses all of them.

## 9. Known gaps and gotchas

- **No backups are configured on any CNPG cluster in this repo.** There is no
  `barmanObjectStore`/`ObjectStore`; durability is one node-pinned Longhorn copy plus
  `Retain`. If the data matters, that is the thing to add next.
- **`strict-local` + 1 replica means node loss = volume loss** for that instance. The
  second Postgres instance protects against *process* and *node* failure differently:
  it holds the data, not a storage mirror.
- **Do not remove the `Prune=false,Delete=false` annotation.** A prune is a `DROP`.
- **Don't put the DB in a chart's bundled Postgres.** One operator, one pattern, one
  place to look.
