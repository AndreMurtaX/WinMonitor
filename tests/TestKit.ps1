#requires -Version 5.1
<#
    Arnês de teste mínimo, sem dependência externa.

    Pester resolveria isto, mas não está garantido nesta máquina e o projeto
    tem como regra não exigir instalação para funcionar. São trinta linhas.

    Dot-source este arquivo, chame os Assert-*, termine com Show-TestSummary.
#>

$script:TestPass     = 0
$script:TestFail     = 0
$script:TestFailures = New-Object System.Collections.ArrayList
$script:TestGroup    = ''

function Start-TestGroup {
    param([Parameter(Mandatory)][string]$Name)
    $script:TestGroup = $Name
    ""
    "-- $Name"
}

function Add-TestResult {
    param([bool]$Ok, [string]$Name, [string]$Detail)
    if ($Ok) {
        $script:TestPass++
        "   ok    $Name"
    } else {
        $script:TestFail++
        [void]$script:TestFailures.Add("[$script:TestGroup] $Name — $Detail")
        "   FALHA $Name"
        "         $Detail"
    }
}

function Assert-True {
    param($Condition, [Parameter(Mandatory)][string]$Name)
    Add-TestResult -Ok ([bool]$Condition) -Name $Name -Detail 'esperava verdadeiro'
}

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory)][string]$Name, [double]$Tolerance = 0)
    $ok = $false
    if ($null -eq $Expected -and $null -eq $Actual) {
        $ok = $true
    } elseif ($null -ne $Expected -and $null -ne $Actual -and
              $Expected -is [ValueType] -and $Actual -is [ValueType]) {
        $ok = [math]::Abs([double]$Expected - [double]$Actual) -le $Tolerance
    } else {
        $ok = ($Expected -eq $Actual)
    }
    Add-TestResult -Ok $ok -Name $Name -Detail "esperava '$Expected', veio '$Actual'"
}

function Assert-Null {
    param($Value, [Parameter(Mandatory)][string]$Name)
    Add-TestResult -Ok ($null -eq $Value) -Name $Name -Detail "esperava nulo, veio '$Value'"
}

function Assert-NotNull {
    param($Value, [Parameter(Mandatory)][string]$Name)
    Add-TestResult -Ok ($null -ne $Value) -Name $Name -Detail 'esperava não-nulo, veio nulo'
}

function Assert-GreaterThan {
    param($Value, $Than, [Parameter(Mandatory)][string]$Name)
    Add-TestResult -Ok ([double]$Value -gt [double]$Than) -Name $Name -Detail "esperava > $Than, veio $Value"
}

function Assert-LessThan {
    param($Value, $Than, [Parameter(Mandatory)][string]$Name)
    Add-TestResult -Ok ([double]$Value -lt [double]$Than) -Name $Name -Detail "esperava < $Than, veio $Value"
}

function Show-TestSummary {
    ""
    "=============================================="
    "  {0} passou, {1} falhou" -f $script:TestPass, $script:TestFail
    if ($script:TestFail -gt 0) {
        ""
        foreach ($f in $script:TestFailures) { "  x $f" }
    }
    "=============================================="
}

# Separado do relatório de propósito: Show-TestSummary emite texto, e misturar
# texto com código de retorno faria 'exit (Show-TestSummary)' receber um array.
function Get-TestExitCode {
    if ($script:TestFail -gt 0) { return 1 }
    return 0
}
