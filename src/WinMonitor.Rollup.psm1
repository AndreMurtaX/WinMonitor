#requires -Version 5.1
<#
    WinMonitor — matemática de agregação.

    Separado do módulo comum porque quase tudo aqui é função pura de dado para
    dado, testável contra fixture sintética. A exceção é Read-WMPatrolDay, que
    lê disco — e está marcada como tal, porque uma versão anterior deste
    cabeçalho afirmava "nenhuma chamada de sistema" enquanto o módulo lia
    arquivo, e a afirmação falsa escondeu dois modos de falha reais.

    A IDEIA CENTRAL
    ---------------
    Média destrói informação térmica. Uma máquina passa a maior parte do tempo
    ociosa, então a estatística diária é dominada pelo ócio e degradação real
    desaparece nela. A solução é estratificar: cada amostra é classificada numa
    faixa de carga e os percentis são calculados DENTRO de cada faixa.

    O ganho depende do regime. Quando a carga alta é uma fatia pequena do dia —
    que é o caso normal de um servidor — a estatística do dia inteiro fica cega
    e a da faixa enxerga tudo. Quando a carga alta é uma fatia grande, o p95 do
    dia inteiro também enxerga, e a estratificação ganha menos. Test-Rollup.ps1
    mede os dois regimes, em vez de escolher o que favorece a tese.

    E a carga é sempre a do PRÓPRIO subsistema: a placa pode estar a 100%
    enquanto o processador dorme.

    LACUNA NÃO É ZERO, E LACUNA NÃO É AUSÊNCIA DE LACUNA
    ---------------------------------------------------
    Duas regras que este módulo aplica até o fim, não só na função onde são
    convenientes:

      1. Métrica ausente vira $null, nunca 0. Contador que nunca pôde ser
         medido vira $null, nunca 0.
      2. Séries temporais PRESERVAM os buracos. Uma sonda que falhou por três
         minutos deixa três $null na série, e a contagem de janelas de carga
         sustentada é obrigada a tropeçar neles.
#>

# ------------------------------------------------------ conversão segura ----

<#
    Converte para número sem inventar valor.

    Devolve $null para qualquer coisa que não seja número — inclusive "N/A",
    string vazia, objeto. Um [double] cru estouraria e mataria a agregação do
    dia inteiro; pior, sob pt-BR o cast cru de '37,3' devolve 373, porque a
    vírgula é lida como separador de milhar.

    Cultura invariante sempre: o dado gravado é JSON, e JSON é invariante.
#>
function ConvertTo-WMNumber {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $null }

    $n = 0.0
    if ($Value -is [ValueType]) {
        $n = [double]$Value
    } else {
        $t = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($t)) { return $null }
        if (-not [double]::TryParse($t,
                                    [System.Globalization.NumberStyles]::Float,
                                    [System.Globalization.CultureInfo]::InvariantCulture,
                                    [ref]$n)) {
            return $null
        }
    }

    <#
        NaN e Infinity são doubles válidos e TryParse os aceita — 'NaN' e
        'Infinity' entram como número. Não são medidas.

        O estrago é silencioso e persistente: NaN faz n subir e gaps ficar em
        zero (a ausência vira medida, contra a regra 1 deste módulo), e como
        [Array]::Sort põe NaN na frente, a mediana e o mínimo saem errados. O
        agregado contaminado serializa e relê sem erro, então o lixo atravessa
        até a linha-base.
    #>
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n)) { return $null }
    $n
}

# Arredondamento comercial. [math]::Round padrão é bancário e faz o máximo sair
# MENOR que o máximo real quando o valor cai exatamente no meio.
function Get-WMRound {
    param($Value, [int]$Digits = 2)
    if ($null -eq $Value) { return $null }
    [math]::Round([double]$Value, $Digits, [System.MidpointRounding]::AwayFromZero)
}

# ------------------------------------------------------------- percentis ----

<#
    Percentil por interpolação linear entre postos — mesmo método do
    PERCENTILE.INC do Excel e do padrão NIST.

    O parâmetro é [object[]] e NÃO [double[]] de propósito: com [double[]] o
    PowerShell converte $null em 0.0 na ENTRADA, antes de qualquer filtro do
    corpo rodar, e ausência vira medida.
