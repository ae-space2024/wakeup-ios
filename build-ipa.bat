@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"
title Build TrollStore IPA

echo.
echo  ==================================================
echo   TrollStore IPA Builder - One Click
echo  ==================================================
echo.
echo  This script will:
echo    1. Login to GitHub (first time only)
echo    2. Create a repo and upload the iOS project
echo    3. Wait for cloud build
echo    4. Download the IPA to your Desktop
echo.

REM ---- 1. Check GitHub CLI ----
where gh >nul 2>&1
if errorlevel 1 (
    echo  [ERROR] GitHub CLI not installed.
    echo  Download from: https://cli.github.com
    echo.
    pause
    exit /b 1
)

REM ---- 2. GitHub login ----
gh auth status >nul 2>&1
if errorlevel 1 (
    echo  GitHub login required. Your browser will open.
    echo  Finish login in browser, then return here.
    echo.
    gh auth login --web --git-protocol https
    gh auth status >nul 2>&1
    if errorlevel 1 (
        echo  [ERROR] Login failed.
        pause
        exit /b 1
    )
)
echo  [OK] GitHub authenticated.

REM ---- 3. Repo info ----
for /f "delims=" %%u in ('gh api user -q .login 2^>nul') do set "GHUSER=%%u"
if "!GHUSER!"=="" (
    echo  [ERROR] Cannot get GitHub username.
    pause
    exit /b 1
)

set "REPONAME=wakeup-ios"
set /p "INPUT=  Repo name [wakeup-ios]: "
if not "!INPUT!"=="" set "REPONAME=!INPUT!"
echo  [OK] Repository: !GHUSER!/!REPONAME!

REM ---- 4. Create repo if missing ----
gh repo view "!GHUSER!/!REPONAME!" >nul 2>&1
if errorlevel 1 (
    echo  Creating repository...
    gh repo create "!REPONAME!" --public --confirm >nul 2>&1
    echo  [OK] Repository created.
) else (
    echo  [OK] Repository exists (code will be updated).
)

REM ---- 5. Upload code ----
if not exist ".git" (
    echo  Initializing git...
    git init -q
    git config user.name "IPA Builder"
    git config user.email "builder@local"
    git add .
    git commit -q -m "iOS project for TrollStore"
    git branch -M main
    git remote remove origin 2>nul
    git remote add origin "https://github.com/!GHUSER!/!REPONAME!.git"
)
echo  Uploading code...
git push -q -u origin main
if errorlevel 1 (
    echo  [ERROR] Upload failed. Check repo permissions.
    pause
    exit /b 1
)
echo  [OK] Code uploaded. Cloud build started.

REM ---- 6. Wait for build ----
echo.
echo  Waiting for build ^(3-5 minutes^)...
set "COUNT=0"
:LOOP
set /a COUNT+=1
if !COUNT! GTR 90 (
    echo  [TIMEOUT] Check manually:
    echo  https://github.com/!GHUSER!/!REPONAME!/actions
    pause
    exit /b 1
)

set "STATUS="
for /f "delims=" %%s in ('gh run list --repo "!GHUSER!/!REPONAME!" --limit 1 --json status -q ".[0].status" 2^>nul') do set "STATUS=%%s"
if "!STATUS!"=="completed" goto CHECK
echo  [!COUNT!/90] Build status: !STATUS!
timeout /t 5 /nobreak >nul
goto LOOP

:CHECK
set "CONCLUSION="
for /f "delims=" %%c in ('gh run list --repo "!GHUSER!/!REPONAME!" --limit 1 --json conclusion -q ".[0].conclusion" 2^>nul') do set "CONCLUSION=%%c"
if not "!CONCLUSION!"=="success" (
    echo.
    echo  [ERROR] Build failed: !CONCLUSION!
    echo  View log: https://github.com/!GHUSER!/!REPONAME!/actions
    echo.
    pause
    exit /b 1
)

REM ---- 7. Download IPA ----
echo.
echo  [OK] Build success! Downloading IPA...
set "DESK=!USERPROFILE!\Desktop"
if not exist "!DESK!" set "DESK=!USERPROFILE!\OneDrive\Desktop"
gh run download --repo "!GHUSER!/!REPONAME!" --name "WakeUpPower-TrollStore" --dir "!DESK!" >nul 2>&1

if exist "!DESK!\WakeUpPower-TrollStore.ipa" (
    echo.
    echo  ==================================================
    echo   SUCCESS!
    echo   IPA saved to:
    echo   !DESK!\WakeUpPower-TrollStore.ipa
    echo.
    echo   Open it with TrollStore on your iPhone/iPad.
    echo  ==================================================
) else (
    echo.
    echo  IPA downloaded. Check your Desktop.
    echo  ^(If missing, download manually from Actions artifacts^)
)
echo.
pause
