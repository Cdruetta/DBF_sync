@echo off
setlocal
title Desinstalador de dbf_sync
echo Desinstalando dbf_sync...

rem 1) Cerrar el programa si esta corriendo
taskkill /IM dbf_sync.exe /F >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*dbf_sync.ps1*' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
timeout /t 2 >nul

rem 2) Quitar inicio con Windows
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v dbf_sync /f >nul 2>&1

rem 3) Quitar acceso directo del escritorio
powershell -NoProfile -ExecutionPolicy Bypass -Command "Remove-Item -LiteralPath ([Environment]::GetFolderPath('Desktop')+'\dbf_sync.lnk') -Force -ErrorAction SilentlyContinue"

rem 4) Borrar archivos del programa
if exist "%LOCALAPPDATA%\dbf_sync" rmdir /S /Q "%LOCALAPPDATA%\dbf_sync"

rem 5) Configuracion y logs (opcional)
echo.
set /p BORRAR=Borrar tambien la configuracion y los logs? (S/N): 
if /I "%BORRAR%"=="S" (
    if exist "%APPDATA%\dbf_sync" rmdir /S /Q "%APPDATA%\dbf_sync"
    echo Configuracion y logs borrados.
    echo Si habia elegido otra carpeta de logs, borrela manualmente.
)

echo.
echo Listo. dbf_sync fue desinstalado.
pause
