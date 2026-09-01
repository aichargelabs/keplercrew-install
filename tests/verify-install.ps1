param([Parameter(Mandatory = $true)][string]$InstallerPath)

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $InstallerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    exit 1
}

$text = [IO.File]::ReadAllText($InstallerPath)
$priorTestOnly = $env:KEPLER_INSTALLER_TEST_ONLY
$env:KEPLER_INSTALLER_TEST_ONLY = '1'
try { . $InstallerPath }
finally { $env:KEPLER_INSTALLER_TEST_ONLY = $priorTestOnly }

$wideBindCases = @(
    'python server.py --host 0.0.0.0',
    'python server.py --host [::]',
    'python server.py --host *',
    '$host = "::"',
    '[Net.IPAddress]::Any',
    '[Net.IPAddress]::IPv6Any'
)
$wideBindBehavior = $true
foreach ($case in $wideBindCases) {
    if (-not (Test-KeplerWideBind -ScriptText $case)) { $wideBindBehavior = $false }
}
$loopbackBehavior = -not (Test-KeplerWideBind -ScriptText 'python server.py --host 127.0.0.1')

$accessCases = @(
    @($true,  $false, $false, $false, $false, 'Continue'),
    @($false, $false, $false, $false, $false, 'FailDefault'),
    @($false, $true,  $true,  $false, $true,  'FailElevated'),
    @($false, $true,  $false, $true,  $true,  'FailAdministrator'),
    @($false, $true,  $false, $false, $false, 'FailScriptless'),
    @($false, $true,  $false, $false, $true,  'ElevateOnce')
)
$accessBehavior = $true
foreach ($case in $accessCases) {
    $actual = Get-KeplerWriteAccessAction -Writable $case[0] -CustomInstallDir $case[1] `
        -AlreadyElevated $case[2] -Administrator $case[3] -HasScriptPath $case[4]
    if ($actual -ne $case[5]) { $accessBehavior = $false }
}

$testRoot = Join-Path $env:TEMP ('kepler-installer-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$hiddenExe = Join-Path $testRoot 'hidden.exe'
Set-Content -LiteralPath $hiddenExe -Value 'MZ' -Encoding ascii
(Get-Item -LiteralPath $hiddenExe).Attributes = `
    ((Get-Item -LiteralPath $hiddenExe).Attributes -bor [IO.FileAttributes]::Hidden)
$script:signatureCalls = 0
function global:Get-AuthenticodeSignature {
    [CmdletBinding()] param([string]$LiteralPath)
    $script:signatureCalls++
    return [pscustomobject]@{ Status = 'Valid' }
}
try {
    Test-KeplerSignatureGate -Root $testRoot
    $hiddenSignatureBehavior = ($script:signatureCalls -eq 1)
    function global:Get-AuthenticodeSignature {
        [CmdletBinding()] param([string]$LiteralPath)
        return [pscustomobject]@{ Status = 'NotSigned' }
    }
    try {
        Test-KeplerSignatureGate -Root $testRoot
        $invalidSignatureBehavior = $false
    }
    catch { $invalidSignatureBehavior = ($_.Exception.Message -match 'SIGN-INVALID') }
}
catch { $hiddenSignatureBehavior = $false; $invalidSignatureBehavior = $false }
finally {
    Remove-Item function:\Get-AuthenticodeSignature -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$script:capturedFilter = $null
function global:Get-WinEvent {
    [CmdletBinding()] param([hashtable]$FilterHashtable)
    $script:capturedFilter = $FilterHashtable
    return @(
        [pscustomobject]@{ Message = 'unrelated product was blocked' },
        [pscustomobject]@{ Message = 'KeplerCrew binary was blocked' }
    )
}
$knownStart = [datetime]'2026-09-01T10:00:00Z'
try {
    $filteredEvents = @(Get-KeplerCodeIntegrityBlocks -StartedAt $knownStart)
    $eventBehavior = (($script:capturedFilter.Id -join ',') -eq '3033,3077') -and
        ($script:capturedFilter.StartTime -eq $knownStart.AddSeconds(-2)) -and
        ($script:capturedFilter.LogName -eq 'Microsoft-Windows-CodeIntegrity/Operational') -and
        ($filteredEvents.Count -eq 1) -and ($filteredEvents[0].Message -match 'Kepler')
}
catch { $eventBehavior = $false }
finally { Remove-Item function:\Get-WinEvent -ErrorAction SilentlyContinue }

$script:sacValue = 0
function global:Get-ItemProperty {
    [CmdletBinding()] param([string]$LiteralPath, [string]$Name)
    if ($LiteralPath -ne 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -or
        $Name -ne 'VerifiedAndReputablePolicyState') { throw 'wrong registry query' }
    return [pscustomobject]@{ VerifiedAndReputablePolicyState = $script:sacValue }
}
try {
    $script:sacValue = 0; $sacOff = Get-KeplerSmartAppControlState
    $script:sacValue = 1; $sacOn = Get-KeplerSmartAppControlState
    $script:sacValue = 2; $sacEvaluation = Get-KeplerSmartAppControlState
    $sacReadBehavior = ($sacOff -eq 'Off' -and $sacOn -eq 'On (enforce)' -and
        $sacEvaluation -eq 'On (evaluation)')
}
catch { $sacReadBehavior = $false }
finally { Remove-Item function:\Get-ItemProperty -ErrorAction SilentlyContinue }

$script:probeUris = @()
function global:Invoke-RestMethod {
    [CmdletBinding()] param([string]$Uri, [int]$TimeoutSec)
    $script:probeUris += $Uri
    if ($Uri -match ':8893/api/health$') { return @{ status = 'ok' } }
    throw 'closed'
}
try {
    $healthyPort = Wait-KeplerLoopbackHealth -Attempts 1 -Seconds 0
    $loopbackProbeBehavior = ($healthyPort -eq 8893 -and
        @($script:probeUris | Where-Object { $_ -notmatch '^http://127\.0\.0\.1:\d+/api/health$' }).Count -eq 0)
    function global:Invoke-RestMethod {
        [CmdletBinding()] param([string]$Uri, [int]$TimeoutSec)
        if ($Uri -match ':8892/api/health$') { return @{ status = 'healthy' } }
        throw 'closed'
    }
    $loopbackProbeBehavior = $loopbackProbeBehavior -and
        ((Wait-KeplerLoopbackHealth -Attempts 1 -Seconds 0) -eq 8892)
    function global:Invoke-RestMethod {
        [CmdletBinding()] param([string]$Uri, [int]$TimeoutSec)
        return @{ status = 'starting' }
    }
    $loopbackProbeBehavior = $loopbackProbeBehavior -and
        ((Wait-KeplerLoopbackHealth -Attempts 1 -Seconds 0) -eq 0)
}
catch { $loopbackProbeBehavior = $false }
finally { Remove-Item function:\Invoke-RestMethod -ErrorAction SilentlyContinue }

$script:sacGateCalls = 0
$originalSignatureGate = ${function:Test-KeplerSignatureGate}
function Test-KeplerSignatureGate {
    [CmdletBinding()] param([string]$Root)
    $script:sacGateCalls++
}
try {
    $offResult = Invoke-KeplerSacSignatureGate -SacState 'Off' -Root 'test-root'
    $onResult = Invoke-KeplerSacSignatureGate -SacState 'On (enforce)' -Root 'test-root'
    $sacConditionalBehavior = (-not $offResult) -and $onResult -and ($script:sacGateCalls -eq 1)
}
catch { $sacConditionalBehavior = $false }
finally { Set-Item function:\Test-KeplerSignatureGate $originalSignatureGate }

# Verify production wiring through the parsed command AST, not a text marker.
# Commenting/removing the call makes this zero even if helper tests still pass.
$installFunction = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Install-KeplerCrew'
}, $true)
$wiredSacCommands = @($installFunction.Body.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Invoke-KeplerSacSignatureGate'
}, $true))
$productionSacWiringBehavior = ($wiredSacCommands.Count -eq 1)

