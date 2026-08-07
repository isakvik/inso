#!/usr/bin/env bash
set -e

# rebuilds the GL static libs imported by gfx/ and log/ on linux (x64).

build_lib_x64_release() {
    src=$1
    dst=$2
    echo $dst
    cc -pthread -c -O2 -DNDEBUG -DIMPL -DSOKOL_GLCORE c/$src.c
    ar rcs $dst.a $src.o
}

build_lib_x64_debug() {
    src=$1
    dst=$2
    echo $dst
    cc -pthread -c -g -DIMPL -DSOKOL_GLCORE c/$src.c
    ar rcs $dst.a $src.o
}

build_lib_x64_release sokol_gfx  gfx/sokol_gfx_linux_x64_gl_release
build_lib_x64_debug   sokol_gfx  gfx/sokol_gfx_linux_x64_gl_debug
build_lib_x64_release sokol_log  log/sokol_log_linux_x64_gl_release
build_lib_x64_debug   sokol_log  log/sokol_log_linux_x64_gl_debug

rm -f *.o