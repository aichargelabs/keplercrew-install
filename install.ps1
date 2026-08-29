# KeplerCrew client installer and updater.
# Usage: powershell -ExecutionPolicy Bypass -Command "irm https://get.keplercrew.com/install.ps1 | iex"
# Running it again updates an existing install to the latest published release.
# Env:
#   KEPLER_LICENSE_KEY  license key (existing install's stored key is reused; prompted otherwise)
#   KEPLER_VERSION      optional version such as 1.0.0 (default: latest)
#   KEPLER_DRY_RUN      set to 1 to resolve and print the release without downloading
#   KEPLER_INSTALL_DIR  optional install directory (default: %LOCALAPPDATA%\Programs\KeplerCrew)
#   KEPLER_NO_LAUNCH    set to 1 to skip launching after install
#   KEPLER_FORCE        set to 1 to reinstall even when already on the resolved version
# Author: aichargelabs.

# Runtime PS version check (no #Requires to avoid breaking irm|iex on some hosts)
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host 'PowerShell 5.0 or later is required. You are running version ' $PSVersionTable.PSVersion
    Write-Host 'Please upgrade: https://docs.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows'
    return
}

function Install-KeplerCrew {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    try {
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
        $api = 'https://api.keygen.sh/v1/accounts/' + $account
        $jsonApi = 'application/vnd.api+json'

        # 0. Resolve the install directory first -- an existing install supplies
        #    the stored license key and the installed version for update checks.
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

        # 3. Resolve the release (latest published stable, or KEPLER_VERSION).
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
                       'Contact support@aichargelabs.com and quote error RELEASE-AUTH-' + $status + '.')
            }
            throw ('Could not reach the release service' + $(if ($status) { ' (' + $status + ')' } else { '' }) +
                   '. Check your network and try again.')
        }
        $allReleases = $releaseData |
            Where-Object { $_.attributes.status -eq 'PUBLISHED' -and $_.attributes.channel -eq 'stable' }

        # An empty catalog is an entitlement problem, never a version problem.
        if ($null -eq $allReleases -or @($allReleases).Count -eq 0) {
            throw ('Your license is valid but is not entitled to any published release. ' +
                   'This is a license configuration problem, not a problem with your machine. ' +
                   'Contact support@aichargelabs.com and quote error RELEASE-NONE.')
        }

        # Sort by semver: major, minor, patch (all numeric).
        # attributes.semver is an OBJECT ({major,minor,patch,...}), so matching a regex
        # against it always fails and every key collapses to 0 -- which silently left the
        # picked release at the mercy of API order. Read the numeric fields, and fall back
        # to parsing attributes.version (a string) when they are absent.
        $sortedReleases = $allReleases | Sort-Object {
            $s = $_.attributes.semver
            if ($null -ne $s -and $null -ne $s.major) {
                [int]$s.major * 1000000 + [int]$s.minor * 1000 + [int]$s.patch
            }
            elseif ([string]$_.attributes.version -match '^(\d+)\.(\d+)\.(\d+)') {
                [int]$Matches[1] * 1000000 + [int]$Matches[2] * 1000 + [int]$Matches[3]
            }
            else { 0 }
        } -Descending

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
                throw ('No published stable release is available for your license. ' +
                       'Contact support@aichargelabs.com and quote error RELEASE-NONE-STABLE.')
            }
        }
        $version = [string]$release.attributes.version

        # 3b. Downgrade guard: refuse if resolved version is lower than installed (unless KEPLER_FORCE=1)
        if (-not [string]::IsNullOrWhiteSpace($installed)) {
            $installedParts = $installed.Split('.')
            $versionParts = $version.Split('.')
            $isDowngrade = $false
            if ([int]$installedParts[0] -gt [int]$versionParts[0]) { $isDowngrade = $true }
            elseif ([int]$installedParts[0] -eq [int]$versionParts[0] -and [int]$installedParts[1] -gt [int]$versionParts[1]) { $isDowngrade = $true }
            elseif ([int]$installedParts[0] -eq [int]$versionParts[0] -and [int]$installedParts[1] -eq [int]$versionParts[1] -and [int]$installedParts[2] -gt [int]$versionParts[2]) { $isDowngrade = $true }

            if ($isDowngrade -and $env:KEPLER_FORCE -ne '1') {
                throw ('Downgrade refused: installed ' + $installed + ' is newer than ' + $version + '. Set KEPLER_FORCE=1 to allow downgrade.')
            }
        }

        # 3c. Already on the resolved version? Nothing to do.
        if (($installed -eq $version) -and ($env:KEPLER_FORCE -ne '1')) {
            Write-Host ('KeplerCrew ' + $version + ' is already installed and up to date.')
            Write-Host 'Set KEPLER_FORCE=1 to reinstall.'
            return
        }
        if (-not [string]::IsNullOrWhiteSpace($installed)) {
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
                           'your machine. Contact support@aichargelabs.com and quote error ARTIFACT-AUTH-' + $statusCode + '.')
                }
                elseif ($statusCode -eq 404) {
                    throw ('Release ' + $version + ' has no Windows bundle (' + $filename + ' is missing for this platform). ' +
                           'Contact support@aichargelabs.com and quote error ARTIFACT-MISSING-' + $version + '.')
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

        if ($env:KEPLER_DRY_RUN -eq '1') {
            Write-Host ('Version:  ' + $version)
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
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
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
        $running = Get-Process -Name 'kepler-backend', 'kepler-engine', 'kepler' -ErrorAction SilentlyContinue |
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
        New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $stagingDir -Force
        Remove-Item -LiteralPath $zipPath -Force

        # Validate run.ps1 exists in extraction
        $extractedRunScript = Join-Path $stagingDir 'run.ps1'
        if (-not (Test-Path -LiteralPath $extractedRunScript)) {
            throw ('Extraction failed: run.ps1 not found in the archive.')
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

        # 10. Launch.
        $runScript = Join-Path $installDir 'run.ps1'
        if ((Test-Path -LiteralPath $runScript) -and ($env:KEPLER_NO_LAUNCH -ne '1')) {
            Write-Host 'Starting KeplerCrew...'
            Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $runScript + '"') -WorkingDirectory $installDir
        }
        else {
            Write-Host ('Run it any time: powershell -ExecutionPolicy Bypass -File "' + $runScript + '"')
        }
    }
    catch {
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

Install-KeplerCrew
