# Release pipeline plan for ROTS

**Status:** Proposed — nothing built. The decisions marked *invariant* are settled by the owner; the rest are this plan's recommendation and can be overridden.
**Date:** 2026-11-12
**Owner:** John (the only person who releases).
**Scope:** one pipeline from pull request to players across every channel ROTS ships on — web and game servers, Steam, iOS, and the Linux binaries — with artifacts built once and promoted, an SBOM per artifact, and a forge that can enforce the gates.
**Related:** [Steam QA delivery plan](steam_game_plan.md), [iOS delivery plan](ios_game_plan.md), [Deploying a private-repo game](deploying-a-private-repo-game.md), [Multi-cluster](multi-cluster.md).

Evidence labels: **GitHub** / **Forgejo** / **Apple** / **Valve** — vendor documentation; **Project** — upstream project source or issue trackers; **Repo** — read from the named file on 2026-11-11/12; **Probe** — read-only probe of a live system or API; **Inferred** — reasoning no source states directly.

Research behind this plan, with per-claim evidence tables: `~/repos/pipeline-release-promotion.md`, `~/repos/pipeline-combined-backend.md`, `~/repos/pipeline-forgejo.md`, `~/repos/pipeline-sbom-provenance.md`.

---

## 1. Summary

**Distribution is not release.** Every green `main` is built once and lands in test channels automatically: `rots-dev`, the Steam `dev` branch, internal TestFlight, `channels/dev`. Players move only when a pointer flips to an artifact that already exists.

Two things make that possible:

1. **A server-side directory decides each build's backend**, keyed by commit sha. An unlisted sha is a dev build. Promotion sets it to `qa`, then `prod`. The store's own signal (Steam `default`/`public`, iOS `.production`) can only *force* prod, which catches a store click the directory was not told about.
2. **Prod is promote-only.** Nothing reaches players from a green `main` any more; only a dispatched release that John runs moves prod, flips the directory, and points the stores.

The forge is currently the weak link: on GitHub Free a private repository has no branch protection, no rulesets, no environments and no attestations (GitHub, Probe), so `main` is unprotected and all eight collaborators are admins (Probe). Forgejo v17, self-hosted and GPL, supplies all of it, including OIDC tokens for Actions from v15 and the `actor_id`/`repository_id` claims from v16 (Forgejo).

## 2. What exists today

| Piece | Today | Source |
|---|---|---|
| PR checks | cargo tests, authserver tests with Postgres+Temporal, a design-doc check; no clippy, fmt or vulnerability step; no headless gameplay test | Repo: `rots4/.github/workflows/build_nix.yml` |
| PR environment | one full stack per open PR at `rots-{N}.john2143.com`, images tagged `<component>-pr-<N>-<headsha>` | Repo: `apps/rots-web-preview.yaml` |
| Build | Nix/crane: wasm bundle, gameserver and authserver images, Linux client/server/authserver | Repo |
| Publish | skopeo to zot `registry.ts.2143.me/2143-labs/rots4:<component>-<sha7>`; binaries to `s3://rots4-releases/builds/<sha>/` and `latest/`; Nix closure to Attic | Repo |
| Deploy | every green `main` commits pinned tags into `apps/rots-web.yaml` and pushes to argo; ArgoCD auto-syncs | Repo: `scripts/ci-argo-bump.sh` |
| Prod rate | 36 prod moves in the 7 days to 2026-11-11 | Probe (argo git log) |
| Credentials | OpenBao via GitHub OIDC; roles bound to `repository_id`, and for writes `ref=refs/heads/main` + `event_name=push` | Repo |
| Gate strength | branch protection and rulesets return 403 on this plan; 0 environments; 8 collaborators, all admin; org default permission `admin` | Probe |
| Artifact retention | zot keeps the 20 newest `<sha7>` tags per component; S3 prunes `builds/` after 90 days | Repo |
| Client identity | `ROTS_BUILD_HASH` (env, else git, else `unknown`); `ConnectRequest` has no protocol version | Repo: `rots4/shared/build.rs:131-139`, `rots4/shared/src/event/server.rs:11` |

