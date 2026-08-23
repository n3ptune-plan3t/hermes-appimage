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

ARCH="\${ARCH:-x86_64}"
export ARCH
WORKDIR="\$(pwd)"

if [ ! -x "\${WORKDIR}/pyroot/bin/python3" ] || [ ! -d "\${WORKDIR}/hermes-webui" ]; then
    echo "ERROR: run get-dependencies.sh first (expects ./pyroot and ./hermes-webui)" >&2
    exit 1
fi

VERSION="${VERSION:-$(cat "\${WORKDIR}/VERSION.txt" 2>/dev/null || echo 0.0.0)}"
export VERSION
echo "Packaging Hermes-Web-AppImage v\${VERSION} (backend-only, no Electron) for \${ARCH}"

# =========================================================
# 1. Stage into pseudo-FHS root
# =========================================================
STAGE="\${WORKDIR}/stage"
rm -rf "\${STAGE}"
mkdir -p "\${STAGE}/usr/bin" \
         "\${STAGE}/usr/share/hermes-webui" \
         "\${STAGE}/usr/share/applications" \
         "\${STAGE}/usr/share/icons/hicolor/256x256/apps"

cp -a "${WORKDIR}/pyroot/." "${STAGE}/usr/"
cp -a "${WORKDIR}/hermes-webui/." "${STAGE}/usr/share/hermes-webui/"

if [ -f "\${WORKDIR}/hermes-web.desktop" ]; then
    cp "${WORKDIR}/hermes-web.desktop" "${STAGE}/usr/share/applications/"
else
    echo "WARNING: hermes-web.desktop not found at repo root (\${WORKDIR}) - generating a default one." >&2
    cat > "\${STAGE}/usr/share/applications/hermes-web.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Hermes Web (light)
GenericName=AI Agent (browser UI)
Comment=Low-RAM Hermes Agent - runs the local webui and opens your browser
Exec=hermes-web
Icon=hermes-web
Terminal=false
Categories=Utility;Network;Chat;
EOF
fi

# =========================================================
# 2. Deploy with quick-sharun (bundles python3 + its libs)
# =========================================================
if [ -f "\${WORKDIR}/icon.png" ]; then
    export ICON="\${WORKDIR}/icon.png"
else
    echo "WARNING: icon.png not found at repo root (\${WORKDIR}) - generating a placeholder (quick-sharun requires a valid ICON path)." >&2
    # Minimal valid 1x1 transparent PNG, base64-encoded - just enough to
    # satisfy quick-sharun's path check. Replace with a real 256x256 icon
    # at repo root whenever you want an actual logo.
    base64 -d > "\${WORKDIR}/generated-icon.png" <<'B64_EOF'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YA
AAAASUVORK5CYII=
B64_EOF
    export ICON="\${WORKDIR}/generated-icon.png"
fi
export DESKTOP="\${STAGE}/usr/share/applications/hermes-web.desktop"
export MAIN_BIN="python3"
export OUTPATH="\${WORKDIR}/dist"

# FIX: \${VAR%pat:-default} is not valid bash expansion. Split into two vars.
GH_OWNER="\${GITHUB_REPOSITORY%%/*}"
GH_REPO="\${GITHUB_REPOSITORY#*/}"
: "\${GH_OWNER:=yourname}"
: "\${GH_REPO:=hermes-web-appimage}"
export UPINFO="gh-releases-zsync|${GH_OWNER}|${GH_REPO}|latest|*\${ARCH}.AppImage.zsync"

mkdir -p "\${OUTPATH}"

if ! command -v quick-sharun >/dev/null 2>&1; then
    curl -fsSL -o /usr/local/bin/quick-sharun \
        "https://raw.githubusercontent.com/pkgforge-dev/Anylinux-AppImages/main/useful-tools/quick-sharun.sh"
    chmod +x /usr/local/bin/quick-sharun
fi

quick-sharun "\${STAGE}/usr/bin/python3"

APPDIR="\$(find . -maxdepth 1 -iname '*.AppDir' | head -n1)"
if [ -z "\$APPDIR" ]; then
    echo "::error::No AppDir found after quick-sharun run" >&2
    exit 1
fi

