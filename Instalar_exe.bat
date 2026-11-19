@echo off
setlocal
title Instalador de dbf_sync
set "DEST=%LOCALAPPDATA%\dbf_sync"
set "SRC=%~dp0"

echo ==== Instalador de dbf_sync ====
echo Origen : %SRC%
echo Destino: %DEST%
echo.

if not exist "%SRC%dbf_sync.exe" goto :falta

echo Cerrando versiones anteriores...
taskkill /IM dbf_sync.exe /F >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { ($_.CommandLine -like '*dbf_sync.ps1*' -or $_.CommandLine -like '*CopiaRunner.ps1*') -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" >nul 2>&1
timeout /t 2 >nul

rem Limpiar restos de versiones anteriores (script y CopiaRunner)
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v CopiaRunner /f >nul 2>&1
if exist "%LOCALAPPDATA%\CopiaRunner" rmdir /S /Q "%LOCALAPPDATA%\CopiaRunner" >nul 2>&1
if exist "%DEST%\dbf_sync.ps1" del /F /Q "%DEST%\dbf_sync.ps1" >nul 2>&1
if exist "%DEST%\Iniciar_dbf_sync.vbs" del /F /Q "%DEST%\Iniciar_dbf_sync.vbs" >nul 2>&1

echo Copiando archivos...
if not exist "%DEST%" mkdir "%DEST%"
if not exist "%DEST%" goto :errdest
copy /Y "%SRC%dbf_sync.exe" "%DEST%\" >nul
if errorlevel 1 goto :errcopia
if exist "%SRC%copia.bat" copy /Y "%SRC%copia.bat" "%DEST%\" >nul
if not exist "%DEST%\copia.bat" echo ATENCION: no se encontro copia.bat junto al instalador. Seleccionelo luego desde la ventana del programa.

echo Configurando inicio con Windows...
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v dbf_sync /t REG_SZ /d "\"%DEST%\dbf_sync.exe\"" /f >nul
if errorlevel 1 echo AVISO: no se pudo configurar el inicio con Windows.

echo Creando acceso directo...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Desktop')+'\dbf_sync.lnk'); $s.TargetPath='%DEST%\dbf_sync.exe'; $s.WorkingDirectory='%DEST%'; $s.IconLocation='%DEST%\dbf_sync.exe,0'; $s.Save()"
if errorlevel 1 echo AVISO: no se pudo crear el acceso directo del escritorio.

echo Iniciando dbf_sync...
start "" "%DEST%\dbf_sync.exe"

echo.
echo Listo. dbf_sync quedo instalado en:
echo    %DEST%
echo Se abrira la ventana de configuracion. Luego funciona en segundo plano
echo (icono junto al reloj) y arranca solo al iniciar Windows.
echo.
pause
exit /b 0

:falta
echo ERROR: no se encuentra dbf_sync.exe junto al instalador.
echo Deben estar en la misma carpeta (y no ejecute el instalador desde dentro de un zip).
pause
exit /b 1

:errdest
echo ERROR: no se pudo crear la carpeta de instalacion: %DEST%
pause
exit /b 1

:errcopia
echo ERROR: no se pudo copiar dbf_sync.exe a %DEST%
echo Cierre dbf_sync (icono junto al reloj, clic derecho, Salir) y vuelva a intentar.
pause
exit /b 1
