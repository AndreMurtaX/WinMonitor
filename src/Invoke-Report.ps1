#requires -Version 5.1
<#
    Relatório e notificação — driver.

    Roda depois das regras. Monta o relatório determinístico, decide se alguém
    precisa ser incomodado, entrega pelos canais configurados e registra o que
    aconteceu.

    A ORDEM É PROPOSITAL: a saúde da coleta é conferida ANTES de qualquer
    conclusão sobre a máquina. Um veredito "normal" calculado sobre a ronda de
    anteontem não é uma boa notícia, é uma notícia falsa — e o relatório precisa
    dizer isso na primeira linha, não numa nota de rodapé.

    O ESTADO SÓ AVANÇA SE A ENTREGA DEU CERTO. Se todos os canais falharem, o
    lastNotifiedDay não é atualizado, e a próxima execução tenta de novo. Gravar
    "notificado" quando ninguém foi notificado é a forma mais fácil de construir
    um monitor que se acha em dia.

    Uso:
      .\src\Invoke-Report.ps1                 último dia com achados
      .\src\Invoke-Report.ps1 -Day 2026-08-14
      .\src\Invoke-Report.ps1 -DryRun         monta e mostra, não entrega nem grava estado
      .\src\Invoke-Report.ps1 -Force          entrega mesmo que a decisão seja "nada novo"
#>
[CmdletBinding()]
param(
    [string]$Day,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'WinMonitor.psm1')        -Force
Import-Module (Join-Path $PSScriptRoot 'WinMonitor.Rollup.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WinMonitor.Rules.psm1')  -Force
Import-Module (Join-Path $PSScriptRoot 'WinMonitor.Report.psm1') -Force

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

$cfg     = Get-WMConfig
$findDir = Get-WMPath $cfg.paths.findings
$notiDir = Confirm-WMDirectory (Get-WMPath $cfg.paths.notify)
$estadoF = Join-Path $notiDir 'state.json'

# --- achados ---------------------------------------------------------------
$arquivos = @()
if (Test-Path -LiteralPath $findDir) {
    $arquivos = @(
        Get-ChildItem -LiteralPath $findDir -Filter '*.json' -File |
            Where-Object { $_.BaseName -match '^\d{4}-\d{2}-\d{2}$' } |
            Sort-Object Name -Descending
    )
}
if ($Day) { $arquivos = @($arquivos | Where-Object { $_.BaseName -eq $Day }) }
if ($arquivos.Count -eq 0) { Write-Warning 'nenhum arquivo de achados; rode .\src\Invoke-Rules.ps1 antes.'; return }

$dia     = $arquivos[0].BaseName
$achados = Read-JsonFile $arquivos[0].FullName
if ($null -eq $achados) { Write-Warning "achados de $dia ilegíveis."; return }

