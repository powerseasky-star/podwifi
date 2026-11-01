@echo off
REM ============================================================
REM  Push this iOS project to GitHub (one-click)
REM
REM  ASCII-only on purpose: cmd.exe breaks on UTF-8 without BOM.
REM
REM  Two ways to provide the token:
REM    1) put the token alone in  token.txt   (this folder)  -> fully silent
REM    2) leave it out                -> the script asks you to paste it
REM  Two ways to provide the repo:
REM    1) put "owner/repo" in        repo.txt  (this folder)
REM    2) leave it out                -> the script asks you
REM
REM  The token is used for ONE push and is NOT written into .git/config.
REM  Delete token.txt after use.
REM ============================================================
setlocal enabledelayedexpansion
chcp 65001 >nul
cd /d "%~dp0"

echo ============================================
echo   Push "PodWifi" iOS project to GitHub
echo ============================================
echo.

set "TOKEN="
if exist "token.txt" (
  for /f "usebackq delims=" %%T in ("token.txt") do if not defined TOKEN set "TOKEN=%%T"
)
if not defined TOKEN (
  set /p TOKEN=Paste your GitHub token (input hidden? no, but it stays local): 
)
if not defined TOKEN (
  echo [ERROR] token is empty.
  goto :fail
)

set "REPO="
if exist "repo.txt" (
  for /f "usebackq delims=" %%R in ("repo.txt") do if not defined REPO set "REPO=%%R"
)
if not defined REPO (
  set /p REPO=Repo as owner/name (e.g. zhanghai/podwifi): 
)
if not defined REPO (
  echo [ERROR] repo is empty.
  goto :fail
)

REM strip optional https://github.com/ prefix and trailing .git
set "REPO=!REPO:https://github.com/=!"
set "REPO=!REPO:http://github.com/=!"
set "REPO=!REPO:.git=!"
if "!REPO:~-1!"=="/" set "REPO=!REPO:~0,-1!"

for /f "tokens=1,2 delims=/" %%A in ("!REPO!") do (
  set "OWNER=%%A"
  set "RNAME=%%B"
)
if not defined RNAME (
  echo [ERROR] repo must look like owner/name
  goto :fail
)

echo.
echo Repo : !OWNER!/!RNAME!
echo.

if not exist ".git" (
  echo [1/5] git init
  git init -b main >nul 2>&1 || git init >nul 2>&1
  git branch -M main >nul 2>&1
)

echo [2/5] set local identity (repo-scoped only, does not touch global config)
git config user.name >nul 2>&1
if errorlevel 1 git config user.name "pod-builder"
git config user.email >nul 2>&1
if errorlevel 1 git config user.email "pod-builder@localhost"

echo [3/5] stage and commit
git add -A
git commit -m "PodWifi iOS receiver v1 (MJPEG + sensor + TTS)" >nul 2>&1
if errorlevel 1 echo       (nothing new to commit - fine)

echo [4/5] push
set "AUTH=https://x-access-token:!TOKEN!@github.com/!OWNER!/!RNAME!.git"
git remote remove origin >nul 2>&1
git remote add origin https://github.com/!OWNER!/!RNAME!.git
git push "!AUTH!" HEAD:main
if errorlevel 1 (
  echo.
  echo       push rejected - repo may already contain files ^(README etc.^).
  echo       Trying to integrate remote history then push again...
  git fetch "!AUTH!" main
  if errorlevel 1 (
    echo [ERROR] cannot fetch remote main. Check repo name and token scope.
    goto :fail
  )
  git rebase FETCH_HEAD
  git push "!AUTH!" HEAD:main
  if errorlevel 1 (
    echo.
    echo [ERROR] push still failed. Open the repo page and confirm it exists and is empty.
    goto :fail
  )
)

echo [5/5] cleanup token from remote url
git remote set-url origin https://github.com/!OWNER!/!RNAME!.git

echo.
echo ============================================
echo   DONE
echo   Actions: https://github.com/!OWNER!/!RNAME!/actions
echo   Wait ~5-8 min, open the run, download artifact "PodWifi-ipa".
echo ============================================
echo.
echo Remember to delete token.txt if you created it.
pause
exit /b 0

:fail
echo.
echo FAILED. Nothing was uploaded.
pause
exit /b 1
