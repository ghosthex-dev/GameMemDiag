@echo off
title GameMemDiag
cd /d "%~dp0"
echo.
echo   GameMemDiag - out-of-memory crash tracer
echo   ========================================
echo.
echo   1  Start monitoring  (do this BEFORE launching the game, leave the window open,
echo                         press Q here after the crash or when you are done)
echo   2  Collect report    (after a crash, a freeze/reboot, or if the monitor window was closed)
echo.
choice /c 12 /n /m "  Choose 1 or 2: "
if errorlevel 2 goto collect

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0GameMemDiag.ps1" -Mode Monitor
goto end

:collect
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0GameMemDiag.ps1" -Mode Collect

:end
echo.
pause
