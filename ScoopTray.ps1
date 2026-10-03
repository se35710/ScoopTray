#Requires -Version 5.1
<#
.SYNOPSIS
    Scoop Tray — a system tray app that checks for Scoop bucket/app updates.
.DESCRIPTION
    Sits in the system tray.  Right-click for the context menu:
      • Check for Updates   – fetches remote git refs for every bucket and
                              compares installed vs available app versions.
      • Update Buckets      – runs `scoop update` (syncs Scoop core + all buckets).
      • Update All Apps     – runs `scoop update *` (updates every outdated app).
      • Open Scoop Dir      – opens the Scoop install folder in Explorer.
      • Exit

    A balloon notification is shown whenever the check finds something new.
    The tray icon badge changes colour:
        Gray   = not checked yet / up-to-date
        Yellow = buckets have new commits (no app updates evaluated yet)
        Green  = everything is up to date (after a full status check)
        Red    = one or more apps are outdated
#>

# ── logging ───────────────────────────────────────────────────────────────────
# Detects whether the process has a real console attached (i.e. was launched
# from a terminal rather than via the VBS launcher / Start-Process -WindowStyle Hidden).
# When no console is present Write-Log is a no-op, so there is zero overhead.
$script:HasConsole = $false
try {
    # [Console]::WindowWidth throws if there is no console window
    $script:HasConsole = [Console]::WindowWidth -gt 0
} catch { }

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped, colour-coded log line to the console.
        Silently does nothing when no console is attached.
    .PARAMETER Message
        The text to log.
    .PARAMETER Level
        INFO (cyan), WARN (yellow), ERROR (red), OK (green), DEBUG (gray).
        Defaults to INFO.
    #>
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','DEBUG')]
        [string]$Level = 'INFO'
    )
    if (!$script:HasConsole) { return }

    $color = switch ($Level) {
        'INFO'  { 'Cyan'    }
        'WARN'  { 'Yellow'  }
        'ERROR' { 'Red'     }
        'OK'    { 'Green'   }
        'DEBUG' { 'DarkGray'}
    }
    $ts = (Get-Date).ToString('HH:mm:ss')
    Write-Host ('[{0}] [{1,-5}] {2}' -f $ts, $Level, $Message) -ForegroundColor $color
}

# ── bootstrap ────────────────────────────────────────────────────────────────
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Resolve Scoop installation directory (honours SCOOP env var, falls back to default)
$script:ScoopDir = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
$script:ScoopApp  = Join-Path $script:ScoopDir 'apps\scoop\current'
$script:BucketsDir = Join-Path $script:ScoopDir 'buckets'
$script:AppsDir    = Join-Path $script:ScoopDir 'apps'

Write-Log "Scoop directory : $($script:ScoopDir)"
Write-Log "Scoop app path  : $($script:ScoopApp)"

if (!(Test-Path $script:ScoopApp)) {
    Write-Log "Scoop installation not found at: $($script:ScoopDir)" -Level ERROR
    [System.Windows.Forms.MessageBox]::Show(
        "Scoop installation not found at:`n$script:ScoopDir`n`nSet the SCOOP environment variable and restart.",
        'Scoop Tray', 'OK', 'Error') | Out-Null
    exit 1
}

# Dot-source the Scoop library modules we need (mirrors what scoop-status.ps1 does)
$libDir = Join-Path $script:ScoopApp 'lib'
Write-Log "Loading Scoop libs from: $libDir" -Level DEBUG
. (Join-Path $libDir 'core.ps1')
. (Join-Path $libDir 'buckets.ps1')
. (Join-Path $libDir 'json.ps1')
. (Join-Path $libDir 'manifest.ps1')
. (Join-Path $libDir 'versions.ps1')
Write-Log 'Scoop libs loaded' -Level DEBUG

# Override $scoopdir / $bucketsdir / $globaldir so Scoop lib functions resolve correctly
# Must be set AFTER dot-sourcing — core.ps1 and buckets.ps1 set these at module level.
$scoopdir   = $script:ScoopDir
$bucketsdir = $script:BucketsDir
$globaldir  = $null   # we only track per-user installs here

