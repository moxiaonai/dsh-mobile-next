#!/bin/sh
# Unit/process tests bind local-only endpoints; no public iroh endpoint is started.
set -eu
if [ "$#" -ne 0 ]; then echo 'Usage: test-native.sh' >&2; exit 2; fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CARGO_BIN=$(rustup which cargo)
RUSTC_BIN=$(rustup which rustc)
RUSTDOC_BIN=$(rustup which rustdoc)
export CARGO_HOME="$ROOT/.cargo-home" RUSTUP_HOME="$ROOT/.rustup-home"
export RUSTC="$RUSTC_BIN" RUSTDOC="$RUSTDOC_BIN"
# Fresh private test roots live in this workspace, not in a user's normal profile.
mkdir -p "$ROOT/.test-tmp"
export TMPDIR="$ROOT/.test-tmp"
"$CARGO_BIN" test --manifest-path "$ROOT/Cargo.toml" --locked --release -p dsh-mobile-iroh-core -p dsh-mobile-iroh-host -p dsh-mobile-iroh-android-transport
