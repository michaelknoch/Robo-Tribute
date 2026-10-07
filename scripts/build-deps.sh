#!/bin/bash
# Builds static, arm64-native OpenSSL and MongoDB C driver (libmongoc + libbson),
# so the app bundle has no Homebrew runtime dependencies and runs on macOS 13+.
set -euo pipefail

MONGOC_VERSION="2.5.5"
MONGOC_SHA256="fa255802fe748b98d4464e07223e87a44c88c02c35398d7607b2f02e967395b1"
OPENSSL_VERSION="4.0.3"
OPENSSL_SHA256="325b5c806167c13b40b1ffeadfe0248197c00eccc4cf123ec1e28d2d2fd216d9"
DEPLOYMENT_TARGET="13.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/.deps"
PREFIX="$DEPS/install"
SRC="$DEPS/mongo-c-driver-$MONGOC_VERSION"
OPENSSL_SRC="$DEPS/openssl-$OPENSSL_VERSION"
OPENSSL_ROOT="$DEPS/openssl"

STAMP="$PREFIX/.versions"
WANTED="mongoc-$MONGOC_VERSION openssl-$OPENSSL_VERSION macos-$DEPLOYMENT_TARGET"
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANTED" ]; then
    echo "Dependencies up to date ($WANTED)"
    exit 0
fi
rm -rf "$PREFIX" "$DEPS/build"
if [ -f "$OPENSSL_ROOT/.version" ] && [ "$(cat "$OPENSSL_ROOT/.version")" != "$OPENSSL_VERSION" ]; then
    rm -rf "$OPENSSL_ROOT"
fi

# Downloads $1, checks it against SHA-256 $2 and unpacks it into $DEPS.
fetch() {
    local archive
    archive="$DEPS/$(basename "$1")"
    curl -fsSL "$1" -o "$archive"
    if ! echo "$2  $archive" | shasum -a 256 -c - >/dev/null; then
        rm -f "$archive"
        echo "Checksum mismatch for $1" >&2
        exit 1
    fi
    tar -xzf "$archive" -C "$DEPS"
    rm -f "$archive"
}

mkdir -p "$DEPS"
if [ ! -f "$OPENSSL_ROOT/lib/libssl.a" ]; then
    rm -rf "$OPENSSL_SRC"
    fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" "$OPENSSL_SHA256"
    (cd "$OPENSSL_SRC" \
        && ./Configure darwin64-arm64-cc no-shared no-tests no-docs no-apps \
            --prefix="$OPENSSL_ROOT" --libdir=lib --openssldir=/etc/ssl \
            -mmacosx-version-min=$DEPLOYMENT_TARGET \
        && make -j"$(sysctl -n hw.ncpu)" build_libs \
        && make install_dev \
        && cp LICENSE.txt "$OPENSSL_ROOT/" \
        && echo "$OPENSSL_VERSION" > "$OPENSSL_ROOT/.version")
fi

rm -rf "$SRC"
fetch "https://github.com/mongodb/mongo-c-driver/releases/download/$MONGOC_VERSION/mongo-c-driver-$MONGOC_VERSION.tar.gz" "$MONGOC_SHA256"

cmake -S "$SRC" -B "$DEPS/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET \
    -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_SHARED=OFF \
    -DENABLE_STATIC=ON \
    -DENABLE_TESTS=OFF \
    -DENABLE_EXAMPLES=OFF \
    -DENABLE_MONGOC=ON \
    -DENABLE_SSL=OPENSSL \
    -DOPENSSL_ROOT_DIR="$OPENSSL_ROOT" \
    -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DENABLE_SASL=OFF \
    -DENABLE_SNAPPY=OFF \
    -DENABLE_ZSTD=OFF \
    -DENABLE_ZLIB=BUNDLED \
    -DENABLE_SRV=ON \
    -DENABLE_CLIENT_SIDE_ENCRYPTION=OFF \
    -DMONGO_USE_CCACHE=OFF

cmake --build "$DEPS/build" --target install

mkdir -p "$PREFIX/lib"
cp "$OPENSSL_ROOT/lib/libssl.a" "$OPENSSL_ROOT/lib/libcrypto.a" "$PREFIX/lib/"
# Version-independent header paths for Package.swift.
mkdir -p "$PREFIX/headers"
ln -sfn "../include/mongoc-$MONGOC_VERSION/mongoc" "$PREFIX/headers/mongoc"
ln -sfn "../include/bson-$MONGOC_VERSION/bson" "$PREFIX/headers/bson"
echo "Installed into $PREFIX"
echo "$WANTED" > "$STAMP"
