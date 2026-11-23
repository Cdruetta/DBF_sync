# AGENTS.md

## Project
Windows tray app (`dbf_sync`) that periodically runs a user `.bat` (typically `copia.bat`) in the background, logs output, and shows status via a tray icon. UI is in Spanish.

## Source of truth
- `dbf_sync.ps1` is the source (UTF-8 with BOM). `DBF_sync.exe` is a generated artifact (ps2exe) — never edit the exe; edit the ps1 and rebuild.
- `README.md` is just a title. Real behavior/docs live in `dbf_sync.ps1` (comments + `Show-About`).

## Commands
- Build: run `Compilar.bat` (downloads ps2exe from PowerShell Gallery into `%TEMP%\ps2exe_mod` on first run; needs internet). Output: `dbf_sync.exe`.
- Install: run `Instalar_exe.bat` (copies exe to `%LOCALAPPDATA%\dbf_sync`, sets `HKCU\...\Run\dbf_sync`, desktop shortcut, launches).
- Uninstall: run `Desinstalar.bat`.
- No tests, lint, or typecheck exist in this repo.

## Architecture
- Single PowerShell script compiled with ps2exe (`-noConsole -STA`). `$IsExe` detects compiled vs script mode and sets `$AppDir`.
- Single instance via mutex `Local\dbf_sync` + event `Local\dbf_sync_Show`; a second launch signals the running instance to show its window and exits.
- Config persisted to `%APPDATA%\dbf_sync\config.json` (`$script:Cfg`). Default bat: `copia.bat` beside app dir. Logs default `%APPDATA%\dbf_sync\logs`. Scheduling mode is `Mode` (`Intervalo` or `Horarios`); in `Horarios` mode uses `Schedule1`/`Schedule2` ("HH:mm") with `Enable1`/`Enable2`.
- Runs the configured bat via `cmd /c` with working dir = bat's parent; captures combined stdout/stderr to `%TEMP%\dbf_sync_salida.tmp`; success = exit code 0 and no timeout. Timeout kills the whole process tree (`taskkill /T /F`).
- Timer tick every 1s drives the cycle (`Update-Cycle`) and UI.

## Conventions / gotchas
- Minimum interval is 10 seconds (validated in `Save-FromUI`).
- Preserve the UTF-8 BOM when editing `dbf_sync.ps1`.
- `copia.bat` is not in this repo; it's the user's sync script. Don't commit a real one.
- Distribution set is `dbf_sync.exe` + `Instalar_exe.bat` + `copia.bat` (see `Compilar.bat`).
- `files.zip` is a stale snapshot of release files; don't treat it as source.
- The committed `DBF_sync.exe` must be regenerated after any ps1 change.