$checks = [ordered]@{
    ParserClean = $true
    AuthenticodeGate = $hiddenSignatureBehavior
    RejectsInvalidSignature = $invalidSignatureBehavior
    ReadsSmartAppControl = $sacReadBehavior
    NeverWritesSmartAppControl = ($text -notmatch '(?is)(Set|New)-ItemProperty[^\r\n]*VerifiedAndReputablePolicyState')
    NoDefenderWeakening = ($text -notmatch '(?i)(Set-MpPreference|Add-MpPreference)')
    NoFirewallMutation = ($text -notmatch '(?i)(New-NetFirewallRule|Set-NetFirewallRule|Remove-NetFirewallRule|Set-NetFirewallProfile)')
    LoopbackOnlyProbe = $loopbackProbeBehavior
    RejectsWideBind = ($wideBindBehavior -and $loopbackBehavior)
    RejectsWideBindVariants = ($wideBindBehavior -and $loopbackBehavior)
    IncludesHiddenSignedFiles = $hiddenSignatureBehavior
    DefaultPathNeverElevates = ($accessBehavior -and ((Get-KeplerWriteAccessAction $false $false $false $false $true) -eq 'FailDefault'))
    LaunchScopedIntegrityEvents = $eventBehavior
    BoundedElevation = ($accessBehavior -and ((Get-KeplerWriteAccessAction $false $true $false $false $true) -eq 'ElevateOnce'))
    SacConditionalSignatureGate = ($sacConditionalBehavior -and $productionSacWiringBehavior)
}

$failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value })
$checks.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }
if ($failed.Count -gt 0) { exit 2 }
exit 0
