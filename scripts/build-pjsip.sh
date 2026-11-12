#!/bin/bash
# Builds PJSIP (universal arm64 + x86_64, no video, no TLS) into Packages/PhoneKit/Frameworks/PJSIP.xcframework
set -euo pipefail
VERSION=2.15
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/pjsip"
OUT="$ROOT/Packages/PhoneKit/Frameworks/PJSIP.xcframework"
mkdir -p "$WORK"; cd "$WORK"

if [ ! -f pj.tgz ]; then
  curl -fL -o pj.tgz "https://github.com/pjsip/pjproject/archive/refs/tags/$VERSION.tar.gz"
fi

build_arch() {   # $1 = arm64 | x86_64 ; leaves $WORK/libpjsip-$1.a
  local ARCH="$1" SRC="$WORK/src-$1"
  rm -rf "$SRC"; mkdir -p "$SRC"; tar xzf "$WORK/pj.tgz" -C "$SRC" --strip-components=1
  cd "$SRC"
  printf '#define PJ_HAS_IPV6 1\n#define PJMEDIA_HAS_VIDEO 0\n' > pjlib/include/pj/config_site.h
  export CFLAGS="-arch $ARCH -mmacosx-version-min=14.0" LDFLAGS="-arch $ARCH"
  # cross-compiling for the other architecture needs --host so configure does not try to run test binaries
  local HOST=""; [ "$ARCH" != "$(uname -m)" ] && HOST="--host=$ARCH-apple-darwin"
  ./configure $HOST --disable-video --disable-ssl --disable-libyuv --disable-sdl --disable-ffmpeg \
              --disable-openh264 --disable-vpx --disable-opencore-amr --disable-bcg729 --disable-darwin-ssl
  # parallel make can race on creating output subdirs (e.g. g722); a serial retry finishes the job
  # configure probes an "arm" host as 32-bit (PJ_POOL_ALIGNMENT 4) but x86_64 as 8. The merged header tree is shared
  # by both archs, so force 8 in both builds; libraries and headers then agree on pool layout.
  sed -i '' 's/^#define PJ_POOL_ALIGNMENT .*/#define PJ_POOL_ALIGNMENT 8/' pjlib/include/pj/compat/os_auto.h
  grep -q '^#define PJ_POOL_ALIGNMENT 8$' pjlib/include/pj/compat/os_auto.h
  make dep && { make -j"$(sysctl -n hw.ncpu)" || make; }
  libtool -static -o "$WORK/libpjsip-$ARCH.a" $(find . -path '*/lib/*.a')
  cd "$WORK"
}
build_arch arm64
build_arch x86_64

# Universal static library (both archs in one file) and one merged header tree
lipo -create "$WORK/libpjsip-arm64.a" "$WORK/libpjsip-x86_64.a" -output "$WORK/libpjsip-all.a"
lipo -info "$WORK/libpjsip-all.a"
rm -rf "$WORK/headers"; mkdir -p "$WORK/headers"
for d in pjlib pjlib-util pjnath pjmedia pjsip; do cp -R "$WORK/src-arm64/$d/include/." "$WORK/headers/"; done

rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework -library "$WORK/libpjsip-all.a" -headers "$WORK/headers" -output "$OUT"
echo "Built $OUT"
