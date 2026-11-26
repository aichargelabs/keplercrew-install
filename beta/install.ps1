# KeplerCrew client installer and updater (beta channel).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm https://get.keplercrew.com/beta/install.ps1)"
# Running it again updates an existing install to the latest published stable or beta release.
# Env:
#   KEPLER_LICENSE_KEY  license key (existing install's stored key is reused; prompted otherwise)
#   KEPLER_VERSION      optional version such as 1.0.0-beta.1 (default: latest)
#   KEPLER_CHANNEL      beta (default: stable and beta releases) or stable (stable only)
#   KEPLER_DRY_RUN      set to 1 to resolve and print the release without downloading
#   KEPLER_ACCEPT_STABLE set to 1 to install stable without asking when the license has no beta access
#   KEPLER_INSTALL_DIR  optional install directory (default: %LOCALAPPDATA%\Programs\KeplerCrew)
#   KEPLER_NO_LAUNCH    set to 1 to skip launching after install
#   KEPLER_FORCE        set to 1 to reinstall even when already on the resolved version
# Security: SAC/Code Integrity state is read only; no firewall or Windows
#   security policy is changed. SAC-enabled machines install signed bundles only.
# Author: aichargelabs.

param([switch]$Force)

function Test-KeplerInstallerGuard {
    param([switch]$Force)
    if ($env:KEPLER_INSIDE_RUN -eq '1') {
        throw 'This is running inside a Kepler task. Updating Kepler from a task would stop every run. Run the installer from your own terminal.'
    }
    $dataDir = $env:APEX_HOME
    if ([string]::IsNullOrWhiteSpace($dataDir)) { $dataDir = Join-Path $env:USERPROFILE '.kepler-trial' }
    $liveDir = Join-Path $dataDir 'state/live'
    $busy = @()
    try {
        foreach ($file in (Get-ChildItem -LiteralPath $liveDir -Filter '*.json' -File -ErrorAction Stop)) {
            try {
                $record = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if (((Get-Date) - $file.LastWriteTimeUtc).TotalSeconds -gt 86400) { continue }
                $status = [string]$record.apex_status
                $pidValue = 0
                if ($null -ne $record.pid) { $pidValue = [int]$record.pid }
                if (@('completed','failed','killed','done','idle','error','halted') -notcontains $status.ToLowerInvariant() -and $pidValue -gt 0) {
                    try { $process = Get-Process -Id $pidValue -ErrorAction Stop; if ($null -ne $record.pid_create_time -and [math]::Abs(($process.StartTime.ToUniversalTime() - [DateTimeOffset]::FromUnixTimeSeconds([long]$record.pid_create_time).UtcDateTime).TotalSeconds) -gt 2) { continue }; $busy += [string]$file.BaseName
                    if (-not [string]::IsNullOrWhiteSpace([string]$record.title)) { $busy[-1] = [string]$record.title } elseif (-not [string]::IsNullOrWhiteSpace([string]$record.cycle_id)) { $busy[-1] = [string]$record.cycle_id } } catch { }
                }
            } catch { }
        }
    } catch { }
    if ($busy.Count -gt 0 -and -not $Force -and $env:KEPLER_FORCE_RUNNING -ne '1') {
        throw (('Kepler has live runs; let them finish first, or override with -Force or KEPLER_FORCE_RUNNING=1:') + [Environment]::NewLine + ($busy -join [Environment]::NewLine))
    }
}

try {
    Test-KeplerInstallerGuard -Force:$Force
}
catch {
    # Refused. Under iex the calling shell has to stay open with the message on
    # screen, so there is no exit here. A script started with -File runs in its
    # own process and sets the exit code there.
    $host.UI.WriteErrorLine($_.Exception.Message)
    $global:LASTEXITCODE = 3
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { exit 3 }
    return
}

Write-Host 'KeplerCrew installer (beta channel)'
if ($env:KEPLER_CHANNEL -ne 'stable') {
    Write-Host 'To return to stable, run:'
    Write-Host 'powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:KEPLER_CHANNEL=''stable''; $env:KEPLER_FORCE=1; iex (irm https://get.keplercrew.com/beta/install.ps1)"'
}

# Runtime PS version check (no #Requires to avoid breaking irm|iex on some hosts)
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host 'PowerShell 5.0 or later is required. You are running version ' $PSVersionTable.PSVersion
    Write-Host 'Please upgrade: https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows'
    return
}

function Get-KeplerSmartAppControlState {
    # Read only. Turning SAC off is one-way without resetting Windows, so this
    # installer must never write VerifiedAndReputablePolicyState.
    try {
        $value = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'VerifiedAndReputablePolicyState' -ErrorAction Stop).VerifiedAndReputablePolicyState
    }
    catch { return $null }
    switch ([int]$value) {
        0 { return 'Off' }
        1 { return 'On (enforce)' }
        2 { return 'On (evaluation)' }
        default { return ('Unknown state ' + $value) }
    }
}

function Get-KeplerCodeIntegrityBlocks {
    param([datetime]$StartedAt)
    # Events 3033/3077 identify Code Integrity/SAC refusal, not a firewall error.
    # Scope them to this launch so an older unrelated Kepler event cannot be
    # misreported as the cause of today's startup failure.
    try {
        return @(Get-WinEvent -FilterHashtable @{
                LogName = 'Microsoft-Windows-CodeIntegrity/Operational'
                Id = 3033, 3077
                StartTime = $StartedAt.AddSeconds(-2)
            } -ErrorAction Stop | Where-Object { $_.Message -match 'kepler' })
    }
    catch { return $null }
}

