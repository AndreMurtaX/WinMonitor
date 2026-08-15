#requires -Version 5.1
<#
    WinMonitor — relatório de tendência e decisão de notificação.

    Determinístico inteiro. Nenhum modelo participa: o que decide se você é
    incomodado é código que você pode ler, não julgamento de LLM.

    O PROBLEMA QUE ESTA CAMADA RESOLVE
    ----------------------------------
    Um monitor que só fala quando há problema é indistinguível de um monitor
    morto. Três semanas de silêncio significam "máquina saudável" ou "o agente
    parou de rodar em 12 de julho e ninguém percebeu"? As duas hipóteses
    produzem exatamente a mesma caixa de entrada vazia.

    Por isso há duas obrigações que valem mesmo quando não há nada de errado:

      1. PULSO. Passados heartbeatDays sem notificação nenhuma, o relatório sai
         assim mesmo, dizendo que nada mereceu atenção. Silêncio deixa de ser
         ambíguo porque silêncio deixa de existir.

      2. SAÚDE DA PRÓPRIA COLETA. Antes de qualquer conclusão sobre a máquina,
         confere-se se a ronda realmente rodou. Um veredito "normal" calculado
         sobre dado de anteontem não é uma boa notícia — é uma notícia falsa, e
         a mais perigosa que este projeto pode dar.

    O terceiro caso, mais sutil: a cobertura pode ficar incompleta por muitos
    dias seguidos sem nenhum achado. O sistema está parcialmente cego e o
    veredito continua saindo "normal", que é verdade sobre o que foi medido e
    silêncio sobre o que não foi. Isso também vira notificação.
#>

Set-StrictMode -Off

<#
    A ronda rodou mesmo?

    Compara as amostras que existem contra as que deveriam existir, dado o
    intervalo configurado. Devolve o atraso da amostra mais recente, que é o
    número que responde "este dado é de agora ou de anteontem?".

    -NowUtc entra por parâmetro em vez de sair de Get-Date porque isto precisa
    ser testável sem esperar o relógio.
#>
function Get-WMCollectionHealth {
    param(
        [Parameter(Mandatory)][string]$PatrolDir,
        [int]$IntervalMinutes = 1,
        [int]$StaleAfterMinutes = 30,
        [datetime]$NowUtc = [datetime]::UtcNow
    )

    $saude = [ordered]@{
        ok               = $false
        reason           = $null
        lastSampleAt     = $null
        minutesSinceLast = $null
        daysPresent      = 0
        expectedPerDay   = [int](1440 / [Math]::Max(1, $IntervalMinutes))
        lastDaySamples   = 0
        lastDayCoverage  = $null
    }

    if (-not (Test-Path -LiteralPath $PatrolDir)) {
        $saude.reason = 'o diretório da ronda não existe: nenhuma coleta jamais rodou'
        return [pscustomobject]$saude
    }

    $dias = @(
        Get-ChildItem -LiteralPath $PatrolDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match '^\d{4}-\d{2}-\d{2}$' } |
            Sort-Object Name
    )
    $saude.daysPresent = $dias.Count

    if ($dias.Count -eq 0) {
        $saude.reason = 'nenhum arquivo de ronda: a coleta nunca produziu amostra'
        return [pscustomobject]$saude
    }

    $ultimo = $dias[-1]
    $linhas = @(Get-Content -LiteralPath $ultimo.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
    $saude.lastDaySamples = $linhas.Count

    <#
        A última amostra vem da última linha PARSEÁVEL, varrendo de trás para
        frente. Usar só a última linha do arquivo daria erro justamente no caso
        em que o processo morreu no meio da escrita — que é exatamente o caso
        que esta função existe para detectar.
    #>
    $ultimaAt = $null
    for ($i = $linhas.Count - 1; $i -ge 0; $i--) {
        $l = $linhas[$i]
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        try { $o = $l | ConvertFrom-Json } catch { continue }
        if ($o -and $o.at) {
            $dt = [datetime]::MinValue
            $estilo = [System.Globalization.DateTimeStyles]::RoundtripKind
            if ([datetime]::TryParse([string]$o.at, [System.Globalization.CultureInfo]::InvariantCulture, $estilo, [ref]$dt)) {
                $ultimaAt = $dt.ToUniversalTime()
                break
            }
        }
    }

    if ($null -eq $ultimaAt) {
        $saude.reason = "o último arquivo de ronda ($($ultimo.BaseName)) não tem nenhuma amostra legível"
        return [pscustomobject]$saude
    }

    $saude.lastSampleAt     = $ultimaAt.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    $atraso                 = [Math]::Round(($NowUtc - $ultimaAt).TotalMinutes, 1)
    $saude.minutesSinceLast = $atraso

    if ($saude.expectedPerDay -gt 0) {
        $saude.lastDayCoverage = [Math]::Round(100.0 * $linhas.Count / $saude.expectedPerDay, 1)
    }

    if ($atraso -gt $StaleAfterMinutes) {
        $saude.reason = ("a ronda não produz amostra há {0} min (limite: {1} min). " -f $atraso, $StaleAfterMinutes) +
                        'Qualquer veredito abaixo foi calculado sobre dado velho.'
        return [pscustomobject]$saude
    }

    $saude.ok = $true
    [pscustomobject]$saude
}

