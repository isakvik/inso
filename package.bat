@echo off

set /p VERSION=<VERSION
set release_dir=build-release
set exec_name=inso.exe
set zip_name=inso-%VERSION%.zip

if exist %release_dir% rmdir /S /Q %release_dir%
mkdir %release_dir%

echo [package] building %VERSION%...

odin build ./src -collection:dep=vendor -out:%release_dir%\%exec_name% -define:SOKOL_USE_GL=true -define:VERSION=%VERSION% -define:WITH_CRASH_HANDLER=true -subsystem:windows -o:speed
if %ERRORLEVEL% neq 0 goto stop

odin build ./tools/inso_start -out:%release_dir%\inso_start.exe -o:speed
if %ERRORLEVEL% neq 0 goto stop

echo [package] copying runtime files...

xcopy ".\lib\windows\*.dll" ".\%release_dir%" /Y /I /Q
for %%d in (data shaders skins songs) do (
    xcopy /E /I /Y /Q ".\%%d" ".\%release_dir%\%%d"
)

echo [package] generating lua docs...
rem regenerate from the freshly built binary (needs its DLLs, hence after the copy above). it's a
rem -subsystem:windows app so it detaches from the console - start /wait blocks until docs are written
start /wait "" ".\%release_dir%\%exec_name%" --gen-lua-docs
if exist ".\docs\lua_api.html" xcopy /E /I /Y /Q ".\docs" ".\%release_dir%\docs"

echo [package] zipping...

set sevenzip=C:\Program Files\7-Zip\7z.exe
if not exist "%sevenzip%" set sevenzip=C:\Program Files (x86)\7-Zip\7z.exe
if not exist "%sevenzip%" (
    echo [package] 7-zip not found, skipping zip
    goto end
)

if exist %zip_name% del %zip_name%
"%sevenzip%" a -tzip %zip_name% ".\%release_dir%\*" > nul
echo [package] done: %zip_name%
goto end

:stop
echo [package] build failed
pause
:end
