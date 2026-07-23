#!/bin/bash
# Downloads, patches, and builds readpst (from the libpst project) from source,
# then installs the resulting arm64 binary into Resources/bin/readpst.
#
# libpst is GPL-2.0-or-later. We build it fresh from its official upstream
# source rather than committing a compiled binary to this repository. This
# script also strips the optional libgsf dependency (used only for .msg
# export, which pstConvert doesn't use) so no extra libraries are required.
#
# Requires Xcode Command Line Tools (clang, make) and curl.

set -euo pipefail

VERSION="0.6.76"
TARBALL_URL="https://github.com/pst-format/libpst/releases/download/libpst-${VERSION}/libpst-${VERSION}.tar.gz"

cd "$(dirname "$0")/.."
PROJECT_ROOT="$(pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Downloading libpst ${VERSION} source…"
curl -sL -o "$WORK_DIR/libpst.tar.gz" "$TARBALL_URL"

echo "==> Extracting…"
tar xzf "$WORK_DIR/libpst.tar.gz" -C "$WORK_DIR"
SRC_DIR="$WORK_DIR/libpst-${VERSION}"

echo "==> Removing optional libgsf dependency (only needed for .msg export)…"
cat > "$SRC_DIR/src/msg.cpp" <<'EOF'
extern "C" {
    #include "define.h"
    #include "msg.h"
}
#include <stdio.h>

extern "C" void write_msg_email(char *fname, pst_item* item, pst_file* pst) {
    (void)fname; (void)item; (void)pst;
    fprintf(stderr, "write_msg_email: .msg output is not supported in this build (libgsf not available)\n");
}
EOF

echo "==> Configuring (no pkg-config required)…"
(
    cd "$SRC_DIR"
    GSF_CFLAGS=" " GSF_LIBS=" " ZLIB_CFLAGS=" " ZLIB_LIBS="-lz" \
        ./configure --disable-python --without-boost
)

echo "==> Building…"
(
    cd "$SRC_DIR"
    make -j"$(sysctl -n hw.ncpu)"
)

echo "==> Installing binary…"
mkdir -p "$PROJECT_ROOT/Resources/bin"
cp "$SRC_DIR/src/readpst" "$PROJECT_ROOT/Resources/bin/readpst"
chmod 755 "$PROJECT_ROOT/Resources/bin/readpst"

mkdir -p "$PROJECT_ROOT/ThirdParty"
cp "$SRC_DIR/COPYING" "$PROJECT_ROOT/ThirdParty/libpst-COPYING.txt"

echo "==> Done: Resources/bin/readpst"
"$PROJECT_ROOT/Resources/bin/readpst" -V