function Test-KeplerPathWritable {
    param([string]$Path)
    $ErrorActionPreference = 'Stop'
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        $probe = Join-Path $Path ('kepler-write-probe-' + $PID + '.tmp')
        Set-Content -LiteralPath $probe -Value 'probe' -Encoding ascii -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

function Get-KeplerWriteAccessAction {
    param(
        [bool]$Writable,
        [bool]$CustomInstallDir,
        [bool]$AlreadyElevated,
        [bool]$Administrator,
        [bool]$HasScriptPath
    )
    if ($Writable) { return 'Continue' }
    if (-not $CustomInstallDir) { return 'FailDefault' }
    if ($AlreadyElevated) { return 'FailElevated' }
    if ($Administrator) { return 'FailAdministrator' }
    if (-not $HasScriptPath) { return 'FailScriptless' }
    return 'ElevateOnce'
}

function Test-KeplerSignatureGate {
    param([string]$Root)
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -Include *.exe, *.dll -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        throw 'No executable files were found in the downloaded bundle (error SIGN-NONE-BETA).'
    }
    $bad = @()
    foreach ($file in $files) {
        try {
            $status = (Get-AuthenticodeSignature -LiteralPath $file.FullName).Status
        }
        catch { $status = 'UnknownError' }
        if ([string]$status -ne 'Valid') {
            $relative = $file.FullName.Substring($Root.Length).TrimStart('\')
            $bad += ('  ' + $relative + ' -- ' + $status)
        }
    }
    if ($bad.Count -gt 0) {
        throw ('Windows Smart App Control requires a trusted Authenticode signature, but this bundle failed verification:' + "`n" + ($bad -join "`n") + "`n" +
            'The install stopped before replacing or running files. Keep Smart App Control, Defender, and Code Integrity enabled.' + "`n" +
            'Contact support@aichargelabs.com for a signed build (error SIGN-INVALID-BETA).')
    }
    Write-Host ('Signatures OK -- ' + $files.Count + ' executable file(s) verified.')
}

function Invoke-KeplerSacSignatureGate {
    param([string]$SacState, [string]$Root)
    if ($SacState -like 'On*') {
        Test-KeplerSignatureGate -Root $Root
        return $true
    }
    return $false
}

function Test-KeplerWideBind {
    param([string]$ScriptText)
    if ([string]::IsNullOrWhiteSpace($ScriptText)) { return $false }
    $wideBind = @(
        '(?i)(?:--host|--bind)\s+["'']?(?:0\.0\.0\.0|\[::\]|::|\*)',
        '(?i)(?:host|bind)\s*=\s*["'']?(?:0\.0\.0\.0|\[::\]|::|\*)',
        '(?i)IPAddress\]?\s*::\s*(?:Any|IPv6Any)',
        '(?i)(?<![\d.])0\.0\.0\.0(?![\d.])'
    )
    foreach ($pattern in $wideBind) {
        if ($ScriptText -match $pattern) { return $true }
    }
    return $false
}

function Wait-KeplerLoopbackHealth {
    param([int]$Attempts = 45, [int]$Seconds = 2)
    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        Start-Sleep -Seconds $Seconds
        foreach ($port in 8890..8899) {
            try {
                $health = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $port + '/api/health') -TimeoutSec 2
                if ($null -ne $health -and ([string]$health.status -in @('ok', 'healthy'))) {
                    return $port
                }
            }
            catch { }
        }
    }
    return 0
}

