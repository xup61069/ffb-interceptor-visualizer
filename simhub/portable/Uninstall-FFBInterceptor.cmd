@rem SPDX-License-Identifier: GPL-3.0-only
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-FFBInterceptor.ps1"
if errorlevel 1 pause