# ── helper: draw a coloured circle icon on-the-fly ───────────────────────────
function New-TrayIcon {
    param(
        [ValidateSet('Gray','Yellow','Green','Red')]
        [string]$Color = 'Gray'
    )
    $bmp = [System.Drawing.Bitmap]::new(16, 16)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $brushColor = switch ($Color) {
        'Gray'   { [System.Drawing.Color]::FromArgb(160,160,160) }
        'Yellow' { [System.Drawing.Color]::FromArgb(255,200,0)   }
        'Green'  { [System.Drawing.Color]::FromArgb(60,180,80)   }
        'Red'    { [System.Drawing.Color]::FromArgb(220,50,50)   }
    }
    $brush = [System.Drawing.SolidBrush]::new($brushColor)
    $pen   = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(80,80,80), 1)
    $g.FillEllipse($brush, 1, 1, 13, 13)
    $g.DrawEllipse($pen,   1, 1, 13, 13)

    # Draw a small 'S' letter
    $font  = [System.Drawing.Font]::new('Arial', 6, [System.Drawing.FontStyle]::Bold)
    $textBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
    $sf = [System.Drawing.StringFormat]::new()
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString('S', $font, $textBrush, [System.Drawing.RectangleF]::new(1,1,13,13), $sf)

    $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}

# ── state ─────────────────────────────────────────────────────────────────────
$script:OutdatedApps   = @()   # array of [pscustomobject] with .Name .Installed .Latest
$script:BucketsBehind  = @()   # bucket names that have unpulled commits
$script:LastChecked    = $null
$script:CheckRunning   = $false
$script:UpdateRunning  = $false

