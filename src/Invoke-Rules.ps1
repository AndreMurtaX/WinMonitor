#requires -Version 5.1
<#
    Avaliação de regras — driver.

    Toda a lógica vive em WinMonitor.Rules.psm1, como função pura testável
    contra fixture. Este script só resolve caminhos, carrega o agregado, a
    linha-base e a tabela de limiares, e grava os Achados.

    É a última coisa que roda antes da fronteira determinística. O que sai
    daqui é o único material que a camada de parecer pode discutir.

    Uso:
      .\src\Invoke-Rules.ps1                  avalia o agregado completo mais recente
      .\src\Invoke-Rules.ps1 -Day 2026-08-14  avalia um dia específico
      .\src\Invoke-Rules.ps1 -Quiet           só grava, sem imprimir
#>
[CmdletBinding()]
param(
    [string]$Day,
    [switch]$Quiet,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'WinMonitor.psm1')        -Force
Import-Module (Join-Path $PSScriptRoot 'WinMonitor.Rollup.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WinMonitor.Rules.psm1')  -Force

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch {
        Write-WMLog -Level error -Source 'rules' -Message "arquivo ilegível: $Path — $($_.Exception.Message)"
        return $null
    }
}

$cfg     = Get-WMConfig
$rollDir = Get-WMPath $cfg.paths.rollup
$outDir  = Confirm-WMDirectory (Get-WMPath $cfg.paths.findings)

# --- tabela de limiares -----------------------------------------------------
$limiares = Read-JsonFile (Get-WMPath 'config\thresholds.json')
if ($null -eq $limiares) {
    Write-Warning 'não consegui ler config\thresholds.json — sem tabela de limiares não há o que avaliar.'
    return
}

# --- agregado ---------------------------------------------------------------
if (-not (Test-Path -LiteralPath $rollDir)) {
    Write-Warning "não há agregado em $rollDir — rode .\src\Invoke-Rollup.ps1 antes."
    return
}

$candidatos = @(
    Get-ChildItem -LiteralPath $rollDir -Filter '*.json' -File |
        Where-Object { $_.BaseName -match '^\d{4}-\d{2}-\d{2}$' } |
        Sort-Object Name
)
if ($Day) { $candidatos = @($candidatos | Where-Object { $_.BaseName -eq $Day }) }

$rollup = $null
$dia    = $null
foreach ($c in ($candidatos | Sort-Object Name -Descending)) {
    $r = Read-JsonFile $c.FullName
    if ($null -eq $r) { continue }
    # Dia parcial descreve um período que ainda não terminou; avaliá-lo como se
    # fosse completo produziria Achado sobre meio dia de dado.
    if ($r.partial -eq $true -and -not $Day) { continue }
    $rollup = $r
    $dia    = $c.BaseName
    break
}

if ($null -eq $rollup) {
    Write-Warning 'nenhum agregado completo disponível para avaliar.'
    return
}

<#
    --- exame do dia, se houver ---

    O agregado só conhece o que a ronda coleta. O exame traz o que é caro demais
    para a ronda — hoje, o log de eventos. As regras precisam enxergar os dois,
    então o bloco do exame é enxertado na raiz da avaliação sob a mesma chave que
    ele usa no próprio arquivo.

    SÓ O EXAME DO MESMO DIA. Enxertar o exame de ontem num agregado de hoje faria
    a regra de erro de hardware responder sobre um período que não é o avaliado —
    e, pior, continuaria respondendo "zero" para sempre depois que o exame
    parasse de rodar. Sem exame do dia, as regras que dependem dele caem em
    "sem dado", que é a resposta correta.
#>
$exame = Read-JsonFile (Join-Path (Get-WMPath $cfg.paths.exam) "$dia.json")
if ($exame) {
    foreach ($k in @($exame.PSObject.Properties.Name)) {
        if ($k -in 'v', 'host', 'at', 'mode', 'coverage', 'complete') { continue }
        Add-Member -InputObject $rollup -NotePropertyName $k -NotePropertyValue $exame.$k -Force
    }
}

# --- linha-base e hardware --------------------------------------------------
$baseline = Read-JsonFile (Join-Path (Get-WMPath $cfg.paths.baseline) 'baseline.json')
$hardware = Read-JsonFile (Get-WMPath 'data\host.json')

<#
    Os nomes de GPU vêm de host.json (Win32_VideoController). Se o arquivo for
    de antes desse campo existir, recoleta-se uma vez — caso contrário toda
    regra restrita a modelo cairia em "não se aplica" para sempre, o que tem
    cara de resposta legítima e é, na verdade, o limiar do fabricante nunca
    sendo conferido.
#>
if ($null -eq $hardware -or $null -eq $hardware.gpuNames -or @($hardware.gpuNames).Count -eq 0) {
    try { $hardware = Get-WMHostFacts -Refresh } catch { }
}
if ($hardware -and $hardware.gpuNames) {
    Add-Member -InputObject $hardware -NotePropertyName gpus -NotePropertyValue @($hardware.gpuNames) -Force
}

# --- avaliação --------------------------------------------------------------
$res = Invoke-WMRules -Rollup $rollup -Rules $limiares -Baseline $baseline -Hardware $hardware
Add-Member -InputObject $res -NotePropertyName evaluatedAt -NotePropertyValue (Get-WMTimestamp) -Force
Add-Member -InputObject $res -NotePropertyName rulesVersion -NotePropertyValue $limiares.version -Force

$destino = Join-Path $outDir "$dia.json"
$json = ConvertTo-Json -InputObject $res -Depth 14
[System.IO.File]::WriteAllText($destino, $json, (New-Object System.Text.UTF8Encoding($false)))

# --- saída ------------------------------------------------------------------
if (-not $Quiet) {
    ""
    "Dia avaliado : $dia"
    "Veredito     : $($res.verdict)"
    "Cobertura    : {0}" -f $(if ($res.coverage.complete) { 'completa' } else { 'INCOMPLETA — ver abaixo' })
    ""
    if ($res.findings.Count -gt 0) {
        "Achados:"
        foreach ($a in $res.findings) {
            "  [{0,-8}] {1}" -f $a.severity, $a.claim
            "             {0} = {1}   (limiar {2}, fonte {3})" -f `
                $a.evidence[0].metric, $a.evidence[0].value, $a.rule.threshold, $a.rule.source.kind
        }
    } else {
        "Nenhum achado nas regras que puderam ser avaliadas."
    }

    <#
        O bloco abaixo NÃO é decoração. Sem ele, "nenhum achado" leria como
        "máquina saudável" mesmo quando metade das regras não pôde rodar.
    #>
    $blocos = @(
        @{ nome = 'sem fonte declarada';   dados = $res.coverage.unsourced }
        @{ nome = 'regra malformada';      dados = $res.coverage.malformed }
        @{ nome = 'métrica ausente';       dados = $res.coverage.noData }
        @{ nome = 'sem linha-base';        dados = $res.coverage.noBaseline }
        @{ nome = 'hardware não confere';  dados = $res.coverage.notApplicable }
    )
    $temLacuna = $false
    foreach ($b in $blocos) {
        $chaves = @(Get-WMNodeKeys $b.dados)
        if ($chaves.Count -eq 0) { continue }
        if (-not $temLacuna) { ""; "NÃO VERIFICADO — isto não é aprovação:"; $temLacuna = $true }
        "  {0}:" -f $b.nome
        foreach ($k in $chaves) { "     {0} — {1}" -f $k, (Get-WMNodeChild $b.dados $k) }
    }
    ""
    "gravado em: $destino"
}

if ($PassThru) { $res }
