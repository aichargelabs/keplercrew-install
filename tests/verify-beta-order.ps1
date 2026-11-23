param([Parameter(Mandatory = $true)][string]$InstallerPath)

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $InstallerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    exit 1
}

foreach ($functionName in 'Get-KeplerVersionOrder', 'Compare-KeplerVersion') {
    $functionAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
        }, $true)
    if ($null -eq $functionAst) {
        Write-Error ('Missing version function: ' + $functionName)
        exit 1
    }
    Invoke-Expression -Command $functionAst.Extent.Text
}

$cases = @(
    @{ Name = 'beta.10 sorts above beta.9'; Left = '8.6.14-beta.10'; Right = '8.6.14-beta.9'; Expected = 1 },
    @{ Name = 'GA sorts above its betas'; Left = '8.6.14'; Right = '8.6.14-beta.10'; Expected = 1 },
    @{ Name = 'newer core beta sorts above older GA'; Left = '8.6.14-beta.2'; Right = '8.6.13'; Expected = 1 },
    @{ Name = 'equal versions compare equal'; Left = '8.6.14-beta.2'; Right = '8.6.14-beta.2'; Expected = 0 }
)
$failed = $false
foreach ($case in $cases) {
    $actual = Compare-KeplerVersion -Left $case.Left -Right $case.Right
    if ($actual -ne $case.Expected) {
        Write-Error ($case.Name + ': expected ' + $case.Expected + ', got ' + $actual)
        $failed = $true
    }
}
if ($null -ne (Get-KeplerVersionOrder -Version 'not-a-version')) {
    Write-Error 'An unparseable version must return null.'
    $failed = $true
}
if ($failed) { exit 1 }
Write-Host 'Beta PowerShell version ordering OK.'
