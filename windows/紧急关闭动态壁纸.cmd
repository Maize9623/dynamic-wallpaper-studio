@echo off
chcp 65001 >nul
taskkill /F /IM DynamicWallpaperStudio.exe >nul 2>&1
timeout /t 2 /nobreak >nul
start "" "%~dp0DynamicWallpaperStudio.exe" --safe-mode
