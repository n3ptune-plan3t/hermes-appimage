#!/bin/sh
# get-dependencies.sh — Stage 1 of the pkgforge-dev template split.
# Runs as root inside the Arch-based AppImage build container BEFORE
# make-appimage.sh. Job here is only to install build deps and produce
# the built application tree — no AppDir/sharun work happens in this file.
set -eu

ARCH="$(uname -m)"

echo "Installing package dependencies..."
echo "---------------------------------------------------------------"
pacman -Syu --noconfirm \
    base-devel \
    git        \
    curl       \
    rsync

echo "Installing debloated packages..."
echo "---------------------------------------------------------------"
# pkgforge-dev's trimmed-library helper - harmless no-op here since we
# ship our own portable CPython, but kept for parity with other templates
# in case future revisions link against system libs (e.g. libffi/libssl).
get-debloated-pkgs --add-common --prefer-nano || true

# -----------------------------------------------------------------
# Comment this out if you need an AUR package.
# (Not used here - hermes-agent/hermes-webui aren't packaged in AUR,
# we build from source below instead.)
# -----------------------------------------------------------------
# make-aur-package PACKAGENAME

# -----------------------------------------------------------------
# Manual build: fetch a portable CPython + hermes-agent + hermes-webui,
# and pip-install the latter two INTO that interpreter.
# -----------------------------------------------------------------
PY_VERSION="${PY_VERSION:-3.11.11}"
PBS_TAG="${PBS_TAG:-20250106}"
case "$ARCH" in
    x86_64)  PY_TARGET="x86_64-unknown-linux-gnu"  ;;
    aarch64) PY_TARGET="aarch64-unknown-linux-gnu" ;;
    *) echo "Unsupported ARCH: $ARCH" >&2; exit 1 ;;
esac
PY_TARBALL="cpython-${PY_VERSION}+${PBS_TAG}-${PY_TARGET}-install_only.tar.gz"
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PY_TARBALL}"

mkdir -p ./pyroot
if [ ! -x ./pyroot/bin/python3 ]; then
    curl -fsSL -o ./python.tar.gz "$PY_URL"
    tar -xzf ./python.tar.gz -C ./pyroot --strip-components=1
fi
PYBIN="$(pwd)/pyroot/bin/python3"

[ -d ./hermes-agent ] || git clone --depth=1 https://github.com/NousResearch/hermes-agent.git ./hermes-agent
[ -d ./hermes-webui ] || git clone --depth=1 https://github.com/nesquena/hermes-webui.git ./hermes-webui

"$PYBIN" -m ensurepip
"$PYBIN" -m pip install --no-cache-dir -e "./hermes-agent[all]"
"$PYBIN" -m pip install --no-cache-dir -r ./hermes-webui/requirements.txt

# Export VERSION for make-appimage.sh (written to a plain file since
# get-dependencies.sh and make-appimage.sh run as separate steps/processes)
"$PYBIN" -c "import importlib.metadata as m; print(m.version('hermes-agent'))" \
    > ./VERSION.txt 2>/dev/null || echo "0.0.0" > ./VERSION.txt

echo "---------------------------------------------------------------"
echo "get-dependencies.sh done. Built tree ready in ./pyroot, ./hermes-webui"
