# DSH Mobile

English · [简体中文](README.md)

> Take over and supervise DeepSeek Harness tasks running on your computer — from your phone.

[![CI](https://github.com/moxiaonai/dsh-mobile-next/actions/workflows/ci.yml/badge.svg)](https://github.com/moxiaonai/dsh-mobile-next/actions/workflows/ci.yml)

DSH Mobile is three pieces: a **DSH plugin** (desktop side, published to npm), a **Flutter client** (Android, with an iOS PWA path), and a **Rust native transport** (iroh, experimental). The plugin opens an HTTPS gateway on the computer with device-pairing auth. The phone connects over LAN or an encrypted remote channel and receives the **real DSH page** plus a mobile layout layer.

This is not "the desktop chat UI shrunk down." The phone is a **pager for your agents**: one screen telling you what needs you, one-tap approval, voice or text steering, full transcript on demand.

---

## Contents

- [Screenshots](#screenshots)
- [Architecture](#architecture)
- [Components](#components)
- [Getting started](#getting-started)
- [Protocol contract](#protocol-contract)
- [Security model](#security-model)
- [Development](#development)
- [Known limitations](#known-limitations)
- [Third-party code and licenses](#third-party-code-and-licenses)

---

## Screenshots

Two tabs: sessions and settings. The session list groups **by project** or **by state**, and each group header collapses. Sessions that need you and any **pending approval** are pinned to the top.

<table>
  <tr>
    <td><img src="screenshots/01-sessions-project.png" width="220" alt="Sessions grouped by project"></td>
    <td><img src="screenshots/02-sessions-state.png" width="220" alt="Sessions grouped by state"></td>
    <td><img src="screenshots/07-approvals.png" width="220" alt="Pending approvals pinned on top"></td>
  </tr>
  <tr>
    <td align="center">Sessions · by project</td>
    <td align="center">Sessions · by state</td>
    <td align="center">Approvals on top</td>
  </tr>
  <tr>
    <td><img src="screenshots/03-session-detail.png" width="220" alt="Session detail"></td>
    <td><img src="screenshots/08-inbox.png" width="220" alt="Notification inbox"></td>
    <td><img src="screenshots/09-pairing.png" width="220" alt="Add computer · scan to pair"></td>
  </tr>
  <tr>
    <td align="center">Session detail (real DSH page in a mobile shell)</td>
    <td align="center">Notification inbox</td>
    <td align="center">Add computer</td>
  </tr>
  <tr>
    <td><img src="screenshots/04-settings.png" width="220" alt="Settings"></td>
    <td><img src="screenshots/05-devices.png" width="220" alt="Paired devices"></td>
    <td><img src="screenshots/06-diagnostics.png" width="220" alt="Connection diagnostics"></td>
  </tr>
  <tr>
    <td align="center">Settings</td>
    <td align="center">Paired devices</td>
    <td align="center">Connection diagnostics</td>
  </tr>
  <tr>
    <td><img src="screenshots/10-connect-timeout.png" width="220" alt="Cannot reach the computer"></td>
    <td><img src="screenshots/11-dark-settings.png" width="220" alt="Dark mode · settings"></td>
    <td><img src="screenshots/12-dark-sessions.png" width="220" alt="Dark mode · sessions"></td>
  </tr>
  <tr>
    <td align="center">Unreachable: cancel, retry, or pair another</td>
    <td align="center">Dark mode · settings</td>
    <td align="center">Dark mode · sessions</td>
  </tr>
</table>

> Captured on an Android emulator. Session titles and conversation content are **blurred** so the repository can stay public; layout and UI copy are unchanged.

---

## Architecture

```
┌─────────────────────────────┐
│  Phone                       │
│  ┌───────────────────────┐  │
│  │ Flutter client         │  │
│  │ · transport (unary+mux)│  │
│  │ · pairing / credentials│  │
│  │ · task center / approvals│ │
│  └──────────┬────────────┘  │
└─────────────┼───────────────┘
              │ HTTPS (LAN)
              │ or QUIC (iroh remote, experimental)
┌─────────────▼───────────────┐
│  Computer                    │
│  ┌───────────────────────┐  │
│  │ dsh-mobile-next plugin │  │
│  │ · gateway (TLS+pairing)│  │
│  │ · device tokens / CSRF │  │
│  │ · upstream credential  │  │
│  │   proxy injection      │  │
│  └──────────┬────────────┘  │
│  ┌──────────▼────────────┐  │
│  │ DSH (default :3080)    │  │
│  └───────────────────────┘  │
└─────────────────────────────┘
```

Key design decision: **the plugin never modifies DSH source.** It inserts itself into the loader tree as a Host plugin, injects the `webServer` and `connection` services, reverse-proxies to the local DSH port, and injects a mobile layout layer into the returned page.

---

## Components

| Directory | Contents | Stack | Size |
| --- | --- | --- | --- |
| [`dsh-mobile-next/`](dsh-mobile-next/) | DSH plugin, published to npm | TypeScript + React | 5,472 lines |
| [`flutter/`](flutter/) | Android client | Dart / Flutter | 19,305 lines |
| [`native/`](native/) | iroh native transport (experimental) | Rust | 7,041 lines |
| [`prototype/`](prototype/) | Zero-dependency clickable prototype | Vanilla HTML/CSS/JS | — |
| [`design/`](design/) | Brand assets and icons | SVG / PNG | — |

### Plugin (`dsh-mobile-next`)

npm package name `dsh-mobile-next`, currently `0.2.0`, MIT. Only two runtime dependencies: `node-forge` (certificates) and `qrcode` (pairing QR codes).

It provides two independent channels:

- **LAN** — the phone reaches the computer over local HTTPS with device-pairing auth; the plugin self-signs a private CA.
- **Remote (iroh, experimental)** — encrypted direct connection preferred, relay as fallback. No domain or public port required. Needs the native component on the host and an iroh-capable app.

```bash
cd dsh-mobile-next
pnpm install
pnpm run typecheck
pnpm test
pnpm run build
```

### Client (`flutter/`)

The transport layer deliberately keeps **zero runtime network dependencies**: `HttpTransport` and `MuxSocket` are hand-rolled abstractions, so unit tests run on a plain Dart VM — no emulator required.

```
lib/src/
├── protocol/     frame definitions, session ops, dual-carrier routing
├── transport/    unary / mux / connection orchestration / iroh
├── auth/         pairing, credential store, iroh descriptor
├── ui/           pages and shared card widgets
└── webview/      session WebView and injected scripts
```

### Native transport (`native/`)

Three Rust crates: `iroh-core` (shared core), `iroh-host` (desktop sidecar), `iroh-android` (Android transport). The Host is an **authenticated byte carrier**, not an HTTP/TLS terminator — TLS is terminated by the HTTPS gateway on the computer, and authorization stays with the gateway.

```bash
./native/scripts/build-macos.sh
./native/scripts/test-native.sh
```

---

## Getting started

### Requirements

| Item | Version |
| --- | --- |
| Node.js | ≥ 20 |
| pnpm | 10+ |
| DSH | `>=0.2.2-rc.1 <0.3.0-0` |
| Flutter (client only) | Dart SDK `^3.13.0` |
| Rust (native transport only) | Toolchain installed |

The plugin's `engines.dsh` is a **compatibility gate**: a mismatched DSH version is rejected at install time (`incompatible-version`) rather than failing at runtime.

### 1. Install the plugin

```bash
# From the registry (once published)
dsh plugin --profile desktop add dsh-mobile-next@0.2.0

# Or from source, packed as a tarball (offline / air-gapped)
cd dsh-mobile-next
pnpm pack
dsh plugin --profile desktop add ./dsh-mobile-next-0.2.0.tgz
```

You can also use **Settings → Plugins → Install** in DSH and enter a package name or local path.

### 2. Enable LAN access

Open the **Mobile Access** panel in the DSH sidebar:

1. Click "Enable LAN access".
2. The panel **automatically** generates a pairing QR code (no second click needed).
3. Scan it with your phone to pair.

By default it only listens on loopback (`127.0.0.0/8`) with `initiallyEnabled: false` — installing the plugin never starts listening on its own; you must enable it explicitly.

### 3. Build the client

```bash
cd flutter
dart pub get
dart analyze
dart test
flutter build apk --debug
```

---

## Protocol contract

**The plugin owns the interface contract; the client only consumes it.** Both path parameters (`pairPath` / `renewPath`) are configurable, not hardcoded.

### Routes reachable by the phone (`/mobile-access-next/*`)

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/pair` | Pairing page HTML |
| `POST` | `/pair` | Exchange a one-time token for device credentials |
| `GET` | `/health` | Health check |
| `POST` | `/renew` | Exchange a device token for a fresh session (required on cold start) |

**Every other `/mobile-access-next/*` path returns 404 and is never proxied.** This is a security boundary: host-only operations such as `/pairing` (mint new tokens) and `/devices/revoke` (kick a device) must never be exposed to the phone.

### Host-only admin routes

| Path | Purpose |
| --- | --- |
| `/status` | Gateway status |
| `/diagnostics` | Diagnostic info |
| `/network` | Network interface candidates |
| `/enable` | Start/stop the gateway |
| `/pairing` | Open a pairing window |
| `/devices` | List paired devices |
| `/devices/revoke` | Revoke one device |
| `/devices/revoke-all` | Revoke all devices |
| `/remote/{config,enable,pairing}` | iroh remote channel management |

### DSH protocol consumed by the client

DSH has **two mutually incompatible carriers**; picking the wrong one fails immediately:

| Carrier | Carries | Endpoint | Symptom when wrong |
| --- | --- | --- | --- |
| `POST /api/<endpoint>` | unary | `session/list`, `session/prompt`… | via mux → `gateway/signature-invalid` |
| `WS /api/remote.mux` | streaming | `$events`, `session/follow`, `job/list`… | via HTTP → 404 |

Four pitfalls that only surface when you actually run it (all handled in code):

1. `session/list` must include `_request`; empty args are rejected.
2. `$events` must include an empty `args` object.
3. The WebSocket upgrade must explicitly carry a `Host` header — `dart:io`'s `WebSocket.connect` does not add one.
4. The scheme must be derived from the origin: `http`→`ws`, `https`→`wss`.

---

## Security model

| Mechanism | Implementation |
| --- | --- |
| Device pairing | One-time token (unusable if the QR leaks), exchanged for a long-lived device token |
| Token storage | Digest only; persisted state never contains a plaintext `deviceToken` |
| TLS | Plugin self-signs a private CA; the client **pins** it (self-signed alone is not enough) |
| Upstream credentials | The plugin holds the DSH credential and injects `dsh-auth-*` cookies; the phone never sees them |
| Writes | CSRF token |
| Origin check | Exact Origin match |
| WebSocket | Exact-path allow-list |
| Secure by default | `initiallyEnabled: false` + loopback-only listening |

**Important:** the `sessionToken` the phone receives is **not** DSH's `dsh-auth-*` cookie. They are distinct authorization layers.

The iroh channel adds further requirements: QUIC authenticates EndpointIds and provides transport-level replay protection; TLS is terminated by the gateway on the computer and the Host only forwards bytes; there is no `no-tls-verify` or external TLS bypass of any kind.

---

## Development

### Tests

| Component | Tests | Status |
| --- | --- | --- |
| Plugin | 12 files / 140 cases | ✅ **147 passed, 2 skipped** (measured with `pnpm test`) |
| Native | `iroh-core` + `iroh-host` | ✅ **56 passed, 0 failed** (measured with `cargo test`) |
| Client | 34 files / 323 cases | ✅ **323 passed** (`flutter test`, measured); `flutter analyze` clean |

```bash
cd dsh-mobile-next && pnpm test          # plugin
cd native && cargo test -p dsh-mobile-iroh-core -p dsh-mobile-iroh-host
cd flutter && flutter analyze && flutter test
```

> The Android crate (`native/iroh-android`) only builds for Android targets,
> so host-side `cargo test` / `cargo clippy` cover the default members only.

### Plugin verification scripts

```bash
cd dsh-mobile-next
node scripts/verify-patch.mjs      # cordis patch evaluation
node scripts/verify-client.mjs     # client bundle exports
node scripts/verify-package.mjs    # tarball installs and loads standalone
```

`prepublishOnly` chains typecheck → test → build → verify-package, so publishing is gated automatically.

### Releasing

**Recommended: push a tag and let CI publish (Trusted Publishing, no token)**

```bash
cd dsh-mobile-next
npm version minor          # updates package.json and creates the git tag
git push --follow-tags
```

The `publish` job runs only on `v*` tags. It exchanges a GitHub OIDC token for a
short-lived npm credential and attaches a provenance attestation. It also
verifies that the tag matches `package.json` and fails otherwise.

**One-time setup** (per package):

1. Open https://www.npmjs.com/package/dsh-mobile-next/access
2. Trusted Publisher → GitHub Actions
3. Enter Organization/User `moxiaonai`, Repository `dsh-mobile-next`, Workflow `ci.yml`

Do **not** add an `NPM_TOKEN` secret afterwards. npm has announced that from
January 2027 bypass-2FA tokens can no longer publish directly; OIDC is the
supported replacement.

**Manual publish** (fallback) requires a granular token with 2FA bypass, and
each publish still needs an OTP. Make sure `~/.npmrc` does not point at an
internal registry, or pass `--registry=https://registry.npmjs.org`.

### Android release signing

The repository ships **no keystore**. Without `flutter/android/key.properties`,
the `release` build type reuses the debug key, so the artifact is test-only and
must not be distributed.

Generate a local keystore (**keep it safe, never commit it**):

```bash
keytool -genkeypair -v -keystore upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Write `flutter/android/key.properties` (already git-ignored):

```properties
storeFile=/absolute/path/to/upload-keystore.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

`flutter build apk --release` then produces a signed APK.

**In CI**: add the four secrets below under Settings → Secrets. The APK job
switches to release signing automatically; without them it keeps building a
debug APK so forks and pull requests still get a testable artifact.

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | output of `base64 -i upload-keystore.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | storePassword |
| `ANDROID_KEY_ALIAS` | keyAlias |
| `ANDROID_KEY_PASSWORD` | keyPassword |

---

## Known limitations

- **The iroh remote channel is experimental.** A `running` state only means the local sidecar and dedicated gateway are up — it **does not prove the phone is reachable, or whether the path is direct or relayed**. The status field is always `verified: false`.
- **The CA is generated per computer.** Bundling the CA into the APK means that build only trusts the computer it was built against; switching computers requires a rebuild, or a switch to carrying the CA fingerprint in the pairing QR code.
- **iOS uses the PWA path**; no native iOS app is distributed.
- **The Flutter client has not been verified on a real device across networks.** Global VPN / TUN and fake-IP DNS may interfere with iroh direct connections and relaying.
- **Android native libraries must be built locally.** The `.so` files under `jniLibs/` are not committed (~19 MB each); see [`native/iroh-android/build-android.sh`](native/iroh-android/build-android.sh).
- **Release signing is optional and falls back to debug.** The repository ships no keystore; without `flutter/android/key.properties`, the `release` build type reuses the debug key, so the artifact is test-only and not distributable. See "Android release signing" below.

---

## Third-party code and licenses

The repository as a whole is **MIT** (see [LICENSE](LICENSE)), but it **contains third-party code**. The boundaries:

| Location | Origin | License |
| --- | --- | --- |
| [`native/iroh-host/`](native/iroh-host/), [`native/iroh-core/`](native/iroh-core/) | Adapted from [saya-ch/dsh-mobile-iroh](https://github.com/saya-ch/dsh-mobile-iroh) | MIT |
| [`native/iroh-android/`](native/iroh-android/) | Same, plus [zexadev/dsh-tether](https://github.com/zexadev/dsh-tether) | MIT / Apache-2.0 |
| Reference implementation | [saya-ch/dsh-mobile](https://github.com/saya-ch/dsh-mobile) | Apache-2.0 |

Original licenses and NOTICE are retained under [`native/licenses/`](native/licenses/). **The root MIT license does not replace the licenses on those imported portions.**

> The reference project `saya-ch/dsh-mobile` served only as a **research reference** for protocol and constraints; its code was not copied into `flutter/` or `dsh-mobile-next/` in this repository.
