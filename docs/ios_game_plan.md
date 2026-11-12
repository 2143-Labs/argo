# iOS delivery plan for ROTS

**Status:** Proposed — not started.
**Date:** 2026-11-11
**Owner:** John (Apple Developer account, App Store Connect, the build Mac); implementation split across `2143-Labs/rots4`, this repo, and `dotfiles`.
**Scope:** shipping the ROTS client as a native iOS app. Every green `main` reaches internal TestFlight testers without human action, and the plan defines what must hold before external TestFlight and before App Store release. Android, iPad-specific layout, in-app purchase, and marketing are out of scope.
**Related:** [Steam QA delivery plan](steam_game_plan.md) (shares the build Mac, the `rots-qa` environment and the protocol-version work), [Release pipeline plan](release_pipeline_plan.md) (how one build is promoted across web, Steam and iOS; it proposes replacing D8's two flavours with run-time routing), [Deploying a private-repo game](deploying-a-private-repo-game.md) (the SeaweedFS binary and OpenBao CI-credential patterns this plan extends), [Adding a secret](adding-a-secret.md).

Evidence labels used below: **Apple** — Apple developer documentation, App Store Review Guidelines (as published 2026-10-16), App Store Connect help; **Project** — upstream project source, docs and issue trackers (Bevy, winit, crates, GitHub); **Repo** — read from the named file on 2026-11-11; **Probe** — reproduced on a 2143-Labs host on 2026-11-11; **Inferred** — reasoning no source states directly. Anything marked *Unverified* has a test in [Open questions](#10-open-questions). The research behind this plan is in `~/repos/ios-{bevy-port,ci-signing,distribution-policy,auth-backend}.md`, with audit trails under `~/repos/ai_research/`.

---

## 1. Summary

ROTS ships on iOS as **the same Bevy client crate, built for `aarch64-apple-ios` and wrapped in a small hand-written Xcode project** in `rots4/ios/`. CI on the self-hosted Mac archives it with `xcodebuild` after every green `main`, signs it manually with material read from OpenBao into a throwaway keychain, keeps the `.ipa` and dSYMs in SeaweedFS, uploads with `xcrun altool`, and adds the processed build to an internal TestFlight group through the App Store Connect REST API. GitHub stores no Apple credential. TestFlight builds talk to the **`rots-qa` environment** defined by the Steam plan; App Store builds are a separate, deliberately triggered archive that talks to prod.

The pipeline is the small part. Three things decide whether ROTS can ship on iOS at all:

1. **Input.** The client reads only keyboard and mouse; on iOS no gameplay input arrives, a paired controller does nothing, and text fields cannot be typed into. Touch is the largest single work item.
2. **Accounts.** App Review requires in-app account deletion, *including* auto-created guest accounts, and the authserver has no deletion route. Sign in with Apple plus the existing guest path is the cheapest compliant login set.
3. **Version skew.** App Store clients lag the server by days and there is no forced update. The wire protocol has no version and cannot evolve, and an incompatible datagram is dropped silently.

Rough size to an internally testable build: **3–5 weeks of one developer**, two to three of them on touch input (Inferred from the port inventory in D4–D6).

## 2. Current state

| Area | Today | Source |
|---|---|---|
| Client features | Default `steam`, `udp`, `clipboard`, `testing`. `steam` cannot build for iOS (`steamworks-sys`'s build script ends `panic!("Unsupported OS")`); `arboard` (`clipboard`) has no iOS backend | Repo: `rots4/client/Cargo.toml`; crate sources |
| Input | Gameplay reads only `ButtonInput<KeyCode>`, `ButtonInput<MouseButton>` and `MouseMotion` (135 references, 10 files). Menus already work with taps through `bevy_picking` | Repo; Project (winit, bevy_winit, bevy_picking sources) |
| Text entry | The custom widget reads `event.key_code`; iOS sends `Key::Character` with an unidentified physical key, so typing does nothing. Nothing sets `Window::ime_enabled` | Repo: `rots4/client/src/ui/text_input.rs:226` |
| Config storage | `Config::load_from_main_dir()` reads `config.yaml` from the working directory and creates it with `.unwrap()` when missing; a signed app bundle is read-only, so this panics at launch | Repo: `rots4/shared/src/lib.rs:297-350` |
| Client backend selection | `--auth-url` CLI flag (clap), default `https://rots.john2143.com/auth`. iOS has no command line | Repo: `rots4/client/src/main.rs:51` |
| Native login | Non-Steam native builds offer only guest play: `POST /guest` creates a character and a claim code. Discord and au2143 OAuth exist only in the web build. The session token is held in memory only | Repo: `rots4/client/src/auth/mod.rs`, `rots4/authserver/src/api.rs:236-249` |
| Account lifecycle | 17 authserver routes, **no deletion route**. `characters.account_id` is `ON DELETE SET NULL`, so deleting an account row would orphan character names and live claim codes. `account_identities` is keyed `(provider, subject)` with no linking | Repo: `rots4/authserver/src/api.rs:49-65`, `rots4/authserver/migrations/20261030_000000_accounts_sessions.sql:21`, `rots4/authserver/src/sessions.rs:301` |
| Game transport | UDP via message-io. `/play` returns `server.udp` = `GAME_UDP_HOST:port`, and `GAME_UDP_HOST` is a hostname in this repo's chart. The client's UDP `connect` is `.unwrap()`ed, and message-io binds every client socket to `0.0.0.0:0` | Repo: `rots4/authserver/src/api.rs:416-427`, `workloads/rots-web/templates/authserver.yaml:112-113`, `rots4/shared/src/netlib.rs:594-596` |
| WebSocket transport | Prod also serves `wss /ws/<k>`, but every handshake must carry the Anubis cookie a browser earned on the page; `/auth` is exempt | Repo: `workloads/rots-web/templates/anubis.yaml:2-11`, `httproute-ws.yaml` |
| Protocol versioning | `ConnectRequest` has no version. Event enums are generated from struct *order*, so inserting a type shifts every later variant index. An undecodable datagram is logged and dropped | Repo: `rots4/shared/src/event/server.rs:11`, `rots4/shared/build.rs:6-29,99-115`, `rots4/shared/src/netlib.rs:724-729` |
| User content | Chat is compiled out (`//chat::ChatPlugin`); user text is display names and character names | Repo: `rots4/server/src/lib.rs:389` |
| LAN gyms | The `testing` feature broadcasts and listens for UDP beacons and spawns a second Bevy app with its own GPU device | Repo: `rots4/server/src/gym_beacon.rs`, `rots4/client/src/gym_discovery.rs` |
| Build identity | `ROTS_BUILD_HASH` env var, else git, else `unknown` | Repo: `rots4/shared/build.rs:131-139` |
| Secrets hygiene | `.gitignore` has no pattern for `*.p8`, `*.p12`, `*.mobileprovision`, `*.ipa`, `*.xcarchive`, `DerivedData/` | Repo: `rots4/.gitignore` |
| Build Mac | nix-darwin host `mac` (aarch64-darwin) with homebrew casks and agenix; **no** GitHub runner, Tailscale or Xcode | Repo: `dotfiles/flake.nix:573`, `dotfiles/nixos/darwin-configuration.nix` |

## 3. Goals and non-goals

**Goals**

1. Every green `main` reaches internal TestFlight testers without human action, from the same commit the Steam `qa` branch gets.
2. TestFlight builds talk to `rots-qa`; only a deliberately built release candidate talks to prod.
3. No Apple, OpenBao or S3 credential is stored in GitHub; signing material never touches the Mac's login keychain.
4. Every bug report names the commit and the TestFlight build number; every crash symbolicates.
5. A client that the server cannot talk to says so and links to the App Store, instead of failing silently.
6. The app passes App Review on its first submission: deletion, login, user-content, IPv6 and privacy obligations are designed in, not discovered.

**Non-goals**

- Android, Apple TV, visionOS, and an iPad-specific layout (iPad support is an open decision, see [Open questions](#10-open-questions)).
- In-app purchase or any paid unlock on iOS.
- LAN gyms on iOS (needs an Apple-approved entitlement; see D3).
- Steam or Discord login on iOS for the first release (see D9).
- Automating App Store submission. Submission and release stay human actions (D15).

## 4. Apple model

Apple's handles, and the limit of each that drives §5.

| Object | What it is | What it cannot do |
|---|---|---|
| **Developer Program membership** | $99/year; individual (personal legal name is the public seller, permanently) or organization (legal entity + D-U-N-S) | Change seller name later; individuals can add 50 App Store Connect users, who are not program team members (Apple) |
| **App ID** | Explicit bundle id (`com.john2143.rots`, proposed) plus capabilities such as Sign in with Apple | Change after the first upload; "managed" capabilities such as multicast need Apple's approval first (Apple) |
| **Apple Distribution certificate** | Team-owned signing identity, created only by Account Holder or Admin | Be created by a CI key with a lower role (Apple) |
| **App Store provisioning profile** | Binds App ID, certificate and entitlements | Run a build on a device outside TestFlight/App Store (Apple TN3125) |
| **App record** | Name, bundle id, SKU, metadata, privacy answers | Change bundle id or SKU after the first upload (Apple) |
| **Build** | `CFBundleShortVersionString` + `CFBundleVersion`; processed by Apple before testers see it; TestFlight builds expire after 90 days | Be rolled back once released on the App Store — only superseded (Apple) |
| **TestFlight group** | Internal: up to 100 App Store Connect users, no review. External: up to 10,000 testers, Beta App Review on the first build of each version | Add internal testers who are not App Store Connect users (Apple) |
| **App Store Connect API key** | Team key with a fixed role; the Account Holder must first request API access | Be scoped to one app, renamed, or re-scoped (Apple) |
| **Sign in with Apple key** | A separate `.p8` the authserver uses to sign its client secret | Be shared with the App Store Connect API key (separate key types, Apple) |

## 5. Decisions

### D1. A native app of the existing client crate

- **Decision:** build the existing `client` **bin** crate for `aarch64-apple-ios` (and `aarch64-apple-ios-sim` for the simulator) and package it as an iOS app. No lib/staticlib refactor.
- **Why:** Bevy 0.20's own iOS example builds a bin target in an Xcode run-script phase and `lipo`s it into the bundle; `#[bevy_main]` expands to Android-only code since Bevy 0.16 (Project). At least three Bevy games are live on the App Store with no Bevy-attributable rejection found (Project, App Store listings).
- **Rejected:** wrapping the wasm build in a web view — its transport is the Anubis-gated WebSocket (§2), and Apple's 4.2 minimum-functionality rule targets repackaged web content (Inferred). A separate mobile crate — doubles the game.

### D2. Packaging: a hand-written Xcode project, archived by `xcodebuild`

- **Decision:** `rots4/ios/ROTS.xcodeproj` with one app target whose only phases are a run script and a Resources copy, in Bevy's `examples/mobile` shape. The script runs `cargo build --release --target aarch64-apple-ios --bin client --no-default-features --features udp` and copies the binary to `$TARGET_BUILD_DIR/$EXECUTABLE_PATH`.
- **Why Xcode at all:** since 2026-04-28 uploads must be "built with Xcode 26 or later using an SDK for iOS 26"; from April 2027, the iOS 27 SDK and a deployment target of iOS 15 or later (Apple). App Store Connect validates the bundle's `DT*` keys, `MinimumOSVersion`, `LC_BUILD_VERSION` SDK and asset catalog, which Xcode stamps and pure-Rust bundlers do not (Apple, Project).
- **Bundle contents:**
  - `assets/` (21 MB) as a folder reference at the bundle root. Bevy resolves assets from `current_exe().parent()`, which on iOS is the `.app` root, so `AssetPlugin` needs no change (Project).
  - `Info.plist`: `CFBundleIdentifier`, `CFBundleShortVersionString`, `CFBundleVersion` (D14), `LSRequiresIPhoneOS`, `UIRequiredDeviceCapabilities` `arm64` + `metal`, `UILaunchScreen` dictionary (a storyboard is not required), landscape-only `UISupportedInterfaceOrientations`, `UIStatusBarHidden`, `ITSAppUsesNonExemptEncryption` (D17), `ROTSBuildHash` and `ROTSAuthURL` (D8). Do not hand-write `MinimumOSVersion` or `UIDeviceFamily`; Xcode derives them. No `NSAppTransportSecurity` dictionary: ATS does not govern raw sockets or rustls (Apple).
  - A single 1024×1024 icon in an asset catalog.
  - `PrivacyInfo.xcprivacy` declaring `NSPrivacyAccessedAPICategoryFileTimestamp` / `C617.1`: Rust `std::fs` on Apple calls `stat`/`fstat`, and missing required-reason declarations are an **upload-time** rejection since 2024-05-01 (Apple, Project). Confirm with `nm -u` on the built binary whether `mach_absolute_time` (boot-time category `35F9.1`) is also needed.
  - `IPHONEOS_DEPLOYMENT_TARGET = 15.0`: Apple rejects below 13.0 today and requires 15.0 from April 2027. Bevy's sample still says 12.0 and is stale (Apple, Project).
- **Not Nix:** nixpkgs ships macOS SDKs only, and its Darwin stdenv exports the macOS `SDKROOT`; iOS cross-compilation is an explicit non-goal upstream (Project). Use rustup and Xcode on the Mac; crane stays for Linux and wasm.
- **Rejected:** `cargo-bundle --format ios`, `xbuild`, `crossbundle` (no `DT*` keys or `Assets.car`); `cargo-mobile2` (its Bevy template is 0.16 and expects a staticlib with FFI). **XcodeGen** is the fallback if hand-maintaining `project.pbxproj` becomes painful.

### D3. iOS feature set: `--no-default-features --features udp`

| Feature | On iOS | Reason |
|---|---|---|
| `udp` | on | The game transport |
| `steam` | off | Does not build; no Steamworks SDK for iOS (Project) |
| `clipboard` | off | `arboard` has no iOS backend; a `UIPasteboard` shim can come later (Project) |
| `testing` | off | LAN gym discovery sends and receives UDP broadcast, which needs `com.apple.developer.networking.multicast` — a managed entitlement Apple must approve per App ID before it can appear in *any* profile, including TestFlight (Apple TN3179). It also spawns a second GPU device. Guideline 2.5.19 (2026-10-16) rejects "hidden, dormant, or undocumented features", so it is compiled out, not hidden (Apple) |
| `web`, `inspector` | off | Not applicable |

Add a `mobile` feature alias in `client/Cargo.toml` so the Xcode script and CI name one thing.

### D4. Storage and configuration move to the app container

- **`config.yaml`:** load from and write to Application Support under a bundle-id directory, created if absent; never panic on a missing or unwritable file. The keybind data in it should stay backed up (Apple). Desktop behaviour is unchanged.
- **Command line:** clap must not parse Xcode's process arguments on iOS. Read launch configuration from Info.plist keys (`ROTSAuthURL`, D8) and call `parse_from` with an empty argument list.
- **Session token:** store the bearer token in the Keychain (`security-framework`, already in `Cargo.lock` through `rustls-platform-verifier`) with a `…ThisDeviceOnly` accessibility class. On iOS a memory-only token is a functional defect: the OS evicts backgrounded games routinely, and a guest character is reachable only through its token or claim code, so a cold start orphans it (Repo, Apple). Delete the item on any 401 and on account deletion. *Unverified:* Keychain items are widely reported to survive reinstall, which is benign here.

### D5. Touch and text input

- **Input seam:** route gameplay reads through one virtual-input layer (on top of `Config::pressing_keybind`) so touch, keyboard and later controllers feed the same actions. `MovementAction::move_input_dir` is already a `Vec2` in the protocol, so a stick can write it directly instead of synthesising four keys (Repo).
- **On-screen controls:** a bevy_ui twin-stick overlay plus action buttons and explicit submit/cancel buttons, reading `Touches` (~600–900 lines, Inferred). No released touch-joystick crate supports Bevy 0.20: `virtual_joystick` pins 0.19, `bevy_touch_stick` is dead at 0.13, and the input-manager crates have no touch input type (Project).
- **Camera:** `CursorGrabMode::Locked` fails softly on iOS (`client/src/camera.rs:337`); camera look comes from a drag region.
- **Text:** replace the custom widget with Bevy 0.20's `bevy_ui_widgets::TextInput`, which sets `ime_enabled` on focus (raising the soft keyboard through winit's `becomeFirstResponder`) and consumes `Key::Character`/`Ime` events (Project). Enter and Escape never arrive from the soft keyboard, so the join-code field, the name confirmation and Escape-to-pause each need an on-screen control or a player can soft-lock.
- **Controllers:** gilrs has no iOS backend (`Gilrs::new()` returns `NotImplemented`), so a paired controller does nothing. Not required: no guideline requires touch or controllers on iOS — 2.4.3 is Apple TV-scoped — but the HIG expects a touch fallback whenever controllers are supported (Apple). Deferred; vendoring the open gilrs iOS merge request or a `GCController` bridge are the options.
- **Menus need no work:** `bevy_picking` turns touches into primary-button presses, and the 17 systems that react to `Added<Pressed>` already respond to taps (Project).

### D6. Lifecycle: tear down on suspend, reconnect on resume

- Backgrounding gives about five seconds before suspension; sockets may be reclaimed and Metal refuses new command buffers from a background app (Apple).
- On `AppLifecycle::WillSuspend`/`Suspended`: stop the message-io node and suppress the reconnect overlay. On `WillResume`/`Running`: enter the existing `NetworkGameState::Reconnecting` path, which already re-runs `/play` and re-dials, instead of reusing a dead socket (Repo). *Unverified on device.*
- Keep `WinitSettings::game()`. Do **not** copy `WinitSettings::mobile()` from Bevy's example: it arms the timer implicated in a thaw stall that ends in a watchdog kill (winit #4679, Project).
- Set `GlobalClusterSettings.gpu_clustering = None` unless the light count needs it (five extra passes plus a readback per frame on physical iOS, bevy #25198), and cap the task pool and tokio workers (bevy #16762).
- **UIScene by April 2027:** Apple: with the latest SDK, an app without the UIScene life cycle "won't launch". winit 0.30.13 — Bevy 0.20's pin — has not adopted it (winit #4224, fix #4723 unmerged). Invisible on the iOS 26 SDK; a launch failure on the iOS 27 SDK that becomes mandatory in April 2027. Adding only the scene manifest gives a **black screen**; the fix is the manifest plus `bevy_ios_app_delegate` or a winit patch (Project). Tracked as a release gate, re-checked at every Bevy upgrade.
- Safe-area insets (HUD under the notch and home indicator) are not exposed by Bevy until winit 0.31 (bevy #23003); `bevy_ios_safearea` is the interim (Project). Release gate.

### D7. Networking: UDP only, IPv6-safe

- **The defect:** on an IPv6-only network with NAT64 — the configuration App Review uses (guideline 2.5.5) and the norm on cellular — DNS64 synthesises an AAAA record for the server hostname, message-io opens an `AF_INET6` socket and binds it to `0.0.0.0:0`, the bind fails (`EINVAL` reproduced on Linux, Probe), and `netlib.rs:594-596` panics on the `.unwrap()`. *Unverified on Darwin*; expected to match.
- **Fix (about fifteen lines in `shared/src/netlib.rs`, no server change):** resolve `(host, port).to_socket_addrs()` and collect every candidate; for each, `connect_with` a `UdpConnectConfig` whose `source_address` is the wildcard of the candidate's own family (`0.0.0.0:0` or `[::]:0`); delete the `.unwrap()` and treat failure as retryable; move to the next candidate after ~5 s without world arrival, using the existing `ConnectAttempt` liveness signal (Apple, Repo). No iOS-only socket path: Apple asks for address-family-agnostic code (Apple).
- **`/play` response:** keep `udp` exactly as it is and add `udp_host` and `udp_port` beside it. Old clients ignore unknown keys (`client/src/auth/mod.rs:738-760` is a hand-rolled lookup); new clients prefer the new fields and fall back to a bracket-aware parse of `udp`. `dial_target()` compares `udp` as a string (`client/src/network.rs:1073-1087`), so its formatting must not change (Repo).
- **Not needed:** an AAAA record for the game host (DNS64 handles it); `NSLocalNetworkUsageDescription` (only the excluded LAN gym touches the local network); anything for cellular UDP (Apple, RFC 4787).
- **Rejected:** moving iOS to the WebSocket transport. It would need a native implementation of the Anubis proof-of-work challenge whose algorithm, difficulty and cookie name are deployment configuration (Repo, Probe).

### D8. Backend identity: baked per build, with the QA flavour fenced off by Apple

The Steam plan selects the backend from the Steam branch at run time so one set of bytes can be promoted. iOS cannot do that cleanly: the build submitted to the App Store is the build that was tested in TestFlight (Apple), and no researched API distinguishes TestFlight from App Store at run time.

- **Decision:** the backend is an Info.plist key, `ROTSAuthURL`, set at archive time. Two flavours:
  - **QA** — every green `main`; `ROTSAuthURL = https://rots-qa.john2143.com/auth`; exported with `testFlightInternalTestingOnly = true`, which makes Apple refuse it for external TestFlight and the App Store (Apple). A QA build therefore cannot be shipped to customers by mistake.
  - **Release** — `workflow_dispatch` only; `ROTSAuthURL` = prod; `testFlightInternalTestingOnly = false`. It goes to the internal group first for a smoke test, then is submitted.
- External TestFlight builds (Phase 5) use the release export settings with the QA URL; the workflow takes `backend` and `audience` inputs.
- The home menu shows `<sha7> · <build number> · <backend host>`, as the Steam client shows its branch.
- **Rejected:** run-time TestFlight detection through the receipt path or StoreKit's transaction environment — not researched, and a wrong guess sends production users to QA (*Unverified*, Inferred).
- **Depends on:** the `rots-qa` environment ([Steam plan D11](steam_game_plan.md#d11-backend-identity-the-steam-branch-selects-the-environment)). Its authserver additionally needs the Sign in with Apple configuration (D9).

### D9. Login: guest, then Sign in with Apple; third-party logins last

Guideline 4.8 applies when a *third-party or social* login authenticates the primary account; the app must then also offer an equivalent privacy-preserving login. An app whose only logins are Sign in with Apple and an anonymous guest never triggers it (Apple). Shipping shapes, in order:

| Shape | 4.8 | 5.1.1(v) deletion | Cost |
|---|---|---|---|
| **(a) Guest only** — the build iOS gets today with `steam` off | Not triggered | **Binding** — auto-created guest accounts must be deletable (Apple) | D10 deletion |
| **(b) + Sign in with Apple** — target for external testing | Not triggered | Binding, plus Apple token revocation | (a) + the endpoints below |
| **(c) + Steam / Discord** | Triggered, satisfied by (b) | Binding, plus in-app credential revocation | (b) + D11 linking + an `ASWebAuthenticationSession` relay |

- **Decision:** internal TestFlight ships (a). Sign in with Apple lands before the first external build. (c) is out of scope until linking (D11) exists.
- **Client:** native `ASAuthorizationController` flow from Rust with `objc2-authentication-services` 0.3.2 — no Swift shim. Its presentation-anchor method is macOS-gated in the binding; declare it in an inherent `impl` inside `define_class!`. The anchor `UIWindow` comes from Bevy's `RawHandleWrapper`. The delegate and the presentation-context provider are **weak** references and must be retained (a non-send resource) until the callback fires (Project). Request **no scopes**: ROTS sends no email, and a no-scope request still returns the stable `sub`; the player names their character through the existing `/characters/name` route.
- **Server** (`authserver/src/apple.rs`, beside `tickets.rs`; no new crate — `jsonwebtoken` with `rust_crypto` and `reqwest` already cover it, Repo):
  - `POST /apple/nonce` → server-minted nonce, stored and single-use. Apple echoes the nonce unhashed (Apple).
  - `POST /apple/native` → verify the identity token: **RS256** against Apple's JWKS selected by `kid` (Apple's prose says "E256"; the live JWKS and discovery document say RS256, Probe), `iss = https://appleid.apple.com`, `aud` = the bundle id, `exp`, nonce. Then exchange the authorization code at `/auth/token` (no `redirect_uri` for native) with an ES256 client secret, store the refresh token encrypted, and call the existing `log_in(…, "apple", sub, …)` so guest attachment works exactly as for Steam.
  - `GET /providers` reports `apple` only when configured.
  - Migration: widen the provider check to `apple`; add an Apple-credentials table and a nonce table. Do not reuse `oauth_states` (redirect-shaped, `return_to NOT NULL`).
- **Secrets:** the Sign in with Apple `.p8`, key id and Team id per environment, through [Adding a secret](adding-a-secret.md).
- **Client on launch:** call `getCredentialState(forUserID:)`; it is the only signal when a user deletes their Apple Account (Apple).
- **Rejected:** au2143 as the "equivalent option" or as "our own account system" — the exemption requires *exclusive* use of your own system, and whether au2143 sign-up allows a private email is unanswered ([Open questions](#10-open-questions)); guest-only as a 4.8 answer — a guest session is not a login service (Apple, Inferred).
- **Never** require Steam login or Steam ownership on iOS: 3.1.1 forbids unlocking functionality by license keys or similar mechanisms, and 3.1.3(b) allows cross-platform entitlements only if the same items are also offered as in-app purchases (Apple). Ownership is recorded but not enforced today (Repo); keep it that way.

### D10. Account deletion, including guests

- **Requirement:** "If your app supports account creation, you must also offer account deletion within the app" (5.1.1(v), since 2022-06-30). Apple's FAQ: auto-created guest accounts are in scope; deactivation is insufficient; support-ticket deletion is reserved for regulated industries, which games are not (Apple).
- **Endpoint:** `DELETE /me` (name to taste), one transaction:
  1. Snapshot the session ids to end, as `/claim` does.
  2. Copy any Apple refresh-token ciphertext into a `social.apple_revocations` outbox.
  3. Delete sessions, then `characters WHERE account_id = $1` (cascades states and shard rows), then identities, then the account.
  4. After commit: signal each Temporal session workflow to log out, and evict each character from the live world through the coordinator primitive `/join-code` uses.
- **Guest arm:** a guest is a `characters` row with `account_id IS NULL` plus a session (Repo). The same endpoint accepts a guest token, deletes its session, and deletes the character only if `account_id` is still `NULL`.
- **Sign in with Apple:** revoke through `POST https://appleid.apple.com/auth/revoke` from the outbox with retry; if no token is held, deletion still proceeds and the user is directed to Apple's settings (Apple TN3194). `POST /apple/notifications` handles `consent-revoked` and **`account-deleted`** (not `account-delete`), verified as a JWS against Apple's keys, idempotent and quick to acknowledge (Apple).
- **Client:** a reachable "Delete account" control with one confirmation; afterwards delete the Keychain token (D4).
- **Privacy policy text** must state what remains for seconds to minutes (instance snapshots, the live players state) instead of claiming instant erasure everywhere (Inferred from the deletion path).

### D11. Identity linking before external testers

- **Problem:** `login_account` creates a fresh account for every unseen `(provider, subject)` (Repo). A player who starts on iOS with Apple and later signs in on Steam gets two accounts and two sets of progress — the failure Apple's own guidance warns about. Email cannot be the join key: Apple relay addresses never match a Steam or Discord address (Apple).
- **Decision:** `UNIQUE (account_id, provider)`; `POST /link/{provider}` (session required, guests refused) returning `{authorize_url}` rather than a 302; `GET /identities`; `POST /unlink/{provider}` returning **403** on the last identity; linking an identity owned by another account returns **409** with no account details and is never forced; merge only when one side is empty (one never-played character, no ownership rows). Extend `/claim` for any pairing-code flow rather than building a parallel one.
- **When:** before external TestFlight (a test cohort can be wiped; customers' duplicate accounts cannot be merged after the fact).
- **Rejected:** PlayFab-style `forceLink`, which its own documentation says can orphan the other account (Project).
- **If (c) ever ships:** start native OAuth with an app-side `POST /{provider}/native/start` and a server-relayed one-time handoff redeemed with an app-generated verifier. Opening `/{provider}/login` directly in `ASWebAuthenticationSession` shares Safari's cookies, and the authserver reads the `rots_session` cookie **before** the bearer token (`authserver/src/sessions.rs:25-46`), so it would bind and then end the user's *web* session (Repo).

### D12. Version skew: negotiate in JSON, freeze the handshake, gate on a minimum build

App Review takes "at least 50% of submissions in less than 24 hours and 90% in less than 48 hours"; phased release spreads an update over seven days and can be paused for 30; anyone can still download manually; there is no forced update; and installed apps stay installed indefinitely (Apple). Meanwhile servers deploy on every green `main`.

This extends [Steam plan D13](steam_game_plan.md#d13-add-a-protocol-version-to-the-connect-handshake-before-external-testing) and must ship **in one release before any iOS build exists that cannot be force-updated**:

1. **Self-describing negotiation over HTTP.** Every authserver request carries `X-Rots-Client: ios/<marketing>/<build>/<protocol>`. Add `GET /api/v1/client-config?platform=…&build=…&protocol=…` returning `{status, min_supported_build, recommended_build, protocol: {min, max}, store_url}`. `/play`, `/guest` and `/apple/*` answer **409 `client_outdated`** with the store URL (not 426, which RFC 9110 ties to an `Upgrade` header). A missing header means a legacy client and is allowed; the client fails open if the config call fails. Policy lives in Helm values in this repo, so raising a floor is an auditable commit.
2. **Frozen UDP prefix.** `protocol_version: u16` is the first field of `ConnectRequest`; `ConnectRequest` stays first in `server.rs`; `ConnectRejected { reason }` moves to the top of `client.rs` with a frozen layout; the server decodes a prefix-only probe type before the real one. postcard ignores trailing bytes, so a new client reaches an old server but not the reverse (Project, Repo). Also add `proto` to game-ticket claims, so the authserver refuses before a socket opens.
3. **Record the skew.** `client_platform`, `client_build`, `client_protocol`, `client_seen_at` on `social.sessions`, updated on `/play`, plus an OpenTelemetry counter. No data exists on how long old App Store versions linger; ROTS must measure it.
4. **Bump strategy:** lockstep with forced update through TestFlight and launch. Its cost: a submission that bumps the protocol needs a prod server speaking the new protocol *while it is in review* (2.1: "turn on your back-end service"), while every installed client still speaks the old one. Protocol-pinned server pools — the authserver already creates one StatefulSet per instance from a PodTemplate (`authserver/src/k8s.rs`), so a `protocol` label is the seam — are the upgrade once iOS players are numerous. Decided before public release.
5. Never gate the build that is in review (2.1), and make the update prompt a plain link to the App Store page, not something that looks like an in-app update action (3.2.2) (Apple).

### D13. Build host: the Mac, one runner, two job labels

- **Runner:** nix-darwin `services.github-runners.rots4-mac` registered to `2143-Labs/rots4` only, so no other repository's jobs land on the machine holding signing material (Inferred). `ephemeral = false`: with `true`, the module deletes its state directory on start (Project). Registration token from agenix, outside the Nix store.
- **Labels:** the default labels already include `macOS` and `ARM64`, and labels are case-insensitive — so `macos` separates nothing (Project). Add `extraLabels = [ "ios" "steam" ]`; the iOS job runs on `[self-hosted, macOS, ARM64, ios]`, the Steam macOS build on `[self-hosted, macOS, ARM64, steam]`. One runner process runs one job at a time; add a second instance (own work directory) only if queueing hurts.
- **Environment:** the module replaces `PATH` with `bash coreutils git gnutar gzip nix` plus `extraPackages`. Add `curl jq openssl xxd awscli2 rustup` and append `/usr/bin /usr/sbin /bin /sbin` so `xcrun`, `codesign` and `security` resolve (Project).
- **Network:** Tailscale (`services.tailscale`, the open-source daemon, the only variant that runs before login) to reach `openbao.ts.2143.me`; the S3 endpoint `192.168.6.31:8333` is on the LAN (Project; whether the Mac is on that LAN is open).
- **Xcode:** installed out of band with `xcodes` (it stores an Apple ID password, so never in a workflow); then `xcodebuild -license accept`, `-runFirstLaunch`, and once per Xcode version `xcodebuild -downloadPlatform iOS`. Jobs select Xcode with `DEVELOPER_DIR`, never `xcode-select -s`. Pin the macOS/Xcode pair: Xcode 26.4–26.6 needs macOS Tahoe 26.2+, Xcode 27.x needs Tahoe 26.6+ (Apple).
- **The launchd risk:** the nix-darwin runner is a **LaunchDaemon** (`_github-runner`, no `SessionCreate`), while GitHub's own installer uses a per-user **LaunchAgent** with `SessionCreate`. A daemon "cannot display any GUI" and uses the global security context (Apple TN2083); the only public report says service mode breaks `codesign` while `run.sh` works (actions/runner#3407). Resolve before writing the workflow, in this order:
  1. daemon as shipped + temporary keychain → `codesign -s "Apple Distribution: …"` on a dummy file;
  2. daemon with `serviceOverrides.SessionCreate = true`;
  3. only if both fail, a LaunchAgent on a dedicated builder account with auto-login (which requires FileVault off — see the managed-Mac question).
- **Runner updates:** the module passes `--disableupdate`, and GitHub stops serving runners more than 63 days behind; bump the flake input on a cadence (Project).
- **Updates of macOS itself:** nix-darwin exposes only `AutomaticallyInstallMacOSUpdates`; real deferral needs MDM (Apple). Turn automatic major upgrades off.

### D14. Signing: manual, from OpenBao, into a throwaway keychain

- **Decision:** `CODE_SIGN_STYLE=Manual` with one Apple Distribution `.p12` and one App Store provisioning profile.
- **Why not automatic signing:** `-allowProvisioningUpdates` with an API key works without an Apple ID in Xcode, but needs an **Admin**-role team key and still wants a local Apple Development identity at archive time — a certificate-churn loop on ephemeral keychains (Apple, Project).
- **Material in OpenBao:** one KV entry (proposed `john2143-com/default/rots4-ios-asc`) holding the `.p8`, the `.p12` and its password, the profile, and the ids. Read with `scripts/ci-openbao-read.sh rots4-ci-ios …` under a new role bound to `refs/heads/main` pushes and `runner_environment: self-hosted`. Only the `.p8`, `.p12` and password are secret; ids can be repository variables.
- **API key:** a **Team** key with the **App Manager** role — the lowest role covering upload, TestFlight tester management, export compliance and submission (Apple). The Account Holder must first request API access, which Apple approves case by case (Apple).
- **Keychain per job** (GitHub's documented recipe, Project):
  - `create-keychain` in `$RUNNER_TEMP`;
  - `set-keychain-settings -lut 21600`;
  - `unlock-keychain`;
  - `import … -T /usr/bin/codesign`, never `-A`, which Apple calls insecure;
  - `set-key-partition-list -S apple-tool:,apple: -s`. This step is mandatory: without it `codesign` tries to show an unlock dialog no one can answer and fails with `errSecInternalComponent` (Apple DTS);
  - append, not replace, the user search list;
  - pass `OTHER_CODE_SIGN_FLAGS="--keychain $KC"`;
  - `delete-keychain` and remove the installed profile in `if: always()`.
  - Never touch the login keychain, and never sign as root.
- **WWDR intermediates** must be in the System keychain for a launchd context to build the chain (Project, community); install once in the nix-darwin activation script.
- **Repository hygiene first:** add `*.p8`, `AuthKey_*.p8`, `*.p12`, `*.mobileprovision`, `*.provisionprofile`, `*.ipa`, `*.xcarchive`, `DerivedData/`, `xcuserdata/` to `rots4/.gitignore`.
- **Triggers:** `push` to `main` and `workflow_dispatch` only. A GitHub environment cannot enforce that here — this organization is on GitHub Free and `rots4` is private, where environments, branch protection and required reviewers are all unavailable (GitHub, Probe). The gate is the OpenBao role instead: `event_name=push`, `ref=refs/heads/main`, `runner_environment=self-hosted` for the continuous builds, and a separate release role bound to `event_name=workflow_dispatch` + `workflow_ref` + `actor_id=John` for anything store-facing ([release pipeline plan](release_pipeline_plan.md)). On a private repository anyone who can open a pull request can compromise a self-hosted runner (Project), so no PR ever reaches this job.

### D15. Upload and distribution

- `xcodebuild -exportArchive` with `method = app-store-connect` (`app-store` is the deprecated spelling), `destination = export`, `signingStyle = manual`, `manageAppVersionAndBuildNumber = false`, `uploadSymbols = true`, `testFlightInternalTestingOnly` per D8.
- Upload with `xcrun altool --upload-package` and the team key (`API_PRIVATE_KEYS_DIR`). altool is deprecated only for notarisation, and within altool `--upload-app` is superseded by `--upload-package` (Apple). `-exportArchive` with `destination = upload` is the alternative that also uploads symbols; this plan keeps its own dSYMs (D16) and uses the local `.ipa` for S3.
- TestFlight is plain REST with an openssl-minted ES256 JWT (20-minute maximum lifetime; re-mint per call, Apple, Probe):
  1. poll `GET /v1/builds?filter[app]=…&filter[version]=<build>&filter[preReleaseVersion.version]=<marketing>&include=buildBetaDetail` until `processingState` is `VALID` (fail on `FAILED`/`INVALID`; Apple flags only processing beyond 24 hours);
  2. `POST /v1/betaBuildLocalizations` with "What to Test" (commit subject and sha);
  3. `POST /v1/betaGroups/{id}/relationships/builds`.
- **Success gate — all must hold:** archive and export exit 0; altool reports success; the build is `VALID`; `buildBetaDetail.internalBuildState` is `READY_FOR_BETA_TESTING` (not `MISSING_EXPORT_COMPLIANCE`); the group call returned 204. "The upload command exited 0" alone is not success: testers see nothing until the build is valid *and* in a group.
- Submission for App Review, the release date and phased release stay manual in App Store Connect.
- **Rejected:** fastlane — its own CI mocks Apple's tools, `upload_to_app_store` is currently broken by an App Store Connect schema change, `upload_to_testflight` still calls the superseded `--upload-app`, and nixpkgs' 2.240.1 is inside GHSA-hqmj-jmgc-wmwp (Project); `match` duplicates OpenBao. **Xcode Cloud** — Apple-hosted and reads source through Apple's GitHub App, which this repo's rule for private-repo games excludes (Project, [rule](deploying-a-private-repo-game.md#3-publish-binaries-to-seaweedfs)).

### D16. Version numbers, build identity, artifacts

- `CFBundleShortVersionString` = `client/Cargo.toml` `version` (`0.1.2` today; three integers, no suffix, Apple).
- `CFBundleVersion` = `<run_number>.<run_attempt>` (plus a fixed offset if the workflow is ever renamed). `GITHUB_RUN_NUMBER` does not change on a re-run while `GITHUB_RUN_ATTEMPT` does, so a plain run number collides when a run is retried after a successful upload (Project). macOS requires build numbers to increase across versions while iOS does not (Apple), so use the same scheme for the Steam macOS bundle and the difference stops mattering.
- `ROTS_BUILD_HASH=$GITHUB_SHA` for the cargo build and in the `ROTSBuildHash` plist key, so the binary is identifiable without running it. The git sha never goes in `CFBundleVersion` (integers only).
- **dSYMs:** the Xcode target has no link step, so Xcode's `dsymutil` never sees Rust code, and Cargo defaults to unpacked debug info on Apple targets (Project). The iOS release profile sets `debug = "line-tables-only"`, `split-debuginfo = "packed"`, `strip = "none"`; copy the `.dSYM` into the archive before export. Expect mangled Rust frames; keep `rustfilt` for offline symbolication. *Unverified* until a forced crash symbolicates.
- **S3:** `s3://rots4-releases/builds/<sha>/ios/` gets `ROTS.ipa`, `ROTS.xcarchive.zip` (`ditto -c -k --keepParent`), `ROTS.app.dSYM.zip`, `ExportOptions.plist` and `build-metadata.json` (sha, marketing version, build number, Xcode version, flavour, App Store Connect build id). The existing 90-day retention job covers the prefix; it uses GNU `date`, so it stays on the Linux runner (Repo).

### D17. App Store paperwork decided early

- **Bundle id and SKU** are immutable after the first upload; choose them in Phase 0.
- **Device family:** device support cannot shrink after release (Apple); decide iPhone-only vs iPhone + iPad before the first submission. iPhone/iPad apps appear on Apple-silicon Macs and Apple Vision Pro by default; opt out unless supported.
- **Storefronts:** exclude China mainland (NPPA approval and ICP filing) and Vietnam (game licence) (Apple).
- **Price:** free on iOS. Free needs no Paid Apps Agreement; any paid unlock brings in 3.1.1 parity with Steam (Apple).
- **Export compliance:** TLS here is rustls with `aws-lc-rs`, an industry-standard algorithm *not* provided by the OS. Apple routes that to the row whose only document is the French encryption declaration, needed only for distribution in France (Apple). Answer once, set `ITSAppUsesNonExemptEncryption` to match, and let the CI PATCH confirm. A France decision is open.
- **User content (1.2):** chat is compiled out, so the scope is display and character names. A name filter, a report action, a block list and a published contact satisfy it; re-enabling free-text chat raises all four to full strength (Apple, Repo).
- **Privacy:** privacy-policy URL in App Store Connect **and** reachable in the app (5.1.1(i)); App Privacy answers — User ID, Gameplay Content, Other User Content, plus Coarse Location / Device ID if the authserver retains IP addresses; no tracking, so no ATT prompt (Apple, Inferred).
- **Age rating:** questionnaire under the 2026 system; new descriptors due 2027-01-12. "Infrequent cartoon or fantasy violence" is 9+ (Apple).
- **EU DSA:** every account must declare a status; declaring non-trader keeps the app listed; TestFlight is unaffected (Apple). ROTS is sold on Steam, which points toward trader status — a legal call.
- **Reviewer access (2.1):** guest play works without credentials; servers must be up during review, which D12's gate must not block.

## 6. Pipeline

```
rots4 CI — push to main (QA flavour) or workflow_dispatch (backend, audience inputs)
  ios-testflight   runs-on [self-hosted, macOS, ARM64, ios]
                   environment ios-testflight (main only); permissions id-token: write
                   concurrency { group: ios-testflight, cancel-in-progress: false }
    1. rustup target add aarch64-apple-ios; xcodebuild -version (DEVELOPER_DIR pinned)
    2. ci-openbao-read.sh rots4-ci-ios → .p8, .p12, profile into $RUNNER_TEMP (umask 077)
    3. temporary keychain (D14); install profile
    4. xcodebuild archive  (run script: cargo build --features mobile, ROTS_BUILD_HASH=$GITHUB_SHA;
                            MARKETING_VERSION, CURRENT_PROJECT_VERSION=<run>.<attempt>, ROTSAuthURL per flavour)
    5. copy .dSYM into the archive; xcodebuild -exportArchive (D15) → ROTS.ipa
    6. ci-openbao-read.sh rots4-ci-releases → s3 cp ROTS.ipa, xcarchive.zip, dSYM.zip, metadata
                                              → s3://rots4-releases/builds/<sha>/ios/
    7. xcrun altool --upload-package ROTS.ipa --platform ios --api-key … --api-issuer …
    8. poll /v1/builds until VALID → What to Test → add to internal group
    9. gate per D15; write App Store Connect build id to build-metadata.json and the job summary
   10. always: delete keychain, profile, key files
```

- The job does not wait for the Steam `steam-publish` job and does not block it; both depend only on a green `main`. The `rots-qa` servers move with the Steam pipeline's image bump; TestFlight processing takes minutes longer than a Steam upload, so iOS testers always meet servers at least as new as their client (Inferred).
- Rust build cache: a persistent `CARGO_TARGET_DIR` outside the runner work directory; DerivedData and the archive in `$RUNNER_TEMP`.
- TestFlight builds expire after 90 days. A quiet `main` is covered by a monthly scheduled `workflow_dispatch`.

## 7. Operating procedures

**Adding internal testers:** add the person as an App Store Connect user (a role from Developer up, or Marketing), then to the internal group. Capacity: 100, or about 51 on an individual membership (Apple). They need iOS 16+ and the TestFlight app. Enable "Test iPhone and iPad apps on Apple silicon Macs" on the group if a Mac should test.

**Tester guide (one page):**

- Install TestFlight; accept the email invitation; install ROTS.
- The home menu shows `sha · build · backend`; include it in every report.
- Report through TestFlight's screenshot feedback. Crashes are shared automatically (Apple).
- If the game says it is out of date, update from TestFlight.

**Crashes and feedback:** Xcode Organizer → Crashes, and App Store Connect → TestFlight → Feedback (downloadable for 120 days). Symbolicate against the dSYM from `builds/<sha>/ios/`. Watchdog and memory (jetsam) kills do not appear there (Apple); suspect them when a tester reports a silent exit during loading.

**Release:**

1. Run the workflow with `backend=prod`, `audience=store`.
2. Smoke-test that build from the internal group against prod.
3. In App Store Connect, attach it to the version, complete metadata, and submit with "manually release".
4. After approval, confirm prod servers accept its protocol (D12), then release — phased for updates.

**There is no rollback.** A bad release is fixed by a new version, optionally with expedited review; phased release can be paused (Apple).

**Raising the minimum supported build:** a commit to the Helm values (D12), only after `client_seen_at` shows the old builds have drained, and never above a build that is currently in review.

**Credential lifecycle:**

- Distribution certificate and profile: watch `expirationDate` through the API. Renew from the Account Holder/Admin account, update OpenBao, and the next run uses them. An expired certificate does not affect live apps, only new uploads (Apple).
- API key compromise: revoke it in App Store Connect, mint a new team key, update OpenBao.
- `.p12` compromise: revoke the certificate; already-shipped builds keep working, then re-issue.

**Xcode / macOS upgrade:** install the new Xcode beside the old one, run `-license accept`, `-runFirstLaunch` and `-downloadPlatform iOS`, then change `DEVELOPER_DIR` in one commit. Upgrade macOS only to a version the pinned Xcode supports.

**Pipeline failures**

| Symptom | Usual cause |
|---|---|
| `errSecInternalComponent` from `codesign` | Keychain partition list not set, or the launchd context cannot reach the keychain (D13 test order) |
| `codesign` hangs | Same; a UI prompt no one can answer |
| `xcrun: error` / `codesign: command not found` | `/usr/bin` missing from the runner's `PATH` (D13) |
| No profiles found matching the bundle id | Profile not installed into `~/Library/Developer/Xcode/UserData/Provisioning Profiles` for the runner's `HOME`, or the profile name differs from `PROVISIONING_PROFILE_SPECIFIER` |
| `ITMS-90725` | SDK below Apple's floor: Xcode too old |
| `ITMS-90534` | Beta or unsupported Xcode used for an upload |
| `ITMS-90870` | Launch screen missing (`UILaunchScreen`) |
| `ITMS-91053` | Required-reason API used without a declaration in `PrivacyInfo.xcprivacy` |
| Build stuck in `MISSING_EXPORT_COMPLIANCE` | `ITSAppUsesNonExemptEncryption` absent and the PATCH not applied |
| Upload rejected for a duplicate build number | Re-run of a run that already uploaded without `run_attempt` in `CFBundleVersion` |
| Launch panics with no window | `config.yaml` in the working directory (D4) or UDP bind on NAT64 (D7) |
| Black screen on launch | UIScene manifest added without the delegate fix (D6) |
| Tester's client sits at "connecting" forever | Protocol mismatch before D12 lands (datagrams dropped silently) |

## 8. Implementation plan

Each phase ends with an observable exit criterion; the next phase that depends on it does not start until it holds. Phases 1 and 2 run in parallel.

### Phase 0 — Apple account and App Store Connect (John; no code)

- [ ] Decide individual or organization enrollment; enroll. (Organization: D-U-N-S, up to 5 + 2 business days.)
- [ ] Request App Store Connect API access; create a **Team** key with **App Manager**.
- [ ] Register explicit App ID `com.john2143.rots` (or the chosen id) with Sign in with Apple enabled; create a Sign in with Apple key.
- [ ] Create the Apple Distribution certificate and an App Store provisioning profile.
- [ ] Create the app record (name, bundle id, SKU, primary language); declare the DSA status; create the internal TestFlight group.
- [ ] Store `.p8`, `.p12` + password, profile and ids in OpenBao; create role `rots4-ci-ios` ([Adding a secret](adding-a-secret.md)).
- [ ] On the Mac, by hand: archive Bevy's `examples/mobile` under this bundle id at version `0.0.1`, with `PrivacyInfo.xcprivacy` and `ITSAppUsesNonExemptEncryption`; upload it; install it through TestFlight.

**Exit:** the throwaway build reaches a phone through TestFlight. Every account, certificate, profile, privacy-manifest and export-compliance mistake is found here, not in CI.

### Phase 1 — Mac runner and signing in CI (dotfiles, rots4)

- [ ] dotfiles: Tailscale; runner `rots4-mac` (labels `ios`, `steam`; `extraPackages`; `/usr/bin` on `PATH`; agenix token); WWDR intermediates in the System keychain; Xcode installed and pinned (D13).
- [ ] Run the D13 three-step `codesign` test and record which launchd context works.
- [ ] rots4: `.gitignore` signing patterns (D14).
- [ ] rots4: `ios-testflight` workflow (D14–D16) building the Phase 0 throwaway project.

**Exit:** a push to `main` puts a new throwaway build into the internal group with no human action; the job gate passes; `builds/<sha>/ios/` exists; no key material remains on the Mac after the job.

### Phase 2 — Shared prerequisites with the Steam plan (rots4, this repo)

- [ ] Build identity ([Steam D12](steam_game_plan.md#d12-build-identity-on-every-binary)) and the `rots-qa` environment ([Steam D11](steam_game_plan.md#d11-backend-identity-the-steam-branch-selects-the-environment)), if not already done.
- [ ] D12 items 1–3: `X-Rots-Client`, `/client-config`, 409 `client_outdated`, frozen handshake prefix, `proto` claim, skew columns. Supersedes the simpler Steam D13.

**Exit:** an older desktop client against a newer server shows "update required" instead of hanging; `client-config` policy changes through a values commit.

### Phase 3 — Port to a testable build (rots4)

- [ ] `mobile` feature alias (D3); Xcode project and bundle per D2.
- [ ] Config storage, Info.plist launch configuration, Keychain session token (D4).
- [ ] Touch layer, camera drag, `TextInput`, on-screen submit/cancel (D5).
- [ ] Suspend/resume teardown and reconnect; `gpu_clustering`; worker caps (D6).
- [ ] IPv6-safe connect; `udp_host`/`udp_port` (D7).
- [ ] Menu shows sha, build number and backend host (D8).

**Exit:** on a physical iPhone, a guest:

- plays a full session against `rots-qa` on cellular;
- does the same on an IPv6-only network (macOS Internet Sharing with NAT64);
- backgrounds for one minute, returns, and is reconnected;
- types a character name and a join code.

### Phase 4 — Every green `main` to internal TestFlight

- [ ] Point the Phase 1 workflow at `rots4/ios/` with the QA flavour.
- [ ] dSYM emission and a deliberate test crash.
- [ ] Monthly scheduled run for build expiry.

**Exit:** a merge to `main` reaches internal testers within the hour; a tester's report names sha and build; a forced crash appears symbolicated (Rust frames possibly mangled) in Xcode Organizer.

### Phase 5 — Accounts and policy for external testers

- [ ] Account deletion, guest and account arms, with UI (D10).
- [ ] Sign in with Apple, client and server, both environments (D9).
- [ ] Apple token revocation outbox and server-to-server notifications (D10).
- [ ] Identity linking (D11).
- [ ] Name filter, report, block, contact (D17); privacy policy in-app and in App Store Connect.
- [ ] External TestFlight: Test Information, feedback email, review contact; release export settings with the QA URL (D8).

**Exit:** the first external build passes Beta App Review; a tester deletes their account in-app and its rows, characters and claim codes are gone from the `rots-qa` database.

### Before public release (tracked, not part of this plan)

- UIScene adoption before the April 2027 SDK floor (D6).
- Safe-area layout; on-device thermal and memory trimming of grass, water, shadows and MSAA.
- D12 bump strategy decided; prod deploys gated on protocol compatibility, as [Steam D15](steam_game_plan.md#d15-promotion-to-default-stays-manual) already requires.
- D17 paperwork: screenshots, App Privacy, age rating, export compliance (France), storefront exclusions, device family.
- Release flavour exercised end to end.

## 9. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| launchd context cannot sign | Medium | No CI signing on the Mac | D13 test order before any workflow work; LaunchAgent fallback |
| Touch work runs long | High | Phase 3 slips | Size it first; ship menus-only touch plus twin-stick before polish |
| Protocol change strands App Store clients | Certain without D12 | Players see a hung "connecting" screen and leave reviews | D12 in Phase 2, before any external build |
| App Review rejection on deletion, login or user content | High without D9–D11, D17 | Submission loop of 1–3 days each | Phase 5 exit is Beta App Review, which applies the same guidelines |
| IPv6-only rejection or cellular panics | Certain without D7 | 2.5.5 rejection; crashes on carriers | D7 in Phase 3; NAT64 in the Phase 3 exit |
| UIScene deadline missed | Low if tracked | App fails to launch on the iOS 27 SDK; uploads blocked from April 2027 | Release gate; check winit at every Bevy upgrade |
| Signing material leaks from the Mac | Low | Arbitrary builds signed as ROTS | Repo-scoped runner, main-only environment, per-job keychain, App Manager key, revocation procedure |
| Apple app transfer or entity change after Sign in with Apple ships | Low | `sub` is team-scoped; identities orphaned (Apple) | Decide individual vs organization before Phase 5 |
| macOS update strands the pinned Xcode | Medium | CI down until reinstall | Automatic major upgrades off; upgrade procedure in §7 |
| Mac is employer-managed | Unknown | May forbid holding a distribution key; FileVault blocks the LaunchAgent fallback | Answer before Phase 1 |

## 10. Open questions

| # | Question | How to resolve |
|---|---|---|
| 1 | Individual or organization enrollment? (Public seller name, tester headroom ~51 vs 100) Is 2143 Labs LLC a registered legal entity? | Evidence for the entity: the Windows Authenticode certificate is issued to `O=2143 Labs LLC` of Kensington, Maryland, which means a CA has identity-vetted it ([current state](steam_game_plan.md#2-current-state)). Organization enrollment additionally needs a D-U-N-S number; John confirms, before Phase 0 |
| 2 | Is the build Mac company-managed (FileVault, MDM, policy on holding signing keys)? | John, before Phase 1 |
| 3 | Which macOS and Xcode are on the Mac? | `sw_vers; xcodebuild -version` |
| 4 | Is the Mac on the LAN with `192.168.6.31:8333`, or only reachable over Tailscale? | `curl -sI http://192.168.6.31:8333` from the Mac |
| 5 | iPhone only, or iPad too? | John, before the first submission |
| 6 | Bundle id | John, Phase 0 (immutable afterwards) |
| 7 | Does au2143 sign-up work without an email? (Only matters if au2143 is ever offered on iOS) | John |
| 8 | Distribute in France (export-compliance document)? | John |
| 9 | Does the authserver retain client IP addresses? (App Privacy answers) | Read authserver logging and tables |
| 10 | Does the binary import `_mach_absolute_time` (boot-time reason `35F9.1`)? | `nm -u` on the first iOS build |
| 11 | Does the launchd daemon context sign (D13)? | D13 test order, Phase 1 |
| 12 | Does archive-only need `xcodebuild -downloadPlatform iOS` on a clean install? | First Phase 1 run |
| 13 | Do `--keychain` in `OTHER_CODE_SIGN_FLAGS` and the packed dSYM work as described? | Phase 1 / Phase 4 runs |
| 14 | altool flag spelling: `--api-key/--api-issuer` (2025 man page) vs `--apiKey/--apiIssuer` (older help) | `xcrun altool --help` on the Mac |
| 15 | Does App Store Connect accept `hasAccessToAllBuilds` on group creation as auto-distribution? | Create the group through the API in Phase 0 |
| 16 | Does the soft keyboard appear through `ime_enabled` on device, and does the NAT64 bind fail the same way on Darwin? | Phase 3 device test |
| 17 | Jetsam and thermal ceilings on the oldest supported device | Phase 3 device test |
| 18 | Can a reliable run-time signal distinguish TestFlight from App Store (would allow Steam-style promotion, D8)? | Research spike; not on the critical path |

## 11. References

**Apple — distribution and policy**
- App Store Review Guidelines — https://developer.apple.com/app-store/review/guidelines/
- 5.1.1(v) account deletion — https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion
- App Review — https://developer.apple.com/distribute/app-review/
- Submitting (SDK and target floors, April 2027) — https://developer.apple.com/app-store/submitting/
- Upcoming requirements — https://developer.apple.com/news/upcoming-requirements/
- TestFlight overview — https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
- Upload builds — https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/
- Accounts and roles — https://developer.apple.com/help/app-store-connect/manage-your-team/overview-of-accounts-and-roles/
- Program enrollment — https://developer.apple.com/help/account/membership/program-enrollment/
- D-U-N-S — https://developer.apple.com/help/account/membership/D-U-N-S/
- EU DSA trader requirements — https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/
- App privacy details — https://developer.apple.com/app-store/app-privacy-details/
- Age ratings — https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions
- Encryption export documentation — https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation/
- `ITSAppUsesNonExemptEncryption` — https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption
- Privacy manifest files — https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
- Required-reason API — https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
- Phased release — https://developer.apple.com/help/app-store-connect/update-your-app/release-a-version-update-in-phases/
- Release options — https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option/
- iPhone/iPad apps on Apple silicon Macs — https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/manage-availability-of-iphone-and-ipad-apps-on-macs-with-apple-silicon/
- IPv6 support — https://developer.apple.com/support/ipv6/

**Apple — build, signing, API**
- Xcode system requirements — https://developer.apple.com/xcode/system-requirements/
- `CFBundleVersion` — https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion
- `CFBundleShortVersionString` — https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring
- App Store Connect API keys — https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api
- API tokens — https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests
- `GET /v1/builds` — https://developer.apple.com/documentation/appstoreconnectapi/get-v1-builds
- Build uploads API — https://developer.apple.com/documentation/appstoreconnectapi/build-uploads
- App Store provisioning profile — https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-connect-provisioning-profile/
- Certificates overview — https://developer.apple.com/help/account/certificates/certificates-overview/
- TN3125 provisioning profiles — https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
- TN3147 notarization tool migration (altool scope) — https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool
- TN2083 daemons and agents — https://developer.apple.com/library/archive/technotes/tn2083/_index.html
- TN3179 local network privacy — https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- Multicast entitlement — https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast
- TN3187 UIScene life cycle — https://developer.apple.com/documentation/technotes/tn3187-migrating-to-the-uikit-scene-based-life-cycle
- TN3208 launch screen — https://developer.apple.com/documentation/technotes/tn3208-preparing-your-apps-launch-screen-to-meet-app-store-requirements
- Preventing insecure network connections (ATS scope) — https://developer.apple.com/documentation/security/preventing-insecure-network-connections
- Background execution time — https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time
- HIG game controls — https://developer.apple.com/design/human-interface-guidelines/game-controls

**Apple — Sign in with Apple**
- Authenticating users — https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple
- Creating a client secret — https://developer.apple.com/documentation/accountorganizationaldatasharing/creating-a-client-secret
- Revoke tokens — https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens
- TN3194 account deletion and token revocation — https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple
- Account change notifications — https://developer.apple.com/documentation/signinwithapple/processing-changes-for-sign-in-with-apple-accounts
- Enabling server-to-server notifications — https://developer.apple.com/help/account/capabilities/enabling-server-to-server-notifications
- OpenID configuration — https://appleid.apple.com/.well-known/openid-configuration
- JWKS — https://appleid.apple.com/auth/keys

**Project**
- Bevy 0.20 `examples/mobile` — https://github.com/bevyengine/bevy/tree/v0.20.0/examples/mobile
- Bevy 0.20 release — https://bevy.org/news/bevy-0-20/
- bevy #23003 (safe area), #19358 (60 fps cap), #25198 (GPU clustering), #24898 (asset `EMFILE`), #16762 (thread priority) — https://github.com/bevyengine/bevy/issues/23003, https://github.com/bevyengine/bevy/issues/19358, https://github.com/bevyengine/bevy/issues/25198, https://github.com/bevyengine/bevy/issues/24898, https://github.com/bevyengine/bevy/issues/16762
- winit FEATURES (iOS input matrix) — https://github.com/rust-windowing/winit/blob/v0.30.13/FEATURES.md
- winit #4224 / #4723 (UIScene), #4679 (thaw stall), #4358 (ProMotion) — https://github.com/rust-windowing/winit/issues/4224, https://github.com/rust-windowing/winit/pull/4723, https://github.com/rust-windowing/winit/issues/4679, https://github.com/rust-windowing/winit/issues/4358
- `bevy_ios_app_delegate` — https://github.com/rustunit/bevy_ios_app_delegate
- GitHub: signing Xcode applications — https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications
- GitHub: self-hosted runners reference (labels) — https://docs.github.com/en/actions/reference/runners/self-hosted-runners
- GitHub: secure use (self-hosted runners on private repos) — https://docs.github.com/en/actions/reference/security/secure-use
- GitHub: variables (`GITHUB_RUN_NUMBER`, `GITHUB_RUN_ATTEMPT`) — https://docs.github.com/en/actions/reference/workflows-and-actions/variables
- actions/runner#3407 (service mode and codesign) — https://github.com/actions/runner/issues/3407
- postcard — https://github.com/jamesmunns/postcard
