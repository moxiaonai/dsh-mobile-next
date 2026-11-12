#!/bin/sh
# Build only the fixed native Host; no caller-supplied executable or shell expression.
set -eu
if [ "$#" -ne 0 ]; then echo 'Usage: build-macos.sh' >&2; exit 2; fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo 'This build entry point requires an ARM64 Mac.' >&2; exit 2
fi
CARGO_BIN=$(rustup which cargo)
RUSTC_BIN=$(rustup which rustc)
RUSTDOC_BIN=$(rustup which rustdoc)
export CARGO_HOME="$ROOT/.cargo-home" RUSTUP_HOME="$ROOT/.rustup-home"
export RUSTC="$RUSTC_BIN" RUSTDOC="$RUSTDOC_BIN"
mkdir -p "$CARGO_HOME" "$ROOT/evidence"
"$CARGO_BIN" build --manifest-path "$ROOT/Cargo.toml" --locked --release -p dsh-mobile-iroh-host
printf 'Host binary: %s/target/release/dsh-mobile-iroh-host\n' "$ROOT"
