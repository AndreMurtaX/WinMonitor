#requires -Version 5.1
<#
    Agregação diária — driver.

    Toda a matemática vive em WinMonitor.Rollup.psm1, como função pura testável
    contra fixture. Este script só resolve caminhos, decide o que agregar e
    grava. Se algo aqui ficar complicado, é sinal de que pertence ao módulo.

    UM DIA RUIM NÃO DERRUBA O LOTE
    Uma versão anterior rodava com $ErrorActionPreference='Stop' e sem proteção
    por dia. Um único valor não-numérico no segundo de cinco dias abortava o
    script, e os dias 3, 4 e 5 — intactos — nunca eram agregados. Cada dia agora
    é tentado por conta própria.

    Uso:
      .\src\Invoke-Rollup.ps1                  agrega todo dia completo ainda sem agregado
      .\src\Invoke-Rollup.ps1 -Day 2026-08-15  agrega um dia específico
      .\src\Invoke-Rollup.ps1 -Force           refaz mesmo se já existir
#>
[CmdletBinding()]
param(
    [string]$Day,
    [switch]$Force,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'WinMonitor.psm1')        -Force
Import-Module (Join-Path $PSScriptRoot 'WinMonitor.Rollup.psm1') -Force

$cfg    = Get-WMConfig
$rawDir = Get-WMPath $cfg.paths.patrol
$outDir = Confirm-WMDirectory (Get-WMPath $cfg.paths.rollup)

if (-not (Test-Path -LiteralPath $rawDir)) {
    Write-Warning "não há dado bruto em $rawDir — a ronda já rodou alguma vez?"
    return
}

$DAY_RE = '^\d{4}-\d{2}-\d{2}$'
$today  = Get-WMDayId

$files = @(
    Get-ChildItem -LiteralPath $rawDir -Filter '*.jsonl' -File |
        Where-Object { $_.BaseName -match $DAY_RE } |
        Sort-Object Name
)
if ($Day) { $files = @($files | Where-Object { $_.BaseName -eq $Day }) }

$done   = 0
$falhou = 0

foreach ($f in $files) {
    $dayId    = $f.BaseName
    $ehHoje   = ($dayId -eq $today)

    # O dia corrente ainda está sendo escrito; agregá-lo por conta própria
    # produziria um dia parcial comparado depois como se fosse completo.
    if ($ehHoje -and -not $Day -and -not $Force) { continue }

    $out = Join-Path $outDir "$dayId.json"

    # Agregado parcial de um dia que ainda não terminou pode ser refeito;
    # agregado completo só é refeito com -Force.
    if ((Test-Path -LiteralPath $out) -and -not $Force) {
        $anterior = $null
        try { $anterior = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        if ($null -ne $anterior -and $anterior.partial -eq $true) {
            # segue e refaz
        } else {
            continue
        }
    }

    try {
        $roll = New-WMDayRollup -Path $f.FullName -DayId $dayId -Bands $cfg.loadBands
        if ($null -eq $roll) {
            Write-WMLog -Level warn -Source 'rollup' -Message "$dayId sem amostra utilizável"
            continue
        }

        Add-Member -InputObject $roll -NotePropertyName madeAt  -NotePropertyValue (Get-WMTimestamp) -Force
        # Marcado como parcial enquanto o dia não fechou, para que a próxima
        # execução o refaça em vez de congelar um dia pela metade para sempre.
        Add-Member -InputObject $roll -NotePropertyName partial -NotePropertyValue ([bool]$ehHoje)   -Force

        $json = ConvertTo-Json -InputObject $roll -Depth 14
        [System.IO.File]::WriteAllText($out, $json, (New-Object System.Text.UTF8Encoding($false)))

        "agregado: {0}{1}  ({2} amostras, {3} reinício(s), {4} linha(s) ruim(ns))" -f `
            $dayId, $(if ($ehHoje) { ' [parcial]' } else { '' }), $roll.samples, $roll.reboots, $roll.badLines
        $done++

        if ($PassThru) { $roll }

    } catch {
        # Um dia problemático não pode impedir os outros de serem agregados.
        $falhou++
        Write-WMLog -Level error -Source 'rollup' -Message "$dayId falhou: $($_.Exception.Message)"
        Write-Warning "$dayId falhou e foi pulado: $($_.Exception.Message)"
    }
}

if ($done -eq 0 -and $falhou -eq 0) { 'nada a agregar.' }
if ($falhou -gt 0) { Write-Warning "$falhou dia(s) falharam; os demais foram agregados." }
