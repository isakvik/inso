@echo off

if not exist build mkdir build
if not exist "build\SDL3.dll" xcopy ".\data\windows" ".\build" /Y /I
if not exist "build\Roboto-Regular.ttf" copy ".\data\Roboto-Regular.ttf" ".\build\Roboto-Regular.ttf" /Y

set exec_name=notosu.exe

tasklist /FI "IMAGENAME eq %exec_name%" | find /I "%exec_name%" >nul
if %ERRORLEVEL% equ 0 ( 
    taskkill /IM %exec_name% /F /T > nul
)

odin build ./src -linker:radlink -debug -out:build/%exec_name% -define:SOKOL_USE_GL=true -o:minimal
if %ERRORLEVEL% equ 1 goto stop 
python debug.py
if %ERRORLEVEL% equ 1 goto stop
goto end
:stop
pause
:end
