@echo off

if not exist build mkdir build
if not exist "build\SDL3.dll" xcopy ".\dll" ".\build" /Y /I

odin build ./src -debug -out:build/main.exe -define:SOKOL_USE_GL=true
if %ERRORLEVEL% equ 1 goto stop 
python debug.py
if %ERRORLEVEL% equ 1 goto stop
goto end
:stop
pause
:end