#>
<#
    Percentil sobre um array JÁ ordenado de doubles.

    Existe para que Get-WMStats ordene UMA vez e calcule p50 e p95 a partir do
    mesmo array. A versão anterior ordenava três vezes por estatística — uma no
    corpo e uma dentro de cada chamada a Get-WMPercentile — usando Sort-Object,
    que empacota cada valor num PSObject. Numa janela de 14 dias isso dominava
    o custo.
#>
function Get-WMPercentileSorted {
    param([double[]]$Sorted, [double]$P)
    if ($null -eq $Sorted -or $Sorted.Length -eq 0) { return $null }
    if ($Sorted.Length -eq 1) { return $Sorted[0] }

    $rank = ($P / 100.0) * ($Sorted.Length - 1)
    $lo   = [int][math]::Floor($rank)
    $hi   = [int][math]::Ceiling($rank)
    if ($lo -eq $hi) { return $Sorted[$lo] }

    $frac = $rank - $lo
    $Sorted[$lo] * (1.0 - $frac) + $Sorted[$hi] * $frac
}

function Get-WMPercentile {
    param(
        [object[]]$Values,
        [Parameter(Mandatory)][ValidateRange(0, 100)][double]$P
    )
    $clean = New-Object System.Collections.ArrayList
    foreach ($v in $Values) {
        $n = ConvertTo-WMNumber $v
        if ($null -ne $n) { [void]$clean.Add($n) }
    }
    if ($clean.Count -eq 0) { return $null }

    # [Array]::Sort sobre double[] em vez de Sort-Object: sem boxing.
    $sorted = [double[]]$clean.ToArray()
    [Array]::Sort($sorted)
    Get-WMPercentileSorted -Sorted $sorted -P $P
}

<#
    Resumo estatístico. Devolve $null quando não há amostra alguma — nunca
    zero, porque zero é um valor medido e ausência não é.

    Guarda também quantos itens da série eram lacuna: sem isso, uma série com
    1400 buracos e 40 medidas parece tão sólida quanto uma com 1440 medidas.
#>
function Get-WMStats {
    param([object[]]$Values, [int]$Round = 2)

    $total = 0
    if ($null -ne $Values) { $total = $Values.Count }

    $clean = New-Object System.Collections.ArrayList
    foreach ($v in $Values) {
        $n = ConvertTo-WMNumber $v
        if ($null -ne $n) { [void]$clean.Add($n) }
    }
    if ($clean.Count -eq 0) { return $null }

    # Ordena UMA vez e tira os dois percentis do mesmo array.
    $sorted = [double[]]$clean.ToArray()
    [Array]::Sort($sorted)

    [ordered]@{
        n    = $sorted.Length
        gaps = $total - $sorted.Length
        min  = Get-WMRound $sorted[0] $Round
        p50  = Get-WMRound (Get-WMPercentileSorted -Sorted $sorted -P 50) $Round
        p95  = Get-WMRound (Get-WMPercentileSorted -Sorted $sorted -P 95) $Round
        max  = Get-WMRound $sorted[-1] $Round
    }
}

# ----------------------------------------------------------- faixas ---------

<#
    Valida a tabela de faixas. Ela vem de config.json, que pode ser sobreposto
    por config.local.json fora do repositório — então não é dado confiável.
    Buraco ou sobreposição na tabela faria amostras sumirem ou irem para a
    faixa errada, caladas.
#>
function Test-WMBands {
    param([Parameter(Mandatory)]$Bands)
    $problems = @()

    $list = @($Bands | Sort-Object { [double]$_.min })
    if ($list.Count -eq 0) { return @('tabela de faixas vazia') }

    $ids = @($list | ForEach-Object { $_.id })
    if (($ids | Sort-Object -Unique).Count -ne $ids.Count) { $problems += 'ids de faixa repetidos' }

    for ($i = 0; $i -lt $list.Count; $i++) {
        if ([double]$list[$i].max -le [double]$list[$i].min) {
            $problems += ("faixa '{0}': max ({1}) nao e maior que min ({2})" -f $list[$i].id, $list[$i].max, $list[$i].min)
        }
        if ($i -gt 0) {
            $prevMax = [double]$list[$i - 1].max
            $curMin  = [double]$list[$i].min
            if ($curMin -lt $prevMax) { $problems += ("faixas '{0}' e '{1}' se sobrepoem" -f $list[$i - 1].id, $list[$i].id) }
            if ($curMin -gt $prevMax) { $problems += ("buraco entre '{0}' e '{1}'" -f $list[$i - 1].id, $list[$i].id) }
        }
    }
    $problems
}

