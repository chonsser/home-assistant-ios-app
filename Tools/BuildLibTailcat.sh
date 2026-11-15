#!/usr/bin/env bash
# Builds Tailcat.xcframework (libtailcat, the C API of https://github.com/tailscale/tailcat)
# for iOS devices, the iOS simulator and Mac Catalyst.
#
# Requirements: Xcode command line tools and the Go toolchain required by tailcat's go.mod.
#
# Usage: Tools/BuildLibTailcat.sh [output directory]
#   TAILCAT_SRC      use an existing tailcat checkout instead of cloning TAILCAT_COMMIT
#   TAILCAT_COMMIT   tailcat commit to build (defaults to the pinned one below)
#   TAILCAT_SLICES   space separated subset of: ios simulator catalyst

set -euo pipefail

TAILCAT_REPOSITORY="https://github.com/tailscale/tailcat.git"
TAILCAT_COMMIT="${TAILCAT_COMMIT:-e00cdde6ff787f801361ff85ed085775c775d4c5}"
TAILCAT_SLICES="${TAILCAT_SLICES:-ios simulator catalyst}"
IOS_MIN="16.4"
CATALYST_MIN="16.4"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT/Sources/Tailcat/Frameworks}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if ! command -v go >/dev/null; then
    echo "error: the Go toolchain is required (https://go.dev/dl/)" >&2
    exit 1
fi

if [ -n "${TAILCAT_SRC:-}" ]; then
    SRC="$TAILCAT_SRC"
else
    SRC="$WORK_DIR/tailcat"
    git init -q "$SRC"
    git -C "$SRC" fetch -q --depth 1 "$TAILCAT_REPOSITORY" "$TAILCAT_COMMIT"
    git -C "$SRC" checkout -q FETCH_HEAD
fi

TAGS="$(tr -d '\n' <"$SRC/build-tags.txt")"

# build <name> <GOOS> <GOARCH> <sdk> <clang target>
build() {
    local name="$1" goos="$2" goarch="$3" sdk="$4" target="$5"
    local sdk_path cc flags
    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
    cc="$(xcrun --sdk "$sdk" --find clang)"
    flags="-isysroot $sdk_path -target $target"
    echo "==> Building libtailcat for $name ($target)"
    (
        cd "$SRC"
        GOOS="$goos" GOARCH="$goarch" CGO_ENABLED=1 CC="$cc" \
            CGO_CFLAGS="$flags" CGO_LDFLAGS="$flags" \
            go build -buildmode=c-archive -trimpath -tags "$TAGS" -ldflags "-s -w" \
            -o "$WORK_DIR/$name/libtailcat.a" ./cmd/libtailcat
    )
}

HEADERS="$WORK_DIR/Headers"
mkdir -p "$HEADERS"
cp "$SRC/cmd/libtailcat/tailcat.h" "$HEADERS/tailcat.h"
cat >"$HEADERS/module.modulemap" <<'MODULEMAP'
module Tailcat {
    header "tailcat.h"
    link "resolv"
    link framework "CoreFoundation"
    link framework "Security"
    export *
}
MODULEMAP

LIBRARIES=()

for slice in $TAILCAT_SLICES; do
    case "$slice" in
    ios)
        build ios-arm64 ios arm64 iphoneos "arm64-apple-ios$IOS_MIN"
        LIBRARIES+=(-library "$WORK_DIR/ios-arm64/libtailcat.a" -headers "$HEADERS")
        ;;
    simulator)
        build simulator-arm64 ios arm64 iphonesimulator "arm64-apple-ios$IOS_MIN-simulator"
        build simulator-x86_64 ios amd64 iphonesimulator "x86_64-apple-ios$IOS_MIN-simulator"
        mkdir -p "$WORK_DIR/simulator"
        lipo -create "$WORK_DIR/simulator-arm64/libtailcat.a" "$WORK_DIR/simulator-x86_64/libtailcat.a" \
            -output "$WORK_DIR/simulator/libtailcat.a"
        LIBRARIES+=(-library "$WORK_DIR/simulator/libtailcat.a" -headers "$HEADERS")
        ;;
    catalyst)
        build catalyst-arm64 darwin arm64 macosx "arm64-apple-ios$CATALYST_MIN-macabi"
        build catalyst-x86_64 darwin amd64 macosx "x86_64-apple-ios$CATALYST_MIN-macabi"
        mkdir -p "$WORK_DIR/catalyst"
        lipo -create "$WORK_DIR/catalyst-arm64/libtailcat.a" "$WORK_DIR/catalyst-x86_64/libtailcat.a" \
            -output "$WORK_DIR/catalyst/libtailcat.a"
        LIBRARIES+=(-library "$WORK_DIR/catalyst/libtailcat.a" -headers "$HEADERS")
        ;;
    *)
        echo "error: unknown slice '$slice'" >&2
        exit 1
        ;;
    esac
done

mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/Tailcat.xcframework"
xcodebuild -create-xcframework "${LIBRARIES[@]}" -output "$OUTPUT_DIR/Tailcat.xcframework"
cp "$SRC/LICENSE" "$OUTPUT_DIR/Tailcat.xcframework/LICENSE"

echo "==> Built $OUTPUT_DIR/Tailcat.xcframework from tailcat $TAILCAT_COMMIT"
du -sh "$OUTPUT_DIR/Tailcat.xcframework"