## 3. Environments and channels

| Environment | Runs | Reached by | Moves when |
|---|---|---|---|
| `rots-{N}` preview | PR head | Web only | Every push to the PR |
| **`rots-dev`** | every green `main` | Web; Steam `dev` branch; TestFlight internal; `channels/dev` | Automatically |
| **`rots-qa`** | one candidate | Steam `qa`; TestFlight external; `channels/qa` | John cuts a candidate |
| **prod** | one release | Web; Steam `default`; App Store; `channels/stable` | John promotes |

- One qa candidate at a time: `rots-qa` runs one server version.
- Web is the one client that cannot skew: the deployment serving the page *is* the environment (Repo). Web tabs left open across a deploy behave like any other old client.
- `rots-qa` needs its own public UDP range and LoadBalancer IP, because outside testers play on cellular; prod holds 36000-37999 end to end, previews 31000-34999 (Repo: `rots4/docs/decisions.md:155-158`, `argo/apps/rots-web.yaml:6-7`). Each environment gets its own Argo Application.

## 4. The pipeline

```
PR ──► tests · preview environment (unchanged)
        │ merge to main
main ──► build ONCE: images · wasm · linux · steam depots · iOS archive
        │  + one CycloneDX SBOM per artifact, signed at build
        ├─► seal: builds/<sha>/candidate.json (digests, SBOMs, protocol range, migrations head)
        ├─► rots-dev pins        (CI may write only the dev pins)
        ├─► Steam `dev` branch · TestFlight internal · channels/dev
        ▼
test what was distributed ── smoke jobs + testers → events/<ts>-<channel>.json
        ▼
promote (workflow_dispatch, John only, OpenBao-gated)
   sha=N → qa    servers + directory N:qa + Steam `qa` + TestFlight external + channels/qa
   sha=N → prod  compatibility check → servers + directory N:prod (one commit) →
                 John: Steam `default` live · App Store submit/release · channels/stable
```

Invariants the promotion step checks (Inferred from the vendor constraints in §5):

- **Client promotion:** refuse unless prod's supported protocol range contains the candidate client's protocol.
- **Server promotion:** refuse unless the candidate accepts the protocol of every supported client, *including a build currently in App Review* (Apple 2.1 requires the backend to work during review).
- **Order:** flip the directory before any store gesture, so the reviewer and the first customers resolve to prod.

## 5. Decisions

### D1. Trunk, `rots-dev` on every green `main`, prod promoted *(invariant)*

- `main` is the only integration branch; no long-lived `dev` branch. PRs merge to `main`, previews stay per PR, and every green `main` deploys `rots-dev`.
- A candidate is a `main` commit that John cuts to `qa`. Prod moves only by promotion.
- **Replaces** the current behaviour where every green `main` moves prod.

### D2. Prod is promote-only *(invariant)*

- Nothing deploys to prod from a green `main`. Steam D15's "before release, prod deploys must follow the `default` promotion" gap disappears, because prod never follows `main` at all.
- Cost: prod stops receiving the ~36 moves a week that today come free. Hotfixes go through the same dispatch.

### D3. One build, promoted by a server-side directory *(recommendation)*

- Every build is App-Store-eligible and identical per commit. On launch the client asks prod's `/api/v1/client-config` with `{platform, sha, build, protocol, signal}`; the directory answers `{env, auth_url, status, notice, ttl_s}`.
- Unlisted sha ⇒ `dev`, so a green `main` needs no commit to route. `qa`/`prod` are set by promotion; `retired` tells an old client to update.
- The **store signal can only force prod** (`steam:default`/`steam:beta:public`, `ios:production`). Anything else on an unpromoted build is a pipeline error: route to prod and alert.
- The device signal cannot tell a TestFlight tester from the App Review reviewer — Apple runs review in the sandbox, the same environment TestFlight uses (Apple) — which is why the client must not choose alone.
- Protocol and minimum-build checks stay with each environment's own authserver; the directory only routes.
- Fail-open: cache the answer per sha, fall back to prod.
- **Replaces, if adopted:** Steam D11 (branch selects backend) and iOS D8 (two baked flavours). Steam's branch name becomes the signal; iOS needs one export per build.
- `[SPECULATIVE design on CONFIRMED signals; AppTransaction values unverified on device]`