# --- saúde da coleta, antes de tudo ----------------------------------------
$saude = Get-WMCollectionHealth `
            -PatrolDir (Get-WMPath $cfg.paths.patrol) `
            -IntervalMinutes ([int]$(if ($cfg.notify.patrolIntervalMinutes) { $cfg.notify.patrolIntervalMinutes } else { 1 })) `
            -StaleAfterMinutes ([int]$(if ($cfg.notify.staleAfterMinutes) { $cfg.notify.staleAfterMinutes } else { 30 }))

# --- tendência --------------------------------------------------------------
$rollup   = Read-JsonFile (Join-Path (Get-WMPath $cfg.paths.rollup) "$dia.json")
$baseline = Read-JsonFile (Join-Path (Get-WMPath $cfg.paths.baseline) 'baseline.json')
$trend    = New-WMTrend -Rollup $rollup -Baseline $baseline

# --- o que ficou sem verificar ---------------------------------------------
$naoVerificado = New-Object System.Collections.ArrayList
foreach ($bloco in 'unsourced', 'malformed', 'noData', 'noBaseline', 'notApplicable') {
    $n = Get-WMNodeChild $achados.coverage $bloco
    foreach ($k in (Get-WMNodeKeys $n)) {
        [void]$naoVerificado.Add(("{0}: {1}" -f $k, (Get-WMNodeChild $n $k)))
    }
}

# --- decisão ----------------------------------------------------------------
$estado = Read-JsonFile $estadoF
if ($null -eq $estado) {
    $estado = [pscustomobject]@{
        lastNotifiedDay          = $null
        lastVerdict              = 'normal'
        lastRuleIds              = @()
        consecutiveIncompleteDays = 0
    }
}

<#
    O contador de cegueira avança aqui, não na decisão: ele conta DIAS, e só
    quem sabe que este é um dia novo pode incrementá-lo. Chamar a decisão duas
    vezes no mesmo dia não pode inflar a contagem.
#>
$diaNovo = ($estado.lastEvaluatedDay -ne $dia)
$cego    = [int]$estado.consecutiveIncompleteDays
if ($diaNovo) {
    if ($achados.coverage -and -not $achados.coverage.complete) { $cego++ } else { $cego = 0 }
}
$estadoParaDecisao = $estado | Select-Object *
$estadoParaDecisao | Add-Member -NotePropertyName consecutiveIncompleteDays -NotePropertyValue $cego -Force

$decisao = Test-WMShouldNotify `
              -Findings $achados -Health $saude -State $estadoParaDecisao -Today $dia `
              -HeartbeatDays ([int]$(if ($cfg.notify.heartbeatDays) { $cfg.notify.heartbeatDays } else { 7 })) `
              -RepeatDays   ([int]$(if ($cfg.notify.repeatDays)   { $cfg.notify.repeatDays }   else { 1 })) `
              -BlindDays    ([int]$(if ($cfg.notify.blindDays)    { $cfg.notify.blindDays }    else { 3 }))

if ($Force -and -not $decisao.notify) {
    $decisao = New-WMNotifyDecision $true 'forcado' 'entrega pedida na linha de comando' $decisao.ruleIds
}

# --- relatório ---------------------------------------------------------------
$relatorio = [pscustomobject][ordered]@{
    v                = 1
    host             = $achados.host
    window           = $dia
    verdict          = $achados.verdict
    coverageComplete = [bool]$achados.coverage.complete
    health           = $saude
    findings         = @($achados.findings)
    trend            = $trend
    notVerified      = @($naoVerificado)
    decision         = $decisao
    madeAt           = Get-WMTimestamp
}

$texto = Format-WMReportText -Report $relatorio

if ($DryRun) {
    $texto
    ''
    "--- decisão: notificar = $($decisao.notify) ($($decisao.reason)) — nada foi entregue nem gravado"
    if ($PassThru) { $relatorio }
    return
}

# --- entrega -----------------------------------------------------------------
$entregas = New-Object System.Collections.ArrayList
$algumOk  = $false

if ($decisao.notify) {
    $segredos = Get-WMSecrets
    $canais   = @($cfg.notify.channels)
    if ($canais.Count -eq 0) { $canais = @('File') }

    foreach ($canal in $canais) {
        $script = Join-Path $PSScriptRoot ("notifiers\Notify-{0}.ps1" -f $canal)
        if (-not (Test-Path -LiteralPath $script)) {
            [void]$entregas.Add(@{ channel = $canal; ok = $false; detail = 'canal desconhecido: não existe script para ele' })
            continue
        }
        $r = & $script -Text $texto -Report $relatorio -Config $cfg -Secrets $segredos
        [void]$entregas.Add(@{ channel = $canal; ok = [bool]$r.ok; detail = [string]$r.detail })
        if ($r.ok) { $algumOk = $true }
    }
}

# --- estado -------------------------------------------------------------------
<#
    lastEvaluatedDay avança sempre: ele serve para não contar o mesmo dia duas
    vezes na cegueira. lastNotifiedDay só avança se ALGUM canal entregou — do
    contrário o monitor se acharia em dia sem ninguém ter sido avisado.
#>
$novoEstado = [ordered]@{
    lastEvaluatedDay          = $dia
    lastNotifiedDay           = $estado.lastNotifiedDay
    lastVerdict               = $estado.lastVerdict
    lastRuleIds               = @($estado.lastRuleIds)
    consecutiveIncompleteDays = $cego
    lastDelivery              = @($entregas)
    updatedAt                 = Get-WMTimestamp
}
if ($decisao.notify -and $algumOk) {
    $novoEstado.lastNotifiedDay = $dia
    $novoEstado.lastVerdict     = [string]$achados.verdict
    $novoEstado.lastRuleIds     = @($decisao.ruleIds)
}

$json = ConvertTo-Json -InputObject ([pscustomobject]$novoEstado) -Depth 8
[System.IO.File]::WriteAllText($estadoF, $json, (New-Object System.Text.UTF8Encoding($false)))

# --- saída ---------------------------------------------------------------------
if (-not $decisao.notify) {
    "Sem novidade: $($decisao.detail)"
    "  (para ver o relatório assim mesmo: -DryRun, ou entregar com -Force)"
    if ($PassThru) { $relatorio }
    return
}

$texto
''
'ENTREGA'
foreach ($e in $entregas) {
    "  {0,-10} {1}  {2}" -f $e.channel, $(if ($e.ok) { 'ok     ' } else { 'FALHOU ' }), $e.detail
}

if (-not $algumOk) {
    Write-WMLog -Level error -Source 'report' -Message "nenhum canal entregou o relatório de $dia"
    ''
    'NENHUM CANAL ENTREGOU. O estado não avançou, e a próxima execução tenta de novo.'
}

if ($PassThru) { $relatorio }
