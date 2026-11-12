#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright © 2026 SIP Phone contributors
# Builds PJSIP (universal arm64 + x86_64, no video, no TLS, no SRTP; audio codecs G.722 and G.711 only)
# into Packages/PhoneKit/Frameworks/PJSIP.xcframework
set -euo pipefail
VERSION=2.15
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/pjsip"
OUT="$ROOT/Packages/PhoneKit/Frameworks/PJSIP.xcframework"
mkdir -p "$WORK"; cd "$WORK"

# SHA-256 of the GitHub tag tarball for $VERSION (computed from two independent downloads, 2026-11-12).
PJ_SHA256=b744544e5028d09d8c2f774d135e0f543930028c04580faa00590b78ee335973

if [ ! -f pj.tgz ]; then
  curl -fL -o pj.tgz.part "https://github.com/pjsip/pjproject/archive/refs/tags/$VERSION.tar.gz"
  mv pj.tgz.part pj.tgz
fi
if ! echo "$PJ_SHA256  pj.tgz" | shasum -a 256 -c -; then
  echo "error: pj.tgz does not match the pinned SHA-256; delete $WORK/pj.tgz and retry, or check the download" >&2
  exit 1
fi

build_arch() {   # $1 = arm64 | x86_64 ; leaves $WORK/libpjsip-$1.a
  local ARCH="$1" SRC="$WORK/src-$1"
  rm -rf "$SRC"; mkdir -p "$SRC"; tar xzf "$WORK/pj.tgz" -C "$SRC" --strip-components=1
  cd "$SRC"
  # PJMEDIA_HAS_SRTP 0 matches --disable-libsrtp (which only adds it to the library CFLAGS) in the shipped headers too.
  # The Speex codec is switched off here, not with --disable-speex-codec: in PJSIP 2.15 that flag also drops the Speex
  # echo canceller glue (echo_speex.o) while echo_common.c still refers to it, so linking fails. libspeex stays for the AEC.
  printf '#define PJ_HAS_IPV6 1\n#define PJMEDIA_HAS_VIDEO 0\n#define PJMEDIA_HAS_SRTP 0\n#define PJMEDIA_HAS_SPEEX_CODEC 0\n' \
    > pjlib/include/pj/config_site.h
  export CFLAGS="-arch $ARCH -mmacosx-version-min=14.0" LDFLAGS="-arch $ARCH"
  # cross-compiling for the other architecture needs --host so configure does not try to run test binaries
  local HOST=""; [ "$ARCH" != "$(uname -m)" ] && HOST="--host=$ARCH-apple-darwin"
  # The app uses only G.722 and G.711 (PCMA/PCMU), so every other codec is left out (licence risk and size).
  # Echo cancellation: CoreAudio's voice-processing unit, falling back to the Speex AEC (PJMEDIA_ECHO_DEFAULT picks
  # Speex before WebRTC), so the Speex DSP stays (no --disable-speex-aec) and libwebrtc goes.
  # libresample stays: the conference bridge converts between 8 kHz, 16 kHz and the device rate.
  # Optional libraries that configure would otherwise autodetect (Opus, SILK, Lyra, UPnP) are switched off explicitly.
  ./configure $HOST --disable-video --disable-ssl --disable-libyuv --disable-sdl --disable-ffmpeg \
              --disable-openh264 --disable-vpx --disable-opencore-amr --disable-bcg729 --disable-darwin-ssl \
              --disable-ilbc-codec --disable-g7221-codec --disable-gsm-codec \
              --disable-l16-codec --disable-silk --disable-opus --disable-lyra \
              --disable-libsrtp --disable-libwebrtc --disable-upnp
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