# Classifica uma carga numa faixa. Fora de faixa devolve $null, e quem chama
# decide o que fazer — nunca cai na faixa errada por descuido.
function Get-WMLoadBand {
    param(
        [Parameter(Mandatory)]$Bands,
        $Load
    )
    # Converter antes de comparar: '100' -lt 25 é comparação de STRING e
    # devolve verdadeiro, jogando carga máxima na faixa ociosa.
    $n = ConvertTo-WMNumber $Load
    if ($null -eq $n) { return $null }

    foreach ($b in $Bands) {
        if ($n -ge [double]$b.min -and $n -lt [double]$b.max) { return $b.id }
    }
    $null
}

<#
    Conta janelas de carga alta: sequências contíguas de pelo menos $MinRun
    amostras acima do limiar.

    Serve ao critério de elegibilidade da linha-base. Contar amostras soltas não
    serviria: vinte picos isolados de um minuto não caracterizam comportamento
    térmico sustentado, que é justamente o que precisa ser medido.

    LACUNA QUEBRA A SEQUÊNCIA. Sem dado não dá para afirmar que a carga se
    manteve — e para isso valer, quem monta a série é obrigado a preservar os
    $null em vez de compactá-los. Ver Get-WMSampleSeries.

    Devolve $null se a série inteira for lacuna: nunca houve como contar, e
    zero seria a afirmação falsa de que se contou e não havia nada.
#>
function Get-WMLoadRuns {
    param(
        [object[]]$Series,
        [double]$Threshold = 75,
        [ValidateRange(1, [int]::MaxValue)][int]$MinRun = 3
    )
    if ($null -eq $Series -or $Series.Count -eq 0) { return $null }

    $seen = 0
    $runs = 0
    $cur  = 0
    foreach ($v in $Series) {
        $n = ConvertTo-WMNumber $v
        if ($null -eq $n) { $cur = 0; continue }
        $seen++
        if ($n -ge $Threshold) {
            $cur++
            if ($cur -eq $MinRun) { $runs++ }
        } else {
            $cur = 0
        }
    }
    if ($seen -eq 0) { return $null }
    $runs
}

# ------------------------------------------------- agregação estratificada ---

<#
    Agrega pares (carga, valor) em faixas, numa passada só.

    A versão anterior filtrava a lista inteira uma vez por faixa e chamava
    Get-WMLoadBand dentro do filtro, custando O(faixas² × amostras). Esta é
    O(amostras) — mas isso vale para ESTA função, não para o módulo: a primeira
    tentativa de otimização deixou o conjunto 3,2x MAIS lento de ponta a ponta,
    porque o ganho aqui foi engolido por `+=` em array dentro dos laços que
    montam os pares. Medir o todo, não a parte.

    $Dropped recebe quantos pares ficaram fora de qualquer faixa. Sem esse
    contador, carga fora de escala sumia em silêncio e nada reconciliava a soma
    das faixas com o total.
#>
function Get-WMBandedStats {
    param(
        [Parameter(Mandatory)]$Bands,
        $Pairs,
        [int]$Round = 2,
        [ref]$Dropped
    )
    $buckets = [ordered]@{}
    foreach ($b in $Bands) { $buckets[$b.id] = New-Object System.Collections.ArrayList }

    $drop = 0
    foreach ($p in $Pairs) {
        # Classificar a faixa ANTES de converter o valor. Um valor ilegível numa
        # amostra de carga conhecida é lacuna DAQUELA faixa, e precisa entrar no
        # balde como $null para ser contado — descartá-lo aqui faria a faixa
        # parecer ter medida completa.
        $id = Get-WMLoadBand -Bands $Bands -Load $p.load
        if ($null -eq $id) { $drop++; continue }
        [void]$buckets[$id].Add((ConvertTo-WMNumber $p.value))
    }

    if ($null -ne $Dropped) { $Dropped.Value = $drop }

    $out = [ordered]@{}
    foreach ($id in $buckets.Keys) {
        if ($buckets[$id].Count -eq 0) { continue }
        $st = Get-WMStats -Values @($buckets[$id]) -Round $Round
        if ($null -ne $st) {
            $out[$id] = $st
        } else {
            <#
                Houve amostras nesta faixa e NENHUMA delas era legível. Omitir a
                faixa faria "dez minutos em carga alta sem termômetro" ficar
                indistinguível de "não houve carga alta" — que é exatamente a
                confusão que este projeto proíbe. A faixa aparece com zero
                medidas e a contagem de lacunas.
            #>
            $out[$id] = [ordered]@{
                n = 0; gaps = $buckets[$id].Count
                min = $null; p50 = $null; p95 = $null; max = $null
            }
        }
    }
    if ($out.Count -eq 0) { return $null }
    $out
}

