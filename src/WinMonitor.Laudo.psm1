#requires -Version 5.1
<#
    WinMonitor — camada de parecer, parte determinística.

    Este módulo NÃO fala com modelo nenhum. Ele faz as duas coisas que precisam
    ser verificáveis sem depender de julgamento:

      1. MONTA o pacote fechado que o modelo recebe.
      2. CONFERE o laudo que o modelo devolve.

    O PACOTE É FECHADO DE PROPÓSITO
    -------------------------------
    O modelo não recebe acesso à máquina, nem ao agregado bruto, nem à tabela de
    limiares. Recebe os Achados, as fatias de série relacionadas a eles, o bloco
    de cobertura e as conclusões do laudo anterior. Ele não pode discutir o que
    não está no pacote — e o que não está no pacote ele não tem como inventar
    com aparência de dado.

    A CONFERÊNCIA NÃO PRECISA DE MODELO
    -----------------------------------
    A defesa mais forte contra número inventado é aritmética, não julgamento:
    extrai-se todo número do texto do laudo e confere-se cada um contra o
    conjunto de valores que o pacote continha. Número órfão é fabricação, e isso
    é regex e teoria dos conjuntos — roda de graça, roda sempre, e não depende de
    um segundo modelo concordar.

    Um verificador adversarial por modelo continua valendo para as afirmações
    semânticas, mas ele é a segunda linha. Esta é a primeira.
#>

Set-StrictMode -Off

# ------------------------------------------------------------- pacote -------

<#
    Monta o pacote de entrada do parecer.

    -Findings   saída de Invoke-WMRules (achados + cobertura + veredito)
    -Rollup     o agregado do dia, para extrair só as fatias citadas
    -Baseline   a linha-base, idem
    -Previous   o laudo anterior, para dar continuidade
    -Hardware   fatos estáticos da máquina

    Só entram no pacote as séries REFERENCIADAS por algum achado. Despejar o
    agregado inteiro daria ao modelo material para correlacionar coisas que
    nenhuma regra examinou — e o laudo passaria a discutir o que não foi
    verificado.
#>
function New-WMLaudoPackage {
    param(
        [Parameter(Mandatory)]$Findings,
        $Rollup,
        $Baseline,
        $Previous,
        $Hardware
    )

    $pacote = [ordered]@{
        v       = 1
        window  = $Findings.window
        host    = $Findings.host
        verdict = $Findings.verdict
    }

    # --- hardware: só o que ajuda a explicar, nada de identificação ---------
    if ($Hardware) {
        $hw = [ordered]@{}
        foreach ($c in 'os', 'cpuName', 'cpuCores', 'cpuThreads', 'cpuBaseMHz', 'memTotalMB') {
            if ($null -ne $Hardware.$c) { $hw[$c] = $Hardware.$c }
        }
        if ($Hardware.gpuNames) { $hw.gpus = @($Hardware.gpuNames) }
        if ($Hardware.disks)    { $hw.disks = @($Hardware.disks) }
        if ($hw.Count -gt 0)    { $pacote.hardware = $hw }
    }

    $pacote.findings = @($Findings.findings)
    $pacote.coverage = $Findings.coverage

    <#
        Continuidade. Sem isto o parecer não consegue dizer "isto já foi
        apontado há dois meses e piorou" — frase que nenhum retrato instantâneo
        produz, e que costuma ser a informação mais útil do laudo.
    #>
    if ($Previous) {
        $pacote.previous = [ordered]@{
            window   = $Previous.window
            verdict  = $Previous.verdict
            ruleIds  = @($Previous.findings | ForEach-Object { $_.ruleId } | Sort-Object -Unique)
            summary  = $Previous.summary
        }
    }

    # --- séries: só as citadas pelos achados --------------------------------
    $series = [ordered]@{}
    foreach ($a in @($Findings.findings)) {
        foreach ($e in @($a.evidence)) {
            if ($null -eq $e.metric) { continue }
            if ($series.Contains($e.metric)) { continue }
            $series[$e.metric] = [ordered]@{
                today    = $e.value
                baseline = $null
            }
        }
    }
    # Preenche a coluna da linha-base quando a métrica existe lá.
    if ($Baseline -and $Baseline.profile) {
        foreach ($m in @($series.Keys)) {
            $b = @(Resolve-WMMetric -Root $Baseline.profile -Path $m)
            if ($b.Count -gt 0) { $series[$m].baseline = (ConvertTo-WMNumber $b[0].value) }
        }
    }
    if ($series.Count -gt 0) { $pacote.series = $series }

    [pscustomobject]$pacote
}

