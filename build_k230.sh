#!/usr/bin/env bash
set -euo pipefail

IMAGE="k230-sdk-builder:22.04"
VOLUME="k230-work"
CONF="${CONF:-BPI-CanMV-K230D-Zero_defconfig}"

SDK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_NAME="$(basename "$SDK_DIR")"
HOST_ROOT="$(cd "$SDK_DIR/.." && pwd)"
OUT_DIR_NAME="k230_sdk_output"

echo "==> SDK dir: $SDK_DIR"
echo "==> Host root: $HOST_ROOT"
echo "==> Config: $CONF"
echo "==> Building Docker image: $IMAGE"

docker build --platform linux/amd64 \
  -f "$SDK_DIR/Dockerfile.k230" \
  -t "$IMAGE" \
  "$SDK_DIR"

echo "==> Creating/reusing Docker volume: $VOLUME"
docker volume create "$VOLUME" >/dev/null

echo "==> Running K230 build inside Docker"
docker run --rm --platform linux/amd64 \
  -v "$HOST_ROOT:/host:rw" \
  -v "$VOLUME:/work" \
  -e CONF="$CONF" \
  -e SDK_NAME="$SDK_NAME" \
  -e OUT_DIR_NAME="$OUT_DIR_NAME" \
  "$IMAGE" \
  bash -lc '
set -euo pipefail

SRC="/host/$SDK_NAME"
DST="/work/k230_sdk"
OUT="/host/$OUT_DIR_NAME"

echo "==> Source on host: $SRC"
echo "==> Build dir in Docker volume: $DST"

mkdir -p "$DST"

rsync -a \
  --exclude ".git/" \
  --exclude "Dockerfile.k230" \
  --exclude "build_k230.sh" \
  --exclude "toolchain/Xuantie-900-gcc-linux-5.10.4-glibc-x86_64-V2.6.0/" \
  --exclude "toolchain/riscv64-unknown-linux-musl-rv64imafdcv-lp64d-*/" \
  --exclude "toolchain/*.tar.*" \
  --exclude "output/" \
  "$SRC/" "$DST/"

mkdir -p "$DST/toolchain"
mkdir -p /opt
rm -rf /opt/toolchain
ln -s "$DST/toolchain" /opt/toolchain

echo "==> /opt/toolchain:"
ls -l /opt/toolchain

cd "$DST"

echo "==> Preparing toolchain"
make CONF="$CONF" prepare_toolchain

echo "==> Preparing source code"
make CONF="$CONF" prepare_sourcecode

echo "==> Building SDK"
make CONF="$CONF" -j1

echo "==> Copying output back to macOS"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -a "$DST/output/." "$OUT/"

echo "DONE"
echo "Output copied to: $OUT"
'
