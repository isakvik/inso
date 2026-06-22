@echo off
setlocal EnableDelayedExpansion

if not exist build goto end

build\notosu.exe --gen-lua-docs

:end
