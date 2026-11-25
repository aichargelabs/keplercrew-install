param([Parameter(Mandatory = $true)][string]$InstallerPath)

# The stable installer over a beta install: a tagged version (8.6.14-beta.22) must be read
# as its X.Y.Z, never cast whole to a number.
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $InstallerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    exit 1
}
$functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-KeplerDowngrade'
    }, $true)
if ($null -eq $functionAst) {
    Write-Error 'Missing function: Test-KeplerDowngrade'
    exit 1
}
Invoke-Expression -Command $functionAst.Extent.Text

$cases = @(
    @{ Name = 'stable replaces its own beta'; Installed = '8.6.14-beta.22'; Version = '8.6.14'; Expected = $false },
    @{ Name = 'newer beta core is a downgrade'; Installed = '8.6.15-beta.1'; Version = '8.6.14'; Expected = $true },
    @{ Name = 'older stable is an upgrade'; Installed = '8.6.13'; Version = '8.6.14'; Expected = $false },
    @{ Name = 'newer stable is a downgrade'; Installed = '8.7.0'; Version = '8.6.14'; Expected = $true },
    @{ Name = 'same version is not a downgrade'; Installed = '8.6.14'; Version = '8.6.14'; Expected = $false },
    @{ Name = 'two-digit parts compare as numbers'; Installed = '8.10.0'; Version = '8.9.9'; Expected = $true },
    @{ Name = 'unreadable installed version is not a downgrade'; Installed = 'not-a-version'; Version = '8.6.14'; Expected = $false }
)
$failed = $false
foreach ($case in $cases) {
    $actual = Test-KeplerDowngrade -Installed $case.Installed -Version $case.Version
    if ($actual -ne $case.Expected) {
        Write-Error ($case.Name + ': expected ' + $case.Expected + ', got ' + $actual)
        $failed = $true
    }
}
if ($failed) { exit 1 }
Write-Host ('stable downgrade guard: ' + $cases.Count + ' cases pass')