# ------------------------------------------------------ leitura do bruto -----

<#
    Lê um JSONL de ronda.  ** Esta função toca o disco. **

    ReadAllLines e não ReadLines: ReadLines segura o handle durante todo o laço
    de consumo (220 ms num dia cheio), e a ronda desiste de gravar depois de
    ~240 ms de tentativas. Vinte milissegundos de margem entre o agregador e a
    perda de uma amostra não é margem.

    Linha corrompida é contada e pulada, nunca fatal — uma escrita interrompida
    por desligamento não pode inutilizar o dia inteiro. Linha que parseia mas
    não é um objeto de amostra também: `123` e `"lixo"` são JSON válido e não
    são amostras.
#>
function Read-WMPatrolDay {
    param([Parameter(Mandatory)][string]$Path)

    $samples = New-Object System.Collections.ArrayList
    $bad     = 0

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Samples = $samples; Bad = 0; Missing = $true }
    }

    $lines = $null
    try {
        $lines = [System.IO.File]::ReadAllLines($Path)
    } catch {
        # Arquivo em uso ou removido pela retenção no meio do caminho.
        return [pscustomobject]@{ Samples = $samples; Bad = 0; Missing = $true }
    }

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $obj = $null
        try { $obj = $line | ConvertFrom-Json } catch { $bad++; continue }

        # JSON válido que não é amostra ainda é linha ruim.
        if ($null -eq $obj -or $obj -isnot [pscustomobject] -or $null -eq $obj.at) {
            $bad++
            continue
        }
        [void]$samples.Add($obj)
    }

    [pscustomobject]@{ Samples = $samples; Bad = $bad; Missing = $false }
}

# ---------------------------------------------------- séries com lacuna -----

<#
    Monta uma série temporal a partir das amostras PRESERVANDO os buracos: uma
    posição por amostra, $null onde a métrica não existe.

    É o que faz Get-WMLoadRuns poder cumprir a promessa de tropeçar na lacuna.
    A versão anterior só acrescentava valores presentes, compactava a série, e
    uma falha de sonda no meio de duas rajadas curtas virava evidência de carga
    sustentada que nunca houve.
#>
function Get-WMSampleSeries {
    param(
        [Parameter(Mandatory)]$Samples,
        [Parameter(Mandatory)][scriptblock]$Selector
    )
    $out = New-Object System.Collections.ArrayList
    foreach ($s in $Samples) {
        $v = $null
        try { $v = & $Selector $s } catch { $v = $null }
        [void]$out.Add((ConvertTo-WMNumber $v))
    }
    , $out.ToArray()
}

# ------------------------------------------------- agregado de uma janela ---

# Soma a contagem de janelas de carga sobre séries já montadas, uma por
# segmento. Devolve $null se nenhum segmento tinha dado — nunca 0, que
# afirmaria "contei e não havia".
function Get-WMRunsFromSeries {
    param($SeriesList, [double]$Threshold = 75, [int]$MinRun = 3)
    $total = $null
    foreach ($ser in $SeriesList) {
        $r = Get-WMLoadRuns -Series $ser -Threshold $Threshold -MinRun $MinRun
        if ($null -ne $r) {
            if ($null -eq $total) { $total = 0 }
            $total += $r
        }
    }
    $total
}

