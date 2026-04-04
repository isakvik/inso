#!/usr/bin/env bash
set -e

mkdir -p build

# copy runtime libraries if not already present
cp -u data/linux/* build/
if [ -f data/segoeui.ttf ] && [ ! -f build/segoeui.ttf ]; then
    cp data/segoeui.ttf build/segoeui.ttf
fi

odin run src \
    -out:build/notosu \
    -define:SOKOL_USE_GL=true \
    -o:minimal \
    -extra-linker-flags:"-Ldata/linux/ -Wl,-rpath,\$ORIGIN -ldl -lm"
