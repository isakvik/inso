#!/usr/bin/env bash
set -e

mkdir -p build

GIT_HASH=$(git rev-parse --short HEAD)
VERSION="0.1.0-dev+${GIT_HASH}"

# copy runtime libraries if not already present
cp -u lib/linux/* build/
if [ -f data/Roboto-Regular.ttf ] && [ ! -f build/Roboto-Regular.ttf ]; then
    cp data/Roboto-Regular.ttf build/Roboto-Regular.ttf
fi

odin build src \
    -out:build/notosu \
    -define:SOKOL_USE_GL=true \
    -define:VERSION=${VERSION} \
    -o:minimal \
    -extra-linker-flags:"-Llib/linux/ -Wl,-rpath,\$ORIGIN -ldl -lm"
