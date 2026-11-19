@echo off
setlocal
title Compilar dbf_sync.exe
cd /d "%~dp0"

if not exist "dbf_sync.ps1" goto :falta

echo Compilando dbf_sync.exe (la primera vez descarga ps2exe, requiere internet)...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $dir=Join-Path $env:TEMP 'ps2exe_mod'; $psd=Join-Path $dir 'ps2exe.psd1'; if (-not (Test-Path $psd)) { if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }; $zip=Join-Path $env:TEMP 'ps2exe.zip'; if (Test-Path $zip) { Remove-Item $zip -Force }; Invoke-WebRequest -UseBasicParsing -Uri 'https://www.powershellgallery.com/api/v2/package/ps2exe' -OutFile $zip; Add-Type -AssemblyName System.IO.Compression.FileSystem; [System.IO.Compression.ZipFile]::ExtractToDirectory($zip,$dir) }; Import-Module $psd -Force; Invoke-ps2exe -inputFile '.\dbf_sync.ps1' -outputFile '.\dbf_sync.exe' -noConsole -STA -title 'dbf_sync' -product 'dbf_sync' -version '1.0.0.0'"
if errorlevel 1 goto :error
if not exist "dbf_sync.exe" goto :error

echo.
echo Listo: se genero dbf_sync.exe en esta carpeta.
echo Para repartir, use solo: dbf_sync.exe + Instalar_exe.bat + copia.bat
echo.
pause
exit /b 0

:falta
echo ERROR: no se encuentra dbf_sync.ps1 junto a este archivo.
pause
exit /b 1

:error
echo.
echo ERROR: no se pudo generar el .exe. Revise los mensajes de arriba.
pause
exit /b 1