# ── check logic (runs in a background runspace) ───────────────────────────────
function Start-ScoopCheck {
    if ($script:CheckRunning) { return }
    $script:CheckRunning = $true
    Rebuild-ContextMenu

    $script:NotifyIcon.Icon = New-TrayIcon -Color Gray

    $scoopDir   = $script:ScoopDir
    $bucketsDir = $script:BucketsDir
    $appsDir    = $script:AppsDir
    $scoopApp   = $script:ScoopApp

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('scoopDir',   $scoopDir)
    $rs.SessionStateProxy.SetVariable('bucketsDir', $bucketsDir)
    $rs.SessionStateProxy.SetVariable('appsDir',    $appsDir)
    $rs.SessionStateProxy.SetVariable('scoopApp',   $scoopApp)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs

    [void]$ps.AddScript({
        # ── load Scoop libs ──────────────────────────────────────────────────
        $libDir    = Join-Path $scoopApp 'lib'
        $globaldir = $null
        . (Join-Path $libDir 'core.ps1')
        . (Join-Path $libDir 'buckets.ps1')
        . (Join-Path $libDir 'json.ps1')
        . (Join-Path $libDir 'manifest.ps1')
        . (Join-Path $libDir 'versions.ps1')
        # core.ps1 sets $scoopdir at module level and would overwrite anything
        # set before the dot-source, so we override it here, after loading.
        $scoopdir     = $scoopDir
        $bucketsdir   = $bucketsDir   # buckets.ps1 also sets this at module level

        $result = [pscustomobject]@{
            BucketsBehind = [System.Collections.Generic.List[string]]::new()
            OutdatedApps  = [System.Collections.Generic.List[pscustomobject]]::new()
            Errors        = [System.Collections.Generic.List[string]]::new()
            Log           = [System.Collections.Generic.List[string]]::new()
        }

        # ── check each bucket for unpulled commits ───────────────────────────
        $localBuckets = Get-LocalBucket
        $result.Log.Add(('Buckets to check: {0}' -f ($localBuckets -join ', ')))
        foreach ($bucket in $localBuckets) {
            $bucketPath = Find-BucketDirectory $bucket -Root
            if (!(Test-Path (Join-Path $bucketPath '.git'))) {
                $result.Log.Add("  [$bucket] skipped – not a git repo")
                continue
            }
            try {
                $result.Log.Add("  [$bucket] fetching origin…")
                $null = & git -C $bucketPath fetch -q origin 2>&1
                $branch  = (& git -C $bucketPath branch --show-current 2>&1) | Select-Object -First 1
                $commits = & git -C $bucketPath log "HEAD..origin/$branch" --oneline 2>&1
                if ($commits) {
                    $count = @($commits).Count
                    $result.BucketsBehind.Add($bucket)
                    $result.Log.Add("  [$bucket] BEHIND by $count commit(s)")
                } else {
                    $result.Log.Add("  [$bucket] up to date")
                }
            } catch {
                $result.Errors.Add("Bucket '$bucket': $_")
                $result.Log.Add("  [$bucket] ERROR: $_")
            }
        }

        # ── check installed apps for outdated versions ───────────────────────
        # Mirrors the logic in scoop-status.ps1
        if (Test-Path $appsDir) {
            $appDirs = @(Get-ChildItem $appsDir -Directory | Where-Object { $_.Name -ne 'scoop' })
            $result.Log.Add(('Apps to check: {0}' -f $appDirs.Count))
            foreach ($appDir in $appDirs) {
                $appName = $appDir.Name
                try {
                    $status = app_status $appName $false
                    if ($status.outdated) {
                        $result.OutdatedApps.Add([pscustomobject]@{
                            Name      = $appName
                            Installed = $status.version
                            Latest    = $status.latest_version
                        })
                        $result.Log.Add("  [$appName] OUTDATED  $($status.version) -> $($status.latest_version)")
                    } else {
                        $result.Log.Add("  [$appName] OK  $($status.version)")
                    }
                } catch {
                    $result.Errors.Add("App '$appName': $_")
                    $result.Log.Add("  [$appName] ERROR: $_")
                }
            }
        }

        return $result
    })

    $handle = $ps.BeginInvoke()

    # Poll for completion on a timer instead of blocking the UI thread.
    # Store on $script: so the GC cannot collect it before it fires.
    $script:_pollTimer          = [System.Windows.Forms.Timer]::new()
    $script:_pollTimer.Interval = 500

    # Capture locals into named script-scope vars so the closure can reach them.
    $script:_pollPs     = $ps
    $script:_pollRs     = $rs
    $script:_pollHandle = $handle

    $script:_pollTimer.Add_Tick({
        if ($script:_pollHandle.IsCompleted) {
            $script:_pollTimer.Stop()
            $script:_pollTimer.Dispose()

            try {
                $raw = $script:_pollPs.EndInvoke($script:_pollHandle)
                # EndInvoke returns a PSDataCollection; the result object is element [0]
                $checkResult = if ($raw -and $raw.Count -gt 0) { $raw[0] } else { $null }
                if ($checkResult) {
                    # Replay log lines from the runspace to the console
                    foreach ($line in $checkResult.Log) {
                        Write-Log $line -Level DEBUG
                    }
                    foreach ($err in $checkResult.Errors) {
                        Write-Log $err -Level ERROR
                    }

                    $script:BucketsBehind = @($checkResult.BucketsBehind)
                    $script:OutdatedApps  = @($checkResult.OutdatedApps)

                    Write-Log ("Check complete – {0} bucket(s) behind, {1} app(s) outdated" -f `
                        $script:BucketsBehind.Count, $script:OutdatedApps.Count) -Level $(
                            if ($script:OutdatedApps.Count -gt 0) { 'WARN' }
                            elseif ($script:BucketsBehind.Count -gt 0) { 'WARN' }
                            else { 'OK' }
                        )
                }
            } catch {
                Write-Log "Error collecting check results: $_" -Level ERROR
            }
            $script:_pollPs.Dispose()
            $script:_pollRs.Dispose()

            $script:LastChecked  = Get-Date
            $script:CheckRunning = $false

            Update-TrayState
        }
    })
    $script:_pollTimer.Start()
}

# ── update tray icon + tooltip + balloon based on current state ───────────────
function Update-TrayState {
    $outdatedCount = $script:OutdatedApps.Count
    $behindCount   = $script:BucketsBehind.Count

    if ($outdatedCount -gt 0) {
        $script:NotifyIcon.Icon = New-TrayIcon -Color Red
        $appList = ($script:OutdatedApps | ForEach-Object { "$($_.Name) $($_.Installed)→$($_.Latest)" }) -join ', '
        $tip  = "Scoop Tray – $outdatedCount app(s) outdated"
        $body = $appList
        Show-Balloon -Title $tip -Text $body -Icon Warning
    } elseif ($behindCount -gt 0) {
        $script:NotifyIcon.Icon = New-TrayIcon -Color Yellow
        $tip  = "Scoop Tray – $behindCount bucket(s) have new commits"
        $body = "Run 'Update Buckets' to pull the latest manifests."
        Show-Balloon -Title $tip -Text $body -Icon Info
    } else {
        $script:NotifyIcon.Icon = New-TrayIcon -Color Green
        $tip  = 'Scoop Tray – everything is up to date'
        Show-Balloon -Title $tip -Text 'No updates available.' -Icon Info
    }

    $checkedStr = if ($script:LastChecked) { $script:LastChecked.ToString('HH:mm') } else { 'never' }
    Set-TrayTooltip "Scoop Tray`nLast checked: $checkedStr`nOutdated apps: $outdatedCount  |  Buckets behind: $behindCount"

    Rebuild-ContextMenu
}

function Set-TrayTooltip([string]$Text) {
    # NotifyIcon tooltip is limited to 63 characters
    $script:NotifyIcon.Text = if ($Text.Length -gt 63) { $Text.Substring(0, 60) + '…' } else { $Text }
}

function Show-Balloon {
    param([string]$Title, [string]$Text,
          [System.Windows.Forms.ToolTipIcon]$Icon = 'Info')
    $script:NotifyIcon.BalloonTipTitle = $Title
    $script:NotifyIcon.BalloonTipText  = if ($Text.Length -gt 255) { $Text.Substring(0, 252) + '…' } else { $Text }
    $script:NotifyIcon.BalloonTipIcon  = $Icon
    $script:NotifyIcon.ShowBalloonTip(5000)
}

# ── run scoop in a new hidden PowerShell window, show live output ─────────────
function Invoke-ScoopCommand {
    param([string]$Arguments, [string]$Description)

    if ($script:UpdateRunning) {
        [System.Windows.Forms.MessageBox]::Show(
            'An update is already running. Please wait.',
            'Scoop Tray', 'OK', 'Information') | Out-Null
        return
    }
    $script:UpdateRunning = $true
    Rebuild-ContextMenu
    Write-Log "Launching: scoop $Arguments"

    $scoopExe  = Join-Path $script:ScoopApp 'bin\scoop.ps1'
    # Use the same PowerShell host that is currently running so the child
    # process inherits the same version (and all its built-in cmdlets).
    $psExe     = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

    $procInfo             = [System.Diagnostics.ProcessStartInfo]::new()
    $procInfo.FileName    = $psExe
    $procInfo.Arguments   = "-NoLogo -ExecutionPolicy Bypass -File `"$scoopExe`" $Arguments"
    $procInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal
    $script:_updateProc   = [System.Diagnostics.Process]::Start($procInfo)

    # Store on $script: so the GC cannot collect the timer or process before the tick fires.
    $script:_updateArgs  = $Arguments
    $script:_waitTimer   = [System.Windows.Forms.Timer]::new()
    $script:_waitTimer.Interval = 1000
    $script:_waitTimer.Add_Tick({
        if ($script:_updateProc.HasExited) {
            $script:_waitTimer.Stop()
            $script:_waitTimer.Dispose()
            $script:UpdateRunning = $false
            Write-Log ("scoop $($script:_updateArgs) exited with code $($script:_updateProc.ExitCode)") -Level $(
                if ($script:_updateProc.ExitCode -eq 0) { 'OK' } else { 'WARN' })
            # Small delay to let file system settle
            [System.Threading.Thread]::Sleep(500)
            Start-ScoopCheck
        }
    })
    $script:_waitTimer.Start()
}

# ── context menu builder ──────────────────────────────────────────────────────
function Rebuild-ContextMenu {
    $menu = [System.Windows.Forms.ContextMenuStrip]::new()

    # ── header (non-clickable status line) ───────────────────────────────────
    $header           = [System.Windows.Forms.ToolStripMenuItem]::new()
    $header.Enabled   = $false
    $checkedStr = if ($script:LastChecked) { $script:LastChecked.ToString('HH:mm:ss') } else { 'not yet' }
    $header.Text      = "Last checked: $checkedStr"
    [void]$menu.Items.Add($header)
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

    # ── outdated apps submenu ─────────────────────────────────────────────────
    if ($script:OutdatedApps.Count -gt 0) {
        $appsMenu      = [System.Windows.Forms.ToolStripMenuItem]::new()
        $appsMenu.Text = "⚠  $($script:OutdatedApps.Count) outdated app(s)"
        foreach ($a in $script:OutdatedApps) {
            $item      = [System.Windows.Forms.ToolStripMenuItem]::new()
            $item.Text = "   $($a.Name)  $($a.Installed) → $($a.Latest)"
            [void]$appsMenu.DropDownItems.Add($item)
        }
        [void]$menu.Items.Add($appsMenu)
    }

    # ── buckets behind submenu ────────────────────────────────────────────────
    if ($script:BucketsBehind.Count -gt 0) {
        $buckMenu      = [System.Windows.Forms.ToolStripMenuItem]::new()
        $buckMenu.Text = "↓  $($script:BucketsBehind.Count) bucket(s) behind"
        foreach ($b in $script:BucketsBehind) {
            $item      = [System.Windows.Forms.ToolStripMenuItem]::new()
            $item.Text = "   $b"
            [void]$buckMenu.DropDownItems.Add($item)
        }
        [void]$menu.Items.Add($buckMenu)
    }

    if ($script:OutdatedApps.Count -gt 0 -or $script:BucketsBehind.Count -gt 0) {
        [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    }

    # ── actions ───────────────────────────────────────────────────────────────
    $busy = $script:CheckRunning -or $script:UpdateRunning

    $miCheck = [System.Windows.Forms.ToolStripMenuItem]::new()
    $miCheck.Text    = if ($script:CheckRunning) { 'Checking…' } else { 'Check for Updates' }
    $miCheck.Enabled = !$busy
    $miCheck.Add_Click({ Start-ScoopCheck })
    [void]$menu.Items.Add($miCheck)

    $miUpdateBuckets = [System.Windows.Forms.ToolStripMenuItem]::new()
    $miUpdateBuckets.Text    = 'Update Buckets  (scoop update)'
    $miUpdateBuckets.Enabled = !$busy
    $miUpdateBuckets.Add_Click({ Invoke-ScoopCommand -Arguments 'update' -Description 'Updating buckets' })
    [void]$menu.Items.Add($miUpdateBuckets)

    $miUpdateAll = [System.Windows.Forms.ToolStripMenuItem]::new()
    $miUpdateAll.Text    = 'Update All Apps  (scoop update *)'
    $miUpdateAll.Enabled = !$busy
    $miUpdateAll.Add_Click({ Invoke-ScoopCommand -Arguments 'update *' -Description 'Updating all apps' })
    [void]$menu.Items.Add($miUpdateAll)

    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

    # ── auto-check interval submenu ───────────────────────────────────────────
    $miInterval      = [System.Windows.Forms.ToolStripMenuItem]::new()
    $miInterval.Text = 'Auto-check interval'

    $intervals = @(
        @{ Label = '15 minutes'; Minutes = 15  }
        @{ Label = '30 minutes'; Minutes = 30  }
        @{ Label = '1 hour';     Minutes = 60  }
        @{ Label = '3 hours';    Minutes = 180 }
        @{ Label = '6 hours';    Minutes = 360 }
        @{ Label = 'Disabled';   Minutes = 0   }
    )
    foreach ($iv in $intervals) {
        $ivItem         = [System.Windows.Forms.ToolStripMenuItem]::new()
        $ivItem.Text    = $iv.Label
        $ivItem.Checked = ($script:AutoCheckMinutes -eq $iv.Minutes)
        $minutes        = $iv.Minutes   # capture for closure
        $ivItem.Add_Click({
            $script:AutoCheckMinutes = $minutes
            if ($minutes -gt 0) {
                $script:AutoCheckTimer.Interval = $minutes * 60 * 1000
                $script:AutoCheckTimer.Start()
                Write-Log "Auto-check interval set to $minutes minute(s)"
            } else {
                $script:AutoCheckTimer.Stop()
                Write-Log 'Auto-check disabled'
            }
            Rebuild-ContextMenu
        })
        [void]$miInterval.DropDownItems.Add($ivItem)
    }
    [void]$menu.Items.Add($miInterval)

    # ── utilities ─────────────────────────────────────────────────────────────
    $miOpen = [System.Windows.Forms.ToolStripMenuItem]::new()
    $miOpen.Text = 'Open Scoop Directory'
    $miOpen.Add_Click({ Start-Process 'explorer.exe' -ArgumentList $script:ScoopDir })
    [void]$menu.Items.Add($miOpen)

    $miLog = [System.Windows.Forms.ToolStripMenuItem]::new()
    $miLog.Text = 'View Installed Apps'
    $miLog.Add_Click({ Show-InstalledApps })
    [void]$menu.Items.Add($miLog)

    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

    $miExit = [System.Windows.Forms.ToolStripMenuItem]::new()
    $miExit.Text = 'Exit'
    $miExit.Add_Click({
        Write-Log 'Exiting Scoop Tray'
        $script:AutoCheckTimer.Stop()
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
        [System.Windows.Forms.Application]::Exit()
    })
    [void]$menu.Items.Add($miExit)

    $script:NotifyIcon.ContextMenuStrip = $menu
}

# ── installed apps info dialog ────────────────────────────────────────────────
function Show-InstalledApps {
    $form                 = [System.Windows.Forms.Form]::new()
    $form.Text            = 'Scoop – Installed Apps'
    $form.Size            = [System.Drawing.Size]::new(560, 420)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false

    $lv                   = [System.Windows.Forms.ListView]::new()
    $lv.Dock              = 'Fill'
    $lv.View              = 'Details'
    $lv.FullRowSelect     = $true
    $lv.GridLines         = $true
    $lv.Columns.Add('App',              160) | Out-Null
    $lv.Columns.Add('Installed',        100) | Out-Null
    $lv.Columns.Add('Latest',           100) | Out-Null
    $lv.Columns.Add('Bucket',           100) | Out-Null
    $lv.Columns.Add('Status',           80)  | Out-Null

    if (Test-Path $script:AppsDir) {
        Get-ChildItem $script:AppsDir -Directory | Where-Object { $_.Name -ne 'scoop' } | ForEach-Object {
            $appName = $_.Name
            try {
                $status  = app_status $appName $false
                $row     = [System.Windows.Forms.ListViewItem]::new($appName)
                [void]$row.SubItems.Add($status.version)
                [void]$row.SubItems.Add($(if ($status.latest_version) { $status.latest_version } else { $status.version }))
                [void]$row.SubItems.Add($(if ($status.bucket) { $status.bucket } else { '–' }))
                $statusText = if ($status.outdated) { 'Outdated' } elseif ($status.hold) { 'Held' } else { 'OK' }
                [void]$row.SubItems.Add($statusText)
                if ($status.outdated) { $row.ForeColor = [System.Drawing.Color]::DarkRed }
                [void]$lv.Items.Add($row)
            } catch {
                $row = [System.Windows.Forms.ListViewItem]::new($appName)
                [void]$row.SubItems.Add('?')
                [void]$row.SubItems.Add('?')
                [void]$row.SubItems.Add('?')
                [void]$row.SubItems.Add('Error')
                [void]$lv.Items.Add($row)
            }
        }
    }

    $form.Controls.Add($lv)
    [void]$form.ShowDialog()
    $form.Dispose()
}

# ── auto-check timer ──────────────────────────────────────────────────────────
$script:AutoCheckMinutes = 60   # default: every hour
$script:AutoCheckTimer   = [System.Windows.Forms.Timer]::new()
$script:AutoCheckTimer.Interval = $script:AutoCheckMinutes * 60 * 1000
$script:AutoCheckTimer.Add_Tick({ Start-ScoopCheck })
$script:AutoCheckTimer.Start()
Write-Log "Auto-check timer started (interval: $($script:AutoCheckMinutes) min)"

# ── create the NotifyIcon ─────────────────────────────────────────────────────
$script:NotifyIcon         = [System.Windows.Forms.NotifyIcon]::new()
$script:NotifyIcon.Icon    = New-TrayIcon -Color Gray
$script:NotifyIcon.Visible = $true
Set-TrayTooltip 'Scoop Tray'
Write-Log 'Tray icon created – Scoop Tray is running'

# Double-click → check now
$script:NotifyIcon.Add_DoubleClick({ Start-ScoopCheck })

# Build the initial menu
Rebuild-ContextMenu

# Kick off an immediate check on startup
Start-ScoopCheck

# ── Ctrl+C / SIGINT handler — clean up the tray icon before exiting ───────────
if ($script:HasConsole) {
    Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress `
        -Action {
            $EventArgs.Cancel = $true   # don't kill the process immediately
            Write-Log 'Ctrl+C received – shutting down cleanly' -Level WARN
            $script:AutoCheckTimer.Stop()
            $script:NotifyIcon.Visible = $false
            $script:NotifyIcon.Dispose()
            [System.Windows.Forms.Application]::Exit()
        } | Out-Null
}

# ── message pump ──────────────────────────────────────────────────────────────
Write-Log 'Entering message pump (UI thread)' -Level DEBUG
try {
    [System.Windows.Forms.Application]::Run()
} finally {
    # Guarantee the icon is removed even if the pump exits unexpectedly
    $script:AutoCheckTimer.Stop()
    if ($script:NotifyIcon.Visible) {
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
    }
    Write-Log 'Message pump exited' -Level DEBUG
}
