# =======================
# Relaunch as Administrator (window will NOT close)
# =======================

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {

    $scriptPath = $PSCommandPath
    $scriptDir  = Split-Path -Parent $scriptPath

    Write-Host "[INFO] Restarting as Administrator..."

    $command = @"
Set-Location -LiteralPath '$scriptDir'
& '$scriptPath'
"@

    Start-Process powershell.exe `
        -Verb RunAs `
	-WindowStyle Hidden `
        -ArgumentList "-NoExit -NoProfile -ExecutionPolicy Bypass -Command $command"

    exit
}

# =========================================================
# VeraCrypt Portable USB Auto Mount / Auto Dismount
# =========================================================

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing

# ---------------- CONFIG ----------------
$containerName = "secrets.hc"
$mountLetter   = "N:"
$vcSubFolder   = "VeraCrypt\VeraCrypt-x64.exe"
$vcSys32       = "VeraCrypt\veracrypt.sys"
$vcSys64       = "VeraCrypt\veracrypt-x64.sys"
# ----------------------------------------

$usbDrive = $PSScriptRoot.Substring(0,2)
$container = Join-Path $PSScriptRoot $containerName

Write-Host "$(Get-Date -Format 'HH:mm:ss') [INFO] Started"
Write-Host "$(Get-Date -Format 'HH:mm:ss') [INFO] USB drive: $usbDrive"

# ---------- Prepare local VeraCrypt ----------
$tempDir = Join-Path $env:TEMP "VeraCryptPortable"
$localVc = Join-Path $tempDir "VeraCrypt-x64.exe"
$driveRoot = $PSScriptRoot.Substring(0,3)
$srcVc = Join-Path $driveRoot $vcSubFolder
$srcSys32 = Join-Path $driveRoot $vcSys32
$srcSys64 = Join-Path $driveRoot $vcSys64

$dstSys32 = Join-Path $tempDir "veracrypt.sys"
$dstSys64 = Join-Path $tempDir "veracrypt-x64.sys"

if (!(Test-Path $srcVc)) {
    Write-Host "[ERROR] VeraCrypt not found on USB"
    exit
}

if (!(Test-Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir | Out-Null
}

# Kill any running VeraCrypt from previous run
Get-Process VeraCrypt* -ErrorAction SilentlyContinue | Stop-Process -Force

# Copy executable safely
Copy-Item $srcVc $localVc -Force
Write-Host "$(Get-Date -Format 'HH:mm:ss') [INFO] VeraCrypt copied locally"

# Copy drivers
if (Test-Path $srcSys32) {
    Copy-Item $srcSys32 $dstSys32 -Force
    Write-Host "$(Get-Date -Format 'HH:mm:ss') [INFO] veracrypt.sys copied"
}

if (Test-Path $srcSys64) {
    Copy-Item $srcSys64 $dstSys64 -Force
    Write-Host "$(Get-Date -Format 'HH:mm:ss') [INFO] veracrypt-x64.sys copied"
}

# ---------- Цвета тёмной темы ----------
$Colors = @{
    WindowBackground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(32,32,32))
    WindowBorder = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(64,64,64))
    TextForeground = [System.Windows.Media.Brushes]::White
    Placeholder = [System.Windows.Media.Brushes]::Gray
    ButtonBackground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(10,132,255))
    ButtonHover = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0,90,180))
    ButtonText = [System.Windows.Media.Brushes]::White
}

# =======================
# GLOBAL STATE
# =======================
$script:UsbRemoved = $false
$script:PwdForm    = $null
$script:LoadForm   = $null
$script:SpinTimer  = $null
$script:MountJob   = $null

# =======================
# USB checking function
# =======================
function Get-UsbDrives {
    Get-CimInstance Win32_LogicalDisk |
    Where-Object { $_.DriveType -eq 2 } |
    Select-Object -ExpandProperty DeviceID
}

function Check-Usb {
    return $usbDrive -in (Get-UsbDrives)
}

# =======================
# Abort-All function
# =======================
function Abort-All {
    if ($script:UsbRemoved) { return }
    $script:UsbRemoved = $true
    Write-Host "$(Get-Date -Format 'HH:mm:ss') [WARN] USB removed → aborting"

    try { $script:SpinTimer.Stop() } catch {}
    try { $script:LoadForm.Close() } catch {}
    try { $script:PwdForm.Close() } catch {}

    if ($script:MountJob) {
        try { Stop-Job $script:MountJob -Force } catch {}
        try { Remove-Job $script:MountJob -Force } catch {}
    }

    Get-Process VeraCrypt* -ErrorAction SilentlyContinue | Stop-Process -Force
    exit
}

# =======================
# Mount container with retry
# =======================
$success = $false

do {
    # ---------- Password form ----------
    $form = New-Object System.Windows.Window
    $form.Width = 400
    $form.Height = 180
    $form.WindowStartupLocation = "CenterScreen"
    $form.ResizeMode = "NoResize"
    $form.WindowStyle = "None"
    $form.AllowsTransparency = $true
    $form.Background = [System.Windows.Media.Brushes]::Transparent
    $form.Topmost = $true
    $script:PwdForm = $form

    $shadow = New-Object System.Windows.Controls.Border
    $shadow.CornerRadius = 12
    $shadow.Background = $Colors.WindowBackground
    $shadow.BorderBrush = $Colors.WindowBorder
    $shadow.BorderThickness = 1
    $shadow.Padding = 20

    $stack = New-Object System.Windows.Controls.StackPanel

    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = "Enter VeraCrypt password"
    $label.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI Variable")
    $label.FontSize = 14
    $label.Foreground = $Colors.TextForeground
    $label.Margin = "0,0,0,10"
    $stack.Children.Add($label) | Out-Null

    $pwdBox = New-Object System.Windows.Controls.PasswordBox
    $pwdBox.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI Variable")
    $pwdBox.FontSize = 16
    $pwdBox.Height = 30
    $pwdBox.VerticalContentAlignment = 'Center'
    $pwdBox.Background = $Colors.WindowBackground
    $pwdBox.BorderBrush = $Colors.WindowBorder
    $pwdBox.BorderThickness = 1
    $pwdBox.Password = "Password"
    $pwdBox.Foreground = $Colors.Placeholder

    $pwdBox.Add_GotFocus({
        if ($pwdBox.Password -eq "Password") {
            $pwdBox.Password = ""
            $pwdBox.Foreground = $Colors.TextForeground
        }
    })
    $pwdBox.Add_LostFocus({
        if ([string]::IsNullOrWhiteSpace($pwdBox.Password)) {
            $pwdBox.Password = "Password"
            $pwdBox.Foreground = $Colors.Placeholder
        }
    })
    $pwdBox.Add_KeyDown({
        param($sender,$e)
        if ($e.Key -eq 'Enter' -and $pwdBox.Password -ne "Password") {
            $script:password = $pwdBox.Password
            $form.Close()
        }
    })
    $stack.Children.Add($pwdBox) | Out-Null

    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = "Mount"
    $btn.Width = 120
    $btn.Height = 35
    $btn.Margin = "0,10,0,0"
    $btn.HorizontalAlignment = "Center"
    $btn.FontFamily = New-Object System.Windows.Media.FontFamily("Segoe UI Variable")
    $btn.FontWeight = "Bold"
    $btn.Background = $Colors.ButtonBackground
    $btn.Foreground = $Colors.ButtonText

    $btn.Add_MouseEnter({ $btn.Foreground = $Colors.ButtonHover })
    $btn.Add_MouseLeave({ $btn.Foreground = $Colors.TextForeground })
    $btn.Add_Click({
        if ($pwdBox.Password -ne "Password") {
            $script:password = $pwdBox.Password
            $form.Close()
        }
    })
    $stack.Children.Add($btn) | Out-Null

    $shadow.Child = $stack
    $form.Content = $shadow
    $pwdBox.Focus()

    # ---------- Timer USB check during password ----------
    $timerPwd = New-Object System.Windows.Threading.DispatcherTimer
    $timerPwd.Interval = [TimeSpan]::FromMilliseconds(500)
    $timerPwd.Add_Tick({ if (-not (Check-Usb)) { Abort-All } })
    $timerPwd.Start()

    $form.ShowDialog() | Out-Null
    $timerPwd.Stop()

    if (-not $script:password) { exit }
    if (-not (Check-Usb)) { Abort-All }

    # ---------- Loader form ----------
    $loadForm = New-Object System.Windows.Window
    $loadForm.Width = 150
    $loadForm.Height = 150
    $loadForm.WindowStartupLocation = "CenterScreen"
    $loadForm.ResizeMode = "NoResize"
    $loadForm.WindowStyle = "None"
    $loadForm.AllowsTransparency = $true
    $loadForm.Background = [System.Windows.Media.Brushes]::Transparent
    $loadForm.Topmost = $true
    $script:LoadForm = $loadForm

    $loadBorder = New-Object System.Windows.Controls.Border
    $loadBorder.CornerRadius = 12
    $loadBorder.Background = $Colors.WindowBackground
    $loadBorder.BorderBrush = $Colors.WindowBorder
    $loadBorder.BorderThickness = 1
    $loadBorder.Padding = 20

    $canvas = New-Object System.Windows.Controls.Canvas
    $canvas.Width = 100
    $canvas.Height = 100
    $ellipse = New-Object System.Windows.Shapes.Ellipse
    $ellipse.Width = 60
    $ellipse.Height = 60
    $ellipse.Stroke = $Colors.ButtonBackground
    $ellipse.StrokeThickness = 6
    $ellipse.StrokeDashArray = New-Object System.Windows.Media.DoubleCollection
    $ellipse.StrokeDashArray.Add(2)
    $ellipse.StrokeDashArray.Add(2)
    $ellipse.RenderTransformOrigin = [System.Windows.Point]::new(0.5,0.5)
    $rotateTransform = New-Object System.Windows.Media.RotateTransform
    $ellipse.RenderTransform = $rotateTransform
    [System.Windows.Controls.Canvas]::SetLeft($ellipse,20)
    [System.Windows.Controls.Canvas]::SetTop($ellipse,20)
    $canvas.Children.Add($ellipse) | Out-Null
    $loadBorder.Child = $canvas
    $loadForm.Content = $loadBorder

    $timerSpin = New-Object System.Windows.Threading.DispatcherTimer
    $timerSpin.Interval = [TimeSpan]::FromMilliseconds(15)
    $timerSpin.Add_Tick({
        $rotateTransform.Angle += 4
        if ($rotateTransform.Angle -ge 360) { $rotateTransform.Angle = 0 }
        if (-not (Check-Usb)) { Abort-All }
    })
    $timerSpin.Start()
    $script:SpinTimer = $timerSpin

    $loadForm.Show()

    # ---------- Mount job ----------
    $script:MountJob = Start-Job -ScriptBlock {
        param($localVc, $container, $mountLetter, $password)
	$args = "/v `"$container`" /l $mountLetter /p `"$password`" /cache no /q /s"
        (Start-Process $localVc $args -Wait -PassThru).ExitCode
    } -ArgumentList $localVc, $container, $mountLetter, $script:password

    # ---------- Wait job ----------
    while ($true) {
        Start-Sleep -Milliseconds 30
        if (-not (Check-Usb)) { Abort-All }
        if ($script:MountJob.State -in 'Completed','Failed') { break }
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action]{}, 'Background')
    }

    $timerSpin.Stop()
    $loadForm.Close()

    $exitCode = Receive-Job $script:MountJob
    Remove-Job $script:MountJob

    if ($exitCode -eq 0) {
        Write-Host "$(Get-Date -Format 'HH:mm:ss') [INFO] Volume mounted to $mountLetter"
        $success = $true
	Start-Process explorer.exe $mountLetter
    } else {
        Write-Host "$(Get-Date -Format 'HH:mm:ss') [ERROR] Mount failed. Please try again."
    }

} while (-not $success)

# ---------- USB monitoring after mount ----------
while ($true) {
    Start-Sleep 2
    if (-not (Check-Usb)) {
        Write-Host "$(Get-Date -Format 'HH:mm:ss') [INFO] USB removed → dismounting"
	Start-Process $localVc "/dismount $mountLetter /force /secureDesktop y /cache no /wipecache /nowaitdlg y /quit" -Wait
        Write-Host "$(Get-Date -Format 'HH:mm:ss') [INFO] Dismounted"
        try {
            Remove-Item -Path $localVc -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $dstSys32 -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $dstSys64 -Force -ErrorAction SilentlyContinue
            Write-Host "$(Get-Date -Format 'HH:mm:ss') [INFO] Temporary VeraCrypt files deleted"
        } catch {
            Write-Host "$(Get-Date -Format 'HH:mm:ss') [ERROR] Failed to delete temp files: $_"
        }
        break
    }
}
