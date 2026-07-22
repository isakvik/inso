@echo off
setlocal EnableDelayedExpansion

if not exist build mkdir build
if not exist "build\SDL3.dll" xcopy ".\lib\windows\*.dll" ".\build" /D /Y /I
if not exist "build\Roboto-Regular.ttf" copy ".\data\Roboto-Regular.ttf" ".\build\Roboto-Regular.ttf" /Y

set exec_name=inso.exe

if "%VERSION%"=="" (
    set /p BASE_VERSION=<VERSION
    for /f "tokens=*" %%i in ('git rev-parse --short HEAD') do set GIT_HASH=%%i
    set VERSION=!BASE_VERSION!-dev+!GIT_HASH!
)

echo [build] %VERSION%

tasklist /FI "IMAGENAME eq %exec_name%" | find /I "%exec_name%" >nul
if %ERRORLEVEL% equ 0 (
    taskkill /IM %exec_name% /F /T > nul
)

odin build ./src -linker:radlink -debug -out:build/%exec_name% -define:SOKOL_USE_GL=true -define:VERSION=%VERSION%
set BUILD_ERR=%ERRORLEVEL%
if %BUILD_ERR% neq 0 exit /b %BUILD_ERR%

odin build ./tools/inso_start -debug -out:build/inso_start.exe
set BUILD_ERR=%ERRORLEVEL%
if %BUILD_ERR% neq 0 exit /b %BUILD_ERR%
echo [build] build OK
