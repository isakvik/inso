#!/usr/bin/env bash
set -e

VERSION=$(tr -d '[:space:]' < VERSION)
release_dir=build-release
exec_name=notosu
zip_name=notosu-${VERSION}-linux.zip

mkdir -p "$release_dir"

echo "[package] building ${VERSION}..."

# note: WITH_CRASH_HANDLER is windows-only (crash_handler_windows.odin), so it's omitted here just like build.sh
odin build ./src \
    -out:"$release_dir/$exec_name" \
    -define:SOKOL_USE_GL=true \
    -define:VERSION=${VERSION} \
    -o:speed \
    -extra-linker-flags:"-Llib/linux/ -Wl,-rpath,\$ORIGIN -ldl -lm"

echo "[package] copying runtime files..."

cp -f lib/linux/* "$release_dir/"
for d in data shaders skins songs; do
    cp -rf "$d" "$release_dir/"
done

# regenerate the lua api reference from the freshly built binary (needs its libs, hence after the copy above).
# non-fatal: never block packaging on a doc hiccup
echo "[package] generating lua docs..."
"$release_dir/$exec_name" --gen-lua-docs || echo "[package] warning: lua doc generation failed"
if [ -f docs/lua_api.html ]; then
    cp -rf docs "$release_dir/"
fi

echo "[package] zipping..."

if ! command -v zip >/dev/null 2>&1; then
    echo "[package] zip not found, skipping zip"
    exit 0
fi

rm -f "$zip_name"
(cd "$release_dir" && zip -rq "../$zip_name" .)
echo "[package] done: $zip_name"
