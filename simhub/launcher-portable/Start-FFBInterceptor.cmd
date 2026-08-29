@rem SPDX-License-Identifier: GPL-3.0-only
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-FFBInterceptor.ps1" -NoPause %*
if errorlevel 1 pause
