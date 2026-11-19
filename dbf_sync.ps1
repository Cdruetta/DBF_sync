# ============================================================================
#  dbf_sync - Ejecuta un .bat de forma periodica en segundo plano
#  - Corre con los permisos del usuario actual (ve las unidades mapeadas z:, f:, g:)
#  - Icono en la bandeja del sistema con indicador de estado
#  - Configuracion guardada en %APPDATA%\dbf_sync\config.json
# ============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$AppName    = 'dbf_sync'
$ConfigDir  = Join-Path $env:APPDATA $AppName
$ConfigFile = Join-Path $ConfigDir 'config.json'
$TempOut    = Join-Path $env:TEMP 'dbf_sync_salida.tmp'

# Modo de ejecucion: .exe compilado (ps2exe) o script .ps1
$SelfPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$IsExe    = ($SelfPath -notmatch '(?i)\\(powershell|pwsh|powershell_ise)\.exe$')
if ($IsExe) { $AppDir = Split-Path -Parent $SelfPath } else { $AppDir = $PSScriptRoot }

# --- Instancia unica por sesion ---------------------------------------------
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\$AppName", [ref]$createdNew)
$showEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, "Local\${AppName}_Show")
if (-not $createdNew) {
    # Ya hay una instancia corriendo: pedirle que muestre su ventana de configuracion
    [void]$showEvent.Set()
    exit
}

# --- Configuracion -----------------------------------------------------------
$script:Cfg = [ordered]@{
    BatPath          = ''
    IntervalValue    = 15
    IntervalUnit     = 'Minutos'
    LogFolder        = (Join-Path $ConfigDir 'logs')
    LogRetentionDays = 30
    TimeoutMinutes   = 30
    AutoStart        = $true
    RunOnStart       = $true
}

function Load-Config {
    if (Test-Path -LiteralPath $ConfigFile) {
        try {
            $j = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                if ($script:Cfg.Contains($p.Name)) { $script:Cfg[$p.Name] = $p.Value }
            }
        } catch {}
    }
}

