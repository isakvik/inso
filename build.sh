#!/usr/bin/env bash
set -e

odin build src -extra-linker-flags:"-Ldata/linux/"

export LD_LIBRARY_PATH=build/ && export OUTPUT=notosu-x86_64.AppImage && ~/linuxdeploy/linuxdeploy-x86_64.AppImage --appdir a
ppdir --executable appdir/usr/bin/notosu.bin --output appimage