### D4. The gate is the credential, and it survives the forge change *(recommendation)*

- A release is a `workflow_dispatch` whose OpenBao role binds `repository_id`, `event_name=workflow_dispatch`, `ref=refs/heads/main`, `workflow_ref` (the promote workflow), `actor_id` (John), `run_attempt=1`, and on Forgejo `token_bound_cidrs` (no `runner_environment` claim exists there).
- GitHub signs those claims, so a workflow cannot forge them; on Forgejo the same mount pattern (`jwt-forgejo`) applies.
- What it buys: release credentials — App Store Connect key, iOS distribution material, the zot credential that retags retained images, store write access — are readable only by a manual run of one named workflow on `main`, started by John.
- What it does not buy: protection from a malicious admin, who can push to `main` today anyway.
- **Rejected:** `v*` tags as the gate (on Free private, anyone with write access can tag a commit that never reached `main`, and that commit's own workflow then runs); GitHub environments (do not exist on a Free private repo); upgrading to Enterprise solely for an approval click.

### D5. Move `rots4` to self-hosted Forgejo; keep `argo` on GitHub *(recommendation)*

- Forgejo v17 on the prod cluster, chart 17.3.2, Postgres via CNPG, SeaweedFS for attachments/LFS/Actions logs, pocket-id for login (`ACCOUNT_LINKING=login`; no admin-group mapping, which would let a pocket-id admin mint site admins).
- `main`: push allowlist = John; everyone else merges by PR with required checks and one approval; protected paths `.forgejo/workflows/**`, `scripts/ci-*` so only John changes CI. Developers hold Actions **read**, so they cannot dispatch or re-run.
- **Why:** it is the only FOSS forge that does all three of gate `main`, gate dispatch, and serve Argo CD previews. GitLab CE's protected environments are Premium (vendor docs).
- **Version floor:** v16+ for the `actor_id`/`repository_id` claims; run v17, upgrade to v18 (2027-01-14), settle on the v19 LTS.
- `argo` stays on GitHub: 11 of its 12 deploy keys are write keys used by other repos, 91 `repoURL`s point at it, and Forgejo would be deployed by Argo CD from a repo it does not host yet.
- **Sequencing gate:** the trust model says anyone who can push can run arbitrary workflows (Forgejo), and runner users are Nix trusted users, which is "essentially equivalent to root" (Nix). So the release runner must not share a Nix daemon with PR runners — its own host or VM.
- **Honest costs:** forge operations (patch releases every 2–5 weeks, no CVE feed — subscribe to the security RSS), `fj` lacks review approval and job logs, the `claude`/`cursor`/`linear` GitHub apps are lost, and forgejo-runner has no upstream macOS support.
- **Open:** internet-reachable or tailnet-only; whether the 7 other admins are demoted to a `devs` team.

### D6. Build once; sign at build; pin by digest *(recommendation)*

- Signing (Windows Authenticode, iOS/macOS as the plans say) happens inside the artifact build, before the candidate is sealed, so the recorded digest describes what ships.
- **Digest pins:** the argo/`rots-deploy` bump writes `tag@sha256:` rather than a tag. Today prod is pinned by tag and the registry user may *update* tags from any run, PR runs included (Probe: zot policy `read, create, update`; `imagePullPolicy: Always`), so a same-repo PR could move a prod tag.
- **Retention for held candidates:** zot keeps 20 `<sha7>` tags, about 4 days at the current rate, which is shorter than store review plus a 7-day phased release. Promotion adds a `release-<version>` tag with an unlimited `keepTags` rule and copies `builds/<sha>/` to `releases/<version>/`, which the 90-day pruner must skip.
- `latest/` is replaced by explicit `channels/dev`, `channels/qa`, `channels/stable`.

### D7. An SBOM per artifact, signed, attached where the artifact lives *(recommendation)*

- CycloneDX JSON, one per shipped artifact. Rust binaries are built with `cargo-auditable`; `cargo-cyclonedx --describe binaries` gives the crate list; syft or sbomnix gives the Nix and system layer. Today the binaries carry no dependency data at all, and syft sees 15 Nix packages and zero crates (Probe).
- Signing: cosign with a key in OpenBao Transit and **no public transparency log** — keyless Sigstore would publish a private repo's name and workflow forever (Probe: cosign 3.1 uploads to Rekor by default even with a key).
- Storage: referrers on the image in zot; sidecar files beside non-OCI artifacts in S3. Note zot's retention deletes a referrer with its subject.
- Scanning: osv-scanner in PRs, blocking only *new* advisories against a baseline; `grype` found none of the four Rust advisories that `cargo audit` and osv-scanner both report (Probe).
- Ceiling: SLSA Build L2. L3 is unreachable while four runners share one VM and one `/nix/store`.

### D8. The candidate record is a manifest in S3 *(recommendation)*

- `builds/<sha>/candidate.json` — immutable, written by a final `seal` job: OCI digests, file sha256s, SBOM references, protocol range, migrations head.
- `builds/<sha>/events/<utc>-<channel>.json` — append-only channel registrations (argo commit, Steam BuildID, App Store Connect build id), so jobs never race on one file.
- Promotion reads the candidate and never rebuilds.

### D9. PR checks gain the missing gates *(recommendation)*

- clippy and fmt (the repo has neither in CI).
- osv-scanner with a baseline, blocking only new advisories.
- A **protocol fingerprint** test: fail when the shared message types change without a `protocol_version` bump. Today a wire change ships silently, because an undecodable datagram is logged and dropped.
- A headless smoke (`--headless-shot` exists; the scenario harness does not) so a broken client is caught before distribution.

## 6. Migration

| Stage | Work | Exit criterion |
|---|---|---|
| 0. Record | `seal` job writing `candidate.json`; digest pins in the bump script; zot `release-*` retention; `releases/` exempt from pruning; PR images moved off the `update` grant | Every green `main` has a sealed candidate; a promoted release's images survive store review |
| 1. Release lane | promote workflow + OpenBao role bound to `workflow_dispatch`/`actor_id`; iOS signing material moved behind it | A dispatch by anyone else fails at OpenBao login |
| 2. Environments | `rots-dev` and `rots-qa` Applications; directory in the deploy repo; Steam `dev` branch | Testers play `rots-qa` from Steam `qa` and TestFlight |
| 3. Compatibility | `protocol_version` + `/client-config` + `X-Rots-Client`; directory routing; retire the two baked iOS flavours | An old client gets "update required"; one build walks dev → qa → prod |
| 4. Forge | Forgejo, runners, OIDC, import, cutover, mirror | A developer cannot dispatch, re-run, push to `main` or write a prod pin |
| 5. Stores | First Steam `default` and App Store release through the promote workflow | A release is reproducible from `candidate.json` + events |

Stage 3 is the prerequisite for external testers; stages 0–2 are independent of the forge choice.

## 7. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Prod stops moving / hotfixes stall under promote-only | Medium at first | Slower fixes; temptation to bypass | One-command dispatch; keep the dispatch under a minute |
| Directory misroute sends a customer to QA | Low with the interlock | Player data in the wrong backend | Store signal forces prod + mismatch alert; per-environment tokens |
| A held candidate's images are pruned | Certain without D6 | Cannot roll back or hold through review | `release-*` retention rule |
| Tag moved out from under prod | Low today | Prod runs unreviewed code | Digest pins; PR images on a separate grant |
| Forgejo operations (upgrades, no CVE feed) | Certain | CI down or a security gap | LTS cadence, security RSS, backups that include the Actions ID-token key |
| Release runner shares a Nix daemon with PR runners | High if built on VM 101 | A PR can plant store paths a release job consumes | Separate host for the release runner |
| Protocol discipline slips | High without D9 | Silent client failures | Fingerprint test; bump checked in review |

## 8. Open questions

| # | Question | Who |
|---|---|---|
| 1 | May only John cut a candidate to `qa`, or may developers write `qa` pins? | John |
| 2 | Is Forgejo internet-reachable, or tailnet-only with a push mirror? | John |
| 3 | Do `rots-qa` and `rots-dev` need a tester allowlist, or are they open with throwaway data? | John |
| 4 | Where does `rots-dev` run: bigp nonprod (wiped weekly) or the prod cluster (public)? | John, against [Multi-cluster](multi-cluster.md) |
| 5 | Marketing version under build-once: does `main` always carry the next store version? | John |
| 6 | Mac fallback if forgejo-runner cannot sign: SSH-driven from Linux, or a GitHub runner kept for the Mac only? | Phase 4 of the iOS plan |

## 9. Choices

Recorded from the session that produced this plan; times are that session's clock. Tiers follow the strength of the owner's own words: **invariant** = the owner drove it and it changes only with their approval; **recommendation** = the owner consented to or hedged toward it, and it is the default.

### Invariants

| When | Choice | Quote |
|---|---|---|
| 2026-11-11 09:15 | Only John releases; there is no second pair of hands | "1+2.. just me" |
| 2026-11-11 09:15 | Tooling must stay FOSS; no paid GitHub tier | "6. we must remain FOSS" |
| 2026-11-11 09:15 | Artifacts stay in SeaweedFS S3 and zot | "5. that artifact location is ok. seaweedfs ok" |
| 2026-11-11 ~09:20 | Trunk-based: no long-lived `dev` branch | `branch_model: trunk` (form answer) |
| 2026-11-11 ~09:20 | Prod is promote-only; `rots-dev` takes the continuous flow | `prod_mode: promote_only` (form answer) |
| 2026-11-11 09:15 | `rots-dev` and `rots-qa` are wanted as separate environments, `rots-qa` for the Steam/iOS builds | "maybe we should make a rots-dev.john2143.com and rots-qa.john2143.com (rots-qa = steam/ios build, dev = dev branch)" |

### Recommendations

| When | Choice | Quote |
|---|---|---|
| 2026-11-11 09:15 | A single build promoted end to end, its backend chosen at run time (D3) | "4. we can consider combined" |
| 2026-11-11 09:15 | Moving `rots4` to self-hosted Forgejo (D5) | "maybe we can consider moving to forgejo" |
| 2026-11-11 22:26 | Sign the Windows executable with the 2143 Labs LLC certificate; no Steam DRM wrapper | "Update our plan accordingly" (approving Steam plan D16) |
| 2026-11-11 22:26 | Digest pins, retention for held candidates, SBOM per artifact, OpenBao-gated promotion, missing PR gates (D4, D6–D9) | "Update our plan accordingly" (approving the plans as written) |

### Not decided

- Whether `qa` cuts need John too, or any developer may write `qa` pins.
- Forgejo internet reachability, and whether the seven other admins are demoted.
- Tester access control on `rots-qa`/`rots-dev`.
- `rots-dev` placement (nonprod cluster vs prod cluster).
- Marketing-version policy under build-once.
- Proton/Windows build host (Steam D14).
- Whether `argo` ever moves to Forgejo.

## 10. References

**GitHub** — deployments and environments; artifact attestations; self-hosted runner security; OIDC reference (`workflow_ref`, `actor_id`, `runner_environment`).

**Forgejo** — Actions OIDC; protected branches and unprotected file patterns; Authorized Integrations; release notes; SECURITY-POLICY.

**Argo CD** — ApplicationSet SCM and pull-request generators.

**Apple / Valve / Microsoft** — as cited in the Steam and iOS plans.

Per-claim source tables live in the four research reports named at the top of this document.