function Save-Config {
    try {
        if (-not (Test-Path -LiteralPath $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
        $script:Cfg | ConvertTo-Json | Set-Content -LiteralPath $ConfigFile -Encoding UTF8
    } catch {
        [System.Windows.Forms.MessageBox]::Show("No se pudo guardar la configuracion:`n$($_.Exception.Message)", $AppName, 'OK', 'Error') | Out-Null
    }
}

function Convert-ToSeconds($value, $unit) {
    $v = [int]$value
    switch ($unit) {
        'Segundos' { return $v }
        'Minutos'  { return $v * 60 }
        'Horas'    { return $v * 3600 }
        default    { return $v * 60 }
    }
}

function Get-IntervalSeconds { return (Convert-ToSeconds $script:Cfg.IntervalValue $script:Cfg.IntervalUnit) }

# --- Estado ------------------------------------------------------------------
$script:Running    = $false   # ciclo automatico activo
$script:Proc       = $null    # proceso del .bat en curso
$script:RunStart   = $null
$script:Next       = $null
$script:LastRun    = $null
$script:LastOk     = $null
$script:LastResult = '-'
$script:Runs       = 0
$script:Mode       = ''
$script:Exiting    = $false
$script:HintShown  = $false

$firstRun = -not (Test-Path -LiteralPath $ConfigFile)
Load-Config
# Primer uso: si no hay .bat configurado, usar copia.bat que este junto al programa
if (-not $script:Cfg.BatPath -or -not (Test-Path -LiteralPath $script:Cfg.BatPath -PathType Leaf)) {
    $cand = Join-Path $AppDir 'copia.bat'
    if (Test-Path -LiteralPath $cand -PathType Leaf) { $script:Cfg.BatPath = $cand; Save-Config }
}

# --- Inicio con Windows (solo usuario actual, sin admin) ---------------------
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Get-Startup {
    try { return ($null -ne (Get-ItemProperty -Path $RunKey -Name $AppName -ErrorAction Stop).$AppName) } catch { return $false }
}

function Set-Startup([bool]$on) {
    try {
        if ($on) {
            $vbs = Join-Path $AppDir 'Iniciar_dbf_sync.vbs'
            if ($IsExe) {
                $cmd = "`"$SelfPath`""
            } elseif (Test-Path -LiteralPath $vbs) {
                $cmd = "wscript.exe `"$vbs`""
            } else {
                $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
            }
            Set-ItemProperty -Path $RunKey -Name $AppName -Value $cmd
        } else {
            Remove-ItemProperty -Path $RunKey -Name $AppName -ErrorAction SilentlyContinue
        }
    } catch {}
}

# --- Iconos de estado --------------------------------------------------------
function New-DotIcon([System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $br  = New-Object System.Drawing.SolidBrush $color
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(110, 0, 0, 0)), 1
    $g.FillEllipse($br, 1, 1, 14, 14)
    $g.DrawEllipse($pen, 1, 1, 13, 13)
    $g.Dispose(); $br.Dispose(); $pen.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function Get-ModeColor($m) {
    switch ($m) {
        'Ejecutando' { return [System.Drawing.Color]::FromArgb(33, 150, 243) }
        'Esperando'  { return [System.Drawing.Color]::FromArgb(46, 160, 67) }
        'Error'      { return [System.Drawing.Color]::FromArgb(220, 53, 69) }
        default      { return [System.Drawing.Color]::FromArgb(140, 140, 140) }
    }
}

$icons = @{}
foreach ($m in 'Detenido', 'Esperando', 'Ejecutando', 'Error') { $icons[$m] = New-DotIcon (Get-ModeColor $m) }

# --- Interfaz ----------------------------------------------------------------
function New-Ctl($type, $x, $y, $w, $h, $text = '') {
    $c = New-Object $type
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, $h)
    if ($text) { $c.Text = $text }
    return $c
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'dbf_sync - Ejecutor de copia.bat'
$form.ClientSize = New-Object System.Drawing.Size(540, 600)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.Icon = $icons['Detenido']

# Estado
$grpEstado = New-Ctl System.Windows.Forms.GroupBox 10 8 520 128 'Estado'
$pnlDot    = New-Ctl System.Windows.Forms.Panel 16 24 28 28
$lblEstado = New-Ctl System.Windows.Forms.Label 52 24 350 28
$lblEstado.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$lblEstado.TextAlign = 'MiddleLeft'
$btnAbout = New-Ctl System.Windows.Forms.Button 410 24 100 26 'Ayuda'
$lblProx = New-Ctl System.Windows.Forms.Label 16 62 490 18
$lblUlt  = New-Ctl System.Windows.Forms.Label 16 83 490 18
$lblRes  = New-Ctl System.Windows.Forms.Label 16 104 490 18
$grpEstado.Controls.AddRange(@($pnlDot, $lblEstado, $btnAbout, $lblProx, $lblUlt, $lblRes))
$pnlDot.Add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $b = New-Object System.Drawing.SolidBrush (Get-ModeColor $script:Mode)
    $e.Graphics.FillEllipse($b, 2, 2, 24, 24)
    $b.Dispose()
})

# Configuracion
$grpCfg = New-Ctl System.Windows.Forms.GroupBox 10 144 520 230 'Configuracion'

$l1 = New-Ctl System.Windows.Forms.Label 12 28 92 20 'Archivo .bat:'
$txtBat = New-Ctl System.Windows.Forms.TextBox 108 25 302 23
$btnBat = New-Ctl System.Windows.Forms.Button 418 24 90 25 'Buscar...'

$l2 = New-Ctl System.Windows.Forms.Label 12 64 92 20 'Ejecutar cada:'
$numInt = New-Ctl System.Windows.Forms.NumericUpDown 108 61 70 23
$numInt.Minimum = 1; $numInt.Maximum = 100000
$cboUnit = New-Ctl System.Windows.Forms.ComboBox 186 61 90 23
$cboUnit.DropDownStyle = 'DropDownList'
[void]$cboUnit.Items.AddRange(@('Segundos', 'Minutos', 'Horas'))
$l3 = New-Ctl System.Windows.Forms.Label 300 64 110 20 'Limite por corrida (min):'
$l3.Size = New-Object System.Drawing.Size(130, 20)
$numTimeout = New-Ctl System.Windows.Forms.NumericUpDown 434 61 60 23
$numTimeout.Minimum = 1; $numTimeout.Maximum = 1440

$l4 = New-Ctl System.Windows.Forms.Label 12 100 92 20 'Carpeta de logs:'
$txtLogDir = New-Ctl System.Windows.Forms.TextBox 108 97 302 23
$btnLogDir = New-Ctl System.Windows.Forms.Button 418 96 90 25 'Buscar...'

$l5 = New-Ctl System.Windows.Forms.Label 12 136 150 20 'Conservar logs (dias):'
$numRet = New-Ctl System.Windows.Forms.NumericUpDown 164 133 60 23
$numRet.Minimum = 1; $numRet.Maximum = 3650
$btnOpenLogs = New-Ctl System.Windows.Forms.Button 398 132 110 25 'Abrir carpeta'

$chkAuto   = New-Ctl System.Windows.Forms.CheckBox 12 166 490 20 'Iniciar el ciclo automaticamente al abrir el programa'
$chkRunNow = New-Ctl System.Windows.Forms.CheckBox 12 188 490 20 'Ejecutar inmediatamente al iniciar el ciclo'
$chkWin    = New-Ctl System.Windows.Forms.CheckBox 12 210 490 20 'Iniciar con Windows (solo para este usuario)'

$grpCfg.Controls.AddRange(@($l1, $txtBat, $btnBat, $l2, $numInt, $cboUnit, $l3, $numTimeout, $l4, $txtLogDir, $btnLogDir, $l5, $numRet, $btnOpenLogs, $chkAuto, $chkRunNow, $chkWin))
$grpCfg.Height = 238

# Botones
$btnSave  = New-Ctl System.Windows.Forms.Button 10 388 120 32 'Guardar'
$btnStart = New-Ctl System.Windows.Forms.Button 140 388 120 32 'Iniciar'
$btnStop  = New-Ctl System.Windows.Forms.Button 270 388 120 32 'Detener'
$btnNow   = New-Ctl System.Windows.Forms.Button 400 388 130 32 'Ejecutar ahora'

# Log en pantalla
$txtLogView = New-Ctl System.Windows.Forms.TextBox 10 430 520 160
$txtLogView.Multiline = $true
$txtLogView.ReadOnly = $true
$txtLogView.ScrollBars = 'Vertical'
$txtLogView.WordWrap = $true
$txtLogView.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$txtLogView.BackColor = [System.Drawing.Color]::White

$form.Controls.AddRange(@($grpEstado, $grpCfg, $btnSave, $btnStart, $btnStop, $btnNow, $txtLogView))

# Icono de bandeja
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = $icons['Detenido']
$notify.Text = $AppName
$notify.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen  = $menu.Items.Add('Abrir ventana')
[void]$menu.Items.Add('-')
$miStart = $menu.Items.Add('Iniciar')
$miStop  = $menu.Items.Add('Detener')
$miNow   = $menu.Items.Add('Ejecutar ahora')
[void]$menu.Items.Add('-')
$miLogs  = $menu.Items.Add('Abrir carpeta de logs')
$miHelp  = $menu.Items.Add('Ayuda / Acerca de')
[void]$menu.Items.Add('-')
$miExit  = $menu.Items.Add('Salir')
$notify.ContextMenuStrip = $menu

# --- Logs --------------------------------------------------------------------
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    foreach ($l in @($Msg -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        $line = "$ts [$Level] $l"
        try {
            if (-not (Test-Path -LiteralPath $script:Cfg.LogFolder)) { New-Item -ItemType Directory -Path $script:Cfg.LogFolder -Force | Out-Null }
            $file = Join-Path $script:Cfg.LogFolder ('dbf_sync_{0:yyyy-MM-dd}.log' -f (Get-Date))
            Add-Content -LiteralPath $file -Value $line -Encoding UTF8
        } catch {}
        $txtLogView.AppendText($line + "`r`n")
    }
    if ($txtLogView.TextLength -gt 60000) { $txtLogView.Text = $txtLogView.Text.Substring(30000) }
}

function Clear-OldLogs {
    try {
        $limit = (Get-Date).AddDays(-[int]$script:Cfg.LogRetentionDays)
        Get-ChildItem -LiteralPath $script:Cfg.LogFolder -Filter 'dbf_sync_*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $limit } | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}
}

# --- Ejecucion ---------------------------------------------------------------
function Stop-ProcTree($proc) {
    try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch {}
}

function Set-NextRun { $script:Next = (Get-Date).AddSeconds((Get-IntervalSeconds)) }

function Start-Run {
    if ($script:Proc) { return }
    $bat = $script:Cfg.BatPath
    if (-not $bat -or -not (Test-Path -LiteralPath $bat -PathType Leaf)) {
        Write-Log "No se encuentra el archivo .bat: '$bat'" 'ERROR'
        $script:LastOk = $false; $script:LastRun = Get-Date; $script:LastResult = 'Archivo .bat no encontrado'
        if ($script:Running) { Set-NextRun }
        return
    }
    try {
        Remove-Item -LiteralPath $TempOut -Force -ErrorAction SilentlyContinue
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $env:ComSpec
        $psi.Arguments = "/c `"`"$bat`" > `"$TempOut`" 2>&1`""
        $psi.WorkingDirectory = Split-Path -Parent $bat
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $script:Proc = [System.Diagnostics.Process]::Start($psi)
        $script:Proc.StandardInput.Close()
        $script:RunStart = Get-Date
        Write-Log "Ejecutando: $bat (PID $($script:Proc.Id))"
    } catch {
        Write-Log "No se pudo iniciar el .bat: $($_.Exception.Message)" 'ERROR'
        $script:Proc = $null
        $script:LastOk = $false; $script:LastRun = Get-Date; $script:LastResult = 'No se pudo iniciar'
        if ($script:Running) { Set-NextRun }
    }
}

function Complete-Run([bool]$timedOut) {
    $p = $script:Proc
    $code = $null
    if ($timedOut) { $code = -1 } else { try { $code = $p.ExitCode } catch { $code = -1 } }
    $dur = (Get-Date) - $script:RunStart
    $out = ''
    if (Test-Path -LiteralPath $TempOut) {
        try {
            $ansi = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
            $out = [System.IO.File]::ReadAllText($TempOut, $ansi)
        } catch {}
    }
    if ($out) { Write-Log ("Salida del .bat:`n" + $out.TrimEnd()) 'OUT' }

    $ok = (-not $timedOut) -and ($code -eq 0)
    $secs = [math]::Round($dur.TotalSeconds, 1)
    if ($ok) {
        Write-Log "Finalizo correctamente (codigo 0, $secs s)"
        $script:LastResult = "OK (codigo 0, $secs s)"
    } elseif ($timedOut) {
        Write-Log "Superó el limite de $($script:Cfg.TimeoutMinutes) min y fue terminado" 'ERROR'
        $script:LastResult = 'ERROR: tiempo limite excedido'
    } else {
        Write-Log "Finalizo con error (codigo $code, $secs s)" 'ERROR'
        $script:LastResult = "ERROR (codigo $code, $secs s)"
    }
    if (-not $ok -and $script:LastOk -ne $false) {
        $notify.ShowBalloonTip(5000, $AppName, 'La ultima ejecucion de copia.bat termino con error. Revise el log.', 'Error')
    }
    $script:LastOk = $ok
    $script:LastRun = Get-Date
    $script:Runs++
    try { $p.Dispose() } catch {}
    $script:Proc = $null
    if ($script:Running) { Set-NextRun }
}

function Update-Cycle {
    if ($script:Proc) {
        if ($script:Proc.HasExited) {
            Complete-Run $false
        } elseif (((Get-Date) - $script:RunStart).TotalMinutes -ge [int]$script:Cfg.TimeoutMinutes) {
            Stop-ProcTree $script:Proc
            Start-Sleep -Milliseconds 300
            Complete-Run $true
        }
        return
    }
    if ($script:Running -and $script:Next -and ((Get-Date) -ge $script:Next)) { Start-Run }
}

function Start-Cycle {
    param([switch]$Silent)
    if ($script:Running) { return $true }
    $bat = $script:Cfg.BatPath
    if (-not $bat -or -not (Test-Path -LiteralPath $bat -PathType Leaf)) {
        if (-not $Silent) { [System.Windows.Forms.MessageBox]::Show('Seleccione un archivo .bat valido antes de iniciar.', $AppName, 'OK', 'Warning') | Out-Null }
        return $false
    }
    $script:Running = $true
    if ($script:Cfg.RunOnStart) { $script:Next = Get-Date } else { Set-NextRun }
    Write-Log "Ciclo iniciado. Archivo: $bat | Cada $($script:Cfg.IntervalValue) $($script:Cfg.IntervalUnit)"
    return $true
}

function Stop-Cycle {
    if (-not $script:Running -and -not $script:Proc) { return }
    $script:Running = $false
    $script:Next = $null
    if ($script:Proc) {
        Stop-ProcTree $script:Proc
        Start-Sleep -Milliseconds 300
        try { $script:Proc.Dispose() } catch {}
        $script:Proc = $null
        Write-Log 'Ejecucion en curso cancelada' 'WARN'
    }
    Write-Log 'Ciclo detenido'
}

# --- UI <-> config -----------------------------------------------------------
function Load-UI {
    $txtBat.Text = [string]$script:Cfg.BatPath
    $numInt.Value = [decimal][math]::Max(1, [int]$script:Cfg.IntervalValue)
    $cboUnit.SelectedItem = [string]$script:Cfg.IntervalUnit
    if ($cboUnit.SelectedIndex -lt 0) { $cboUnit.SelectedIndex = 1 }
    $numTimeout.Value = [decimal][math]::Max(1, [int]$script:Cfg.TimeoutMinutes)
    $txtLogDir.Text = [string]$script:Cfg.LogFolder
    $numRet.Value = [decimal][math]::Max(1, [int]$script:Cfg.LogRetentionDays)
    $chkAuto.Checked = [bool]$script:Cfg.AutoStart
    $chkRunNow.Checked = [bool]$script:Cfg.RunOnStart
    $chkWin.Checked = Get-Startup
}

function Save-FromUI {
    $bat = $txtBat.Text.Trim().Trim('"')
    if (-not $bat -or -not (Test-Path -LiteralPath $bat -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show('El archivo .bat indicado no existe.', $AppName, 'OK', 'Warning') | Out-Null
        return $false
    }
    $secs = Convert-ToSeconds $numInt.Value $cboUnit.SelectedItem
    if ($secs -lt 10) {
        [System.Windows.Forms.MessageBox]::Show('El intervalo minimo es de 10 segundos.', $AppName, 'OK', 'Warning') | Out-Null
        return $false
    }
    $logDir = $txtLogDir.Text.Trim().Trim('"')
    if (-not $logDir) {
        [System.Windows.Forms.MessageBox]::Show('Indique una carpeta para los logs.', $AppName, 'OK', 'Warning') | Out-Null
        return $false
    }
    try { New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null }
    catch {
        [System.Windows.Forms.MessageBox]::Show("No se pudo crear/acceder a la carpeta de logs:`n$($_.Exception.Message)", $AppName, 'OK', 'Warning') | Out-Null
        return $false
    }
    $script:Cfg.BatPath = $bat
    $script:Cfg.IntervalValue = [int]$numInt.Value
    $script:Cfg.IntervalUnit = [string]$cboUnit.SelectedItem
    $script:Cfg.TimeoutMinutes = [int]$numTimeout.Value
    $script:Cfg.LogFolder = $logDir
    $script:Cfg.LogRetentionDays = [int]$numRet.Value
    $script:Cfg.AutoStart = $chkAuto.Checked
    $script:Cfg.RunOnStart = $chkRunNow.Checked
    Save-Config
    Set-Startup $chkWin.Checked
    if ($script:Running -and -not $script:Proc) { Set-NextRun }
    Write-Log 'Configuracion guardada'
    return $true
}

function Format-Span($ts) {
    if ($ts.TotalSeconds -lt 0) { $ts = [TimeSpan]::Zero }
    return ('{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
}

function Get-Mode {
    if ($script:Proc) { return 'Ejecutando' }
    if (-not $script:Running) { return 'Detenido' }
    if ($script:LastOk -eq $false) { return 'Error' }
    return 'Esperando'
}

function Update-UI {
    $mode = Get-Mode
    if ($mode -ne $script:Mode) {
        $script:Mode = $mode
        $notify.Icon = $icons[$mode]
        $form.Icon = $icons[$mode]
        $pnlDot.Invalidate()
    }
    $lblEstado.Text = switch ($mode) {
        'Ejecutando' { 'Ejecutando copia...' }
        'Esperando'  { 'Activo - esperando proxima ejecucion' }
        'Error'      { 'Activo - la ultima ejecucion fallo' }
        default      { 'Detenido' }
    }
    if ($script:Proc) {
        $lblProx.Text = 'En ejecucion desde hace ' + (Format-Span ((Get-Date) - $script:RunStart))
    } elseif ($script:Running -and $script:Next) {
        $lblProx.Text = ('Proxima ejecucion: {0:HH:mm:ss}   (en {1})' -f $script:Next, (Format-Span ($script:Next - (Get-Date))))
    } else {
        $lblProx.Text = 'Proxima ejecucion: -'
    }
    $lblUlt.Text = 'Ultima ejecucion: ' + $(if ($script:LastRun) { '{0:yyyy-MM-dd HH:mm:ss}' -f $script:LastRun } else { '-' })
    $lblRes.Text = "Resultado: $($script:LastResult)   |   Ejecuciones: $($script:Runs)"

    $busy = [bool]$script:Proc
    $btnStart.Enabled = (-not $script:Running)
    $btnStop.Enabled  = ($script:Running -or $busy)
    $btnNow.Enabled   = (-not $busy)
    $miStart.Enabled  = $btnStart.Enabled
    $miStop.Enabled   = $btnStop.Enabled
    $miNow.Enabled    = $btnNow.Enabled

    $tip = "$AppName - $mode"
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $notify.Text = $tip
}

function Show-Form {
    $form.Show()
    $form.WindowState = 'Normal'
    $form.Activate()
}

function Open-LogFolder {
    try {
        if (-not (Test-Path -LiteralPath $script:Cfg.LogFolder)) { New-Item -ItemType Directory -Path $script:Cfg.LogFolder -Force | Out-Null }
        Start-Process explorer.exe -ArgumentList "`"$($script:Cfg.LogFolder)`""
    } catch {}
}

function Exit-App {
    $script:Exiting = $true
    $timer.Stop()
    Stop-Cycle
    Write-Log 'Programa cerrado'
    $notify.Visible = $false
    $notify.Dispose()
    try { $mutex.ReleaseMutex() } catch {}
    [System.Windows.Forms.Application]::ExitThread()
}

$script:Version = '1.0'

function Show-About {
    $texto = @"
dbf_sync  -  versión $($script:Version)

QUÉ HACE
Ejecuta automáticamente un archivo .bat (por ejemplo copia.bat) cada cierto tiempo, en segundo plano y con los permisos del usuario actual. El .bat hace la copia; dbf_sync solo lo ejecuta, lo controla y registra el resultado.

CÓMO USARLO
1. En "Archivo .bat" elija el archivo a ejecutar (botón Buscar...).
2. En "Ejecutar cada" indique cada cuánto debe correr.
3. Elija la carpeta donde se guardan los logs.
4. Presione Guardar y luego Iniciar.
Al cerrar la ventana (X) el programa sigue funcionando junto al reloj. Para cerrarlo por completo: clic derecho en el ícono y Salir.

INDICADOR DE ESTADO (ícono y círculo)
Verde: activo, esperando la próxima ejecución.
Azul: ejecutando en este momento.
Rojo: la última ejecución falló (revise el log).
Gris: detenido.

OPCIONES
Límite por corrida: tiempo máximo que puede tardar el .bat. Si lo supera, se termina y se registra como error.
Conservar logs: los logs más antiguos que esa cantidad de días se borran solos.
Iniciar el ciclo al abrir: empieza a ejecutar apenas se abre el programa.
Ejecutar inmediatamente: la primera corrida es al iniciar, sin esperar el intervalo.
Iniciar con Windows: se abre solo al iniciar sesión.

BOTONES
Guardar: guarda la configuración.
Iniciar / Detener: activa o cancela el ciclo (Detener también cancela la corrida en curso).
Ejecutar ahora: corre el .bat una vez, sin esperar el intervalo.

NOTAS
- Corre con la sesión del usuario: las unidades mapeadas (Z:, F:, G:) deben estar disponibles.
- Una corrida se considera correcta si el .bat termina con código 0 (el del último comando).
- Si en el log aparece "La unidad especificada no es válida", falta montar una unidad.
"@
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Acerca de dbf_sync'
    $f.ClientSize = New-Object System.Drawing.Size(580, 540)
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.TopMost = $true
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $f.Icon = $form.Icon
    $tb = New-Ctl System.Windows.Forms.TextBox 10 10 560 480
    $tb.Multiline = $true
    $tb.ReadOnly = $true
    $tb.ScrollBars = 'Vertical'
    $tb.TabStop = $false
    $tb.BackColor = [System.Drawing.Color]::White
    $tb.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $tb.Text = ($texto -replace "`r?`n", "`r`n")
    $ok = New-Ctl System.Windows.Forms.Button 460 500 110 30 'Cerrar'
    $ok.DialogResult = 'OK'
    $f.AcceptButton = $ok
    $f.CancelButton = $ok
    $f.Controls.AddRange(@($tb, $ok))
    [void]$f.ShowDialog()
    $f.Dispose()
}

# --- Eventos -----------------------------------------------------------------
$btnBat.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Seleccione el archivo .bat a ejecutar'
    $dlg.Filter = 'Archivos por lotes (*.bat;*.cmd)|*.bat;*.cmd|Todos los archivos (*.*)|*.*'
    if ($txtBat.Text -and (Test-Path -LiteralPath (Split-Path -Parent $txtBat.Text) -ErrorAction SilentlyContinue)) {
        $dlg.InitialDirectory = Split-Path -Parent $txtBat.Text
    }
    if ($dlg.ShowDialog() -eq 'OK') { $txtBat.Text = $dlg.FileName }
})

$btnLogDir.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Seleccione la carpeta donde se guardaran los logs'
    if ($txtLogDir.Text -and (Test-Path -LiteralPath $txtLogDir.Text)) { $dlg.SelectedPath = $txtLogDir.Text }
    if ($dlg.ShowDialog() -eq 'OK') { $txtLogDir.Text = $dlg.SelectedPath }
})

$btnOpenLogs.Add_Click({ Open-LogFolder })
$miLogs.Add_Click({ Open-LogFolder })
$btnAbout.Add_Click({ Show-About })
$miHelp.Add_Click({ Show-About })

$btnSave.Add_Click({ [void](Save-FromUI); Update-UI })
$btnStart.Add_Click({ if (Save-FromUI) { [void](Start-Cycle) }; Update-UI })
$btnStop.Add_Click({ Stop-Cycle; Update-UI })
$btnNow.Add_Click({ if (Save-FromUI) { Start-Run }; Update-UI })

$miOpen.Add_Click({ Show-Form })
$miStart.Add_Click({ [void](Start-Cycle); if (-not $script:Running) { Show-Form }; Update-UI })
$miStop.Add_Click({ Stop-Cycle; Update-UI })
$miNow.Add_Click({ Start-Run; Update-UI })
$miExit.Add_Click({ Exit-App })
$notify.Add_DoubleClick({ Show-Form })

$form.Add_FormClosing({
    param($s, $e)
    if ($script:Exiting -or $e.CloseReason -eq 'WindowsShutDown') { return }
    $e.Cancel = $true
    $s.Hide()
    if (-not $script:HintShown) {
        $notify.ShowBalloonTip(3000, $AppName, 'Sigue ejecutandose en segundo plano. Clic derecho en el icono para salir.', 'Info')
        $script:HintShown = $true
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try { if ($showEvent.WaitOne(0)) { Show-Form }; Update-Cycle; Update-UI }
    catch { try { Write-Log "Error interno: $($_.Exception.Message)" 'ERROR' } catch {} }
})

# --- Arranque ----------------------------------------------------------------
if ($firstRun -and $IsExe) { Set-Startup $true }
Load-UI
Clear-OldLogs
Write-Log 'Programa iniciado'
$started = $false
if ($script:Cfg.AutoStart) { $started = Start-Cycle -Silent }
Update-UI
$timer.Start()

if ($firstRun -or -not $script:Cfg.BatPath -or -not $started) { Show-Form }

try {
    $ctx = New-Object System.Windows.Forms.ApplicationContext
    [System.Windows.Forms.Application]::Run($ctx)
} finally {
    try { $notify.Visible = $false; $notify.Dispose() } catch {}
    try { $mutex.ReleaseMutex() } catch {}
}