<#
    Constrói o agregado de uma janela — um dia, ou as semanas da linha-base.

    Entra caminho(s) de arquivo e tabela de faixas, sai objeto. Toca o disco
    apenas por Read-WMPatrolDay.

    POR QUE OS SEGMENTOS EXISTEM
    Percentil não se importa com ordem, então para as estatísticas os dias
    podem ser concatenados. Contagem de janelas de carga se importa muito: uma
    rajada que termina o dia 1 e outra que começa o dia 2 viram UMA janela na
    concatenação, e duas janelas legítimas de tamanho 5 e 4 na virada viram uma
    só. Por isso a contagem é feita por segmento e somada, e as estatísticas
    sobre o conjunto todo.

    O que é estratificado por carga e o que não é:
      CPU e GPU     estratificados, cada um pela carga do PRÓPRIO subsistema.
      Memória       não. Pool do kernel é nível, não resposta a carga.
      Espaço livre  não, e o que interessa é o MÍNIMO — a maré baixa do dia.
#>
function New-WMDayRollup {
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)][string]$DayId,
        [Parameter(Mandatory)]$Bands
    )

    $bandProblems = Test-WMBands -Bands $Bands
    if ($bandProblems.Count -gt 0) {
        throw ("tabela de faixas invalida: " + ($bandProblems -join '; '))
    }

    <#
        Ordena por nome de arquivo. A ordem importa para UMA coisa: a detecção
        de reinício, que compara uptime entre amostras consecutivas. Com os dias
        fora de ordem, o salto de uptime na emenda vira um reinício falso. Os
        percentis são indiferentes à ordem; esta linha existe só por causa dos
        reinícios, e é mais barata que documentar um contrato que o chamador
        pode esquecer.
    #>
    $ordered = @($Path | Sort-Object { Split-Path $_ -Leaf })

    $segments = @()
    $bad      = 0
    $missing  = 0
    foreach ($p in $ordered) {
        $r = Read-WMPatrolDay -Path $p
        if ($r.Missing) { $missing++; continue }
        $segments += , (@($r.Samples))
        $bad += $r.Bad
    }

    $all = New-Object System.Collections.ArrayList
    foreach ($seg in $segments) { foreach ($s in $seg) { [void]$all.Add($s) } }
    if ($all.Count -eq 0) { return $null }

    # Janela com mais de um host é erro de operação, não dado a fundir.
    $hosts = @($all | ForEach-Object { $_.host } | Where-Object { $_ } | Sort-Object -Unique)

    $roll = [ordered]@{
        v            = 2
        host         = $hosts[0]
        day          = $DayId
        samples      = $all.Count
        badLines     = $bad
        missingFiles = $missing
    }
    if ($hosts.Count -gt 1) { $roll.hostsMixed = $hosts }

    # ---- reinícios: $null quando nenhuma amostra trouxe uptime -------------
    $upSeries = Get-WMSampleSeries -Samples $all -Selector { param($s) $s.upH }
    $seenUp   = @($upSeries | Where-Object { $null -ne $_ }).Count
    if ($seenUp -eq 0) {
        $roll.reboots = $null
    } else {
        $reb = 0; $last = $null
        foreach ($v in $upSeries) {
            if ($null -eq $v) { continue }
            if ($null -ne $last -and $v -lt $last) { $reb++ }
            $last = $v
        }
        $roll.reboots = $reb
    }

    <#
        Lacunas DECLARADAS pela ronda (sonda que falhou e disse que falhou).

        Nome distinto de propósito: cada bloco de estatística também tem um
        campo `gaps`, que significa outra coisa — buracos na série daquela
        métrica. Os dois números coincidem às vezes e divergem no geral, e
        chamá-los igual no mesmo JSON garantia que a camada de parecer
        confundisse um com o outro.
    #>
    $probeGaps = [ordered]@{}
    foreach ($s in $all) {
        if ($s.cov -and $s.cov.gap) {
            foreach ($k in $s.cov.gap.PSObject.Properties.Name) {
                if (-not $probeGaps.Contains($k)) { $probeGaps[$k] = 0 }
                $probeGaps[$k]++
            }
        }
    }
    $roll.probeGaps = $probeGaps

    # ---- CPU ---------------------------------------------------------------
    # Uma passada só, e ArrayList em vez de `+=`: acrescentar a array em laço
    # recopia o array inteiro a cada item, e foi o que fez a janela de 14 dias
    # custar 130 s em vez de 40.
    $cpuUtilAll = New-Object System.Collections.ArrayList
    $cpuPairs   = New-Object System.Collections.ArrayList
    $cpuBySeg   = @()

    foreach ($seg in $segments) {
        $segUtil = New-Object System.Collections.ArrayList
        foreach ($s in $seg) {
            $u = ConvertTo-WMNumber $s.cpu.util
            [void]$segUtil.Add($u)
            [void]$cpuUtilAll.Add($u)

            <#
                Sem bloco cpu não há par a classificar. Acrescentar um par com
                carga nula fazia a amostra ser contada em outOfBand, misturando
                "carga fora de escala" com "não houve medida de carga" — que são
                coisas diferentes e levam a conclusões diferentes.
            #>
            if ($null -ne $s.cpu) {
                [void]$cpuPairs.Add([pscustomobject]@{ load = $s.cpu.util; value = $s.cpu.mhz })
            }
        }
        $cpuBySeg += , $segUtil.ToArray()
    }

    $cpuRuns = Get-WMRunsFromSeries -SeriesList $cpuBySeg -Threshold 75 -MinRun 3

    $cpuDrop = 0
    $roll.cpu = [ordered]@{
        util         = Get-WMStats -Values $cpuUtilAll.ToArray() -Round 1
        mhzByLoad    = Get-WMBandedStats -Bands $Bands -Pairs $cpuPairs -Round 0 -Dropped ([ref]$cpuDrop)
        outOfBand    = $cpuDrop
        highLoadRuns = $cpuRuns
    }

    # ---- memória -----------------------------------------------------------
    $mem = [ordered]@{}
    foreach ($f in 'usedPct', 'commitPct', 'poolNonpagedMB', 'poolPagedMB') {
        $field = $f
        $ser = Get-WMSampleSeries -Samples $all -Selector ([scriptblock]::Create("param(`$s) `$s.mem.$field"))
        $st  = Get-WMStats -Values $ser -Round 1
        if ($null -ne $st) { $mem[$f] = $st }
    }
    if ($mem.Count -gt 0) { $roll.mem = $mem }

    # ---- armazenamento -----------------------------------------------------
    $volIds  = @($all | ForEach-Object { @($_.sto.vol) } | Where-Object { $_ } | ForEach-Object { $_.id } | Sort-Object -Unique)
    $diskIds = @($all | ForEach-Object { @($_.sto.disk) } | Where-Object { $_ } | ForEach-Object { $_.id } | Sort-Object -Unique)

    $sto = [ordered]@{}
    if ($volIds.Count -gt 0) {
        $v = [ordered]@{}
        foreach ($id in $volIds) {
            $target = $id
            $ser = Get-WMSampleSeries -Samples $all -Selector {
                param($s)
                foreach ($x in @($s.sto.vol)) { if ($null -ne $x -and $x.id -eq $target) { return $x.freeGB } }
                $null
            }.GetNewClosure()
            $st = Get-WMStats -Values $ser -Round 1
            if ($null -ne $st) { $v[$id] = $st }
        }
        if ($v.Count -gt 0) { $sto.volFreeGB = $v }
    }
    if ($diskIds.Count -gt 0) {
        $d = [ordered]@{}
        foreach ($id in $diskIds) {
            $target = $id
            $ser = Get-WMSampleSeries -Samples $all -Selector {
                param($s)
                foreach ($x in @($s.sto.disk)) { if ($null -ne $x -and $x.id -eq $target) { return $x.busyPct } }
                $null
            }.GetNewClosure()
            $st = Get-WMStats -Values $ser -Round 1
            if ($null -ne $st) { $d[$id] = $st }
        }
        if ($d.Count -gt 0) { $sto.diskBusyPct = $d }
    }
    if ($sto.Count -gt 0) { $roll.sto = $sto }

    # ---- GPU ---------------------------------------------------------------
    $gpuIds = @($all | ForEach-Object { @($_.gpu) } | Where-Object { $_ -and $null -ne $_.idx } |
                ForEach-Object { [string]$_.idx } | Sort-Object -Unique)

    if ($gpuIds.Count -gt 0) {
        $FIELDS = @('tempC', 'watts', 'coreMHz', 'fanPct')
        $gpus   = [ordered]@{}

        foreach ($idx in $gpuIds) {
            $target = $idx

            <#
                UMA passada por GPU. A versão anterior invocava um scriptblock
                de busca ~7 vezes por amostra (uma por série, uma por campo), e
                invocação de scriptblock domina o custo em janelas de semanas.
            #>
            $utilAll = New-Object System.Collections.ArrayList
            $tempAll = New-Object System.Collections.ArrayList
            $pairs   = @{}
            foreach ($f in $FIELDS) { $pairs[$f] = New-Object System.Collections.ArrayList }
            $utilBySeg = @()
            $thSeen = 0; $thTrue = 0; $hdSeen = 0; $hdTrue = 0

            foreach ($seg in $segments) {
                $segUtil = New-Object System.Collections.ArrayList
                foreach ($s in $seg) {
                    $g = $null
                    foreach ($cand in @($s.gpu)) {
                        if ($null -ne $cand -and [string]$cand.idx -eq $target) { $g = $cand; break }
                    }

                    if ($null -eq $g) {
                        # GPU ausente nesta amostra: buraco preservado nas duas
                        # séries, para que a contagem de janelas tropece nele.
                        [void]$segUtil.Add($null)
                        [void]$utilAll.Add($null)
                        [void]$tempAll.Add($null)
                        continue
                    }

                    $u = ConvertTo-WMNumber $g.util
                    [void]$segUtil.Add($u)
                    [void]$utilAll.Add($u)
                    [void]$tempAll.Add((ConvertTo-WMNumber $g.tempC))

                    foreach ($f in $FIELDS) {
                        [void]$pairs[$f].Add([pscustomobject]@{ load = $g.util; value = $g.$f })
                    }

                    <#
                        Contenção térmica: a PRESENÇA do campo é rastreada
                        separadamente do valor. FIELDS_MIN da sonda não inclui a
                        máscara de contenção, então no modo degradado — que é
                        justamente quando o driver está com problema — o campo
                        nem existe. Contar isso como "não houve contenção"
                        gravaria que a placa nunca se conteve por calor sobre
                        dado que nunca foi medido.
                    #>
                    $names = $g.PSObject.Properties.Name
                    if ($names -contains 'thrThermal' -and $null -ne $g.thrThermal) {
                        $thSeen++
                        if ($g.thrThermal -eq $true) { $thTrue++ }
                    }
                    if ($names -contains 'thrHard' -and $null -ne $g.thrHard) {
                        $hdSeen++
                        if ($g.thrHard -eq $true) { $hdTrue++ }
                    }
                }
                $utilBySeg += , $segUtil.ToArray()
            }

            $runs = Get-WMRunsFromSeries -SeriesList $utilBySeg -Threshold 75 -MinRun 3

            $entry = [ordered]@{
                util         = Get-WMStats -Values $utilAll.ToArray() -Round 1
                highLoadRuns = $runs
                throttle     = [ordered]@{
                    thermal         = $(if ($thSeen -eq 0) { $null } else { $thTrue })
                    thermalMeasured = $thSeen
                    hard            = $(if ($hdSeen -eq 0) { $null } else { $hdTrue })
                    hardMeasured    = $hdSeen
                }
            }

            <#
                tempCAllDay existe para uma finalidade só: permitir MEDIR o
                ganho da estratificação em vez de afirmá-lo, comparando a
                estatística não-estratificada contra a estratificada. Nenhuma
                regra de diagnóstico deve usá-lo como base.
            #>
            $entry.tempCAllDay = Get-WMStats -Values $tempAll.ToArray() -Round 1

            foreach ($f in $FIELDS) {
                $round = 1
                if ($f -eq 'coreMHz') { $round = 0 }
                $drop = 0
                $banded = Get-WMBandedStats -Bands $Bands -Pairs $pairs[$f] -Round $round -Dropped ([ref]$drop)
                if ($null -ne $banded) {
                    $entry["$($f)ByLoad"] = $banded
                    if ($drop -gt 0) { $entry["$($f)OutOfBand"] = $drop }
                }
            }

            $gpus[$idx] = $entry
        }
        $roll.gpu = $gpus
    }

    [pscustomobject]$roll
}

Export-ModuleMember -Function `
    ConvertTo-WMNumber, Get-WMRound, Get-WMPercentile, Get-WMPercentileSorted, Get-WMStats,
    Test-WMBands, Get-WMLoadBand, Get-WMLoadRuns, Get-WMBandedStats,
    Read-WMPatrolDay, Get-WMSampleSeries, Get-WMRunsFromSeries, New-WMDayRollup
