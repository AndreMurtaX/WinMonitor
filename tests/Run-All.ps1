#requires -Version 5.1
<#
    Roda todas as suítes e devolve código de saída diferente de zero se
    qualquer uma falhar.

      .\tests\Run-All.ps1
#>
[CmdletBinding()]
param([switch]$Quiet)

$suites = @('Test-Rollup.ps1', 'Test-Drivers.ps1')
$falhas = 0

foreach ($s in $suites) {
    $p = Join-Path $PSScriptRoot $s
    ""
    "##################  $s  ##################"
    if ($Quiet) {
        & $p | Select-Object -Last 6
    } else {
        & $p
    }
    if ($LASTEXITCODE -ne 0) { $falhas++ }
}

""
if ($falhas -eq 0) {
    "TODAS AS SUITES PASSARAM"
    exit 0
} else {
    "$falhas suite(s) falharam"
    exit 1
}
