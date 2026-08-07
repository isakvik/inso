@echo off

rem rebuilds the static libs imported by gfx/ and log/ (GL backend only).
rem requires a MSVC dev prompt (uses cl + lib).

set sources=gfx log

rem GL Debug
for %%s in (%sources%) do (
    cl /c /D_DEBUG /DIMPL /DSOKOL_GLCORE c\sokol_%%s.c /Z7
    lib /OUT:%%s\sokol_%%s_windows_x64_gl_debug.lib sokol_%%s.obj
    del sokol_%%s.obj
)

rem GL Release
for %%s in (%sources%) do (
    cl /c /O2 /DNDEBUG /DIMPL /DSOKOL_GLCORE c\sokol_%%s.c
    lib /OUT:%%s\sokol_%%s_windows_x64_gl_release.lib sokol_%%s.obj
    del sokol_%%s.obj
)