<#
    Tendência: o valor de hoje contra a linha-base, métrica por métrica, faixa
    por faixa.

    É o único lugar do projeto onde "39 °C" vira informação, porque só aqui ele
    aparece ao lado do "31 °C na mesma carga, há três meses" que lhe dá sentido.

    Sem linha-base, devolve a lista do que SERÁ comparado quando ela existir —
    e não uma tabela vazia. A diferença importa: tabela vazia parece "nada a
    relatar"; a lista declarada diz "ainda não sei, e é isto que vou saber".
#>
function New-WMTrend {
    param(
        <#
            NÃO é obrigatório, e isso foi um defeito encontrado por teste: com
            -Rollup marcado como Mandatory, um dia sem agregado derrubava o
            driver inteiro com erro de ligação de parâmetro. Sem relatório e sem
            notificação — o monitor emudecia por causa de um arquivo faltando,
            que é precisamente o modo de falha que esta fase existe para
            eliminar. Agregado ausente vira tabela de 'semDado', não exceção.
        #>
        $Rollup,
        $Baseline,
        [string[]]$Metrics = @(
            'gpu.*.tempCByLoad.b75.p95',
            'gpu.*.tempCByLoad.b00.p95',
            'gpu.*.fanPctByLoad.b75.p95',
            'cpu.mhzByLoad.b75.p50',
            'cpu.tempCByLoad.b75.p95',
            'mem.commitPct.p95'
        )
    )

    $linhas = New-Object System.Collections.ArrayList
    $temBase = ($Baseline -and $Baseline.profile)

    foreach ($padrao in $Metrics) {
        $hoje = @(Resolve-WMMetric -Root $Rollup -Path $padrao)

        <#
            Quando o curinga não casa nada no agregado de hoje, ainda assim há
            algo a dizer: a métrica está prevista e não veio. Some-la da tabela
            seria transformar ausência em silêncio — o erro que este projeto
            combate em todas as camadas.
        #>
        if ($hoje.Count -eq 0) {
            [void]$linhas.Add([pscustomobject][ordered]@{
                metric   = $padrao
                today    = $null
                baseline = $null
                delta    = $null
                state    = 'semDado'
            })
            continue
        }

        foreach ($h in $hoje) {
            $vHoje = ConvertTo-WMNumber $h.value
            $vBase = $null
            if ($temBase) {
                $b = @(Resolve-WMMetric -Root $Baseline.profile -Path $h.path)
                if ($b.Count -gt 0) { $vBase = ConvertTo-WMNumber $b[0].value }
            }

            $estado = 'comparado'
            $delta  = $null
            if ($null -eq $vHoje)      { $estado = 'semDado' }
            elseif (-not $temBase)     { $estado = 'semLinhaBase' }
            elseif ($null -eq $vBase)  { $estado = 'semLinhaBase' }
            else                       { $delta  = Get-WMRound ($vHoje - $vBase) 2 }

            [void]$linhas.Add([pscustomobject][ordered]@{
                metric   = $h.path
                today    = $vHoje
                baseline = $vBase
                delta    = $delta
                state    = $estado
            })
        }
    }

    [pscustomobject][ordered]@{
        hasBaseline    = [bool]$temBase
        baselineWindow = $(if ($temBase) { $Baseline.window } else { $null })
        rows           = @($linhas)
    }
}