# ------------------------------------------- conferência determinística -----

<#
    Extrai os números "permitidos" de um pacote: tudo que o laudo pode
    legitimamente citar.

    Inclui valores de evidência, limiares, séries, e as CONTAGENS derivadas —
    quantidade de achados, de regras não avaliadas, de itens por severidade.
    Sem as contagens, uma frase correta como "três achados" seria acusada de
    fabricação.
#>
function Get-WMAllowedNumbers {
    param([Parameter(Mandatory)]$Package)

    $set = New-Object System.Collections.Generic.HashSet[double]
    function Add-N { param($v) $n = ConvertTo-WMNumber $v; if ($null -ne $n) { [void]$set.Add([double]$n) } }

    foreach ($a in @($Package.findings)) {
        Add-N $a.rule.threshold
        foreach ($e in @($a.evidence)) { Add-N $e.value }
    }

    if ($Package.series) {
        foreach ($k in (Get-WMNodeKeys $Package.series)) {
            $s = Get-WMNodeChild $Package.series $k
            Add-N $s.today
            Add-N $s.baseline
        }
    }

    if ($Package.hardware) {
        foreach ($k in (Get-WMNodeKeys $Package.hardware)) { Add-N (Get-WMNodeChild $Package.hardware $k) }
    }

    # --- contagens derivadas -------------------------------------------------
    $achados = @($Package.findings)
    Add-N $achados.Count
    $porSeveridade = @{}
    foreach ($a in $achados) {
        $s = [string]$a.severity
        if (-not $porSeveridade.ContainsKey($s)) { $porSeveridade[$s] = 0 }
        $porSeveridade[$s]++
    }
    foreach ($v in $porSeveridade.Values) { Add-N $v }

    if ($Package.coverage) {
        Add-N @($Package.coverage.evaluated).Count
        foreach ($b in 'unsourced', 'malformed', 'noData', 'noBaseline', 'notApplicable') {
            $bloco = Get-WMNodeChild $Package.coverage $b
            Add-N @(Get-WMNodeKeys $bloco).Count
        }
        # Total de regras: avaliadas + todas as lacunas.
        $total = @($Package.coverage.evaluated).Count
        foreach ($b in 'unsourced', 'malformed', 'noData', 'noBaseline', 'notApplicable') {
            $total += @(Get-WMNodeKeys (Get-WMNodeChild $Package.coverage $b)).Count
        }
        Add-N $total
    }

    # Números que qualquer texto em português usa sem estar citando medida.
    foreach ($n in 0, 1, 2) { [void]$set.Add([double]$n) }

    $set
}

<#
    Confere que todo número do laudo aparece no pacote.

    Tokens que contêm dígito mas NÃO são medida — caminhos de métrica
    (gpu.0.tempCByLoad.b75.p95), identificadores de regra (R-GPU-TEMP-SPEC-3080),
    datas (2026-08-14) — são removidos do texto ANTES da extração. Sem isso,
    citar corretamente o nome de uma regra seria acusado de inventar número.

    Tolerância: o modelo pode arredondar 86,3 para 86 ao escrever. Um número do
    texto é aceito se algum permitido casar dentro da tolerância relativa OU se
    for o arredondamento de um permitido.
