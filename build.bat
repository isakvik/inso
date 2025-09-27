@echo off

if not exist build mkdir build


odin build ./src -debug -out:build/main.exe

if %ERRORLEVEL% equ 1 goto stop
else goto end
python debug.py
goto end
:stop
pause
:end
