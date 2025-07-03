@ECHO OFF
setlocal enabledelayedexpansion

REM Check for required gettext tools
echo "Checking for required gettext tools..."

set "TOOLS_MISSING=0"
where xgettext >nul 2>&1
if errorlevel 1 (
    echo "Error: xgettext not found in PATH"
    set "TOOLS_MISSING=1"
)
where msgmerge >nul 2>&1
if errorlevel 1 (
    echo "Error: msgmerge not found in PATH"
    set "TOOLS_MISSING=1"
)
where msgfmt >nul 2>&1
if errorlevel 1 (
    echo "Error: msgfmt not found in PATH"
    set "TOOLS_MISSING=1"
)
if "%TOOLS_MISSING%"=="1" (
    echo .
    echo "Please install gettext tools first"
    echo "- Windows: Download from https://mlocati.github.io/articles/gettext-iconv-windows.html"
    pause
    exit /b 1
)
echo "All required tools are available."
echo .


REM Generate/Update POT file (translation template)

set "POT_FILE=.\l10n\koreader.pot"
echo "Generating or updating POT file: %POT_FILE%"
mkdir "%~dp0l10n" >nul 2>&1

REM Find all .lua files
dir /s /b *.lua > lua_files.tmp
set "LUA_FILES_EXIST=false"

for /f "delims=" %%f in (lua_files.tmp) do (
    set "LUA_FILES_EXIST=true"
    goto :break_loop
)
:break_loop

if "%LUA_FILES_EXIST%"=="false" (
    echo "Error: No Lua files found!" >&2
    del lua_files.tmp >nul 2>&1
    exit /b 1
)

REM Generate POT file
for /f "delims=" %%f in (lua_files.tmp) do (
    set "LUA_FILE_LIST=!LUA_FILE_LIST! "%%f""
)
xgettext --language=Lua --from-code=UTF-8 --keyword=_  --no-location  --output="%POT_FILE%" %LUA_FILE_LIST%
if errorlevel 1 (
    echo "Error: Failed to generate POT file" >&2
    del lua_files.tmp >nul 2>&1
    exit /b 1
)
del lua_files.tmp >nul 2>&1
echo "Successfully updated POT file: %POT_FILE%"

REM Update PO files
if exist "%POT_FILE%" (
    echo "Starting PO files update..."
    for /d %%d in ("%~dp0l10n\*") do (
        set "PO_PATH=%%d\koreader.po"
        if exist "!PO_PATH!" (
            echo  "Processing: %%d\koreader.po"
            msgmerge --no-fuzzy-matching --no-location --no-wrap --backup=off --update "!PO_PATH!" "%POT_FILE%"
            if errorlevel 1 (
                echo "Warning: Failed to update %%d\koreader.po!" >&2
            )
            msgfmt --check-format --verbose "!PO_PATH!" >nul 2>&1 || (
                echo "Warning: Format errors found in %%d\koreader.po" >&2
            )
        )
    )
    echo "PO files update completed"
) else (
    echo "Error: POT file not found: %POT_FILE%" >&2
    exit /b 1
)

REM Compile PO files to MO files
echo "Starting MO files compilation..."
set "COMPILE_COUNT=0"

for /d %%d in ("%~dp0l10n\*") do (
    if exist "%%d\koreader.po" (
        set "MO_FILE=%%d\koreader.mo"
        echo  "Compiling: %%~nxd\koreader.po -> %%~nxd\koreader.mo"
        msgfmt -o "!MO_FILE!" "%%d\koreader.po"
        if errorlevel 1 (
            echo "Error: Failed to compile %%~nxd\koreader.po!" >&2
        ) else (
            set /a "COMPILE_COUNT+=1"
        )
    )
)
echo "Compilation completed, successfully generated !COMPILE_COUNT! MO files"

REM make folder
mkdir projecttitle.koplugin

REM copy everything into the right folder name
copy *.lua projecttitle.koplugin
xcopy fonts projecttitle.koplugin\fonts /s /i
xcopy icons projecttitle.koplugin\icons /s /i
xcopy resources projecttitle.koplugin\resources /s /i
xcopy l10n projecttitle.koplugin\l10n /s /i

REM cleanup unwanted
del /q projecttitle.koplugin\resources\collage.jpg
del /q projecttitle.koplugin\resources\licenses.txt

REM zip the folder
7z a -tzip projecttitle.zip projecttitle.koplugin

REM delete the folder
rmdir /s /q projecttitle.koplugin

pause