<#
    A decisão de incomodar alguém.

    Regras, em ordem de prioridade. A primeira que casar decide, e a razão fica
    registrada no relatório — quem recebe precisa saber POR QUE recebeu.

    O anti-repetição é deliberadamente frouxo num ponto: 'agir' que persiste
    volta a notificar depois de repeatDays. Um problema que continua não deixa
    de ser problema porque já foi anunciado uma vez, e silenciar o segundo aviso
    é como desligar o alarme de incêndio porque ele já tocou.
#>
function Test-WMShouldNotify {
    param(
        [Parameter(Mandatory)]$Findings,
        $Health,
        $State,
        [int]$HeartbeatDays = 7,
        [int]$RepeatDays = 1,
        [int]$BlindDays = 3,
        [Parameter(Mandatory)][string]$Today
    )

    $regras = @($Findings.findings | ForEach-Object { [string]$_.ruleId } | Sort-Object -Unique)
    $antes  = @()
    if ($State -and $State.lastRuleIds) { $antes = @($State.lastRuleIds | ForEach-Object { [string]$_ }) }

    $novas = @($regras | Where-Object { $antes -notcontains $_ })
    $desde = Get-WMDaysBetween -From $State.lastNotifiedDay -To $Today

    # 1. A coleta parou. Vem antes de tudo: sem ela nada abaixo é confiável.
    if ($Health -and -not $Health.ok) {
        return (New-WMNotifyDecision $true 'coleta' $Health.reason $regras)
    }

    # 2. Achado novo, de qualquer severidade.
    if ($novas.Count -gt 0) {
        return (New-WMNotifyDecision $true 'achadoNovo' ("apareceu o que não havia antes: " + ($novas -join ', ')) $regras)
    }

    # 3. Veredito piorou.
    $ordem = @{ 'normal' = 0; 'observar' = 1; 'agir' = 2 }
    $vAgora = [string]$Findings.verdict
    $vAntes = [string]$State.lastVerdict
    if ($ordem.ContainsKey($vAgora) -and $ordem.ContainsKey($vAntes) -and $ordem[$vAgora] -gt $ordem[$vAntes]) {
        return (New-WMNotifyDecision $true 'piorou' "o veredito passou de $vAntes para $vAgora" $regras)
    }

    # 4. Problema que continua: reavisa passados RepeatDays.
    if ($regras.Count -gt 0 -and ($null -eq $desde -or $desde -ge $RepeatDays)) {
        return (New-WMNotifyDecision $true 'persiste' "os mesmos achados continuam: $($regras -join ', ')" $regras)
    }

    # 5. Cego há muitos dias seguidos, mesmo sem nenhum achado.
    $cego = [int]$State.consecutiveIncompleteDays
    if ($Findings.coverage -and -not $Findings.coverage.complete -and $cego -ge $BlindDays) {
        return (New-WMNotifyDecision $true 'cego' "a cobertura está incompleta há $cego dias seguidos; o veredito é sobre o que foi medido, não sobre a máquina" $regras)
    }

    # 6. Pulso: silêncio nunca pode virar ambiguidade.
    if ($null -eq $desde -or $desde -ge $HeartbeatDays) {
        return (New-WMNotifyDecision $true 'pulso' "sem notificação há $(if ($null -eq $desde) { 'sempre' } else { "$desde dias" }); este aviso existe para você saber que o monitor continua vivo" $regras)
    }

    New-WMNotifyDecision $false 'nadaNovo' "nada mudou desde o último aviso, há $desde dias" $regras
}

function New-WMNotifyDecision {
    param([bool]$Notify, [string]$Reason, [string]$Detail, [string[]]$RuleIds)
    [pscustomobject][ordered]@{
        notify  = $Notify
        reason  = $Reason
        detail  = $Detail
        ruleIds = @($RuleIds)
    }
}

<#
    Diferença em dias entre dois identificadores AAAA-MM-DD.

    Parse invariante e explícito. Em pt-BR, ler '2026-08-15' com a cultura do
    sistema já mordeu este projeto três vezes — e num calendário tailandês o
    mesmo texto vira 2569. Devolve $null quando não dá para saber, e $null aqui
    significa "nunca notificado", que os chamadores tratam como "notifique".
#>
function Get-WMDaysBetween {
    param([string]$From, [string]$To)
    if ([string]::IsNullOrWhiteSpace($From) -or [string]::IsNullOrWhiteSpace($To)) { return $null }
    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    $estilo = [System.Globalization.DateTimeStyles]::None
    $a = [datetime]::MinValue; $b = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($From, 'yyyy-MM-dd', $ci, $estilo, [ref]$a)) { return $null }
    if (-not [datetime]::TryParseExact($To,   'yyyy-MM-dd', $ci, $estilo, [ref]$b)) { return $null }
    [int]($b - $a).TotalDays
}

