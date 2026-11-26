# Rotating the Mullvad exit endpoints: finalizer fix and full remake (2026-11-26)

**Status: COMPLETE and verified.** All four in-cluster exit nodes (`vpn-endpoint-<cc>-mullvad`,
chart `workloads/vpn-endpoints`) were remade with new Mullvad devices and new tailnet nodes.
Clients routed through each one exited from Mullvad in the right country.

| endpoint | old tailnet node | new tailnet node |
|---|---|---|
| za | `mullvad-za-johannesburg-spirab` | `mullvad-za-johannesburg-betcor` |
| jp | `mullvad-jp-tokyo-honrat` | `mullvad-jp-tokyo-reswor` |
| ee | `mullvad-ee-tallinn-rapbis` | `mullvad-ee-tallinn-warcra` |
| de | `mullvad-de-dusseldorf-sachor` | `mullvad-de-dusseldorf-aliger` |

## Finalizer growth (fixed in #165)

Each generated Application had collected about 8,100 finalizers (de 8133, ee 8095, jp 8107,
za 8115; about 385 KB per object), nearly all duplicate copies of `pre-delete-finalizer.argocd.argoproj.io`
and `.../cleanup`. Two Argo CD v3.5.2 behaviours combined to cause it:

- The ApplicationSet template listed both pre-delete finalizers.
- The ApplicationSet controller rebuilds an app's finalizers as the template list plus every
  `pre-delete`/`post-delete` finalizer already on the app (`defaultPreservedFinalizers`), so each
  update appended another copy.

The app controller adds both pre-delete finalizers itself whenever the chart has PreDelete hooks.
#165 therefore keeps only `resources-finalizer` in the template, and the validator now asserts that.
The live apps were patched once back to the three unique entries, and they stayed at three,
including after being recreated.

## How to rotate an endpoint

1. Delete the Application, one endpoint at a time:
   `kubectl -n argocd delete application vpn-endpoint-<cc>-mullvad --wait=false`.
   The Helm pre-delete Job `<cc>-mullvad-deregister` deletes the Mullvad device, the headscale
   node, the PVC and the `<cc>-mullvad-identity` ConfigMap. The ApplicationSet then recreates the
   app, and `enroll` registers a new identity.
2. Check that the identity really changed: `<cc>-mullvad-identity` `.data.node_name` must differ
   from the old one. The old name must be gone from `headscale nodes list`, and the new one must be
   online with `0.0.0.0/0` and `::/0` approved.
3. Verify through a real client, not from inside the pod. `wget am.i.mullvad.net` from the pod's
   own containers goes out through Gluetun directly and never tests forwarding.

Rotating one endpoint at a time keeps the Mullvad device count under the 5-device cap, because
deregister removes the old device before enroll creates the new one.

### Known race: the deregister hook can be skipped

In 2 of 6 deletes, Argo CD v3.5.2 treated the pre-delete hook as finished before it ran
(`controller/hook.go`, `executeHooks`):

1. A second deletion pass ran before the informer cache had seen the Job it had just created.
2. That pass's create returned `AlreadyExists`, which is logged
   (`Hook resource {batch Job ...-deregister} already exists, skipping`) and skipped.
3. With no hooks in the cache, the function returned done.
4. The cascade then pruned the hook's ServiceAccount and scripts ConfigMap before its pod could
   start.

The PVC (`Delete=false`) and the identity ConfigMap survive that cascade, so the endpoint comes back
with its **old** identity. That outcome is harmless, but it is a silent no-op. Step 2 above detects
it; deleting again worked both times. Do not script unattended rotations until Argo CD fixes this.

## Clients must reselect after a rotation

Clients that had an old node selected lose their exit node, and they may keep stale exit-node DNS.
With an exit node selected, Tailscale sends all DNS to that node's peerAPI DNS-over-HTTPS endpoint.
This happens even though headscale sets global nameservers, because they are not marked for use
with exit nodes. The exit node forwards those queries to its own resolver: inside these pods that
is Gluetun's DNS on `127.0.0.1:53`, with malicious-domain blocking on.

After the rotation, an iPad kept sending DNS to the deleted de node's address (`100.64.0.30`), and
no page loaded even though packets flowed. Turning Tailscale off and on, then picking the new node,
fixed both the iPad and the iPhone.

## Verification

- A throwaway client pod (kernel TUN, ephemeral preauth key for user John2143, removed afterwards)
  passed two rounds against all four new nodes:
  - HTTPS to an IP literal;
  - DNS through MagicDNS;
  - `am.i.mullvad.net` reporting `mullvad_exit_ip: true` in the expected country;
  - a 3 MB download in 2–8 s.
- The controls `nas` and `mullvad-us-vpin-deccam` passed the same checks.
- In the first ~90 s after the test client joined, de and ee failed every check; the same checks
  passed two minutes later. Give a newly joined client time before judging an endpoint.
- Live counters then showed John's iPad on jp (direct) and iPhone on de (DERP) forwarding traffic.
