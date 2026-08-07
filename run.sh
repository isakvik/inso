#!/usr/bin/env bash
set -e

mkdir -p build

# copy runtime libraries if not already present
cp -u lib/linux/* build/
if [ -f data/Roboto-Regular.ttf ] && [ ! -f build/Roboto-Regular.ttf ]; then
    cp data/Roboto-Regular.ttf build/Roboto-Regular.ttf
fi

odin run src \
    -collection:dep=vendor \
    -out:build/inso_temp \
    -define:SOKOL_USE_GL=true \
    -o:minimal \
    -extra-linker-flags:"-Llib/linux/ -Wl,-rpath,\$ORIGIN -ldl -lm"
