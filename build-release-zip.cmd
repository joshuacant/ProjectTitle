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
del projecttitle.koplugin\resources\collage.jpg
del projecttitle.koplugin\resources\licenses.txt
del /s /q projecttitle.koplugin\*.po

REM zip the folder
7z a -tzip projecttitle.zip projecttitle.koplugin

REM delete the folder
rmdir /s /q projecttitle.koplugin

pause