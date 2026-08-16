#requires -Version 5.1
<#
    Testes da camada de relatório e notificação.

    A pergunta que organiza esta suíte não é "o relatório sai bonito?", e sim
    "em que situação este sistema fica calado quando deveria falar?". Silêncio
    indevido é o único defeito aqui que ninguém percebe acontecendo — por
    definição, ele não produz nada para se notar.

      .\tests\Test-Report.ps1
#>
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TestKit.ps1')

Import-Module (Join-Path $root 'src\WinMonitor.psm1')        -Force
Import-Module (Join-Path $root 'src\WinMonitor.Rollup.psm1') -Force
Import-Module (Join-Path $root 'src\WinMonitor.Rules.psm1')  -Force
Import-Module (Join-Path $root 'src\WinMonitor.Report.psm1') -Force

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wm-rep-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function New-Data { param([string]$Json) $Json | ConvertFrom-Json }

function Read-JsonState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
}

function New-PatrolDir {
    param([string]$Name, [string[]]$Lines)
    $d = Join-Path $tmp $Name
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    if ($Lines) {
        $f = Join-Path $d '2026-08-15.jsonl'
        [System.IO.File]::WriteAllLines($f, $Lines, (New-Object System.Text.UTF8Encoding($false)))
    }
    $d
}