# ---------------------------------------------------------
# FIX 1: quick-sharun deploys binaries to shared/bin (with a
# bin/ symlink shim). The old custom AppRun pointed at
# \$HERE/usr/bin/python3 which does not exist in the final layout.
# The new AppRun below uses \$HERE/bin/python3 instead.
# ---------------------------------------------------------

# ---------------------------------------------------------
# FIX 2: bring the ENTIRE python3.11 tree (stdlib + site-packages).
# Previously only site-packages was copied - stdlib was missing,
# so even 'import urllib.request' would have died after libpython
# was fixed.
# ---------------------------------------------------------
mkdir -p "\${APPDIR}/usr/share/hermes-webui"
rsync -a "${STAGE}/usr/share/hermes-webui/" "${APPDIR}/usr/share/hermes-webui/"

for PYLIBDIR in "\${STAGE}"/usr/lib/python3.*; do
    [ -d "\$PYLIBDIR" ] || continue
    PYVER="\$(basename "\$PYLIBDIR")"
    mkdir -p "${APPDIR}/usr/lib/${PYVER}"
    rsync -a "\$PYLIBDIR/" "${APPDIR}/usr/lib/${PYVER}/"
done

# ---------------------------------------------------------
# FIX 3: libpython*.so — CPython dlopen's it at runtime rather than
# linking directly, so sharun's ldd-walk misses it. Copy manually.
# ---------------------------------------------------------
mkdir -p "\${APPDIR}/shared/lib"
LIBPYTHON_FOUND=0
for f in "\${WORKDIR}"/pyroot/lib/libpython3*.so*; do
    if [ -e "\$f" ]; then
        cp -aL "$f" "${APPDIR}/shared/lib/"
        LIBPYTHON_FOUND=1
    fi
done
if [ "\$LIBPYTHON_FOUND" -eq 0 ]; then
    echo "::error::could not locate libpython3*.so under pyroot/lib - aborting build" >&2
    exit 1
fi

# ---------------------------------------------------------
# Sanitize: remove any leaked CI workspace dirs (e.g. '__w')
# that may have been copied into the bundle by absolute-path
# references during pip installs or staging.
# ---------------------------------------------------------
rm -rf "${APPDIR}/shared/lib/__w" "${APPDIR}/usr/lib/__w" 2>/dev/null || true

# ---------------------------------------------------------
# Verification gate: fail CI loudly if ANY binary in shared/bin
# has unresolvable shared libs, instead of shipping a dead AppImage.
# ---------------------------------------------------------
MISSING=0
while IFS= read -r -d '' f; do
    if OUT="\$(ldd "$f" 2>/dev/null)" && echo "$OUT" | grep -q "not found"; then
        echo "::error::Missing deps for \$f:" >&2
        echo "\$OUT" | grep "not found" >&2
        MISSING=1
    fi
done < <(find "\${APPDIR}/shared/bin" -maxdepth 1 -type f -print0)
if [ "\$MISSING" -ne 0 ]; then
    echo "::error::Bundle verification failed - missing shared libraries" >&2
    exit 1
fi
echo "Bundle verification passed: all shared/bin deps resolve."

# =========================================================
# 3. Custom AppRun — start the server headlessly, hand off to
#    the user's EXISTING browser (no Electron/Chromium bundled).
#
#    NOTE: uses \$HERE/bin/python3 (the sharun symlink shim),
#    NOT \$HERE/usr/bin/python3 — that path doesn't exist in the
#    deployed AppDir layout.
# =========================================================
rm -f "\${APPDIR}/AppRun"
cat > "\${APPDIR}/AppRun" <<'APPRUN_EOF'
#!/bin/sh
set -eu
HERE="\$(readlink -f "\$(dirname "\$0")")"

export HERMES_HOME="${HERMES_HOME:-$HOME/.local/share/hermes-web-appimage}"
mkdir -p "\$HERMES_HOME"

export PYTHONHOME="\$HERE/usr"
export PYTHONPATH="\$HERE/usr/lib/python3.11/site-packages"
export HERMES_WEBUI_PORT="\${HERMES_WEBUI_PORT:-8787}"
PY="\$HERE/bin/python3"
SERVER="\$HERE/usr/share/hermes-webui/server.py"
URL="http://127.0.0.1:\${HERMES_WEBUI_PORT}"

"\$PY" "\$SERVER" &
SERVER_PID=\$!
cleanup() { kill "\$SERVER_PID" 2>/dev/null || true; }
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
