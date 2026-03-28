#!/usr/bin/env bash
set -e

mkdir -p build

if [ ! -f build/libbass.so ]; then
    cp data/linux/* build/
fi
if [ ! -f build/segoeui.ttf ]; then
    cp data/segoeui.ttf build/
fi

pkill -x notosu 2>/dev/null || true

odin build ./src \
    -debug \
    -out:build/notosu \
    -define:SOKOL_USE_GL=true \
    -o:minimal \
    -extra-linker-flags:"-Wl,-rpath,."

python3 debug.py
