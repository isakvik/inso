@echo off
setlocal EnableDelayedExpansion

if not exist build goto end

build\inso.exe --gen-lua-docs

:end
