#requires -Version 5.1
<#
    Congela a linha-base — a referência contra a qual toda deriva futura é medida.

    A JANELA É UMA SÓ
    -----------------
    Uma versão anterior media elegibilidade sobre TODOS os agregados já
    existentes e construía o perfil sobre os ÚLTIMOS 14 arquivos brutos. Nada
    garantia que os dois conjuntos se referissem ao mesmo período, e o resultado
    medido foi uma linha-base congelada SEM a faixa de carga alta — a faixa que
    é o motivo de o projeto existir — declarando 80 janelas de evidência.

    Aqui a janela é determinada primeiro, e tanto a elegibilidade quanto o
    perfil saem dela.

    ELEGIBILIDADE
    -------------
    Exige 14 dias E pelo menos 20 janelas de carga alta sustentada, ambos DENTRO
    da janela. As duas condições, não uma: 14 dias de máquina ociosa não
    caracterizam comportamento térmico nenhum, e 20 rajadas em três dias não
    capturam variação de temperatura ambiente ao longo das semanas.

    E o perfil resultante precisa realmente conter a faixa de carga alta. Sem
    ela não há contra o que comparar, e uma linha-base que não serve para
    comparar é pior que nenhuma — porque parece que serve.

    Antes disso o agente responde "ainda não sei", que é honesto.

    REFAZER É MANUAL, E EXIGE MOTIVO
    --------------------------------
    De propósito. Depois de limpar o gabinete, a queda de temperatura é
    INFORMAÇÃO, não ruído a ser absorvido em silêncio por uma janela móvel. Quem
    manda a referência andar é você, dizendo por quê, e a anterior vai para o
    arquivo em vez do lixo.

    Uso:
      .\src\New-Baseline.ps1 -CheckOnly
      .\src\New-Baseline.ps1 -Reason "primeira linha-base"
      .\src\New-Baseline.ps1 -Reason "limpeza do gabinete e troca de pasta"
#>
[CmdletBinding()]
param(
    [string]$Reason,
    [int]$WindowDays = 14,
    [int]$MinDays = 14,
    [int]$MinHighLoadRuns = 20,
    [int]$MinSamplesPerDay = 60,
    [switch]$Force,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'WinMonitor.psm1')        -Force
Import-Module (Join-Path $PSScriptRoot 'WinMonitor.Rollup.psm1') -Force

$cfg     = Get-WMConfig
$rawDir  = Get-WMPath $cfg.paths.patrol
$rollDir = Get-WMPath $cfg.paths.rollup
$baseDir = Confirm-WMDirectory (Get-WMPath $cfg.paths.baseline)

$DAY_RE = '^\d{4}-\d{2}-\d{2}$'
$today  = Get-WMDayId

# ------------------------------------------------------------- a janela -----

if (-not (Test-Path -LiteralPath $rawDir)) {
    Write-Warning "não há dado bruto em $rawDir — a ronda já rodou alguma vez?"
    return
}

# Nome estrito e sem o dia corrente, que ainda está sendo escrito e entraria
# como um dia curto que baixa todas as estatísticas da janela.
$rawFiles = @(
    Get-ChildItem -LiteralPath $rawDir -Filter '*.jsonl' -File |
        Where-Object { $_.BaseName -match $DAY_RE -and $_.BaseName -ne $today } |
        Sort-Object Name
)

if ($rawFiles.Count -eq 0) {
    Write-Warning 'não há nenhum dia completo de ronda ainda.'
    return
}

$window = @($rawFiles | Select-Object -Last $WindowDays)

<#
    O nome NÃO pode ser $windowDays.

    Nomes de variável em PowerShell são case-insensitive, então $windowDays É o
    parâmetro [int]$WindowDays, e atribuir um array a ele lança
    ArgumentTransformationMetadataException e mata o script. Esse defeito
    existiu aqui e ficou invisível porque, sem nenhum dia completo de ronda, a
    execução retornava antes desta linha — o script parecia funcionar
    exatamente porque ainda não havia dado.
#>
$windowIds = @($window | ForEach-Object { $_.BaseName })

# ---------------------------------------------------- elegibilidade ---------

