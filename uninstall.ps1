# KeplerCrew client uninstaller.
# Usage: powershell -ExecutionPolicy Bypass -Command "irm https://get.keplercrew.com/uninstall.ps1 | iex"
# Removes the application, frees the license seat, and de-registers the kepler command.
# Env:
#   KEPLER_INSTALL_DIR   install directory to remove (default: %LOCALAPPDATA%\Programs\KeplerCrew)
#   KEPLER_PURGE         set to 1 to ALSO delete your local data (projects, cycles, logs)
#   KEPLER_KEEP_LICENSE  set to 1 to keep the seat activated (reinstalling on this same machine)
#   KEPLER_YES           set to 1 to skip the confirmation prompt (unattended)
# Author: aichargelabs.

# Runtime PS version check (no #Requires to avoid breaking irm|iex on some hosts)
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host 'PowerShell 5.0 or later is required. You are running version ' $PSVersionTable.PSVersion
    return
}

function Uninstall-KeplerCrew {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    try {
        # 0. Resolve the install directory and the data directory. The data dir is
        #    APEX_HOME as set by the bundled run.ps1 -- never assumed to be inside
        #    the install dir, because it is not.
        $installDir = $env:KEPLER_INSTALL_DIR
        if ([string]::IsNullOrWhiteSpace($installDir)) {
            $installDir = Join-Path $env:LOCALAPPDATA 'Programs\KeplerCrew'
        }
        $dataDir = $env:APEX_HOME
        if ([string]::IsNullOrWhiteSpace($dataDir)) {
            $dataDir = Join-Path $env:USERPROFILE '.kepler-trial'
        }

        if (-not (Test-Path -LiteralPath $installDir)) {
            Write-Host ('No KeplerCrew install found at ' + $installDir + ' - nothing to uninstall.')
            if (Test-Path -LiteralPath $dataDir) {
                Write-Host ('Your data is still at ' + $dataDir + '. Remove it with:')
                Write-Host ('  Remove-Item -Recurse -Force "' + $dataDir + '"')
            }
            return
        }

        $purge = ($env:KEPLER_PURGE -eq '1')

        # 1. Confirm. This deletes software and (optionally) work, so an accidental
        #    paste must not be enough. Non-interactive hosts must opt in explicitly.
        if ($env:KEPLER_YES -ne '1') {
            Write-Host ''
            Write-Host 'This will uninstall KeplerCrew:'
            Write-Host ('  - stop the app and remove ' + $installDir)
            Write-Host '  - free your license seat so the key can be used on another machine'
            Write-Host '  - remove the kepler command from your PATH'
            if ($purge) {
                Write-Host ('  - DELETE your data: ' + $dataDir + ' (projects, cycles, logs)')
            }
            else {
                Write-Host ('  - KEEP your data: ' + $dataDir)
            }
            Write-Host ''
            if ([Console]::IsInputRedirected) {
                Write-Host 'Running non-interactively. Re-run with KEPLER_YES=1 to confirm:'
                Write-Host '  powershell -ExecutionPolicy Bypass -Command "$env:KEPLER_YES=1; irm https://get.keplercrew.com/uninstall.ps1 | iex"'
                return
            }
            $answer = Read-Host 'Type yes to continue'
            if ($answer.Trim().ToLower() -ne 'yes') {
                Write-Host 'Cancelled - nothing was changed.'
                return
            }
        }

        # 2. Stop anything running FROM THIS INSTALL DIR. Match on the executable
        #    path so a second install (or an unrelated process) is never touched.
        $prefix = $installDir.TrimEnd('\') + '\'
        $running = Get-Process -Name 'kepler-backend', 'kepler-engine', 'kepler' -ErrorAction SilentlyContinue |
            Where-Object {
                $pathMatch = $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
                $moduleMatch = $false
                try { $moduleMatch = $_.MainModule.FileName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } catch { }
                $pathMatch -or $moduleMatch
            }
        if ($running) {
            Write-Host 'Stopping KeplerCrew...'
            $running | Stop-Process -Force
            $running | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }

        # 3. Free the license seat BEFORE deleting anything -- the key lives in the
        #    install dir and the activated machine id in the data dir, so once either
        #    is gone the seat can only be released by support.
        if ($env:KEPLER_KEEP_LICENSE -eq '1') {
            Write-Host 'Keeping the license seat activated (KEPLER_KEEP_LICENSE=1).'
        }
        else {
            $engine = Join-Path $installDir 'engine\kepler-engine.exe'
            $licenseFile = Join-Path $installDir 'licenses\customer.key'
            if ((Test-Path -LiteralPath $engine) -and (Test-Path -LiteralPath $licenseFile)) {
                Write-Host 'Freeing the license seat...'
                $previousHome = $env:APEX_HOME
                $previousKey = $env:KEPLER_LICENSE_KEY
                try {
                    $env:APEX_HOME = $dataDir
                    $env:KEPLER_LICENSE_KEY = ([string](Get-Content -LiteralPath $licenseFile -Raw)).Trim()
                    & $engine license deactivate
                    if ($LASTEXITCODE -ne 0) { throw ('the engine exited with code ' + $LASTEXITCODE) }
                }
                catch {
                    # Never fatal: an offline or air-gapped machine must still be able
                    # to uninstall. Say plainly that the seat is still held.
                    Write-Host ''
                    Write-Host ('Could not free the license seat: ' + $_.Exception.Message)
                    Write-Host 'Your key is still activated on this machine. Email support@aichargelabs.com'
                    Write-Host 'to release it, or the next install with this key may be refused.'
                    Write-Host ''
                }
                finally {
                    $env:APEX_HOME = $previousHome
                    $env:KEPLER_LICENSE_KEY = $previousKey
                }
            }
            else {
                Write-Host 'No license key stored here - skipping seat release.'
            }
        }

        # 4. De-register the kepler command (mirror of the installer's PATH block).
        try {
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            if ($null -ne $userPath -and $userPath -ne '') {
                $kept = @()
                $removed = $false
                foreach ($entry in $userPath.Split(';')) {
                    if ($entry.Trim().TrimEnd('\') -eq $installDir.TrimEnd('\')) { $removed = $true; continue }
                    if ($entry -ne '') { $kept += $entry }
                }
                if ($removed) {
                    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
                    Write-Host 'The kepler command was removed from your PATH.'
                }
            }
        }
        catch {
            Write-Host ('Could not update PATH: ' + $_.Exception.Message)
        }

        # 5. Remove the application. Retry briefly: a just-stopped process can still
        #    hold a handle for a moment, and the window hosting run.ps1 may own the cwd.
        $deleted = $false
        for ($i = 0; $i -lt 5; $i++) {
            try {
                Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction Stop
                $deleted = $true
                break
            }
            catch {
                Start-Sleep -Seconds 1
            }
        }
        if (-not $deleted) {
            Write-Host ''
            Write-Host ('Could not remove ' + $installDir + ' - a file is still in use.')
            Write-Host 'Close any open KeplerCrew window and run:'
            Write-Host ('  Remove-Item -Recurse -Force "' + $installDir + '"')
            Write-Host ''
        }
        else {
            Write-Host ('Removed ' + $installDir)
        }

        # Clean up the update leftovers the installer may have staged next door
        # (install.ps1 stages at "<dir>.new-<pid>" and swaps via "<dir>.old" /
        # "<parent>\keplercrew-old-temp").
        $installParent = Split-Path $installDir -Parent
        foreach ($leftover in @(($installDir + '.old'), (Join-Path $installParent 'keplercrew-old-temp'))) {
            if (Test-Path -LiteralPath $leftover) {
                Remove-Item -LiteralPath $leftover -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Get-ChildItem -LiteralPath $installParent -Directory -Filter ((Split-Path $installDir -Leaf) + '.new-*') -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

        # 6. Data: deleted only on an explicit opt-in.
        if (Test-Path -LiteralPath $dataDir) {
            if ($purge) {
                try {
                    Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction Stop
                    Write-Host ('Removed your data: ' + $dataDir)
                }
                catch {
                    Write-Host ('Could not remove ' + $dataDir + ': ' + $_.Exception.Message)
                }
            }
            else {
                Write-Host ''
                Write-Host ('Your projects and history were kept at ' + $dataDir)
                Write-Host 'Reinstalling picks them up again. To delete them:'
                Write-Host ('  Remove-Item -Recurse -Force "' + $dataDir + '"')
            }
        }

        Write-Host ''
        Write-Host 'KeplerCrew uninstalled.'
        Write-Host 'Reinstall any time:'
        Write-Host '  powershell -ExecutionPolicy Bypass -Command "irm https://get.keplercrew.com/install.ps1 | iex"'
    }
    catch {
        # Error path safe under iex: do NOT exit (closes customer's console)
        $host.UI.WriteErrorLine('')
        $host.UI.WriteErrorLine('=== KeplerCrew Uninstall Failed ===')
        $host.UI.WriteErrorLine('')
        $host.UI.WriteErrorLine($_.Exception.Message)
        $host.UI.WriteErrorLine('')
        $host.UI.WriteErrorLine('Please contact support@aichargelabs.com')
        $host.UI.WriteErrorLine('')
        return
    }
}

Uninstall-KeplerCrew