<#
    O relatório completo, em texto puro.

    Texto e não HTML porque isto precisa caber num corpo de e-mail, num Telegram
    e num terminal sem virar sopa de tag. E porque o conteúdo é curto: se o
    relatório precisar de formatação para ser legível, ele está longo demais.
#>
<#
    Número para o texto, SEMPRE com ponto decimal.

    O operador -f formata com a cultura corrente, então em pt-BR 48.2 sai como
    "48,2". Parece detalhe estético e não é: o relatório deixa de bater com o
    JSON de onde veio, quem copiar o valor e procurar no agregado não acha nada,
    e o mesmo comando passa a imprimir texto diferente em máquinas de idiomas
    diferentes. É a mesma armadilha de cultura que já mordeu a leitura das
    sondas e a montagem dos nomes de arquivo, agora na saída.
#>
function Format-WMNumber {
    param($Value)
    if ($null -eq $Value) { return '(sem dado)' }
    $n = ConvertTo-WMNumber $Value
    if ($null -eq $n) { return [string]$Value }
    ([double]$n).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-WMReportText {
    param([Parameter(Mandatory)]$Report)

    $l = New-Object System.Collections.ArrayList
    $add = { param($t) [void]$l.Add($t) }

    & $add ("WinMonitor — {0} — {1}" -f $Report.host, $Report.window)
    & $add ("=" * 60)
    & $add ''

    if (-not $Report.health.ok) {
        & $add 'ATENÇÃO — A COLETA NÃO ESTÁ SAUDÁVEL'
        & $add ("  {0}" -f $Report.health.reason)
        & $add ''
    }

    & $add ("Veredito : {0}" -f $Report.verdict)
    & $add ("Cobertura: {0}" -f $(if ($Report.coverageComplete) { 'completa' } else { 'INCOMPLETA' }))
    & $add ("Motivo do aviso: {0} — {1}" -f $Report.decision.reason, $Report.decision.detail)
    & $add ''

    if (@($Report.findings).Count -gt 0) {
        & $add 'ACHADOS'
        foreach ($a in @($Report.findings)) {
            & $add ("  [{0,-8}] {1}" -f $a.severity, $a.claim)
            foreach ($e in @($a.evidence)) {
                & $add ("             {0} = {1}  ({2})" -f $e.metric, (Format-WMNumber $e.value), $e.from)
            }
        }
        & $add ''
    } else {
        & $add 'ACHADOS: nenhum.'
        & $add '  Isto vale para o que foi medido. Veja abaixo o que não foi.'
        & $add ''
    }

    & $add 'TENDÊNCIA'
    if (-not $Report.trend.hasBaseline) {
        & $add '  Ainda não há linha-base congelada, então não há contra o que comparar.'
        & $add '  Estas são as métricas que serão comparadas quando ela existir:'
        foreach ($r in @($Report.trend.rows)) {
            & $add ("    {0,-40} hoje: {1}" -f $r.metric, (Format-WMNumber $r.today))
        }
    } else {
        & $add ("  linha-base de {0}" -f $Report.trend.baselineWindow)
        foreach ($r in @($Report.trend.rows)) {
            if ($r.state -eq 'comparado') {
                $seta = if ($r.delta -gt 0) { '+' } else { '' }
                & $add ("    {0,-40} {1,8} <- {2,8}   ({3}{4})" -f $r.metric,
                        (Format-WMNumber $r.today), (Format-WMNumber $r.baseline), $seta, (Format-WMNumber $r.delta))
            } else {
                & $add ("    {0,-40} {1}" -f $r.metric, $r.state)
            }
        }
    }
    & $add ''

    if (@($Report.notVerified).Count -gt 0) {
        & $add 'NÃO VERIFICADO'
        foreach ($n in @($Report.notVerified)) { & $add ("  - {0}" -f $n) }
        & $add ''
    }

    & $add ("gerado em {0}" -f $Report.madeAt)
    $l -join "`r`n"
}

Export-ModuleMember -Function `
    Get-WMCollectionHealth, New-WMTrend, Test-WMShouldNotify, New-WMNotifyDecision,
    Get-WMDaysBetween, Format-WMNumber, Format-WMReportText
