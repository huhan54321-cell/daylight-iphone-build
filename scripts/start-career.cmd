@echo off
chcp 65001 >nul
cd /d "%~dp0.."
where node >nul 2>nul
if errorlevel 1 (
  echo 需要先安装 Node.js 20 或更新版。
  pause
  exit /b 1
)
node scripts\career-server.cjs --lan
if errorlevel 1 pause
