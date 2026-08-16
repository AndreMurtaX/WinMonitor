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

    O QUE DECIDE é o atraso da amostra mais recente: o número que responde
    "este dado é de agora ou de anteontem?". A cobertura do dia — amostras que
    existem contra as que deveriam existir — é CALCULADA E DECLARADA, e
    deliberadamente não decide sozinha: um dia com poucas amostras pode ser um
    dia em que a máquina passou desligada, e chamar isso de coleta doente seria
    alarme falso diário.

    O comentário anterior dizia que a função "compara as amostras que existem
    contra as que deveriam existir", como se a comparação valesse alguma coisa
    na decisão. Ela não valia: era calculada e descartada. Agora está dito o que
    ela é — informação para quem lê o relatório — e ela aparece na razão quando
    é gritante o bastante para importar.

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
        expectedSoFar    = $null
        futureStampMin   = $null
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
    $ultimaAt  = $null
    $carimbos  = New-Object System.Collections.ArrayList
    for ($i = $linhas.Count - 1; $i -ge 0; $i--) {
        $l = $linhas[$i]
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        try { $o = $l | ConvertFrom-Json } catch { continue }
        if ($o -and $o.at) {
            $dt = [datetime]::MinValue
            $estilo = [System.Globalization.DateTimeStyles]::RoundtripKind
            if ([datetime]::TryParse([string]$o.at, [System.Globalization.CultureInfo]::InvariantCulture, $estilo, [ref]$dt)) {
                $utc = $dt.ToUniversalTime()
                [void]$carimbos.Add($utc)
                if ($null -eq $ultimaAt) { $ultimaAt = $utc }
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

    <#
        A COBERTURA É CONTRA O DIA DECORRIDO, não contra o dia inteiro.

        Comparar com 1440 amostras enquanto o dia ainda está no começo declara
        escassez numa máquina perfeitamente saudável: medido, às 01:00 dá 4,2%,
        às 03:00 dá 12,5%, e só depois das 06:00 a afirmação deixa de ser falsa.
        Uma ressalva que aparece todo dia de madrugada é ruído, e ruído é o que
        faz alguém parar de ler.
    #>
    <#
        O DIA DECORRIDO É O DIA LOCAL, porque o arquivo é nomeado em hora local.

        A primeira versão media o decorrido em UTC contra um arquivo cujo nome
        vem de Get-WMDayId, que usa hora LOCAL. Em UTC-3, com a ronda sem perder
        uma única amostra, o resultado medido:

            00:30 local   30 amostras, 210 "esperadas"  ->  14,3%  ressalva FALSA
            22:30 local  1350 amostras,  90 "esperadas"  -> 1500%

        Falso nas duas pontas: de madrugada acusa escassez que não existe, e das
        21h à meia-noite o denominador desaba e a escassez REAL não tem como
        disparar. A janela de alarme falso caiu de 6 h para 1 h — magnitude
        menor, mesma classe. É o critério com que eu mesmo reprovei outro
        defeito, aplicado a este.

        O teste não pegou porque a fixture escrevia 'at' em Z e nomeava o
        arquivo pelo dia UTC — forma que o coletor NUNCA produz. Mecânica certa
        sobre dado falso.

        E a comparação só faz sentido se o arquivo for o de HOJE: comparar o
        arquivo de ontem com o relógio de agora produzia percentual sem
        significado.
    #>
    if ($saude.expectedPerDay -gt 0) {
        $agoraLocal = $NowUtc.ToLocalTime()
        $ehHoje = ($ultimo.BaseName -eq $agoraLocal.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture))

        if ($ehHoje) {
            $minutosDoDia      = [Math]::Max(1.0, ($agoraLocal - $agoraLocal.Date).TotalMinutes)
            $esperadasAteAgora = [Math]::Max(1.0, $minutosDoDia / [Math]::Max(1, $IntervalMinutes))
            $saude.expectedSoFar   = [int]$esperadasAteAgora
            $saude.lastDayCoverage = Get-WMRound (100.0 * $linhas.Count / $esperadasAteAgora) 1
        } else {
            # Dia fechado: o denominador é o dia inteiro, não o relógio de agora.
            $saude.expectedSoFar   = [int]$saude.expectedPerDay
            $saude.lastDayCoverage = Get-WMRound (100.0 * $linhas.Count / $saude.expectedPerDay) 1
        }
    }

    <#
        AMOSTRA NO FUTURO TAMBÉM É COLETA DOENTE, e não é hipótese: relógio
        corrigido para trás por NTP, retomada de suspensão e restauração de
        instantâneo de VM produzem isso. Medido antes da primeira correção:
        ronda parada há três dias mais um carimbo 120 dias à frente devolvia
        ok=True e razão vazia.

        CARIMBO NO FUTURO NÃO PODE PROVAR FRESCOR — nem por pouco.

        A folga de 5 minutos absorvia mais que ruído de relógio: como QUALQUER
        atraso negativo escapava da trava de dado velho, bastavam 4 minutos de
        adiantamento para mascarar uma ronda parada há três dias, e a razão
        ainda AFIRMAVA que ela estava viva. A magnitude tinha caído; a classe
        não.

        Agora o frescor é medido pela amostra mais recente que NÃO está no
        futuro. Carimbo adiantado deixa de ser prova de vida e vira ressalva:
        ele pode ser ruído de relógio, e ruído de relógio não atesta coleta.
    #>
    if ($atraso -lt 0) {
        $futuro = [Math]::Abs($atraso)
        $passado = @($carimbos | Where-Object { $_ -le $NowUtc })
        if ($passado.Count -eq 0) {
            $saude.reason = ("a única amostra legível está {0} min NO FUTURO. " -f $futuro) +
                            'Sem nenhum carimbo no passado, não há como afirmar que a ronda rodou.'
            return [pscustomobject]$saude
        }

        $ultimoReal = ($passado | Sort-Object)[-1]
        $atraso = [Math]::Round(($NowUtc - $ultimoReal).TotalMinutes, 1)
        $saude.lastSampleAt     = $ultimoReal.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        $saude.minutesSinceLast = $atraso
        $saude.futureStampMin   = $futuro

        if ($atraso -gt $StaleAfterMinutes) {
            $saude.reason = ("há carimbo {0} min no futuro, e a amostra mais recente que NÃO está no futuro tem {1} min (limite: {2}). " -f $futuro, $atraso, $StaleAfterMinutes) +
                            'O relógio está errado E a ronda está parada; o carimbo adiantado escondia a segunda coisa.'
            return [pscustomobject]$saude
        }
    }

    if ($atraso -gt $StaleAfterMinutes) {
        $saude.reason = ("a ronda não produz amostra há {0} min (limite: {1} min). " -f $atraso, $StaleAfterMinutes) +
                        'Qualquer veredito abaixo foi calculado sobre dado velho.'
        return [pscustomobject]$saude
    }

    $saude.ok = $true
    <#
        Coleta recente mas rala: a ronda está viva e passou a maior parte do dia
        sem produzir. Não reprova — máquina desligada é motivo legítimo — mas
        entra na razão, porque um percentil calculado sobre 1% das amostras do
        dia não é o mesmo número que um calculado sobre todas.
    #>
    if ($null -ne $saude.lastDayCoverage -and $saude.lastDayCoverage -lt 25) {
        # Format-WMNumber, não -f: dez linhas abaixo há um comentário inteiro
        # explicando que o operador usa a cultura corrente e faz o texto deixar
        # de bater com o JSON. Eu escrevi o comentário e caí nele quarenta
        # linhas acima, na mesma sessão.
        $saude.reason = ("a ronda está viva, mas o dia tem {0}% das amostras esperadas até agora ({1} de {2}). " -f
                            (Format-WMNumber $saude.lastDayCoverage), $linhas.Count, $saude.expectedSoFar) +
                        'As estatísticas do dia repousam sobre menos dado do que o normal.'
    }
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

    <#
        A RAZÃO DA COLETA SAI NOS DOIS CASOS.

        Só era impressa quando a coleta estava DOENTE. Então a ressalva de
        cobertura rala — escrita depois de ok=true — era calculada, guardada num
        campo e nunca renderizada: nem no arquivo, nem no webhook, que enviam
        apenas este texto. Zero leitores.

        Isso é a mesma falha de antes numa forma nova: antes o número era
        calculado e descartado; depois passou a ser calculado, guardado e não
        mostrado. Para quem lê, não mudou nada.
    #>
    if (-not $Report.health.ok) {
        & $add 'ATENÇÃO — A COLETA NÃO ESTÁ SAUDÁVEL'
        & $add ("  {0}" -f $Report.health.reason)
        & $add ''
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$Report.health.reason)) {
        & $add 'Sobre a coleta:'
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