function Show-KeplerStartFailureGuidance {
    param([string]$InstallDir, [string]$Version, [datetime]$StartedAt)
    $blocks = Get-KeplerCodeIntegrityBlocks -StartedAt $StartedAt
    Write-Host ''
    if ($null -ne $blocks -and @($blocks).Count -gt 0) {
        Write-Host 'Windows Code Integrity (Smart App Control / WDAC) blocked startup; this is not a firewall failure.'
        Write-Host ('  Windows refused a KeplerCrew ' + $Version + ' binary (events 3033/3077).')
        Write-Host '  Keep Smart App Control and Defender enabled. Contact support@aichargelabs.com for a signed build (error CI-BLOCKED-BETA).'
        return
    }
    Write-Host 'The backend did not confirm healthy on loopback ports 8890-8899.'
    Write-Host ('  For a chosen port: powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $InstallDir 'run.ps1') + '" -Port 8905')
    Write-Host '  If antivirus quarantined a binary, leave it quarantined and contact support for a signed build.'
    Write-Host '  No firewall change is needed: KeplerCrew listens on 127.0.0.1 only.'
}

function Get-KeplerVersionOrder {
    param([string]$Version)
    $match = [regex]::Match($Version, '^(\d+)\.(\d+)\.(\d+)(?:-beta\.([1-9]\d*))?$')
    if (-not $match.Success) { return $null }
    $isBeta = $match.Groups[4].Success
    $betaNumber = [long]0
    if ($isBeta) { $betaNumber = [long]::Parse($match.Groups[4].Value) }
    return [pscustomobject]@{
        Major = [long]::Parse($match.Groups[1].Value)
        Minor = [long]::Parse($match.Groups[2].Value)
        Patch = [long]::Parse($match.Groups[3].Value)
        Stable = $(if ($isBeta) { 0 } else { 1 })
        Beta = $betaNumber
    }
}

function Compare-KeplerVersion {
    param([string]$Left, [string]$Right)
    $leftOrder = Get-KeplerVersionOrder -Version $Left
    $rightOrder = Get-KeplerVersionOrder -Version $Right
    if ($null -eq $leftOrder -or $null -eq $rightOrder) {
        throw ('Invalid KeplerCrew version in downgrade comparison: ' + $Left + ', ' + $Right)
    }
    foreach ($part in 'Major', 'Minor', 'Patch', 'Stable', 'Beta') {
        if ($leftOrder.$part -gt $rightOrder.$part) { return 1 }
        if ($leftOrder.$part -lt $rightOrder.$part) { return -1 }
    }
    return 0
}

function Install-KeplerCrew {
    $script:pinnedBundleError = $null
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    try {
        $installChannel = [string]$env:KEPLER_CHANNEL
        if ([string]::IsNullOrEmpty($installChannel)) { $installChannel = 'beta' }
        if ($installChannel -cne 'beta' -and $installChannel -cne 'stable') {
            throw 'KEPLER_CHANNEL must be "beta" or "stable".'
        }

        # Proxy support: use system credentials for outbound connections
        [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultCredentials

        # TLS hardening: add Tls12 (and Tls13 if available) instead of replacing all protocols
        $currentProtocol = [Net.ServicePointManager]::SecurityProtocol
        $currentProtocol = $currentProtocol -bor [Net.SecurityProtocolType]::Tls12
        try {
            $currentProtocol = $currentProtocol -bor [Net.SecurityProtocolType]::Tls13
        }
        catch {
            # Tls13 not available on older .NET versions
        }
        [Net.ServicePointManager]::SecurityProtocol = $currentProtocol

        $account = '11cdb180-ce9f-4b8b-82c6-ca59f9b2c512'
        # The installer accepts only the supported licensing authority.
        $keygenBase = 'https://licenses.aichargelabs.com/v1'
        if (-not [string]::IsNullOrWhiteSpace($env:KEPLER_KEYGEN_BASE) -and
            $env:KEPLER_KEYGEN_BASE.TrimEnd('/') -cne $keygenBase) {
            throw 'Unsupported licensing endpoint.'
        }
        $api = $keygenBase.TrimEnd('/') + '/accounts/' + $account
        $jsonApi = 'application/vnd.api+json'

        # 0. Resolve the install directory first -- an existing install supplies
        #    the stored license key and the installed version for update checks.
        $customInstallDir = -not [string]::IsNullOrWhiteSpace($env:KEPLER_INSTALL_DIR)
        $installDir = $env:KEPLER_INSTALL_DIR
        if ([string]::IsNullOrWhiteSpace($installDir)) {
            $installDir = Join-Path $env:LOCALAPPDATA 'Programs\KeplerCrew'
        }
        $licenseFile = Join-Path $installDir 'licenses\customer.key'
        $versionFile = Join-Path $installDir 'version.txt'
        $installed = $null
        if (Test-Path -LiteralPath $versionFile) {
            $installed = ([string](Get-Content -LiteralPath $versionFile -Raw)).Trim()
        }

        # The default per-user directory needs no administrator rights. Elevate
        # once only when a custom protected directory is actually unwritable.
        $writable = Test-KeplerPathWritable -Path $installDir
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $writeAction = Get-KeplerWriteAccessAction `
            -Writable $writable `
            -CustomInstallDir $customInstallDir `
            -AlreadyElevated ($env:KEPLER_ELEVATED -eq '1') `
            -Administrator $isAdmin `
            -HasScriptPath (-not [string]::IsNullOrWhiteSpace($PSCommandPath))
        if ($writeAction -ne 'Continue') {
            if ($writeAction -eq 'FailDefault') {
                throw ('The default per-user install directory is unexpectedly unwritable: "' +
                    $installDir + '". Check your LOCALAPPDATA permissions; the installer will not request ' +
                    'administrator rights for the default path (error DEFAULT-PATH-UNWRITABLE-BETA).')
            }
            if ($writeAction -eq 'FailElevated') {
                throw ('The elevated installer still cannot write to "' + $installDir + '". Choose a user-writable KEPLER_INSTALL_DIR.')
            }
            if ($writeAction -eq 'FailAdministrator') {
                throw ('"' + $installDir + '" is not writable even with administrator rights. Choose another KEPLER_INSTALL_DIR.')
            }
            if ($writeAction -eq 'FailScriptless') {
                throw ('"' + $installDir + '" needs administrator rights. Save beta/install.ps1 and run it from an elevated PowerShell, or use the default per-user directory.')
            }
            Write-Host ('"' + $installDir + '" needs administrator rights -- requesting UAC consent once...')
            $childArgs = '-NoProfile -ExecutionPolicy Bypass -Command "& { $env:KEPLER_ELEVATED = ''1''; & ''<PATH>'' }"'
            $childArgs = $childArgs.Replace('<PATH>', $PSCommandPath)
            try {
                Start-Process powershell -Verb RunAs -Wait -ArgumentList $childArgs | Out-Null
            }
            catch {
                throw ('Elevation was declined: ' + $_.Exception.Message + ' Nothing was changed.')
            }
            return
        }

        # Read-only security preflight. SAC is never disabled or reconfigured.
        $sacState = Get-KeplerSmartAppControlState
        if ($sacState -like 'On*') {
            Write-Host ('Smart App Control is ' + $sacState + ' -- the downloaded bundle must be Authenticode-signed.')
        }

        # 1. License key -- env var, stored key from a previous install, or prompt
        #    (never echoed, never left in shell history).
        $key = $env:KEPLER_LICENSE_KEY
        if ([string]::IsNullOrWhiteSpace($key) -and (Test-Path -LiteralPath $licenseFile)) {
            $key = ([string](Get-Content -LiteralPath $licenseFile -Raw)).Trim()
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                Write-Host 'Using the stored license key.'
            }
        }
        if ([string]::IsNullOrWhiteSpace($key)) {
            if ([Console]::IsInputRedirected) {
                throw 'Set KEPLER_LICENSE_KEY when running non-interactively.'
            }
            $secure = Read-Host 'Enter your KeplerCrew license key' -AsSecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            $key = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        $key = $key.Trim()
        if ([string]::IsNullOrWhiteSpace($key)) {
            throw 'A license key is required.'
        }

        # 2. Validate the key before downloading anything.
        Write-Host 'Validating license...'
        $validation = Invoke-RestMethod -Method Post `
            -Uri ($api + '/licenses/actions/validate-key') `
            -ContentType $jsonApi -Headers @{ Accept = $jsonApi } `
            -Body (@{ meta = @{ key = $key } } | ConvertTo-Json)
        if (-not $validation.meta.valid) {
            $code = [string]$validation.meta.code
            throw ('License is not valid (' + $code + '). Contact support@aichargelabs.com.')
        }
        Write-Host 'License OK.'

        # 3. Resolve the release (latest published stable or beta, or KEPLER_VERSION).
        #    Three different things can go wrong here and they need three different
        #    messages. A license that authenticates fine can still be refused the
        #    release catalog (policy forbids license-key auth), or be shown an EMPTY
        #    catalog (it lacks an entitlement the releases are gated on). Reporting
        #    either as "version not found" sends the customer hunting for a version
        #    problem that does not exist.
        $auth = @{ Accept = $jsonApi; Authorization = ('License ' + $key) }
        try {
            $releaseData = (Invoke-RestMethod -Uri ($api + '/releases?limit=50') -Headers $auth).data
        }
        catch [Net.WebException] {
            $status = $null
            if ($null -ne $_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -eq 401 -or $status -eq 403) {
                throw ('Your license is valid but is not permitted to download releases (' + $status + '). ' +
                       'This is a license configuration problem, not a problem with your machine. ' +
                       'Contact support@aichargelabs.com and quote error RELEASE-AUTH-' + $status + '-BETA.')
            }
            throw ('Could not reach the release service' + $(if ($status) { ' (' + $status + ')' } else { '' }) +
                   '. Check your network and try again.')
        }
        $allReleases = $releaseData |
            Where-Object {
                $_.attributes.status -eq 'PUBLISHED' -and
                ($_.attributes.channel -eq $installChannel -or
                    ($installChannel -eq 'beta' -and $_.attributes.channel -eq 'stable'))
            }

        # An empty catalog is an entitlement problem, never a version problem.
        if ($null -eq $allReleases -or @($allReleases).Count -eq 0) {
            throw ('Your license is valid but is not entitled to any published release. ' +
                   'This is a license configuration problem, not a problem with your machine. ' +
                   'Contact support@aichargelabs.com and quote error RELEASE-NONE-BETA.')
        }

        # A license without beta access is shown stable releases only. Ask before the
        # beta command installs stable. An install already on beta is the normal update path.
        $hasBeta = @($allReleases | Where-Object { $_.attributes.channel -eq 'beta' }).Count -gt 0
        if ($installChannel -eq 'beta' -and -not $hasBeta -and [string]::IsNullOrWhiteSpace($env:KEPLER_VERSION)) {
            $installedChannel = ''
            $channelFile = Join-Path $installDir 'channel.txt'
            if (Test-Path -LiteralPath $channelFile) {
                $installedChannel = ([string](Get-Content -LiteralPath $channelFile -Raw)).Trim()
            }
            if ($installed -like '*-beta.*') { $installedChannel = 'beta' }
            if ($installedChannel -ne 'beta') {
                Write-Host 'You do not have beta access: no beta version is available to your license.'
                if ($env:KEPLER_ACCEPT_STABLE -eq '1') {
                    Write-Host 'Continuing with the stable version (KEPLER_ACCEPT_STABLE=1).'
                    $installChannel = 'stable'
                }
                elseif ($env:KEPLER_DRY_RUN -eq '1') {
                    Write-Host 'Dry run: a real install asks before it continues with the stable version.'
                }
                elseif ([Console]::IsInputRedirected) {
                    throw ('Nothing was installed. For beta access contact support@aichargelabs.com. ' +
                           'To install the stable version instead, set KEPLER_ACCEPT_STABLE=1 and run again.')
                }
                else {
                    $stableAnswer = Read-Host 'Would you like to proceed with the stable version? [y/N]'
                    if ($stableAnswer -notmatch '^\s*(y|yes)\s*$') {
                        throw 'Nothing was installed. For beta access contact support@aichargelabs.com.'
                    }
                    $installChannel = 'stable'
                }
            }
        }

        # Sort by the version string: numeric X.Y.Z first, then stable above every
        # beta of the same core, then beta.N by its integer N. attributes.semver is
        # deliberately not used because its prerelease metadata is not authoritative.
        $sortedReleases = $allReleases | Sort-Object -Property `
            @{ Expression = { $order = Get-KeplerVersionOrder $_.attributes.version; if ($null -ne $order) { $order.Major } else { 0 } }; Descending = $true }, `
            @{ Expression = { $order = Get-KeplerVersionOrder $_.attributes.version; if ($null -ne $order) { $order.Minor } else { 0 } }; Descending = $true }, `
            @{ Expression = { $order = Get-KeplerVersionOrder $_.attributes.version; if ($null -ne $order) { $order.Patch } else { 0 } }; Descending = $true }, `
            @{ Expression = { $order = Get-KeplerVersionOrder $_.attributes.version; if ($null -ne $order) { $order.Stable } else { 0 } }; Descending = $true }, `
            @{ Expression = { $order = Get-KeplerVersionOrder $_.attributes.version; if ($null -ne $order) { $order.Beta } else { 0 } }; Descending = $true }

        $wanted = $env:KEPLER_VERSION
        if (-not [string]::IsNullOrWhiteSpace($wanted)) {
            $wanted = $wanted.Trim().TrimStart('v')
            $release = $sortedReleases | Where-Object { $_.attributes.version -eq $wanted } | Select-Object -First 1
            if ($null -eq $release) {
                # The catalog is non-empty (checked above), so this really is a bad
                # version. Name the ones that ARE available, and point at the pin --
                # $env:KEPLER_VERSION survives for the whole PowerShell session, so a
                # pin set once keeps applying to every later install and update in
                # that window, long after the user has forgotten setting it.
                $available = ($sortedReleases | ForEach-Object { $_.attributes.version }) -join ', '
                throw ('Version "' + $wanted + '" is not available to your license. ' +
                       'Your license can install: ' + $available + '. ' +
                       'This version was requested because KEPLER_VERSION is set in this shell. ' +
                       'To install the latest instead, run:  $env:KEPLER_VERSION=$null  ' +
                       'and then re-run the install command.')
            }
        }
        else {
            $release = $sortedReleases | Select-Object -First 1
            if ($null -eq $release) {
                if ($installChannel -eq 'stable') {
                    throw ('No published stable release is available for your license. ' +
                           'Contact support@aichargelabs.com and quote error RELEASE-NONE-BETA.')
                }
                throw ('No published stable or beta release is available for your license. ' +
                       'Contact support@aichargelabs.com and quote error RELEASE-NONE-BETA.')
            }
        }
        $version = [string]$release.attributes.version

        # 3b. Downgrade guard: use the same prerelease-aware ordering as release selection.
        if (-not [string]::IsNullOrWhiteSpace($installed)) {
            $resolvedOrder = Get-KeplerVersionOrder -Version $version
            if ($null -eq $resolvedOrder) {
                throw ('Resolved KeplerCrew version "' + $version + '" could not be read.')
            }
            $installedOrder = Get-KeplerVersionOrder -Version $installed
            if ($null -eq $installedOrder) {
                Write-Host ('Installed version "' + $installed + '" could not be read; continuing without the downgrade check.')
            }
            else {
                $isDowngrade = (Compare-KeplerVersion -Left $installed -Right $version) -gt 0
                if ($isDowngrade -and $env:KEPLER_FORCE -ne '1') {
                    throw ('Downgrade refused: installed ' + $installed + ' is newer than ' + $version + '. Set KEPLER_FORCE=1 to allow downgrade.')
                }
            }
        }

        # 3c. Up-to-date handling runs after artifact resolution: a pinned release
        #    without this platform's bundle is an error even if already installed.
        if (-not [string]::IsNullOrWhiteSpace($installed) -and
            (($installed -ne $version) -or ($env:KEPLER_FORCE -eq '1'))) {
            if ($installed -eq $version) {
                Write-Host ('Reinstalling KeplerCrew ' + $version + '...')
            }
            else {
                Write-Host ('Updating KeplerCrew ' + $installed + ' -> ' + $version + '...')
            }
        }

        # 4. Resolve the Windows zip artifact of that release. License-key auth
        #    cannot LIST artifacts, so the filename follows the release convention.
        #    The singular endpoint answers 303 whose body carries the artifact
        #    metadata and whose Location is the signed download URL; redirects are
        #    handled manually so the Authorization header never reaches storage.
        $filename = 'KeplerCrew-win32-x64-' + $version + '.zip'
        $metaReq = [Net.HttpWebRequest]::Create($api + '/releases/' + $release.id + '/artifacts/' + $filename)
        $metaReq.Method = 'GET'
        $metaReq.Accept = $jsonApi
        $metaReq.Headers.Add('Authorization', 'License ' + $key)
        $metaReq.AllowAutoRedirect = $false
        # Apply proxy credentials to the request
        $metaReq.Proxy = [Net.WebRequest]::GetSystemWebProxy()
        $metaReq.Proxy.Credentials = [Net.CredentialCache]::DefaultCredentials

        $metaResp = $null
        try {
            $metaResp = $metaReq.GetResponse()
        }
        catch [Net.WebException] {
            $metaResp = $_.Exception.Response
            if ($null -ne $metaResp) {
                $statusCode = [int]$metaResp.StatusCode
                $statusClass = [Math]::Floor($statusCode / 100)
                if ($statusCode -eq 401 -or $statusCode -eq 403) {
                    # Do NOT tell the user to check their key: the key already passed
                    # validation and listed this release. Being refused the artifact is
                    # an entitlement problem on our side, and re-typing the key never
                    # fixes it.
                    throw ('Your license listed release ' + $version + ' but was refused its download (' +
                           $statusCode + '). This is a license configuration problem, not a problem with ' +
                           'your machine. Contact support@aichargelabs.com and quote error ARTIFACT-AUTH-' + $statusCode + '-BETA.')
                }
                elseif ($statusCode -eq 404) {
                    if (-not [string]::IsNullOrWhiteSpace($wanted)) {
                        $script:pinnedBundleError = 'KeplerCrew ' + $version + ' has no build for win32/x64 yet.'
                        throw $script:pinnedBundleError
                    }
                    throw ('Release ' + $version + ' has no Windows bundle (' + $filename + ' is missing for this platform). ' +
                           'Contact support@aichargelabs.com and quote error ARTIFACT-MISSING-' + $version + '-BETA.')
                }
                elseif ($statusClass -eq 4 -or $statusClass -eq 5) {
                    throw ('Service error (' + $statusCode + '). Please try again later.')
                }
            }
            if ($null -eq $metaResp) {
                throw ('Failed to connect to artifact service. Check your network.')
            }
        }

        # Handle 303 redirect directly (PS 5.1 does NOT throw on 303)
        $statusCode = [int]$metaResp.StatusCode
        if ($statusCode -eq 302 -or $statusCode -eq 303 -or $statusCode -eq 307 -or $statusCode -eq 308) {
            $location = [string]$metaResp.Headers['Location']
            $reader = New-Object IO.StreamReader($metaResp.GetResponseStream())
            $meta = $reader.ReadToEnd() | ConvertFrom-Json
            $reader.Close(); $metaResp.Close()

            if ([string]::IsNullOrWhiteSpace($location)) {
                throw ('The artifact endpoint returned no download location for ' + $filename)
            }
            $expected = [string]$meta.data.attributes.checksum

            # Checksum fail-closed: empty/missing checksum is fatal
            if ([string]::IsNullOrWhiteSpace($expected)) {
                throw ('Artifact metadata missing checksum - verification cannot proceed. Contact support.')
            }

            # Free-space check: need 2.5x artifact size free
            $artifactSize = [long]$meta.data.attributes.size
            $installDrive = (Split-Path $installDir -Qualifier)
            $freeBytes = (Get-PSDrive -Name $installDrive.TrimEnd(':')).Free
            if ($artifactSize * 2.5 -gt $freeBytes) {
                throw ('Insufficient disk space. Need ' + [Math]::Ceiling($artifactSize * 2.5 / 1MB) + ' MB free on ' + $installDrive + ':, have ' + [Math]::Floor($freeBytes / 1MB) + ' MB.')
            }
        }
        else {
            throw ('Unexpected response from artifact endpoint: ' + $statusCode)
        }

        # Already on the resolved version? Persist the channel on a real no-op;
        # dry runs continue to the reporting block below without writing anything.
        if (($installed -eq $version) -and ($env:KEPLER_FORCE -ne '1') -and ($env:KEPLER_DRY_RUN -ne '1')) {
            Write-Host ('KeplerCrew ' + $version + ' is already installed and up to date.')
            Write-Host 'Set KEPLER_FORCE=1 to reinstall.'
            Set-Content -LiteralPath (Join-Path $installDir 'channel.txt') -Value $installChannel -NoNewline -Encoding ascii
            Write-Host ('Channel set to ' + $installChannel + '.')
            return
        }
        if ($env:KEPLER_DRY_RUN -eq '1') {
            Write-Host ('Version:  ' + $version)
            Write-Host ('Channel:  ' + $installChannel)
            if (-not [string]::IsNullOrWhiteSpace($installed)) {
                Write-Host ('Installed: ' + $installed)
            }
            Write-Host ('Artifact: ' + $filename)
            Write-Host ('SHA256:   ' + $expected)
            return
        }

        # 5. Download from the signed URL (time-limited, no credentials attached).
        #    Retry once if download fails (signed URL may have expired mid-stream).
        $downloadAttempt = 0
        $downloadSucceeded = $false

        while ($downloadAttempt -lt 2 -and -not $downloadSucceeded) {
            $downloadAttempt++
            if ($downloadAttempt -gt 1) {
                Write-Host 'Download failed, retrying with fresh signed URL...'
                # Re-request metadata to get a fresh signed URL
                $metaReq = [Net.HttpWebRequest]::Create($api + '/releases/' + $release.id + '/artifacts/' + $filename)
                $metaReq.Method = 'GET'
                $metaReq.Accept = $jsonApi
                $metaReq.Headers.Add('Authorization', 'License ' + $key)
                $metaReq.AllowAutoRedirect = $false
                $metaReq.Proxy = [Net.WebRequest]::GetSystemWebProxy()
                $metaReq.Proxy.Credentials = [Net.CredentialCache]::DefaultCredentials

                $metaResp = $metaReq.GetResponse()
                $statusCode = [int]$metaResp.StatusCode
                if ($statusCode -eq 302 -or $statusCode -eq 303 -or $statusCode -eq 307 -or $statusCode -eq 308) {
                    $location = [string]$metaResp.Headers['Location']
                    $reader = New-Object IO.StreamReader($metaResp.GetResponseStream())
                    $meta = $reader.ReadToEnd() | ConvertFrom-Json
                    $reader.Close(); $metaResp.Close()
                    $expected = [string]$meta.data.attributes.checksum
                }
                else {
                    throw ('Failed to refresh signed URL: ' + $statusCode)
                }
            }

            Write-Host ('Downloading KeplerCrew ' + $version + '...')
            $downloadDir = Join-Path $env:TEMP ('keplercrew-install-' + $PID)
            New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
            $zipPath = Join-Path $downloadDir $filename
            try {
                Invoke-WebRequest -Uri $location -OutFile $zipPath -UseBasicParsing -TimeoutSec 300
                $downloadSucceeded = $true
            }
            catch {
                if ($downloadAttempt -ge 2) {
                    throw ('Download failed after retry: ' + $_.Exception.Message)
                }
                # Will retry
            }
        }

        # 6. Verify checksum.
        if (-not [string]::IsNullOrWhiteSpace($expected)) {
            # .NET directly, not Get-FileHash: that cmdlet's module fails to load when
            # Windows PowerShell inherits a PowerShell 7 PSModulePath (tool-launched shells).
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $fs = [System.IO.File]::OpenRead($zipPath)
            try { $actual = ([System.BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant() }
            finally { $fs.Dispose(); $sha.Dispose() }
            if ($actual -ne $expected.ToLowerInvariant()) {
                throw ('Checksum mismatch -- download corrupted. Expected ' + $expected + ' got ' + $actual)
            }
            Write-Host 'Checksum OK.'
        }

        # 6b. Stop a running KeplerCrew from this install dir so files are not
        #     locked during extraction. Match processes by Path OR MainModule path
        #     (still never kill anything outside the install dir).
        #     Note: powershell.exe hosting run.ps1 cannot be path-matched;
        #     cwd locks are handled by the .old-swap approach.
        $prefix = $installDir.TrimEnd('\') + '\'
        $running = Get-Process -Name 'kepler-backend', 'kepler-engine', 'kepler', 'llama-server', 'whisper-server' -ErrorAction SilentlyContinue |
            Where-Object {
                $pathMatch = $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
                $moduleMatch = $false
                try { $moduleMatch = $_.MainModule.FileName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } catch { }
                $pathMatch -or $moduleMatch
            }
        if ($running) {
            Write-Host 'Stopping the running KeplerCrew...'
            $running | Stop-Process -Force
            $running | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }

        # 7. Extract to staging dir, validate, then atomic swap.
        Write-Host ('Installing to ' + $installDir + '...')
        $stagingDir = $installDir + '.new-' + $PID
        if (Test-Path -LiteralPath $stagingDir) { Remove-Item -Recurse -Force -LiteralPath $stagingDir }
        # Windows PowerShell 5.1's Expand-Archive fails on archives that contain an
        # entry larger than 2GB (the bundled assistant model is ~2.7GB) - it produces
        # an empty output with no error, which would surface as the run.ps1 check
        # below. Extract via the .NET API instead: it handles zip64 and large entries.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $stagingDir)
        Remove-Item -LiteralPath $zipPath -Force

        # Validate run.ps1 exists in extraction
        $extractedRunScript = Join-Path $stagingDir 'run.ps1'
        if (-not (Test-Path -LiteralPath $extractedRunScript)) {
            throw ('Extraction failed: run.ps1 not found in the archive.')
        }

        # SAC-enabled Windows will refuse unsigned native code. Verify before
        # swapping the current install, and never suggest weakening that policy.
        $null = Invoke-KeplerSacSignatureGate -SacState $sacState -Root $stagingDir

        # KeplerCrew is local-only. A wide bind would create a real network
        # exposure and must not be "fixed" by adding a firewall exception.
        if (Test-KeplerWideBind -ScriptText ([string](Get-Content -LiteralPath $extractedRunScript -Raw))) {
            throw 'The bundle launcher requests a non-loopback bind. Installation stopped (error BIND-WIDE-BETA).'
        }

        # Preserve licenses directory from current install (if exists)
        $licenseDir = Join-Path $installDir 'licenses'
        $stagingLicenseDir = Join-Path $stagingDir 'licenses'
        if ((Test-Path -LiteralPath $licenseDir) -and -not (Test-Path -LiteralPath $stagingLicenseDir)) {
            New-Item -ItemType Directory -Path $stagingLicenseDir -Force | Out-Null
        }
        if (Test-Path -LiteralPath $licenseFile) {
            Copy-Item -LiteralPath $licenseFile -Destination $stagingLicenseDir -Force
        }

        # Perform the swap: rename current to .old, then .new into place.
        # Use ABSOLUTE paths rooted at install dir's parent to avoid CWD dependence.
        $installParent = Split-Path $installDir -Parent
        $oldDir = $installDir + '.old'
        $tempDir = Join-Path $installParent 'keplercrew-old-temp'
        $swapSucceeded = $false
        try {
            if (Test-Path -LiteralPath $installDir) {
                if (Test-Path -LiteralPath $oldDir) {
                    Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                Rename-Item -LiteralPath $installDir -NewName $tempDir -ErrorAction Stop
                Rename-Item -LiteralPath $tempDir -NewName (Split-Path $oldDir -Leaf) -ErrorAction Stop
            }
            Rename-Item -LiteralPath $stagingDir -NewName (Split-Path $installDir -Leaf) -ErrorAction Stop
            $swapSucceeded = $true
        }
        catch {
            # Swap failed - leave .old in place for manual recovery
            Write-Host ('Swap failed: ' + $_.Exception.Message)
            Write-Host ('Staging directory left at: ' + $stagingDir)
            throw ('Installation failed during swap. Please check the directories manually.')
        }

        # Clean up .old on success
        if ($swapSucceeded -and (Test-Path -LiteralPath $oldDir)) {
            Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Update installDir reference after swap
        $installDir = $env:KEPLER_INSTALL_DIR
        if ([string]::IsNullOrWhiteSpace($installDir)) {
            $installDir = Join-Path $env:LOCALAPPDATA 'Programs\KeplerCrew'
        }
        $versionFile = Join-Path $installDir 'version.txt'
        $licenseFile = Join-Path $installDir 'licenses\customer.key'

        # Record the selected channel after the swap so updates cannot lose it.
        Set-Content -LiteralPath (Join-Path $installDir 'channel.txt') -Value $installChannel -NoNewline -Encoding ascii
        Write-Host ('Channel set to ' + $installChannel + '.')

        # Write version.txt LAST, only after swap succeeded
        Set-Content -LiteralPath $versionFile -Value $version -NoNewline -Encoding ascii

        # 8. Store the license for the launcher -- user-only ACL, never world-readable.
        #    Delete any previous key file first: its ACL has inheritance stripped, so an
        #    update would otherwise fail with "Access to the path is denied".
        $licenseDir = Join-Path $installDir 'licenses'
        New-Item -ItemType Directory -Path $licenseDir -Force | Out-Null
        if (Test-Path -LiteralPath $licenseFile) {
            # takeown-free: we own the directory, so grant ourselves delete rights first.
            icacls $licenseFile /grant ([Security.Principal.WindowsIdentity]::GetCurrent().Name + ':(F)') | Out-Null
            Remove-Item -LiteralPath $licenseFile -Force
        }
        Set-Content -LiteralPath $licenseFile -Value $key -NoNewline -Encoding ascii
        # Use the FULLY QUALIFIED identity (DOMAIN\User). A bare user name is ambiguous --
        # when the account name equals the machine name, icacls resolves it to the machine
        # account and writes an empty principal, locking the file out of future updates.
        icacls $licenseFile /inheritance:r `
            /grant:r ([Security.Principal.WindowsIdentity]::GetCurrent().Name + ':(R,W)') | Out-Null

        Write-Host ('KeplerCrew ' + $version + ' installed.')

        # 9. Register the 'kepler' command -- newer bundles ship kepler.cmd; older
        #    archives without it skip this block so installs keep working unchanged.
        $keplerCmd = Join-Path $installDir 'kepler.cmd'
        if (Test-Path -LiteralPath $keplerCmd) {
            try {
                $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
                if ($null -eq $userPath) { $userPath = '' }
                $onPath = $false
                foreach ($entry in $userPath.Split(';')) {
                    if ($entry.Trim().TrimEnd('\') -eq $installDir.TrimEnd('\')) { $onPath = $true; break }
                }
                if (-not $onPath) {
                    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $installDir), 'User')
                }
                Write-Host 'The kepler command is registered - in a NEW terminal try: kepler open | kepler status | kepler stop'
            }
            catch {
                Write-Host ('Could not register the kepler command on PATH: ' + $_.Exception.Message)
            }
        }

        # 10. Launch, then verify the backend on loopback only.
        $runScript = Join-Path $installDir 'run.ps1'
        if ((Test-Path -LiteralPath $runScript) -and ($env:KEPLER_NO_LAUNCH -ne '1')) {
            Write-Host 'Starting KeplerCrew...'
            $launchStartedAt = Get-Date
            Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $runScript + '"') -WorkingDirectory $installDir
            $healthyOn = Wait-KeplerLoopbackHealth
            if ($healthyOn -gt 0) {
                Write-Host ('Backend healthy on 127.0.0.1:' + $healthyOn + ' -- UI: http://127.0.0.1:' + $healthyOn + '/')
            }
            else {
                Show-KeplerStartFailureGuidance -InstallDir $installDir -Version $version -StartedAt $launchStartedAt
            }
        }
        else {
            Write-Host ('Run it any time: powershell -NoProfile -ExecutionPolicy Bypass -File "' + $runScript + '"')
        }
    }
    catch {
        if ($null -ne $script:pinnedBundleError) { return }
        # Error path safe under iex: do NOT exit (closes customer's console)
        # Print multi-line error in red with support contact
        $host.UI.WriteErrorLine('')
        $host.UI.WriteErrorLine('=== KeplerCrew Installation Failed ===')
        $host.UI.WriteErrorLine('')
        $host.UI.WriteErrorLine($_.Exception.Message)
        $host.UI.WriteErrorLine('')
        $host.UI.WriteErrorLine('Please try again or contact support@aichargelabs.com')
        $host.UI.WriteErrorLine('')
        return
    }
}

if ($env:KEPLER_INSTALLER_TEST_ONLY -ne '1') {
    Install-KeplerCrew
    if ($null -ne $script:pinnedBundleError) {
        throw $script:pinnedBundleError
    }
}