$AGORA = [datetime]::Parse('2026-08-15T18:00:00Z', [System.Globalization.CultureInfo]::InvariantCulture,
                           [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()

function Amostra { param([string]$At) '{"v":1,"host":"T","at":"' + $At + '","cpu":{"util":3}}' }

try {

    # =====================================================================
    Start-TestGroup 'Saúde da coleta: a pergunta que vem antes de todas'

    $vazio = Join-Path $tmp 'nao-existe'
    $h = Get-WMCollectionHealth -PatrolDir $vazio -NowUtc $AGORA
    Assert-True (-not $h.ok) 'diretório inexistente não é saudável'
    Assert-True ($h.reason -match 'nunca rodou|não existe') 'e a razão diz que nunca houve coleta'

    $h = Get-WMCollectionHealth -PatrolDir (New-PatrolDir 'semArquivo') -NowUtc $AGORA
    Assert-True (-not $h.ok) 'diretório sem arquivo não é saudável'

    $h = Get-WMCollectionHealth -PatrolDir (New-PatrolDir 'fresco' @((Amostra '2026-08-15T17:55:00Z'))) -NowUtc $AGORA
    Assert-True $h.ok 'amostra de 5 min atrás é saudável'
    Assert-Equal 5 $h.minutesSinceLast 'e o atraso é medido em minutos'

    $h = Get-WMCollectionHealth -PatrolDir (New-PatrolDir 'velho' @((Amostra '2026-08-15T15:00:00Z'))) -NowUtc $AGORA
    Assert-True (-not $h.ok) 'amostra de 3 horas atrás NÃO é saudável'
    Assert-True ($h.reason -match 'dado velho') 'e a razão avisa que o veredito é sobre dado velho'

    <#
        O CASO QUE MOTIVA A VARREDURA DE TRÁS PARA FRENTE.
        Se o processo morre no meio da escrita, a última linha fica cortada.
        Ler só a última linha daria erro justamente na situação que esta função
        existe para detectar — e um erro aqui viraria "não sei dizer" quando a
        resposta certa é "a coleta parou".
    #>
    $cortado = @((Amostra '2026-08-15T17:56:00Z'), '{"v":1,"host":"T","at":"2026-08-15T17:5')
    $h = Get-WMCollectionHealth -PatrolDir (New-PatrolDir 'cortado' $cortado) -NowUtc $AGORA
    Assert-True $h.ok 'linha truncada no fim não impede a leitura da anterior'
    Assert-Equal 4 $h.minutesSinceLast 'e o atraso vem da última linha ÍNTEGRA'

    $lixo = @('{"sem":"campo at"}', 'nem json')
    $h = Get-WMCollectionHealth -PatrolDir (New-PatrolDir 'lixo' $lixo) -NowUtc $AGORA
    Assert-True (-not $h.ok) 'arquivo sem nenhuma amostra legível não é saudável'

    <#
        AMOSTRA NO FUTURO.

        A conferência era só 'atraso > limite', e atraso NEGATIVO passava. Medido
        pela verificação adversarial: ronda parada há três dias mais um arquivo
        com carimbo à frente devolvia ok=True, atraso de -172800 min e razão
        vazia — coleta declarada saudável sobre dado que ainda não aconteceu.

        Relógio corrigido para trás por NTP, retomada de suspensão e restauração
        de instantâneo de VM produzem exatamente isso. Os testes existentes só
        tinham atraso positivo: 5 e 4 minutos.
    #>
    $h = Get-WMCollectionHealth -PatrolDir (New-PatrolDir 'futuro' @((Amostra '2026-08-16T18:00:00Z'))) -NowUtc $AGORA
    Assert-True (-not $h.ok) 'amostra 24 h NO FUTURO não é coleta saudável'
    Assert-True ($h.reason -match 'FUTURO') 'e a razão diz que o carimbo está à frente'
    Assert-True ($h.minutesSinceLast -lt 0) 'o atraso negativo é registrado, não escondido'

    <#
        UM ÚNICO CARIMBO NO FUTURO NÃO PROVA VIDA, nem por um minuto.

        A versão anterior tolerava até 5 min de adiantamento, e como QUALQUER
        atraso negativo escapava da trava de dado velho, bastavam 4 minutos para
        mascarar uma ronda parada há três dias — com a razão AFIRMANDO que ela
        estava viva. A magnitude tinha caído de 120 dias para 5 minutos; a classe
        do defeito, não.
    #>
    $h = Get-WMCollectionHealth -PatrolDir (New-PatrolDir 'soFuturo' @((Amostra '2026-08-15T18:01:00Z'))) -NowUtc $AGORA
    Assert-True (-not $h.ok) 'uma única amostra no futuro não atesta coleta, nem por um minuto'
    Assert-True ($h.reason -match 'FUTURO') 'e a razão diz que o carimbo está à frente'

    <#
        O caso REAL de ruído de relógio: a ronda escreveu várias amostras, a mais
        nova saiu um minuto adiantada. O frescor é medido pela mais recente que
        NÃO está no futuro, então isto continua saudável — que é o que impede a
        correção de virar alarme falso diário.
    #>
    $ruido = @((Amostra '2026-08-15T17:57:00Z'), (Amostra '2026-08-15T17:58:00Z'), (Amostra '2026-08-15T18:01:00Z'))
    $h = Get-WMCollectionHealth -PatrolDir (New-PatrolDir 'ruidoRelogio' $ruido) -NowUtc $AGORA
    Assert-True $h.ok 'ruído de relógio com amostras reais atrás continua saudável'
    Assert-Equal 2 $h.minutesSinceLast 'e o frescor vem da amostra mais recente que NÃO está no futuro'

    <#
        O caso que a folga escondia: ronda parada, mas com um carimbo pouco
        adiantado. Antes: ok=True e "a ronda está viva". Agora o adiantamento
        deixa de ser prova e a parada aparece.
    #>
    $mascara = @((Amostra '2026-08-12T10:00:00Z'), (Amostra '2026-08-15T18:04:00Z'))
    $h = Get-WMCollectionHealth -PatrolDir (New-PatrolDir 'mascarada' $mascara) -NowUtc $AGORA
    Assert-True (-not $h.ok) 'carimbo pouco adiantado não esconde mais ronda parada há dias'
    Assert-True ($h.reason -match 'parada') 'e a razão diz as DUAS coisas: relógio errado e ronda parada'

    <#
        Cobertura rala: a ronda está viva e o dia tem quase nada. Não reprova —
        máquina desligada é motivo legítimo — mas precisa aparecer, porque um
        percentil sobre 1% das amostras não é o mesmo número que sobre todas.
        A versão anterior calculava lastDayCoverage e nunca a usava, enquanto o
        cabeçalho afirmava que comparava o que existe com o que deveria existir.
    #>
    $h = Get-WMCollectionHealth -PatrolDir (New-PatrolDir 'rala' @((Amostra '2026-08-15T17:59:00Z'))) -NowUtc $AGORA
    Assert-True $h.ok 'uma amostra recente mantém a coleta saudável'
    Assert-True ($h.reason -match 'amostras esperadas') 'mas a escassez do dia é declarada'
    Assert-True ($h.lastDayCoverage -lt 1) 'e a cobertura do dia é medida'

    <#
        A COBERTURA É CONTRA O DIA DECORRIDO, e isto é o que separa ressalva de
        ruído diário.

        Medido: comparando contra as 1440 do dia inteiro, uma máquina
        PERFEITAMENTE saudável declarava escassez toda madrugada — 4,2% à 01:00,
        12,5% às 03:00, 20,8% às 05:00 — e só depois das 06:00 a afirmação
        deixava de ser falsa. Ressalva que aparece todo dia é ruído, e ruído faz
        alguém parar de ler.
    #>
    $treHoras = [datetime]::Parse('2026-08-15T03:00:00Z', [System.Globalization.CultureInfo]::InvariantCulture,
                                  [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    $cheio = @(1..180 | ForEach-Object { Amostra ("2026-08-15T{0:00}:{1:00}:00Z" -f [int](($_ - 1) / 60), (($_ - 1) % 60)) })
    $h = Get-WMCollectionHealth -PatrolDir (New-PatrolDir 'madrugada' $cheio) -NowUtc $treHoras
    Assert-True $h.ok 'às 03:00, com todas as amostras do período, a coleta é saudável'
    Assert-True (-not ($h.reason -match 'amostras esperadas')) 'e NÃO declara escassez: 180 de 180 esperadas até agora'
    Assert-Equal 180 $h.expectedSoFar 'o esperado é o do dia DECORRIDO, não o do dia inteiro'

    # E o número da razão sai com PONTO, como o JSON — não com a vírgula do -f.
    $h = Get-WMCollectionHealth -PatrolDir (New-PatrolDir 'ponto' @((Amostra '2026-08-15T17:59:00Z'))) -NowUtc $AGORA
    Assert-True (-not ($h.reason -match '\d,\d')) 'a porcentagem na razão usa ponto, batendo com o JSON'

    # =====================================================================
    Start-TestGroup 'Diferença de dias, com cultura hostil'

    Assert-Equal 3 (Get-WMDaysBetween -From '2026-08-12' -To '2026-08-15') 'três dias'
    Assert-Equal 0 (Get-WMDaysBetween -From '2026-08-15' -To '2026-08-15') 'mesmo dia'
    Assert-True ($null -eq (Get-WMDaysBetween -From $null -To '2026-08-15')) 'sem origem devolve nulo'
    Assert-True ($null -eq (Get-WMDaysBetween -From 'ontem' -To '2026-08-15')) 'texto inválido devolve nulo'

    <#
        Cultura tailandesa: o calendário budista faz '2026' virar outro ano ao
        ser lido pela cultura corrente. Já quebrou a escrita de nome de arquivo
        neste projeto; aqui quebraria a contagem de dias sem avisar, e o pulso
        deixaria de disparar.
    #>
    $antes = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('th-TH')
        Assert-Equal 3 (Get-WMDaysBetween -From '2026-08-12' -To '2026-08-15') 'três dias, também sob th-TH'
        Assert-Equal '48.2' (Format-WMNumber 48.2) 'o número sai com PONTO, também sob th-TH'
    } finally {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $antes
    }

    $antes = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('pt-BR')
        Assert-Equal '48.2' (Format-WMNumber 48.2) 'e com PONTO sob pt-BR: o texto tem de bater com o JSON'
    } finally {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $antes
    }

    # =====================================================================
    Start-TestGroup 'A decisão de incomodar alguém'

    $SEMACHADO = New-Data '{"window":"2026-08-15","verdict":"normal","findings":[],"coverage":{"complete":true}}'
    $COMACHADO = New-Data '{"window":"2026-08-15","verdict":"agir","findings":[{"ruleId":"R-DISK-SPACE-LOW"}],"coverage":{"complete":true}}'
    $INCOMPLETO = New-Data '{"window":"2026-08-15","verdict":"normal","findings":[],"coverage":{"complete":false}}'
    $SAUDAVEL  = [pscustomobject]@{ ok = $true;  reason = $null }
    $PARADA    = [pscustomobject]@{ ok = $false; reason = 'a ronda não produz amostra há 900 min' }

    function St {
        param([string]$Dia, [string]$Ver = 'normal', [string[]]$Regras = @(), [int]$Cego = 0)
        [pscustomobject]@{ lastNotifiedDay = $Dia; lastVerdict = $Ver; lastRuleIds = @($Regras); consecutiveIncompleteDays = $Cego }
    }

    # 1. Coleta parada vence tudo, inclusive um veredito 'normal' recém-calculado.
    $d = Test-WMShouldNotify -Findings $SEMACHADO -Health $PARADA -State (St '2026-08-15') -Today '2026-08-15'
    Assert-True $d.notify 'coleta parada notifica'
    Assert-Equal 'coleta' $d.reason 'e essa é a razão, acima de qualquer outra'

    # 2. Achado novo.
    $d = Test-WMShouldNotify -Findings $COMACHADO -Health $SAUDAVEL -State (St '2026-08-15') -Today '2026-08-15'
    Assert-True $d.notify 'achado novo notifica'
    Assert-Equal 'achadoNovo' $d.reason 'pela razão certa'

    # 3. Veredito piorou, com os mesmos achados de antes.
    $d = Test-WMShouldNotify -Findings $COMACHADO -Health $SAUDAVEL `
            -State (St '2026-08-15' 'observar' @('R-DISK-SPACE-LOW')) -Today '2026-08-15'
    Assert-True $d.notify 'piora de veredito notifica mesmo sem achado novo'
    Assert-Equal 'piorou' $d.reason 'pela razão certa'

    # 4. Melhora NÃO dispara por si — mas o achado que continua dispara por persistência.
    $d = Test-WMShouldNotify -Findings $COMACHADO -Health $SAUDAVEL `
            -State (St '2026-08-14' 'agir' @('R-DISK-SPACE-LOW')) -Today '2026-08-15' -RepeatDays 1
    Assert-Equal 'persiste' $d.reason 'o mesmo achado, um dia depois, reavisa'

    $d = Test-WMShouldNotify -Findings $COMACHADO -Health $SAUDAVEL `
            -State (St '2026-08-15' 'agir' @('R-DISK-SPACE-LOW')) -Today '2026-08-15' -RepeatDays 1
    Assert-True (-not $d.notify) 'no mesmo dia, não repete'

    # 5. Cego há dias, sem nenhum achado: o veredito 'normal' esconde a cegueira.
    $d = Test-WMShouldNotify -Findings $INCOMPLETO -Health $SAUDAVEL `
            -State (St '2026-08-15' 'normal' @() 3) -Today '2026-08-15' -BlindDays 3
    Assert-True $d.notify 'cobertura incompleta por 3 dias notifica'
    Assert-Equal 'cego' $d.reason 'pela razão certa'

    $d = Test-WMShouldNotify -Findings $INCOMPLETO -Health $SAUDAVEL `
            -State (St '2026-08-15' 'normal' @() 2) -Today '2026-08-15' -BlindDays 3
    Assert-True (-not $d.notify) 'dois dias ainda não'

    <#
        6. O PULSO. É a regra que impede o modo de falha mais silencioso deste
        projeto: um monitor que nunca fala é idêntico a um monitor morto.
    #>
    $d = Test-WMShouldNotify -Findings $SEMACHADO -Health $SAUDAVEL `
            -State (St '2026-08-08') -Today '2026-08-15' -HeartbeatDays 7
    Assert-True $d.notify 'sete dias de silêncio disparam o pulso'
    Assert-Equal 'pulso' $d.reason 'pela razão certa'

    $d = Test-WMShouldNotify -Findings $SEMACHADO -Health $SAUDAVEL `
            -State (St '2026-08-09') -Today '2026-08-15' -HeartbeatDays 7
    Assert-True (-not $d.notify) 'seis dias ainda não'

    # Nunca notificado é o caso do primeiro dia, e tem de falar.
    $d = Test-WMShouldNotify -Findings $SEMACHADO -Health $SAUDAVEL -State (St $null) -Today '2026-08-15'
    Assert-True $d.notify 'nunca notificado antes: fala'
    Assert-Equal 'pulso' $d.reason 'pelo pulso'

    <#
        MUTAÇÃO: se o pulso for removido, uma máquina saudável e silenciosa
        deixa de produzir qualquer sinal. Este teste é o que fica vermelho.
    #>
    $d = Test-WMShouldNotify -Findings $SEMACHADO -Health $SAUDAVEL `
            -State (St '2026-01-01') -Today '2026-08-15' -HeartbeatDays 7
    Assert-True $d.notify 'sete meses de silêncio não podem passar em branco'

    # =====================================================================
    Start-TestGroup 'Tendência: ausência declarada, nunca omitida'

    $ROLL = New-Data '{"gpu":{"0":{"tempCByLoad":{"b00":{"p95":46},"b75":{"p95":81}}}},"mem":{"commitPct":{"p95":48.2}}}'
    $BASE = New-Data '{"window":"2026-07-01..2026-07-14","profile":{"gpu":{"0":{"tempCByLoad":{"b75":{"p95":73}}}}}}'

    $t = New-WMTrend -Rollup $ROLL -Baseline $BASE -Metrics @('gpu.*.tempCByLoad.b75.p95')
    Assert-True $t.hasBaseline 'a linha-base é reconhecida'
    Assert-Equal 1 (@($t.rows).Count) 'uma placa, uma linha'
    Assert-Equal 8 $t.rows[0].delta 'a placa está 8 graus acima da linha-base'
    Assert-Equal 'comparado' $t.rows[0].state 'e a linha está comparada'

    $t = New-WMTrend -Rollup $ROLL -Baseline $null -Metrics @('gpu.*.tempCByLoad.b75.p95')
    Assert-True (-not $t.hasBaseline) 'sem linha-base, é dito'
    Assert-Equal 'semLinhaBase' $t.rows[0].state 'e a linha declara isso'
    Assert-Equal 81 $t.rows[0].today 'mas o valor de hoje continua visível'

    <#
        Métrica prevista que não veio: a linha PRECISA existir dizendo 'semDado'.
        Sumir com ela transformaria ausência em silêncio — e uma tabela sem a
        linha lê-se como "nada a relatar sobre isso".
    #>
    $t = New-WMTrend -Rollup $ROLL -Baseline $BASE -Metrics @('cpu.tempCByLoad.b75.p95')
    Assert-Equal 1 (@($t.rows).Count) 'métrica ausente ainda produz linha'
    Assert-Equal 'semDado' $t.rows[0].state 'declarada como sem dado'
    Assert-Equal 'cpu.tempCByLoad.b75.p95' $t.rows[0].metric 'e nomeada'

    <#
        REGRESSÃO. -Rollup era Mandatory, e um dia sem agregado derrubava o
        driver inteiro com erro de ligação de parâmetro: sem relatório e sem
        notificação. O monitor emudecia por causa de um arquivo faltando — o
        exato modo de falha que esta fase existe para eliminar.
    #>
    $t = New-WMTrend -Rollup $null -Baseline $null -Metrics @('gpu.*.tempCByLoad.b75.p95', 'mem.commitPct.p95')
    Assert-Equal 2 (@($t.rows).Count) 'sem agregado nenhum, a tabela ainda tem as duas linhas'
    Assert-True (@($t.rows | Where-Object { $_.state -ne 'semDado' }).Count -eq 0) 'todas declaradas sem dado'

    # =====================================================================
    Start-TestGroup 'O texto do relatório diz o que precisa'

    $rel = [pscustomobject]@{
        host = 'T'; window = '2026-08-15'; verdict = 'normal'; coverageComplete = $false
        health = $PARADA
        findings = @()
        trend = (New-WMTrend -Rollup $ROLL -Baseline $null -Metrics @('gpu.*.tempCByLoad.b75.p95'))
        notVerified = @('R-CPU-TEMP-SPEC: fonte pendente')
        decision = (New-WMNotifyDecision $true 'coleta' 'parou' @())
        madeAt = '2026-08-15T18:00:00-03:00'
    }
    $txt = Format-WMReportText -Report $rel

    Assert-True ($txt -match 'A COLETA NÃO ESTÁ SAUDÁVEL') 'coleta parada aparece no TOPO, não em rodapé'
    Assert-True ($txt.IndexOf('COLETA NÃO ESTÁ SAUDÁVEL') -lt $txt.IndexOf('Veredito')) 'e antes do veredito'
    Assert-True ($txt -match 'INCOMPLETA') 'a cobertura incompleta é dita'
    Assert-True ($txt -match 'R-CPU-TEMP-SPEC') 'o que não foi verificado é listado'
    Assert-True ($txt -match 'Motivo do aviso') 'e quem recebe sabe por que recebeu'

    # Sem achados, o texto não pode sugerir que a máquina está boa.
    $rel2 = $rel | Select-Object *
    $rel2.health = $SAUDAVEL
    $txt2 = Format-WMReportText -Report $rel2
    Assert-True ($txt2 -match 'vale para o que foi medido') '"nenhum achado" vem com a ressalva do que não foi medido'

    <#
        A RAZÃO DA COLETA PRECISA CHEGAR A QUEM LÊ, mesmo com a coleta saudável.

        Medido pela verificação: a ressalva de cobertura rala era escrita DEPOIS
        de ok=true, e Format-WMReportText só imprimia health.reason quando a
        coleta estava DOENTE. Notify-File grava só este texto; Notify-Webhook
        envia só este texto. Zero leitores.

        É a mesma falha de antes numa forma nova: antes o número era calculado e
        descartado; depois passou a ser calculado, guardado num campo e não
        mostrado. Para quem lê, não mudou nada — e eu tinha escrito no comentário
        que "aparece na razão para quem lê o relatório".
    #>
    $rel3 = $rel | Select-Object *
    $rel3.health = [pscustomobject]@{ ok = $true; reason = 'a ronda está viva, mas o dia tem 3% das amostras esperadas até agora (12 de 400).' }
    $txt3 = Format-WMReportText -Report $rel3
    Assert-True ($txt3 -match 'amostras esperadas') 'a ressalva de coleta rala aparece no texto entregue'
    Assert-True ($txt3 -match 'Sobre a coleta') 'sob um título que a distingue do alarme de coleta parada'
    Assert-True (-not ($txt3 -match 'NÃO ESTÁ SAUDÁVEL')) 'e sem chamar de doente uma coleta que está viva'

    # Coleta saudável e sem ressalva não inventa seção.
    $rel4 = $rel | Select-Object *
    $rel4.health = [pscustomobject]@{ ok = $true; reason = $null }
    Assert-True (-not ((Format-WMReportText -Report $rel4) -match 'Sobre a coleta')) 'sem ressalva, a seção nem aparece'

    # =====================================================================
    Start-TestGroup 'Invoke-Report: o estado não pode avançar sem entrega'

    <#
        A INVARIANTE MAIS IMPORTANTE DO DRIVER.

        Se lastNotifiedDay avançar quando nenhum canal entregou, o monitor passa
        a se achar em dia: no dia seguinte a decisão vê "notificado ontem", cala,
        e o alerta que ninguém recebeu nunca mais é tentado. O sistema fica
        silencioso e convencido de que fez o seu trabalho.

        Este teste roda o driver de verdade, com um canal que sempre falha.
    #>
    $proj = Join-Path $tmp 'proj'
    New-Item -ItemType Directory -Path $proj -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'src')    -Destination $proj -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $root 'config') -Destination $proj -Recurse -Force
    New-Item -ItemType Directory -Path (Join-Path $proj 'data\findings') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $proj 'data\patrol')   -Force | Out-Null

    $enc = New-Object System.Text.UTF8Encoding($false)
    $dia = '2026-08-15'

    # Achados com um problema real, para que a decisão seja "notificar".
    [System.IO.File]::WriteAllText(
        (Join-Path $proj "data\findings\$dia.json"),
        '{"v":1,"window":"2026-08-15","host":"T","verdict":"agir","findings":[{"ruleId":"R-DISK-SPACE-LOW","severity":"agir","claim":"pouco espaco","evidence":[]}],"coverage":{"complete":true,"evaluated":["R-DISK-SPACE-LOW"],"unsourced":{},"malformed":{},"noData":{},"noBaseline":{},"notApplicable":{}}}',
        $enc)

    # Ronda fresca, para que a saúde da coleta não roube a razão da notificação.
    $agoraIso = [datetime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    [System.IO.File]::WriteAllText((Join-Path $proj "data\patrol\$dia.jsonl"), (Amostra $agoraIso), $enc)

    # Um canal que falha sempre. É a única forma honesta de testar a regra.
    [System.IO.File]::WriteAllText(
        (Join-Path $proj 'src\notifiers\Notify-Quebrado.ps1'),
        "param(`$Text, `$Report, `$Config, `$Secrets)`r`n@{ ok = `$false; detail = 'falha proposital de teste' }`r`n",
        $enc)

    $cfgP = Join-Path $proj 'config\config.json'
    $c = Get-Content $cfgP -Raw -Encoding UTF8 | ConvertFrom-Json
    $c.notify.channels = @('Quebrado')
    [System.IO.File]::WriteAllText($cfgP, (ConvertTo-Json -InputObject $c -Depth 12), $enc)

    $saida = & (Join-Path $proj 'src\Invoke-Report.ps1') -Day $dia 2>&1 | Out-String
    $st    = Read-JsonState (Join-Path $proj 'data\notify\state.json')

    Assert-True ($null -ne $st) 'o estado é gravado mesmo com a entrega falhando'
    Assert-True ($null -eq $st.lastNotifiedDay) 'lastNotifiedDay NÃO avança quando nenhum canal entregou'
    Assert-Equal $dia $st.lastEvaluatedDay 'mas lastEvaluatedDay avança, para não contar o dia duas vezes'
    Assert-True ($saida -match 'NENHUM CANAL ENTREGOU') 'e o driver diz isso em voz alta'

    # Agora o mesmo dia com um canal que funciona: aí sim o estado avança.
    $c.notify.channels = @('File')
    [System.IO.File]::WriteAllText($cfgP, (ConvertTo-Json -InputObject $c -Depth 12), $enc)

    & (Join-Path $proj 'src\Invoke-Report.ps1') -Day $dia | Out-Null
    $st2 = Read-JsonState (Join-Path $proj 'data\notify\state.json')
    Assert-Equal $dia $st2.lastNotifiedDay 'com entrega bem-sucedida, lastNotifiedDay avança'
    Assert-True (@($st2.lastRuleIds) -contains 'R-DISK-SPACE-LOW') 'e as regras avisadas ficam registradas'
    Assert-True (Test-Path (Join-Path $proj 'data\report\ultimo.txt')) 'e o relatório foi mesmo escrito'

    # Segunda chamada no MESMO dia não deve repetir o aviso.
    $saida2 = & (Join-Path $proj 'src\Invoke-Report.ps1') -Day $dia | Out-String
    Assert-True ($saida2 -match 'Sem novidade') 'a segunda chamada no mesmo dia não repete'

} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Show-TestSummary
exit (Get-TestExitCode)
