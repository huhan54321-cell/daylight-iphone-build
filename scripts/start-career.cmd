@echo off
chcp 65001 >nul
cd /d "%~dp0.."
where node >nul 2>nul
if errorlevel 1 (
  echo 需要先安装 Node.js 24.15 或更新版（SQLite 数据库支持）。
  pause
  exit /b 1
)
set "CAREER_PROXY_FLAG="
node --help | findstr /C:"--use-env-proxy" >nul 2>nul
if not errorlevel 1 set "CAREER_PROXY_FLAG=--use-env-proxy"
if exist "data\career-private\search.env" (
  node %CAREER_PROXY_FLAG% --env-file="data\career-private\search.env" scripts\career-server.cjs
) else (
  node scripts\career-server.cjs
)
if errorlevel 1 pause