$rollups   = @()
$semRollup = @()
foreach ($d in $windowIds) {
    $p = Join-Path $rollDir "$d.json"
    if (-not (Test-Path -LiteralPath $p)) { $semRollup += $d; continue }
    try {
        $rollups += (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        # Agregado ilegível é lacuna declarada, não dia que some calado.
        $semRollup += $d
        Write-Warning "agregado ilegível e ignorado: $d.json"
    }
}

# Um dia com três amostras não é um dia. Sem este piso, 14 arquivos de uma
# amostra cada passariam na elegibilidade. Agregado marcado como parcial
# também não conta: descreve um dia que ainda não terminou.
$diasValidos = @($rollups | Where-Object { $_.samples -ge $MinSamplesPerDay -and $_.partial -ne $true })

$runs      = 0
$diasSemRun = 0
foreach ($r in $diasValidos) {
    $v = $null
    if ($r.cpu) { $v = $r.cpu.highLoadRuns }
    if ($null -eq $v) { $diasSemRun++; continue }   # nunca medido: não soma como zero
    $runs += [int]$v
}

$okDays = $diasValidos.Count -ge $MinDays
$okRuns = $runs -ge $MinHighLoadRuns

""
"Janela candidata: {0} a {1}  ({2} arquivo(s) bruto(s))" -f $windowIds[0], $windowIds[-1], $window.Count
"Elegibilidade da linha-base — medida DENTRO desta janela"
"  dias com >= {0,4} amostras : {1,4}  / {2}   {3}" -f $MinSamplesPerDay, $diasValidos.Count, $MinDays, $(if ($okDays) { 'ok' } else { 'ainda não' })
"  janelas de carga alta      : {0,4}  / {1}   {2}" -f $runs, $MinHighLoadRuns, $(if ($okRuns) { 'ok' } else { 'ainda não' })
if ($semRollup.Count -gt 0)  { "  dias sem agregado utilizável : {0}" -f ($semRollup -join ', ') }
if ($diasSemRun -gt 0)       { "  dias sem medida de carga     : {0}" -f $diasSemRun }
""

if ($CheckOnly) {
    if ($okDays -and $okRuns) { 'Pronto para congelar a linha-base.' }
    else { 'Ainda não há dado suficiente. Deixe a ronda acumular.' }
    return
}

if (-not ($okDays -and $okRuns) -and -not $Force) {
    Write-Warning @'
Dado insuficiente para uma linha-base honesta.

Congelar agora produziria uma referência que descreve um período curto demais, e
toda comparação futura mediria contra ruído. Deixe a ronda acumular.

Se você tem motivo para forçar mesmo assim (laboratório, teste), use -Force — e
saiba que a referência vai carregar essa fraqueza registrada dentro dela.
'@
    return
}

if ([string]::IsNullOrWhiteSpace($Reason)) {
    Write-Warning 'Informe -Reason. Linha-base sem motivo registrado vira um número órfão que ninguém sabe explicar seis meses depois.'
    return
}

# ------------------------------------------------------------- construção ---

"Recalculando a partir do bruto: {0} dia(s)..." -f $window.Count

$perfil = New-WMDayRollup -Path @($window | ForEach-Object { $_.FullName }) `
                          -DayId ('{0}..{1}' -f $windowIds[0], $windowIds[-1]) `
                          -Bands $cfg.loadBands

if ($null -eq $perfil) {
    Write-Warning 'a janela não produziu nenhuma amostra utilizável'
    return
}

<#
    A recusa que a versão anterior não fazia: sem a faixa de carga alta no
    perfil, não existe contra o que comparar a métrica que mais importa. Uma
    linha-base assim parece funcional e não é.
#>
function Test-FaixaAlta {
    param($Banda)
    # n -gt 0 importa: uma faixa pode existir com n=0 quando houve amostras e
    # nenhuma medida legível. Faixa sem medida não serve de referência.
    ($null -ne $Banda) -and ($null -ne $Banda['b75']) -and ([int]$Banda['b75'].n -gt 0)
}

$temFaixaAlta = $false
$motivoFalta  = ''

$gpusSemRef = @()

if ($perfil.gpu -and $perfil.gpu.Count -gt 0) {
    <#
        Havendo GPU, a referência térmica de GPU é obrigatória — o b75 da CPU
        não substitui. Uma versão anterior aceitava esse atalho e congelava uma
        linha-base cuja GPU só tinha a faixa ociosa.

        Mas exigir a faixa alta de TODAS as placas é estrito demais e cria um
        impasse permanente: uma integrada, uma placa só de vídeo ou uma
        secundária ociosa nunca passa de 75%, e a linha-base ficaria impossível
        numa máquina cuja GPU principal tem a referência completa.

        Basta UMA com referência. As demais ficam registradas em
        evidence.gpusWithoutReference, para a camada de parecer saber que não
        tem contra o que comparar aquelas — em vez de descobrir isso tarde e
        comparar contra nada.
    #>
    $comB75 = @()
    foreach ($idx in $perfil.gpu.Keys) {
        if (Test-FaixaAlta $perfil.gpu[$idx].tempCByLoad) { $comB75 += $idx } else { $gpusSemRef += $idx }
    }
    $temFaixaAlta = ($comB75.Count -gt 0)
    if (-not $temFaixaAlta) {
        $motivoFalta = "nenhuma GPU tem medida de temperatura na faixa de carga alta"
    }
} elseif (Test-FaixaAlta $perfil.cpu.mhzByLoad) {
    $temFaixaAlta = $true
} else {
    $motivoFalta = 'não há nenhuma amostra medida na faixa de carga alta'
}

if (-not $temFaixaAlta) {
    Write-Warning @"
Linha-base recusada: $motivoFalta.

Ela existe para comparar comportamento sob carga contra a mesma carga meses
depois. Sem a faixa de 75-100% medida, não há contra o que comparar — e uma
linha-base assim pareceria funcional e falharia calada na primeira comparação.

Deixe a máquina trabalhar e a ronda acumular.
"@
    return
}

if ($window.Count -lt $WindowDays) {
    Write-Warning ("a janela tem {0} dia(s), menos que os {1} pedidos — só há isso de bruto disponível." -f $window.Count, $WindowDays)
}

$baseline = [ordered]@{
    v         = 2
    createdAt = Get-WMTimestamp
    reason    = $Reason
    forced    = [bool]($Force -and -not ($okDays -and $okRuns))
    window    = [ordered]@{
        from  = $windowIds[0]
        to    = $windowIds[-1]
        days  = $window.Count
        # Os dias exatos ficam gravados: sem isso, ninguém consegue conferir
        # depois se a evidência descrevia mesmo o período congelado.
        dayList = $windowIds
    }
    evidence  = [ordered]@{
        validDays        = $diasValidos.Count
        highLoadRuns     = $runs
        daysWithoutRollup = $semRollup
        minSamplesPerDay = $MinSamplesPerDay
        # GPUs que nunca chegaram à faixa de carga alta nesta janela: ficam sem
        # referência térmica, e quem for comparar precisa saber disso.
        gpusWithoutReference = $gpusSemRef
    }
    profile   = $perfil
}

# ------------------------------------------------------------- gravação -----

$target = Join-Path $baseDir 'baseline.json'

# A anterior vai para o arquivo, nunca para o lixo: a sequência de referências
# ao longo do tempo é ela própria um registro de manutenção da máquina.
if (Test-Path -LiteralPath $target) {
    $archDir = Confirm-WMDirectory (Join-Path $baseDir 'archive')
    $stamp   = (Get-Date).ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    Move-Item -LiteralPath $target -Destination (Join-Path $archDir "baseline-$stamp.json") -Force
    "linha-base anterior arquivada em baseline\archive\baseline-$stamp.json"
}

$json = ConvertTo-Json -InputObject ([pscustomobject]$baseline) -Depth 14
[System.IO.File]::WriteAllText($target, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-WMLog -Source 'baseline' -Message "linha-base congelada ($($windowIds[0])..$($windowIds[-1])): $Reason"

""
"Linha-base congelada."
"  janela  : {0} a {1}  ({2} dia(s), {3} amostras)" -f $baseline.window.from, $baseline.window.to, $baseline.window.days, $perfil.samples
"  carga   : {0} janela(s) de carga alta na evidência" -f $runs
"  motivo  : $Reason"
"  arquivo : $target"
if ($gpusSemRef.Count -gt 0) {
    Write-Warning ("GPU(s) [{0}] nunca passaram de 75% de carga nesta janela e ficaram SEM referência térmica. Comparações futuras não terão contra o que medi-las. Registrado em evidence.gpusWithoutReference." -f ($gpusSemRef -join ', '))
}
if ($baseline.forced) { Write-Warning 'Congelada com -Force sobre dado insuficiente. A referência carrega essa fraqueza, registrada em forced=true.' }