#>
function Test-WMLaudoNumbers {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)]$Package,
        [double]$Tolerance = 0.05
    )

    $permitidos = Get-WMAllowedNumbers -Package $Package

    # --- remove tokens que carregam dígito sem ser medida -------------------
    $limpo = $Text

    $literais = New-Object System.Collections.ArrayList
    foreach ($a in @($Package.findings)) {
        [void]$literais.Add([string]$a.ruleId)
        [void]$literais.Add([string]$a.id)
        foreach ($e in @($a.evidence)) { [void]$literais.Add([string]$e.metric) }
    }
    if ($Package.series)  { foreach ($k in (Get-WMNodeKeys $Package.series)) { [void]$literais.Add([string]$k) } }
    if ($Package.coverage) {
        foreach ($b in 'unsourced', 'malformed', 'noData', 'noBaseline', 'notApplicable') {
            foreach ($k in (Get-WMNodeKeys (Get-WMNodeChild $Package.coverage $b))) { [void]$literais.Add([string]$k) }
        }
        foreach ($k in @($Package.coverage.evaluated)) { [void]$literais.Add([string]$k) }
    }
    [void]$literais.Add([string]$Package.window)
    if ($Package.previous) { [void]$literais.Add([string]$Package.previous.window) }
    if ($Package.hardware -and $Package.hardware.gpus)  { foreach ($g in @($Package.hardware.gpus))  { [void]$literais.Add([string]$g) } }
    if ($Package.hardware -and $Package.hardware.disks) { foreach ($d in @($Package.hardware.disks)) { [void]$literais.Add([string]$d.name) } }
    if ($Package.hardware -and $Package.hardware.cpuName) { [void]$literais.Add([string]$Package.hardware.cpuName) }

    # Do mais longo para o mais curto: senão um prefixo come o token maior.
    foreach ($lit in (@($literais | Where-Object { $_ }) | Sort-Object { $_.Length } -Descending)) {
        $limpo = $limpo.Replace($lit, ' ')
    }
    # Datas e horas em qualquer formato ISO.
    $limpo = [regex]::Replace($limpo, '\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2})?)?', ' ')

    # --- extrai e confere ---------------------------------------------------
    $orfaos = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($limpo, '\d+(?:[.,]\d+)?')) {
        $n = ConvertTo-WMNumber ($m.Value -replace ',', '.')
        if ($null -eq $n) { continue }

        $ok = $false
        foreach ($p in $permitidos) {
            if ($p -eq $n) { $ok = $true; break }
            $margem = [math]::Max([math]::Abs($p) * $Tolerance, 0.5)
            if ([math]::Abs($p - $n) -le $margem) { $ok = $true; break }
        }
        if (-not $ok -and -not $orfaos.Contains($m.Value)) { [void]$orfaos.Add($m.Value) }
    }

    [pscustomobject]@{
        ok       = ($orfaos.Count -eq 0)
        orphans  = @($orfaos)
        allowed  = @($permitidos | Sort-Object)
    }
}

<#
    Confere que o laudo só discute Achados que existem.

    O parecer pode acrescentar OBSERVAÇÕES — hipóteses explicitamente rotuladas
    como não verificadas, em seção separada. O que ele não pode é apresentar
    hipótese como achado. Esta função procura menções a identificadores de regra
    que não estão no pacote.
#>
function Test-WMLaudoRuleIds {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)]$Package
    )

    $conhecidos = New-Object System.Collections.Generic.HashSet[string]
    foreach ($a in @($Package.findings)) { [void]$conhecidos.Add([string]$a.ruleId) }
    if ($Package.coverage) {
        foreach ($b in 'unsourced', 'malformed', 'noData', 'noBaseline', 'notApplicable') {
            foreach ($k in (Get-WMNodeKeys (Get-WMNodeChild $Package.coverage $b))) {
                [void]$conhecidos.Add(([string]$k -split '#')[0])
            }
        }
        foreach ($k in @($Package.coverage.evaluated)) { [void]$conhecidos.Add([string]$k) }
    }

    $inventados = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($Text, '\bR-[A-Z0-9-]{2,}\b')) {
        $id = $m.Value.TrimEnd('-')
        if (-not $conhecidos.Contains($id) -and -not $inventados.Contains($id)) { [void]$inventados.Add($id) }
    }

    [pscustomobject]@{
        ok       = ($inventados.Count -eq 0)
        invented = @($inventados)
        known    = @($conhecidos | Sort-Object)
    }
}

Export-ModuleMember -Function `
    New-WMLaudoPackage, Get-WMAllowedNumbers, Test-WMLaudoNumbers, Test-WMLaudoRuleIds
