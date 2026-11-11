# Steam QA delivery plan for ROTS

**Status:** Proposed — not started.
**Date:** 2026-11-11
**Owner:** John (Steamworks partner account, Apple account, runner hosts); implementation split across `2143-Labs/rots4`, this repo, and `dotfiles`.
**Scope:** getting every green `main` build of the ROTS client onto Steam for QA testers on Linux, Windows and macOS, and pointing those builds at an isolated QA backend. Store page, pricing, release and marketing are out of scope.
**Related:** [Deploying a private-repo game](deploying-a-private-repo-game.md) (the existing SeaweedFS binary and OpenBao CI-credential pattern this plan extends), [Multi-cluster](multi-cluster.md), [iOS delivery plan](ios_game_plan.md) (shares the build Mac, `rots-qa` and the protocol-version work).

Evidence labels used below: **Valve** — Steamworks documentation (`partner.steamgames.com/doc/...`, public); **Apple** — Apple developer documentation; **Repo** — read from the named file on 2026-11-11; **Probe** — reproduced on a 2143-Labs host on 2026-11-10/11; **Inferred** — reasoning no source states directly. Anything marked *Unverified* has a test in [Open questions](#10-open-questions).

---

## 1. Summary

ROTS ships QA builds on a **password-protected `qa` beta branch of the main app (4346770)**. CI uploads one Steam build containing a Linux, a Windows and a macOS depot after every green `main` (the Windows executable Authenticode-signed, since Valve ships whatever it is given), using `steamcmd` on a dedicated self-hosted uploader with a cached login token, so GitHub stores no Steam credential. Testers get access through the Steamworks partner account (staff) or Release State Override keys (everyone else). The client reads which Steam branch launched it and talks to a new **`rots-qa` environment** in this repo when that branch is `qa`, so one set of bytes can be promoted from `qa` to `default` without a rebuild.

The upload itself is the small part. The decisions that determine whether QA works are **who owns the app** (entitlement) and **which backend a build talks to** (identity); both are recorded below.

## 2. Current state

| Area | Today | Source |
|---|---|---|
| Steam app | App id `4346770`, paid, unreleased, store page in progress | Repo: `rots4/client/src/auth/steam.rs:15` |
| Steamworks in the client | `bevy-steamworks` (git pin) → `steamworks` 0.13.1 → `steamworks-sys` 0.13.0, which vendors the SDK redistributables and **links them dynamically** | Repo: `rots4/client/Cargo.toml:31`; crate `build.rs` |
| Steam ownership | The authserver calls `ISteamUser/CheckAppOwnership` for 4346770 on every Steam login and stores the answer in `social.steam_app_ownership` | Repo: `rots4/authserver/src/providers.rs`, `authserver/README.md:61` |
| CI | `rots4` `.github/workflows/build_nix.yml` on `[self-hosted, nixos]` only; builds Linux client/server/authserver; **no Windows or macOS job** | Repo |
| Windows code signing | A 2143 Labs LLC Authenticode certificate exists and is unused: there is no Windows build to sign. Type (OV/EV) and key custody unrecorded | John; [open questions](#10-open-questions) |
| Binaries | `s3://rots4-releases/builds/<sha>/rots4-client-linux` (bare Nix-built ELF) plus `latest/` | Repo; [SeaweedFS section](deploying-a-private-repo-game.md#3-publish-binaries-to-seaweedfs) |
| Backend | `apps/rots-web.yaml` (prod, bumped on every green `main`), `apps/rots-web-preview.yaml` (one environment per PR) | Repo |
| Client backend selection | `--auth-url` CLI flag only, default `https://rots.john2143.com/auth` | Repo: `rots4/client/src/main.rs:51` |
| Build identity | `BUILD_HASH` = git short hash, else `"unknown"`; crane builds have no `.git` and the flake sets no `ROTS_BUILD_HASH`, so every Nix build reports `unknown` | Repo: `rots4/shared/build.rs:131-138`, `rots4/flake.nix` |
| Protocol versioning | `ConnectRequest` carries name, location, colour and ticket — no version. Messages are postcard, which is not self-describing | Repo: `rots4/shared/src/event/server.rs:11` |
| Runners | Four 2143-Labs org runners (plus repo-level runners) on VM 101, all sharing `runnerCommon`: user `github-runner`, `HOME` = their wiped `workDir`, sandbox already relaxed (`RestrictNamespaces = false`, `SystemCallFilter = []`) | Repo: `dotfiles/nixos/github-configuration.nix:32-80,88-96,368-384` |

## 3. Goals and non-goals

**Goals**

1. Every green `main` reaches QA testers through the Steam client within minutes, on all three platforms, from one commit.
2. QA builds talk to an isolated backend; QA activity never creates prod accounts, sessions, characters or ownership rows.
3. Any build can be promoted to another branch or rolled back by pointing a branch at an existing BuildID, without rebuilding.
4. No Steam, Apple, S3 or code-signing credential is stored in GitHub, and no signing key material is stored in the repository or in OpenBao (D16).
5. Every bug report can name the exact commit, Steam branch and BuildID.

**Non-goals**

- Releasing the game, Early Access, store page, pricing, Steam Cloud, achievements.
- Automating promotion to the `default` branch (stays a human action; see D15).
- Notarised, universal macOS builds (required before public release; not for QA — see D10).

## 4. Steamworks model

Steam offers five handles. Each one's limits drive the decisions in §5.

| Object | What it is | What it cannot do |
|---|---|---|
| **App** `4346770` | The identity the client initialises with and the authserver checks ownership of | Change id — both ends hardcode it |
| **Depot** | One file set, OS-tagged in App Admin | Carry its OS in a build script (there is no OS key in VDF — Valve) |
| **Package** | The licence: which apps and depots an account may download | — this is the only entitlement knob |
| **Branch** | A named pointer to a BuildID, optionally password-protected | Grant access. A password hides a branch "including its name" from accounts that already own the app (Valve). It is not a licence |
| **Build account** | The Steam account `steamcmd` logs in as | Upload through any API; there is no upload key (Valve) |

Before release, an app is owned only by "the Steam accounts in the Steamworks partner account (or by anyone who has redeemed a Steam key)" (Valve, Builds). The Developer Comp package is auto-granted to partner-account members.

## 5. Decisions

### D1. Deliver QA builds on a beta branch of the main app, not Steam Playtest

- **Decision:** depots on app 4346770; branch `qa`; no Playtest app for now.
- **Why:** Playtest creates a *child* app id (Valve). The client initialises with 4346770 and the authserver checks ownership of 4346770, so a Playtest-only tester would be recorded as not owning the game and every Steam code path would be exercised against a licence the real game never sees. Playtest testers also cannot see the main app's branches (Inferred from Valve's Playtest separation).
- **Rejected:** Playtest (above); a separate demo app (Valve forbids keys for a demo that is not public); zip downloads (no auto-update, Steam auth behaves differently).
- **Revisit when:** external testing needs self-serve signups or more than the ~2,500 override keys. That requires the client and authserver to accept a second app id — a product change, not packaging.

### D2. Entitlement: partner accounts for staff, Release State Override keys for everyone else

- **Decision:** staff are added as users on the Steamworks partner account. Contractors and external QA receive **Release State Override** keys from the app's "Beta Testing" package. Dev Comp keys and Default Release keys are not used for QA (Valve: Dev Comp is "not intended to be used for basic testing"; Default Release keys unlock only after release).
- **Constraints (Valve, Keys):** override keys are generally capped at about 2,500 and reviewed case by case; a first-time developer waits **3 weeks after AppID creation** before any key request; activating a key removes the game from the tester's wishlist; keys never expire at launch and are revoked by banning them.
- **Consequence:** the 3-week clock gates the first external tester date, not CI. Check it in Phase 0.

### D3. Branch topology

| Branch | Who sets builds live | Password | Purpose |
|---|---|---|---|
| `default` | Human, App Admin only | n/a | Pre-release: what owners get unless they opt in. Post-release: what customers get |
| `qa` | CI, every green `main` | yes | Primary QA stream |
| `qa-<feature>` | Human, on demand | yes, per branch | Focused testing of one PR without freezing `qa` |
| `press` | Human | yes | Later; press and influencer builds |

- A branch and its password must exist **before** its first set-live. Valve: "if you wish for branch contents to remain private, you should set your branch password before setting a build live on the branch." Order: create branch → set password → issue keys → first set-live.
- Build scripts can set any branch live **except** `default` (Valve), and committing to a branch that does not exist fails after the upload completes.
- Rollback is setting an older BuildID live on the branch. Promotion is setting an existing BuildID live on another branch. Neither rebuilds.

### D4. One Steam build per commit, containing all depots

- **Decision:** one `run_app_build` uploads the Linux, Windows and macOS depots together.
- **Why:** Valve assigns a single BuildID only after every depot finishes, so `SetLive` switches all platforms atomically. Per-platform builds would let Mac and Linux testers run different commits.
- **Consequence:** a platform that fails to build blocks the Steam upload for that commit. Accepted: the previous BuildID stays live.
- *Unverified:* whether a build containing only some depots keeps the branch's other depots. Not relied on.

### D5. Upload from a dedicated self-hosted NixOS runner with a cached token

- **Where:** a new org runner on VM 101 (defined beside the others in `dotfiles/nixos/github-configuration.nix`) labelled `steam-upload`, running as its **own Unix user** (`rots-steam`), not `github-runner`. Compose it as `runnerCommon // { user = "rots-steam"; group = "rots-steam"; … }`: `orgRunner` merges `runnerCommon` last, which would reset the user.
  - **Why its own user:** every existing runner runs as `github-runner`, so a token in one runner's home is readable by any job, including pull-request jobs, on that VM (Repo).
- **Tool:** nixpkgs `steamcmd` (a `steam-run`-wrapped bootstrap that self-updates). It is unfree: allow `steamcmd` **and** `steam-unwrapped` (Probe). No Docker, no Steamworks SDK checkout: `run_app_build` is built into steamcmd and the SDK download is login-walled (Probe).
- **Sandbox:** reuse the existing `runnerCommon` overrides. `steam-run`'s bubblewrap needs user namespaces and mount syscalls (Probe), which those overrides already permit (Repo).
- **Token persistence:** the runner module sets `HOME` to `workDir` and deletes `workDir` on every start (Probe, nixpkgs `service.nix`), which would delete the login token. Set `extraEnvironment.HOME = "/var/lib/rots-steam/home"` (0700, owned by `rots-steam`); the token lives at `$HOME/.local/share/Steam/config/config.vdf`.
- **Login (Valve, "Using SteamPipe In A CI/CD Environment"):** a human runs `steamcmd +login <builder>` once on the host as `rots-steam`, enters the password and the emailed Steam Guard code, then `quit`. Every CI run uses `+login <builder>` **with no password**. Supplying the password again "will issue a new SteamGuard token", invalidating the cache. `+@NoPromptForPassword 1` makes a missing token fail fast (exit 5, Probe) instead of hanging.
- **Build account:** a fresh Steam account with exactly **Edit App Metadata** and **Publish App Changes To Steam** (Valve). Never logged in to a desktop client: one account allows one session at a time (Valve wiki).
- **Credentials in GitHub:** none. S3 read access uses the existing OIDC → OpenBao pattern ([CI credentials](deploying-a-private-repo-game.md#ci-credentials-github-oidc-to-openbao)) with a new read-only identity (D8).
- **Rejected:** `game-ci/steam-deploy` (passes the Steam password on every run, which Valve says mints a new guard token; its v3.2.2 defaults `releaseBranch` to `default`, which Valve refuses); community TOTP generation (needs the authenticator `shared_secret` in CI; not Valve-documented); containers (adds a root-equivalent socket to solve a problem the host already solves).

### D6. Serialise uploads three ways

Valve documents no per-app upload lock, and the current steamcmd contains no "already running" message (Probe). Overlapping uploads most likely both succeed and the last commit wins the branch, which can leave an older build live (Inferred). So:

1. one runner carries the `steam-upload` label;
2. the job sets `concurrency: { group: steam-upload-4346770, cancel-in-progress: false }` — never `true`, which could kill steamcmd between depot upload and commit;
3. the script holds `flock` on `/var/lib/rots-steam/upload.lock`.

### D7. Gate success on the log, not the exit code

steamcmd exit codes are undocumented; observed failures exit 5 or 6 (Probe), but community tooling reports failures that exit 0 and successes that do not.

- **Pass** only when all hold: exit status 0; the log contains `Successfully finished AppID 4346770 build (BuildID <n>).`; the log contains no `ERROR!`, `Login Failure` or `FAILED (` line. The often-quoted `Success! App '…' fully uploaded` does not exist in current steamcmd (Probe).
- **Exit 0 without a BuildID line** (e.g. `"Preview" "1"` left on) is a failure.
- **A BuildID line with a non-zero exit** means "uploaded, set-live unknown": warn and check the Builds page.
- Upload `BuildOutput/*.log` as a job artifact on every run. Valve: "look in your output directory for error information, not the console."
- Record the BuildID in the job summary and in `s3://rots4-releases/builds/<sha>/steam/build.json`.

### D8. Artifact contract: Steam-ready depot trees in SeaweedFS

Each platform build publishes a complete depot tree, not a bare binary:

```
s3://rots4-releases/builds/<sha>/steam/
  rots4-linux.tar.zst
  rots4-windows.tar.zst
  rots4-macos.tar.zst
  manifest.json           # sha, build hash, per-file sha256 of the three tarballs
  build.json              # written by the upload job: BuildID, branch, time
```

| Depot tree | Contents |
|---|---|
| `linux/` | `client` (mode 0755), `libsteam_api.so`, `assets/` |
| `windows/` | `client.exe` (Authenticode-signed, D16), `steam_api64.dll` (Valve-signed), `assets/` |
| `macos/` | `ROTS.app/Contents/{Info.plist, MacOS/client, MacOS/libsteam_api.dylib, Resources/assets/}` |

Invariants, asserted by the producer **and** re-asserted by the uploader:

- **The Steam API library sits beside the executable.** `steamworks-sys` links it dynamically, so a missing library is a loader failure before `main`, which the client's "Steam unavailable" fallback cannot catch (Repo). Copy it from `steamworks-sys`'s `OUT_DIR` so it matches the crate (crate issue #63).
- **`assets/` is in the depot root** (Linux, Windows). Bevy resolves assets relative to the executable, and Steam launches with the install directory as the working directory.
- **No `steam_appid.txt`.** Valve: "Make sure to remove the steam_appid.txt file when uploading the game to your Steam depot!"
- **The Windows executable is signed, and Valve's DLL is not.** `client.exe` carries the 2143 Labs LLC signature with an RFC 3161 timestamp; `steam_api64.dll` keeps the signature Valve shipped (D16). The uploader re-asserts both on the extracted tree.
- **No symlinks, no `.DS_Store`, `._*`, `__MACOSX`, `Thumbs.db`, `desktop.ini`, `*Zone.Identifier`.** Reports conflict on symlink handling in bundles; ship none.
- **Tar, never zip, never GitHub Actions artifacts.** `actions/upload-artifact` resets modes to 644, stripping the executable bit; this repo's guide already forbids Actions artifacts for these builds.
- **No archive inside a depot.** SteamPipe chunks files at ~1 MB and uploads only chunks the server lacks (Valve, Probe), so loose files re-upload almost nothing when unchanged; an archive changes nearly every chunk.
- **S3 access:** the platform build jobs write with the existing `rots4-ci-releases` role (main-push only). The uploader reads with a new **read+list-only** S3 identity and OpenBao role `rots4-steam-releases`, bound to `refs/heads/main` push, following steps 1–3 of [Publish binaries to SeaweedFS](deploying-a-private-repo-game.md#3-publish-binaries-to-seaweedfs).
- The existing bare `rots4-client-linux` upload stays as it is.

### D9. Linux depot client must not be a Nix-linked ELF

- **Problem:** a crane-built binary's ELF interpreter and RUNPATH point into `/nix/store`, which does not exist on a tester's Ubuntu or Steam Deck, so the client would fail to start and look like a broken download. (Inferred from how Nix links; the uploader's `patchelf --print-interpreter` check catches it.)
- **Decision:** build the Linux depot client against Valve's Steam Linux Runtime SDK container, as a separate flake output or CI step, with `libsteam_api.so` beside the binary and `RUNPATH=$ORIGIN`.
- **Fallback** if the runtime build is impractical: `patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 --set-rpath '$ORIGIN'` plus bundling the non-system libraries the client links directly.
- **Status:** chosen direction, validated in Phase 2. *Unverified* which runtime generation (scout vs sniper) and which libraries must be bundled.

### D10. macOS: build on the Mac, ship a `.app`, ad-hoc sign for QA

- **Build host:** the self-hosted GitHub runner on the new Mac that the [iOS plan (D13)](ios_game_plan.md#d13-build-host-the-mac-one-runner-two-job-labels) defines; this job runs on `[self-hosted, macOS, ARM64, steam]`. A `macos` label would separate nothing: GitHub already gives every macOS runner the `macOS` label, and labels are case-insensitive. The Apple SDK licence permits the build only "FOR EXECUTION ON AN APPLE-BRANDED PRODUCT RUNNING MACOS", so the NixOS runners cannot produce this binary (Apple). Hosted macOS runners are excluded by [this repo's rule for private-repo games](deploying-a-private-repo-game.md#3-publish-binaries-to-seaweedfs).
- **Target:** `aarch64-apple-darwin`, `MACOSX_DEPLOYMENT_TARGET=11.0`. The Steam client's floor is macOS 12 and the client is native arm64 (Valve FAQ, client beta notes, Probe of the shipping client).
- **Bundle:** assembled by a short script, not `cargo-bundle`/`cargo-packager`.
  - `Info.plist`: `CFBundleExecutable` = `client`, `CFBundleIdentifier` (chosen once, never changed), `CFBundlePackageType` `APPL`, `CFBundleShortVersionString`, `CFBundleVersion`, `LSMinimumSystemVersion` `11.0`, `NSHighResolutionCapable` `true`.
  - `libsteam_api.dylib` goes in `Contents/MacOS/`, beside `client` — **not** `Contents/Frameworks/`. It is a universal x86_64+arm64 dylib whose install name is `@loader_path/libsteam_api.dylib`, and it is already Developer ID-signed by Valve; do not re-sign it (Probe of the vendored file).
  - Assets go in `Contents/Resources/assets/`; the client sets `AssetPlugin.file_path` to `../Resources/assets` on macOS when no manifest-dir assets exist (Bevy resolves from the executable's directory, which is `Contents/MacOS`).
- **Signing for QA:** ad-hoc (`codesign --force -s -`), after `lipo` and bundle assembly. Mandatory on Apple Silicon; free (Apple).
- **Gatekeeper:** a Steam-installed, unsigned, unnotarised app is not blocked, because Gatekeeper checks only files with `com.apple.quarantine` and Steam's downloader never sets it (Apple; Probe of the shipping `steamclient.dylib`). A copy taken out of Steam (zip, AirDrop) *is* quarantined and blocked on macOS 15+.
- **Launch option:** App Admin → Installation → General Installation, OS macOS, Executable `ROTS.app`. Valve: bundle launches pick the best architecture; direct binary launches inherit the Steam process's.
- **Before public release (not QA):** universal binary (`lipo` of both darwin targets; Rosetta's general support ends after macOS 27 — Apple); Apple Developer Program ($99/yr); Developer ID signature with `--options runtime` and Valve's two entitlements `com.apple.security.cs.disable-library-validation` and `com.apple.security.cs.allow-dyld-environment-variables` (without them Steamworks and the overlay cannot load under hardened runtime); `notarytool` (most within 5 minutes, 98% within 15, 75 submissions a day — Apple); `stapler staple` on the `.app`; the App Admin checkboxes "64 Bit Binaries Included" and "App Bundles Are Notarized". Valve's policy requires notarisation; nothing enforces it (Valve staff, 2019). Treat it as a release gate, not a pipeline gate.
- **Credentials when that day comes:** the Developer ID `.p12` and an App Store Connect **Team** API key in OpenBao, read through the same OIDC pattern; imported into a temporary keychain per job.

### D11. Backend identity: the Steam branch selects the environment

- **Decision:** at startup the client reads `current_beta_name()` (available in `steamworks` 0.13.1, `app.rs:126`). On branch `qa` or `qa-*` it defaults `--auth-url` to the QA environment; on `default` (no beta) it defaults to prod. An explicit `--auth-url` always wins. The client logs the branch → URL decision at startup and shows it on the home menu.
- **Why:** one binary and one depot set per commit; promoting a BuildID from `qa` to `default` switches it to prod with no rebuild, so "we shipped the staging build" cannot happen.
- **Also:** register a second App Admin launch option, "Play (QA backend)", passing `--auth-url` explicitly, so a human can force QA from any branch.
- **Rejected:** separate QA and prod builds/depots (doubles every artifact and invites publishing the wrong one); relying only on launch options (invisible mistakes from a dropdown).

**The QA environment** (this repo):

- A new Application `apps/rots-qa.yaml` (proposed) from the existing `workloads/rots-web` chart: namespace `rots-qa`, host `rots-qa.john2143.com`, its own authserver secret key path, its own CNPG database, its own Temporal task queue, managed game servers.
- Images track the same `<sha7>` tags as the Steam `qa` build. The upload job bumps them **before** running steamcmd, mirroring `rots4/scripts/ci-argo-bump.sh`, so servers move first and clients follow minutes later.
- Steam ticket login and ownership checks must work there: it needs the same Steamworks publisher Web API key the prod authserver uses (stored under its own OpenBao path; see [Adding a secret](adding-a-secret.md)).
- *Open:* UDP port range and LoadBalancer address (prod uses 36000–37999 on `192.168.6.32`, previews 31000–34999 on `192.168.6.33`), and whether it runs on prod or the bigp nonprod cluster.

### D12. Build identity on every binary

- The flake passes `ROTS_BUILD_HASH` from `self.rev` / `self.dirtyShortRev` to every build, so crane builds stop reporting `unknown`. The Mac and Steam-runtime builds pass the same value.
- The home menu shows `<sha7> · <branch> · BuildID <n>`. Bug reports carry all three.
- The Steam BuildID is for display and telemetry only. Valve: `GetAppBuildId` "may change at any time based on backend updates to the game"; never use it for compatibility.

### D13. Add a protocol version to the connect handshake before external testing

- **Problem:** the server deploys from `main` and Steam clients update minutes later. `ConnectRequest` has no version and postcard is not self-describing, so a wire change makes an older client fail to decode rather than see a clear error.
- **Decision:** add `protocol_version: u16` to `ConnectRequest`, bump it on every wire-incompatible change, and have the server reject mismatches with a `ConnectRejected { reason }` the client shows ("client out of date — let Steam update").
- **When:** before the first external key is issued.

### D14. Windows: no depot until CI builds it

- **Decision:** the Windows depot is created in Phase 0 but stays out of the build script until a CI job produces `rots4-windows.tar.zst`. A hand-built executable is never uploaded.
- **Open:** where the Windows build runs — cross-compiled on the NixOS runners or a self-hosted Windows runner. Not researched; decided in Phase 4.
- **Client fixes that ship with it:** `#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]` so no console window opens behind the game; `steam_api64.dll` beside `client.exe`; and the executable signed at build time (D16).

### D15. Promotion to `default` stays manual

- Build scripts cannot set `default` live (Valve). After release, setting `default` live also needs Steam Mobile or SMS confirmation, and any security change on the account blocks it for 3 days (Valve).
- The Web API `ISteamApps/SetAppBuildLive` with `betakey=public` may be able to set `default` on an *unreleased* app without confirmation (Valve parameter docs; *Unverified*, contradicts the upload doc). Optional experiment; nothing depends on it.
- **Required before release:** prod's `deploy` job currently moves prod servers on every green `main`, while customers sit on a manually promoted `default`. Before release, prod deploys must follow the `default` promotion, or D13 must cover every gap.

### D16. Sign the Windows executable; never apply the Steam DRM wrapper

- **Decision:** `client.exe` is Authenticode-signed with the 2143 Labs LLC certificate at build time, with an RFC 3161 timestamp. `steam_api64.dll` ships exactly as `steamworks-sys` vendors it. No Steam DRM wrapper.
- **Valve neither signs nor re-signs uploaded files.** SteamPipe ships the bytes that are in the depot. The only server-side modification Valve documents is the opt-in wrapper: `drm_wrap` "posts your plaintext executable to the Steam back end… The wrap is performed server side, and then steamcmd downloads the wrapped executable", which is then uploaded and served (Valve).
- **No wrapper, because ownership is already gated in the client.** Valve: "use the API instead of the Steam DRM wrapper", and their FAQ warns the wrapper "is modifying your binary in the same way a virus might do" and draws antivirus false positives. The client initialises through `SteamworksPlugin::init_app(ROTS_STEAM_APP_ID)` and the authserver checks ownership (Repo), so the wrapper would buy obfuscation at the cost of a wrap step per commit and a signature that must be applied after wrapping.
- **If it is ever adopted:** wrap first, sign second. Wrapping rewrites the executable and invalidates any existing signature.
- **Why sign, given Steam:** SmartScreen is not the reason — Steam downloads and launches the game itself, so the file never gets the Mark of the Web that SmartScreen keys on (Inferred from Microsoft's scoping plus community reports of Steam installs). **Windows 11 Smart App Control is the reason**: it treats an executable that is "unsigned, or the signature is invalid" as untrusted and blocks it when its cloud reputation service cannot vouch for it (Microsoft), and a Rust binary rebuilt every commit has no reputation. Signing also lowers the antivirus false-positive rate, though by reputation rather than by guarantee (Inferred).
- **Do not re-sign Valve's DLL.** The vendored `steam_api64.dll` already carries an Authenticode certificate table whose subject is "Valve Corp." (Probe of the crate's `redistributable_bin/win64`); a second signature adds nothing and risks the chain.
- **The key does not live in OpenBao.** Since 2023-06-01 the CA/Browser Forum baseline requirements keep OV and EV code-signing keys in certified hardware (FIPS 140-2 Level 2 or Common Criteria EAL 4+) (CA/B Forum), so the signable material is a USB token or the CA's cloud signing service. OpenBao holds the token PIN or the cloud-signing credential, bound to the push-to-`main` lane, never to a pull request. Even if the current certificate predates the rule and still has an exportable `.pfx`, that file does not go into OpenBao.
- **Signed on Linux, not on Windows.** `jsign` does Authenticode from the NixOS runner over PKCS#11, YubiKey, DigiCert KeyLocker/ONE, Azure Key Vault or Google Cloud KMS (Project); `osslsigncode` with a PKCS#11 engine is the fallback.
- **When:** inside the Windows depot build, before the manifest is written, so the recorded sha256 and the SBOM describe the signed bytes and one build still serves `qa` and `default` (D4, D8). Signing at promotion instead would produce a different file per channel.
- **Rejected:** shipping unsigned (Smart App Control and antivirus exposure, for no saving); signing after a DRM wrap (no wrapper); a `.pfx` in OpenBao (against the CA/B rules, and it would put a long-lived signing key in reach of every job on the write lane); re-signing `steam_api64.dll`.
- *Unverified:* whether the certificate is OV or EV and whether it is on a token or in a cloud service. Both change only how the key is reached, not the pipeline shape ([open questions](#10-open-questions) 13).

## 6. Pipeline

```
rots4 CI (green main)
  build-linux   (NixOS runner, Steam runtime)  ─┐
  build-windows (D14; signed per D16, later)    ├─► s3://rots4-releases/builds/<sha>/steam/*.tar.zst
  build-macos   (Mac runner)                   ─┘          + manifest.json
                                                                │
  steam-publish (needs all builds; runs-on [self-hosted, steam-upload]; concurrency per D6)
    1. flock /var/lib/rots-steam/upload.lock
    2. read S3 via OpenBao role rots4-steam-releases; verify manifest sha256s
    3. bump apps/rots-qa.yaml image tags to <sha7> in this repo (servers first)
    4. wipe /var/lib/rots-steam/content; extract each tarball into content/<platform>/
    5. delete junk; assert D8 invariants (no symlinks, no steam_appid.txt, no /nix/store interpreter, 0755 client, client.exe signature verifies)
    6. render steam/app_build.vdf (Desc = "<sha> run <id>.<attempt>", SetLive = qa, Preview = 0)
    7. steamcmd +@ShutdownOnFailedCommand 1 +@NoPromptForPassword 1 +login <builder> +run_app_build <abs vdf> +quit
    8. gate per D7; write build.json; upload BuildOutput/*.log as artifacts
```

- **Full snapshots:** each depot build replaces the depot's file list with what is on disk under the mappings (Valve: a new build "may modify or remove any files which had been included in previous builds"). Staging is wiped every run; `FileExclusion` lines are a backstop, never the mechanism.
- **`BuildOutput`** (`/var/lib/rots-steam/output/`) is persistent and outside the content root. Its `.csm`/`.csd` cache speeds up scanning; losing it costs time, not upload volume.
- **Build scripts** live in `rots4/steam/`: `app_build.vdf.in` (absolute `ContentRoot` per depot, `"FileMapping" { "LocalPath" "*" "DepotPath" "." "Recursive" "1" }`, junk `FileExclusion`s) — depot ids come from Phase 0.
- **Pull requests** validate VDF changes with `"Preview" "1"` (prints the file manifest, uploads nothing). It still needs the builder login, so it runs only on the uploader and only for same-repo PRs that touch `steam/`.

## 7. Operating procedures

**Issuing access**

1. Staff: add to the Steamworks partner account (inherits Dev Comp).
2. External: assign one Release State Override key per person; record name, key, date in the key tracker (owner's choice of tool). Send the tester guide (below) and the `qa` access code.
3. Ending access: ban the keys with the key-banning tool, choosing the end-of-beta reason (Valve). Rotate the branch password when someone leaves.

**Tester guide (one page, sent with each key)**

- Steam → Games → *Activate a Product on Steam…* → enter key.
- Library → right-click ROTS → Properties → **Game Versions & Betas** → "Enter access code to unlock a private game version or beta" → code → **Check Code** → select `qa`.
- The home menu shows the build (`sha · branch · BuildID`); include it in every report.
- macOS: the first launch can sit on "Verifying…" for a while. Don't copy the game out of Steam.

**Smoke test after every set-live** (automatable as a follow-up job): a second Steam account that owns the app, never the builder, runs
`steamcmd +login <qa-account> +app_update 4346770 -beta qa -betapassword <code> validate +quit`. This exercises entitlement, password, depot-in-package and delta — none of which the upload's own success line proves.

**Promote** `qa` → `default`: App Admin → Builds → pick the BuildID → "Set build live for branch…" `default` → Preview Change → Set Build Live Now. Same bytes; D11 points them at prod.

**Roll back:** same gesture with an older BuildID on the affected branch. Then revert `apps/rots-qa.yaml` (or prod) if the server changed.

**Token compromise:** run `logout` / `clear_credentials` on the uploader, change the builder password, "Deauthorize all" Steam Guard devices, then repeat the one-time login. After release, a security change blocks set-live for 3 days. The blast radius before release is arbitrary content on the passworded branches; after release, the same plus whatever the account can set live.

**Pipeline failures**

| Symptom | Usual cause |
|---|---|
| exit 5, `No cached credentials and @NoPromptForPassword is set` | Token lost (HOME wiped, runner rebuilt). Repeat the one-time login |
| `ERROR! Failed 'DepotBuild …' - status = 6` | Missing permission or wrong `ContentRoot`/`LocalPath` (Valve) |
| `Failed to initialize build on server (Access Denied)` | Depots not published, or account lacks permissions |
| `ERROR! Failed to get application info …` | Wrong app id, or App Admin changes never published (Valve) |
| `ERROR! Failed to commit build … : Failure` | `SetLive` branch missing, or set to `default` |
| Testers install zero files on one OS | Depot not in Dev Comp / Beta Testing package. `licenses_for_app 4346770` in the tester's Steam console shows what they own (Valve) |
| `Invalid content configuration` on launch | No build live on the selected branch, bad launch option, or depot not owned (Valve) |
| Mac app bounces and quits | `libsteam_api.dylib` not beside the binary (`otool -L` should show `@loader_path/libsteam_api.dylib`) |
| Linux client "does nothing" | Nix interpreter in the depot binary (D9) or missing `libsteam_api.so` |

## 8. Implementation plan

Each phase ends with an observable exit criterion; the next phase does not start until it holds.

### Phase 0 — Steamworks configuration (John; no code)

- [ ] Create depots: ROTS Linux (OS Linux), ROTS Windows (OS Windows), ROTS macOS (OS macOS). Save, **Publish**.
- [ ] Add all three to the Developer Comp package and to the Beta Testing package.
- [ ] Set the install folder name; add launch options: Linux `client`, Windows `client.exe`, macOS `ROTS.app`, plus "Play (QA backend)" variants (D11).
- [ ] Create branch `qa` and set its password before any build exists.
- [ ] Create the builder Steam account; grant Edit App Metadata + Publish App Changes To Steam.
- [ ] Note the 3-week key clock (D2); request a first batch of Release State Override keys when allowed.
- [ ] Hand-upload a throwaway Linux build from a workstation to `qa`.

**Exit:** a second partner-account member installs from `qa` and the throwaway build launches. Every App Admin mistake (`Access Denied`, `Invalid content configuration`, empty installs) is found here, not in CI.

### Phase 1 — Build identity and protocol version (rots4)

- [ ] `ROTS_BUILD_HASH` from the flake (D12); menu shows sha, branch, BuildID.
- [ ] `protocol_version` in `ConnectRequest` with a readable rejection (D13).
- [ ] Branch-derived auth URL with logging and `--auth-url` override (D11).

**Exit:** a Nix build reports its commit; a mismatched client gets the rejection message; launching with `--auth-url` still overrides.

### Phase 2 — Steam-ready Linux depot tree (rots4)

- [ ] Steam Linux Runtime build of the client (D9), or the patchelf fallback.
- [ ] Assemble `linux/` per D8; publish `rots4-linux.tar.zst` + `manifest.json` from `build_nix.yml`.

**Exit:** the tarball extracted into an empty directory on a non-Nix Linux machine launches the client, which finds its assets and initialises Steamworks when started from Steam.

### Phase 3 — Uploader and QA environment (dotfiles, this repo, rots4)

- [ ] dotfiles: `rots-steam` user and group, `/var/lib/rots-steam` (0700), runner `2143-labs-steam` with label `steam-upload`, `extraEnvironment.HOME`, unfree predicate for `steamcmd` and `steam-unwrapped`, `steamcmd` in `extraPackages`.
- [ ] One-time interactive login as `rots-steam` (D5).
- [ ] SeaweedFS read-only identity + OpenBao role `rots4-steam-releases` (D8).
- [ ] This repo: `apps/rots-qa.yaml` and its secrets; decide ports and cluster (D11).
- [ ] rots4: `steam/app_build.vdf.in`, `scripts/steam-upload.sh`, `steam-publish` job (D6, D7); first run with `"Preview" "1"`, then real.

**Exit:** a green `main` produces a BuildID on `qa` without human action; the Phase 0 tester's Steam client updates to it within minutes and it talks to `rots-qa`; the smoke-test command succeeds.

### Phase 4 — macOS and Windows depots (parallel)

- [ ] Mac: runner, toolchain, bundle script, `AssetPlugin` path fix, ad-hoc sign, publish `rots4-macos.tar.zst` (D10).
- [ ] Windows: choose the build host, `windows_subsystem`, sign `client.exe` (D16), publish `rots4-windows.tar.zst` (D14).
- [ ] Add both depots to the build script.

**Exit:** one BuildID carries all three depots; a tester on each OS installs it from Steam (macOS verified on a Mac other than the build Mac, Windows on a machine with Smart App Control on); `osslsigncode verify` passes on the installed `client.exe`.

### Phase 5 — External QA

- [ ] Tester guide; key tracker; first external keys issued.
- [ ] Smoke test runs after every set-live.

**Exit:** a tester who has never seen the repo installs, plays against `rots-qa`, and files a report that names sha, branch and BuildID, without help.

### Before public release (tracked, not part of this plan)

D10 release requirements (universal binary, Developer ID, notarisation, stapling, Valve checkboxes); D15 prod-deploy gating; supported-OS checkboxes in App Admin.

## 9. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Wire change breaks testers' clients between server deploy and client update | High until D13 | Testers report "game broken" for a working server | D13; servers bumped before upload (D11) |
| QA traffic in prod | Certain without D11 | Polluted accounts, ownership rows, characters; QA tests prod signing keys | D11 QA environment |
| Overlapping uploads leave an older build live | Low with D6 | Testers on stale build | D6 three-layer serialisation |
| Builder token theft | Low | Arbitrary content on QA branches pre-release; more after | D5 separate user, 0700 HOME, two-permission account, no desktop login |
| Nix-linked Linux binary shipped | High without D9 | Linux client fails on every non-Nix machine | D9 build; uploader's interpreter check |
| Key request blocked by the 3-week rule | Depends on AppID age | External QA date slips | Check in Phase 0 |
| Valve enforces notarisation later | Low | macOS uploads rejected | D10 release path is already defined |
| Windows build blocked by Smart App Control on a tester's machine | Certain without D16 | Tester cannot launch; reads as a virus report | D16 signing with a timestamp; Phase 4 exit tests on a Smart App Control machine |
| Signing key custody stalls Windows CI | Medium until the certificate's form is known | No signed builds; Phase 4 slips | Open question 13; token on the runner's host or the CA's cloud service, both reachable from `jsign` |

## 10. Open questions

| # | Question | How to resolve |
|---|---|---|
| 1 | Does the current Nix `.#client` even find `libsteam_api.so`? | `nix build .#client && readelf -d result/bin/client \| grep -iE 'needed\|runpath'` |
| 2 | Steam Linux Runtime: which generation, which libraries to bundle (D9) | Phase 2 spike |
| 3 | Where does the Windows build run (D14) | Decide in Phase 4 |
| 4 | `rots-qa`: prod or bigp cluster; UDP range; LB address | Decide in Phase 3 against `apps/rots-web.yaml` and [Multi-cluster](multi-cluster.md) |
| 5 | Does a partial-depot build keep the branch's other depots (D4) | Throwaway branch, two builds |
| 6 | Does `SetAppBuildLive betakey=public` set `default` on an unreleased app (D15) | One API call against a throwaway build |
| 7 | Does an unchanged re-upload create a new BuildID | Re-run the upload job on the same sha |
| 8 | Does the uploader preserve the executable bit from file mode | Install the Linux depot on a clean machine, `ls -l` |
| 9 | Do `FileExclusion` patterns match dotfiles in subdirectories | Inspect a `"Preview" "1"` manifest |
| 10 | Does `../Resources/assets` work for Bevy in a bundle | First Mac build |
| 11 | Which Mac is the build Mac, and is it the nix-darwin host `mac` in dotfiles | John |
| 12 | Are all macOS testers on Apple Silicon (arm64-only QA builds) | Ask testers before Phase 4 |
| 13 | Is the 2143 Labs LLC certificate OV or EV, and is the key on a USB token or in the CA's cloud signing service | Read the certificate's issuing CA and its key-custody record; decides whether `jsign` uses PKCS#11 or a cloud keystore |
| 14 | Does the signed `client.exe` arrive byte-identical through Steam's delivery | `osslsigncode verify` on the installed file (Phase 4 exit) |

## 11. References

**Valve**
- Uploading to Steam — https://partner.steamgames.com/doc/sdk/uploading
- Branches — https://partner.steamgames.com/doc/store/application/branches
- Builds — https://partner.steamgames.com/doc/store/application/builds
- Depots — https://partner.steamgames.com/doc/store/application/depots
- Packages — https://partner.steamgames.com/doc/store/application/packages
- Testing on Steam — https://partner.steamgames.com/doc/store/testing
- Steam Playtest — https://partner.steamgames.com/doc/features/playtest
- Steam Keys — https://partner.steamgames.com/doc/features/keys
- Platforms (macOS requirements) — https://partner.steamgames.com/doc/store/application/platforms
- Steamworks API overview (library placement, `steam_appid.txt`) — https://partner.steamgames.com/doc/sdk/api
- ISteamApps Web API (`SetAppBuildLive`) — https://partner.steamgames.com/doc/webapi/ISteamApps
- ISteamApps client API (`GetCurrentBetaName`, `GetAppBuildId`) — https://partner.steamgames.com/doc/api/ISteamApps
- Steam macOS 11 support (client floor) — https://help.steampowered.com/en/faqs/view/659D-A19E-018A-81A6
- Steam DRM wrapper (`drm_wrap`, server-side wrap, antivirus caveat) — https://partner.steamgames.com/doc/features/drm

**Apple**
- Notarizing macOS software — https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Customizing the notarization workflow — https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
- Gatekeeper and runtime protection — https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web
- Disable library validation entitlement — https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation
- Rosetta changes — https://developer.apple.com/news/?id=w5ngl9k2
- Xcode and Apple SDKs Agreement — https://www.apple.com/legal/sla/docs/xcode.pdf

**Microsoft**
- Smart App Control FAQ (unsigned or invalidly signed apps are blocked) — https://support.microsoft.com/en-us/windows/security/threat-malware-protection/smart-app-control-frequently-asked-questions
- Sign your app for Smart App Control compliance (RSA and ECC both supported) — https://learn.microsoft.com/en-us/windows/apps/develop/smart-app-control/code-signing-for-smart-app-control

**Tooling**
- nixpkgs `steamcmd` — https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/st/steamcmd/package.nix
- nixpkgs GitHub runner module — https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/continuous-integration/github-runner/service.nix
- steamworks-rs (`build.rs`, issue #63) — https://github.com/Noxime/steamworks-rs
- `jsign` (Authenticode from Linux over PKCS#11, YubiKey, DigiCert KeyLocker/ONE, Azure Key Vault, Google Cloud KMS) — https://ebourg.github.io/jsign/
- CA/Browser Forum code signing baseline requirements (private-key hardware since 2023-06-01) — https://cabforum.org/working-groups/code-signing/requirements/
- GitHub Actions concurrency — https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency
