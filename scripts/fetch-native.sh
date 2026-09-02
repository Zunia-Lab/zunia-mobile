#!/usr/bin/env bash
# Downloads zunia-core native artifacts from a GitHub Release and installs them
# into the Flutter android/ios trees for FFI loading.
#
# Required env:
#   ZUNIA_CORE_TAG  Release tag, e.g. v0.1.0
#
# Optional env:
#   ZUNIA_CORE_REPO  Owner/name (default: Zunia-Lab/zunia-core)
#   DEST_ROOT        Mobile repo root (default: parent of this script)
#
# Artifacts expected on the release:
#   android-libs.tar.gz
#   ZuniaCore.xcframework.tar.gz
#   SHA256SUMS
#
# Usage:
#   ZUNIA_CORE_TAG=v0.1.0 ./scripts/fetch-native.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_ROOT="${DEST_ROOT:-$ROOT}"
REPO="${ZUNIA_CORE_REPO:-Zunia-Lab/zunia-core}"
TAG="${ZUNIA_CORE_TAG:-}"

if [[ -z "$TAG" ]]; then
  echo "ZUNIA_CORE_TAG is required (e.g. v0.1.0)" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh (GitHub CLI) is required to download release assets" >&2
  exit 1
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/zunia-native.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "Fetching zunia-core@$TAG from $REPO into $WORKDIR"
gh release download "$TAG" \
  -R "$REPO" \
  -D "$WORKDIR" \
  -p 'android-libs.tar.gz' \
  -p 'ZuniaCore.xcframework.tar.gz' \
  -p 'SHA256SUMS' \
  -p 'SHA256SUMS.asc' || true

if [[ ! -f "$WORKDIR/SHA256SUMS" ]]; then
  echo "SHA256SUMS missing from release $TAG" >&2
  exit 1
fi

(
  cd "$WORKDIR"
  # Only verify the artifacts we care about (file may list npm tarballs too).
  for f in android-libs.tar.gz ZuniaCore.xcframework.tar.gz; do
    if [[ -f "$f" ]]; then
      grep -E "[[:space:]]$f\$" SHA256SUMS | shasum -a 256 -c -
    else
      echo "warning: $f not present on release $TAG" >&2
    fi
  done
)

JNI_DEST="$DEST_ROOT/android/app/src/main/jniLibs"
FW_DEST="$DEST_ROOT/ios/Frameworks"

if [[ -f "$WORKDIR/android-libs.tar.gz" ]]; then
  rm -rf "$JNI_DEST"
  mkdir -p "$JNI_DEST"
  tar -xzf "$WORKDIR/android-libs.tar.gz" -C "$WORKDIR"
  # Archive layout from build-native.sh: android/{arm64-v8a,armeabi-v7a,x86_64}/libzunia_ffi.so
  if [[ -d "$WORKDIR/android" ]]; then
    cp -R "$WORKDIR/android/"* "$JNI_DEST/"
  else
    # Flat ABI dirs at archive root
    for abi in arm64-v8a armeabi-v7a x86_64; do
      if [[ -d "$WORKDIR/$abi" ]]; then
        mkdir -p "$JNI_DEST/$abi"
        cp -R "$WORKDIR/$abi/"* "$JNI_DEST/$abi/"
      fi
    done
  fi
  echo "Installed Android libs -> $JNI_DEST"
  find "$JNI_DEST" -type f -name '*.so' | sort
fi

if [[ -f "$WORKDIR/ZuniaCore.xcframework.tar.gz" ]]; then
  rm -rf "$FW_DEST/ZuniaCore.xcframework"
  mkdir -p "$FW_DEST"
  tar -xzf "$WORKDIR/ZuniaCore.xcframework.tar.gz" -C "$FW_DEST"
  echo "Installed iOS xcframework -> $FW_DEST/ZuniaCore.xcframework"
fi

# Record the pin for humans / CI.
echo "$TAG" > "$DEST_ROOT/.zunia-core-native-tag"
echo "Done. Pinned native tag: $TAG"
