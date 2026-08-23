#!/usr/bin/env bash
# make-appimage.sh — Stage 2 of the pkgforge-dev template split.
# Runs AFTER get-dependencies.sh. Only job here: stage into a pseudo-FHS
# root, deploy with quick-sharun, drop in the custom AppRun, package.
#
# A LOW-RAM alternative to the Electron "Hermes Desktop" AppImage: no
# Electron/Chromium bundled. AppRun starts the local hermes-webui server
# and hands off to whatever browser is already on the system.
set -eEuo pipefail

if [ -f "./env" ]; then source ./env; fi

ARCH="${ARCH:-x86_64}"
export ARCH
WORKDIR="$(pwd)"

if [ ! -x "${WORKDIR}/pyroot/bin/python3" ] || [ ! -d "${WORKDIR}/hermes-webui" ]; then
    echo "ERROR: run get-dependencies.sh first (expects ./pyroot and ./hermes-webui)" >&2
    exit 1
fi

VERSION="${VERSION:-$(cat "${WORKDIR}/VERSION.txt" 2>/dev/null || echo 0.0.0)}"
export VERSION
echo "Packaging Hermes-Web-AppImage v${VERSION} (backend-only, no Electron) for ${ARCH}"

# =========================================================
# 1. Stage into pseudo-FHS root
# =========================================================
STAGE="${WORKDIR}/stage"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/usr/bin" \
         "${STAGE}/usr/share/hermes-webui" \
         "${STAGE}/usr/share/applications" \
         "${STAGE}/usr/share/icons/hicolor/256x256/apps"

cp -a "${WORKDIR}/pyroot/." "${STAGE}/usr/"
cp -a "${WORKDIR}/hermes-webui/." "${STAGE}/usr/share/hermes-webui/"
cp "${WORKDIR}/hermes-web.desktop" "${STAGE}/usr/share/applications/"

# =========================================================
# 2. Deploy with quick-sharun (bundles python3 + its libs)
# =========================================================
export ICON="${WORKDIR}/icon.png"   # supply your own 256x256 icon here
export DESKTOP="${STAGE}/usr/share/applications/hermes-web.desktop"
export MAIN_BIN="python3"
export OUTPATH="${WORKDIR}/dist"
export UPINFO="gh-releases-zsync|${GITHUB_REPOSITORY%/*:-yourname}|${GITHUB_REPOSITORY#*/:-hermes-web-appimage}|latest|*${ARCH}.AppImage.zsync"
mkdir -p "${OUTPATH}"

if ! command -v quick-sharun >/dev/null 2>&1; then
    curl -fsSL -o /usr/local/bin/quick-sharun \
        "https://raw.githubusercontent.com/pkgforge-dev/Anylinux-AppImages/main/useful-tools/quick-sharun.sh"
    chmod +x /usr/local/bin/quick-sharun
fi

quick-sharun "${STAGE}/usr/bin/python3"

APPDIR="$(find . -maxdepth 1 -iname '*.AppDir' | head -n1)"

# Bring the webui source (non-ELF, sharun's ldd-walk won't grab it)
mkdir -p "${APPDIR}/usr/share/hermes-webui"
rsync -a "${STAGE}/usr/share/hermes-webui/" "${APPDIR}/usr/share/hermes-webui/"

# Bring pure-python site-packages sharun may have missed
rsync -a "${STAGE}/usr/lib/python3."*"/site-packages/" \
    "${APPDIR}/usr/lib/python3.11/site-packages/" 2>/dev/null || true

# =========================================================
# 3. Custom AppRun — the whole point of this build: start the
#    server headlessly, then hand off to the user's EXISTING
#    browser instead of bundling Electron/Chromium.
# =========================================================
rm -f "${APPDIR}/AppRun"
cat > "${APPDIR}/AppRun" <<'APPRUN_EOF'
#!/bin/sh
set -eu
HERE="$(readlink -f "$(dirname "$0")")"

export HERMES_HOME="${HERMES_HOME:-$HOME/.local/share/hermes-web-appimage}"
mkdir -p "$HERMES_HOME"

export PYTHONHOME="$HERE/usr"
export PYTHONPATH="$HERE/usr/lib/python3.11/site-packages"
export HERMES_WEBUI_PORT="${HERMES_WEBUI_PORT:-8787}"
PY="$HERE/usr/bin/python3"
SERVER="$HERE/usr/share/hermes-webui/server.py"
URL="http://127.0.0.1:${HERMES_WEBUI_PORT}"

"$PY" "$SERVER" &
SERVER_PID=$!
cleanup() { kill "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

i=0
until "$PY" -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('${URL}/api/health', timeout=1).status==200 else 1)" 2>/dev/null; do
    i=$((i+1))
    [ "$i" -gt 60 ] && { echo "hermes-webui failed to start" >&2; exit 1; }
    sleep 0.5
done

open_browser() {
    for b in brave brave-browser google-chrome-stable google-chrome chromium chromium-browser; do
        if command -v "$b" >/dev/null 2>&1; then
            "$b" --app="$URL" >/dev/null 2>&1 &
            wait "$!"
            return
        fi
    done
    xdg-open "$URL" >/dev/null 2>&1 || true
    wait "$SERVER_PID"
}

open_browser
APPRUN_EOF
chmod +x "${APPDIR}/AppRun"

# =========================================================
# 4. Turn AppDir into AppImage (uruntime, no FUSE required)
# =========================================================
quick-sharun --make-appimage

echo "Done. Output:"
ls -la "${OUTPATH}"/*.AppImage 2>/dev/null || true
