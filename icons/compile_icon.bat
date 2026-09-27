@echo off
rem compiles icons\inso.rc into icons\inso.res (idempotent, cached by .res existence)
setlocal

set "res_out=%~dp0inso.res"
if exist "%res_out%" exit /b 0

echo [icon] compiling %~dp0inso.rc

where rc >nul 2>nul
if not errorlevel 1 (
    rc /nologo /fo "%res_out%" "%~dp0inso.rc"
    if exist "%res_out%" exit /b 0
    del /q "%res_out%" 2>nul
)

exit /b 0