#requires -Version 5.1
<#
    Testes da camada de agregação.

    Esta suíte foi reescrita depois que um teste de mutação mostrou que a
    anterior, com 44 asserções verdes, deixava passar 8 de 12 sabotagens reais —
    incluindo estratificar a temperatura da GPU pela carga da CPU, que é a
    negação da tese central do projeto.

    A lição está registrada aqui porque ela vale mais que os testes: suíte verde
    não é evidência de cobertura. Vários grupos abaixo existem especificamente
    para matar uma sabotagem que sobrevivia, e estão marcados com [MUTAÇÃO].

      .\tests\Test-Rollup.ps1
#>
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TestKit.ps1')
Import-Module (Join-Path $root 'src\WinMonitor.psm1')        -Force
Import-Module (Join-Path $root 'src\WinMonitor.Rollup.psm1') -Force

$bands   = (Get-WMConfig).loadBands
$fixture = Join-Path $PSScriptRoot 'New-Fixture.ps1'
$tmp     = Join-Path ([System.IO.Path]::GetTempPath()) ('wm-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function New-Day {
    param([string]$Name)
    $p = Join-Path $tmp "$Name.jsonl"
    $rest = $args
    & $fixture -Day $Name -OutFile $p @rest | Out-Null
    $p
}

try {

    # =====================================================================
    Start-TestGroup 'Percentis'

    $seq = 1..100 | ForEach-Object { [double]$_ }
    Assert-Equal 50.5  (Get-WMPercentile -Values $seq -P 50)  'p50 de 1..100'   -Tolerance 0.001
    Assert-Equal 95.05 (Get-WMPercentile -Values $seq -P 95)  'p95 de 1..100'   -Tolerance 0.001
    Assert-Equal 3.85  (Get-WMPercentile -Values @(1.0,2.0,3.0,4.0) -P 95) 'p95 de {1,2,3,4} confere com PERCENTILE.INC' -Tolerance 0.001
    Assert-Equal 1.75  (Get-WMPercentile -Values @(1.0,2.0,3.0,4.0) -P 25) 'p25 de {1,2,3,4}' -Tolerance 0.001
    Assert-Equal 42    (Get-WMPercentile -Values @(42.0) -P 95) 'valor único'   -Tolerance 0.001
    Assert-Null        (Get-WMPercentile -Values @() -P 50)   'série vazia devolve nulo'

    # =====================================================================
    Start-TestGroup 'Conversão de número: cultura e lixo  [MUTAÇÃO]'

    # O Windows aqui é pt-BR. [double]'37,3' cru devolve 373 — a vírgula lida
    # como separador de milhar. Já corrompeu 36,45 W em 3645 W numa sonda.
    Assert-Equal 37.3 (ConvertTo-WMNumber '37.3') 'ponto decimal é lido como decimal' -Tolerance 0.001
    Assert-Null       (ConvertTo-WMNumber '37,3') 'vírgula NÃO vira separador de milhar: rejeita em vez de inventar 373'
    Assert-Null       (ConvertTo-WMNumber 'N/A')  '"N/A" vira nulo, não exceção'
    Assert-Null       (ConvertTo-WMNumber '')     'vazio vira nulo'
    Assert-Null       (ConvertTo-WMNumber $null)  'nulo continua nulo'
    Assert-Null       (ConvertTo-WMNumber $true)  'booleano não vira 1'
    Assert-Equal 5    (ConvertTo-WMNumber 5)      'número passa' -Tolerance 0.001

    # =====================================================================
    Start-TestGroup 'Estatísticas: ausência não é zero, e é contada'

    $s = Get-WMStats -Values @(10.0, 20.0, 30.0) -Round 2
    Assert-Equal 3  $s.n    'contagem'
    Assert-Equal 0  $s.gaps 'sem lacunas'
    Assert-Equal 10 $s.min  'mínimo'
    Assert-Equal 30 $s.max  'máximo'
    Assert-Equal 20 $s.p50  'mediana'

    Assert-Null (Get-WMStats -Values @()) 'série vazia devolve nulo, não zero'
    $sn = Get-WMStats -Values @(5.0, $null, 15.0)
    Assert-Equal 2 $sn.n    'nulos são descartados, não contados como zero'
    Assert-Equal 1 $sn.gaps 'e as lacunas ficam registradas'
    Assert-Equal 5 $sn.min  'nulo não vira o novo mínimo'

    # Arredondamento comercial: o bancário faria o máximo sair MENOR que o real.
    Assert-Equal 4909 (Get-WMStats -Values @(4906.5, 4907.5, 4908.5) -Round 0).max 'máximo não encolhe no arredondamento'

    # =====================================================================
    Start-TestGroup 'Tabela de faixas é validada  [MUTAÇÃO]'

    Assert-Equal 0 (Test-WMBands -Bands $bands).Count 'a tabela de produção é válida'
    $buraco = @(@{id='a';min=0;max=25}, @{id='b';min=50;max=100})
    Assert-GreaterThan (Test-WMBands -Bands $buraco).Count 0 'buraco entre faixas é detectado'
    $sobrep = @(@{id='a';min=0;max=60}, @{id='b';min=50;max=100})
    Assert-GreaterThan (Test-WMBands -Bands $sobrep).Count 0 'sobreposição é detectada'
    $repet  = @(@{id='a';min=0;max=50}, @{id='a';min=50;max=100})
    Assert-GreaterThan (Test-WMBands -Bands $repet).Count 0 'id repetido é detectado'

    # =====================================================================
    Start-TestGroup 'Faixas de carga'

    Assert-Equal 'b00' (Get-WMLoadBand -Bands $bands -Load 0)    'carga 0'
    Assert-Equal 'b00' (Get-WMLoadBand -Bands $bands -Load 24.9) 'logo abaixo da fronteira'
    Assert-Equal 'b25' (Get-WMLoadBand -Bands $bands -Load 25)   'fronteira pertence à faixa de cima'
    Assert-Equal 'b50' (Get-WMLoadBand -Bands $bands -Load 74.9) 'faixa do meio'
    Assert-Equal 'b75' (Get-WMLoadBand -Bands $bands -Load 75)   'início da faixa alta'
    Assert-Equal 'b75' (Get-WMLoadBand -Bands $bands -Load 100)  'carga máxima'
    Assert-Null        (Get-WMLoadBand -Bands $bands -Load $null) 'carga nula não classifica'
    Assert-Null        (Get-WMLoadBand -Bands $bands -Load 150)  'fora de escala não classifica'
    # Comparação de string jogaria '100' na faixa ociosa: '100' -lt 25 é verdade.
    Assert-Equal 'b75' (Get-WMLoadBand -Bands $bands -Load '100') 'carga como texto não cai na faixa errada'

    # =====================================================================
    Start-TestGroup 'Janelas de carga: a lacuna QUEBRA a sequência  [MUTAÇÃO]'

    Assert-Equal 1 (Get-WMLoadRuns -Series @(10,80,80,80,10) -MinRun 3) 'três seguidas contam como uma janela'
    Assert-Equal 0 (Get-WMLoadRuns -Series @(10,80,80,10,80,80,10) -MinRun 3) 'picos de dois minutos não contam'
    Assert-Equal 2 (Get-WMLoadRuns -Series @(80,80,80,10,90,90,90,90) -MinRun 3) 'duas janelas separadas'
    Assert-Equal 1 (Get-WMLoadRuns -Series (@(80.0) * 50) -MinRun 3) 'uma janela longa conta uma vez só'

    # A propriedade que o docstring promete e que nenhum teste anterior cobria.
    Assert-Equal 0 (Get-WMLoadRuns -Series @(90,90,$null,90,90) -MinRun 3) 'lacuna no meio impede a janela de se formar'
    Assert-Equal 1 (Get-WMLoadRuns -Series @(90,90,90,$null,90,90) -MinRun 3) 'a janela antes da lacuna ainda conta'
    Assert-Null    (Get-WMLoadRuns -Series @($null,$null,$null) -MinRun 3) 'série toda vazia devolve nulo, não zero'
    Assert-Null    (Get-WMLoadRuns -Series @()) 'série sem itens devolve nulo'

    # =====================================================================
    Start-TestGroup 'Agregado de um dia'

    $f1 = New-Day '2026-01-01' -Samples 1440 -Bursts 10 -BurstLen 20 -Seed 7
    $r1 = New-WMDayRollup -Path $f1 -DayId '2026-01-01' -Bands $bands

    Assert-NotNull $r1                          'agregado foi produzido'
    Assert-Equal 1440 $r1.samples               'todas as amostras foram lidas'
    Assert-Equal 0    $r1.badLines              'nenhuma linha corrompida'
    Assert-Equal 0    $r1.reboots               'uptime monotônico, nenhum reinício'
    Assert-Equal 10   $r1.cpu.highLoadRuns      'dez rajadas viram dez janelas de carga alta'
    Assert-Equal 200  $r1.gpu['0'].tempCByLoad['b75'].n '10 rajadas x 20 amostras na faixa alta'
    Assert-GreaterThan $r1.gpu['0'].tempCByLoad['b75'].p50 $r1.gpu['0'].tempCByLoad['b00'].p50 'faixa alta é mais quente que a ociosa'

    # Memória e armazenamento não tinham NENHUMA asserção antes.
    Assert-NotNull $r1.mem.usedPct           'memória: uso agregado existe'
    Assert-NotNull $r1.mem.commitPct         'memória: commit agregado existe'
    Assert-NotNull $r1.mem.poolNonpagedMB    'memória: pool não-paginado agregado existe'
    Assert-Equal 1440 $r1.mem.poolNonpagedMB.n 'memória: todas as amostras entraram'
    Assert-NotNull $r1.sto.volFreeGB['C:']   'armazenamento: volume C: agregado'
    Assert-NotNull $r1.sto.diskBusyPct['0 C:'] 'armazenamento: ocupação do disco agregada'
    # A fixture drena 0,01 GB por amostra: o mínimo é a maré baixa do dia.
    Assert-LessThan $r1.sto.volFreeGB['C:'].min $r1.sto.volFreeGB['C:'].max 'espaço livre cai ao longo do dia'

    # =====================================================================
    Start-TestGroup 'A carga é a do PRÓPRIO subsistema  [MUTAÇÃO]'

    # Carga de GPU oposta à de CPU. Se a temperatura da GPU for estratificada
    # pela carga da CPU, a faixa alta passa a conter as amostras em que a placa
    # estava FRIA e a relação se inverte.
    $fx = New-Day '2026-01-05' -Samples 600 -Bursts 6 -BurstLen 20 -GpuAntiCorrelated -Seed 21
    $rx = New-WMDayRollup -Path $fx -DayId '2026-01-05' -Bands $bands

    $gAlta = $rx.gpu['0'].tempCByLoad['b75'].p50
    $gBaixa = $rx.gpu['0'].tempCByLoad['b00'].p50
    Assert-NotNull $gAlta  'faixa alta da GPU existe mesmo com carga anti-correlacionada'
    Assert-NotNull $gBaixa 'faixa ociosa da GPU existe'
    Assert-GreaterThan $gAlta $gBaixa 'GPU quente na SUA faixa alta, mesmo com a CPU ociosa nesse momento'
    Assert-GreaterThan ($gAlta - $gBaixa) 20 'a separação é grande: estratificar pela carga errada inverteria o sinal'

    # =====================================================================
    Start-TestGroup 'Lacuna de sonda não vira evidência de carga  [MUTAÇÃO]'

    # Duas rajadas curtas separadas por uma falha de sonda. Compactar a série
    # faria as duas metades se colarem e virarem carga sustentada que não houve.
    $fg = New-Day '2026-01-06' -Samples 200 -Bursts 0 -DropProbe cpu -DropFrom 50 -DropCount 5 -Seed 31
    $rg = New-WMDayRollup -Path $fg -DayId '2026-01-06' -Bands $bands
    Assert-Equal 5 $rg.probeGaps.cpu 'as cinco lacunas declaradas foram contadas'
    Assert-Equal 0 $rg.cpu.highLoadRuns 'dia ocioso com lacuna não inventa janela de carga'

    <#
        O caso que faltava, e que deixava a correção inteira sem defesa: uma
        rajada CURTA partida ao meio por uma lacuna. Se a série for compactada,
        as duas metades se colam e viram carga sustentada que nunca houve.
        Com dia ocioso (o teste acima) compactar não muda nada — por isso ele
        sozinho não bastava.
    #>
    $fp = New-Day '2026-01-12' -Samples 60 -Bursts 1 -BurstLen 5 -DropProbe cpu -DropFrom 7 -DropCount 1 -Seed 61
    $rp = New-WMDayRollup -Path $fp -DayId '2026-01-12' -Bands $bands
    Assert-Equal 1 $rp.probeGaps.cpu 'a lacuna no meio da rajada foi declarada'
    Assert-Equal 0 $rp.cpu.highLoadRuns 'duas metades de 2 amostras NÃO se colam através da lacuna'

    # Dia inteiro sem CPU: contador nunca pôde ser medido, então é nulo.
    $fn = New-Day '2026-01-07' -Samples 30 -Bursts 0 -DropProbe cpu -DropFrom 0 -DropCount 30 -Seed 33
    $rn = New-WMDayRollup -Path $fn -DayId '2026-01-07' -Bands $bands
    Assert-Null $rn.cpu.highLoadRuns 'sem nenhuma medida de CPU, janelas é NULO e não zero'
    Assert-Null $rn.cpu.util         'e a estatística de uso também'

    # =====================================================================
    Start-TestGroup 'Contenção da GPU: ausente não é "não houve"  [MUTAÇÃO]'

    # Modo degradado da sonda (FIELDS_MIN): a máscara de contenção não existe.
    # Gravar 0 aqui afirmaria que a placa nunca se conteve por calor sobre dado
    # que nunca foi medido — exatamente quando o driver está com problema.
    $fd = New-Day '2026-01-08' -Samples 40 -Bursts 1 -BurstLen 20 -NoThrottleFields -Seed 41
    $rd = New-WMDayRollup -Path $fd -DayId '2026-01-08' -Bands $bands
    Assert-Null  $rd.gpu['0'].throttle.thermal          'sem o campo, contenção térmica é NULA'
    Assert-Equal 0 $rd.gpu['0'].throttle.thermalMeasured 'e fica registrado que zero amostras a mediram'

    $fe = New-Day '2026-01-09' -Samples 40 -Bursts 1 -BurstLen 20 -Seed 41
    $re = New-WMDayRollup -Path $fe -DayId '2026-01-09' -Bands $bands
    Assert-Equal 0  $re.gpu['0'].throttle.thermal          'com o campo presente e falso, contenção é ZERO'
    Assert-Equal 40 $re.gpu['0'].throttle.thermalMeasured  'e 40 amostras a mediram'

    # =====================================================================
    Start-TestGroup 'Virada do dia não funde nem desfaz janelas  [MUTAÇÃO]'

    # Dia A termina em carga alta; dia B começa em carga alta. São DUAS janelas.
    # Contar sobre a concatenação faria virar uma só.
    $dA = New-Day '2026-01-10' -Samples 100 -Bursts 0 -BurstLen 10 -EdgeBurstEnd   -Seed 51
    $dB = New-Day '2026-01-11' -Samples 100 -Bursts 0 -BurstLen 10 -EdgeBurstStart -Seed 52

    $rA = New-WMDayRollup -Path $dA -DayId '2026-01-10' -Bands $bands
    $rB = New-WMDayRollup -Path $dB -DayId '2026-01-11' -Bands $bands
    Assert-Equal 1 $rA.cpu.highLoadRuns 'dia A tem uma janela, colada no fim'
    Assert-Equal 1 $rB.cpu.highLoadRuns 'dia B tem uma janela, colada no começo'

    $rAB = New-WMDayRollup -Path @($dA, $dB) -DayId 'janela' -Bands $bands
    Assert-Equal 200 $rAB.samples          'as amostras dos dois dias foram somadas'
    Assert-Equal 2   $rAB.cpu.highLoadRuns 'e as janelas continuam duas, não fundem na virada'

    # =====================================================================
    Start-TestGroup 'Robustez: nada de corromper ou derrubar o dia'

    $f2 = New-Day '2026-01-02' -Samples 100 -Bursts 2 -BurstLen 10 -Seed 3
    Add-Content -LiteralPath $f2 -Value '{"v":1,"host":"FIXTURE-HOST","at":"trunc' -Encoding UTF8
    Add-Content -LiteralPath $f2 -Value '123'    -Encoding UTF8
    Add-Content -LiteralPath $f2 -Value '"lixo"' -Encoding UTF8
    $r2 = New-WMDayRollup -Path $f2 -DayId '2026-01-02' -Bands $bands
    Assert-Equal 100 $r2.samples  'as amostras boas foram todas aproveitadas'
    Assert-Equal 3   $r2.badLines 'truncada, escalar e string: três linhas ruins contadas'

    # Valor não-numérico em linha sintaticamente válida não pode matar o dia.
    $f3 = New-Day '2026-01-03' -Samples 20 -Bursts 0 -Seed 5
    Add-Content -LiteralPath $f3 -Encoding UTF8 -Value `
        '{"v":1,"host":"FIXTURE-HOST","at":"2026-01-03T23:59:00.000-03:00","mode":"patrol","upH":100,"cpu":{"util":10,"mhz":"N/A"},"gpu":[{"idx":0,"tempC":"N/A","util":10}],"cov":{"ok":[],"gap":{}}}'
    $r3 = $null
    $erro = $null
    try { $r3 = New-WMDayRollup -Path $f3 -DayId '2026-01-03' -Bands $bands } catch { $erro = $_.Exception.Message }
    Assert-Null $erro 'valor "N/A" não lança exceção'
    Assert-Equal 21 $r3.samples 'a amostra com valor ruim ainda conta como amostra'
    Assert-Equal 20 $r3.cpu.mhzByLoad['b00'].n 'mas o valor ruim não entra na estatística'
    Assert-Equal 1  $r3.cpu.mhzByLoad['b00'].gaps 'e fica contado como lacuna'

    # Arquivo inexistente não pode estourar.
    $r4 = $null
    $erro2 = $null
    try { $r4 = New-WMDayRollup -Path (Join-Path $tmp 'nao-existe.jsonl') -DayId 'x' -Bands $bands } catch { $erro2 = $_.Exception.Message }
    Assert-Null $erro2 'arquivo ausente não lança exceção'
    Assert-Null $r4    'e devolve nulo'

    # =====================================================================
    Start-TestGroup 'A PROVA, medida honestamente: p95 contra p95'

    <#
        A versão anterior deste teste comparava a MEDIANA do dia contra o P95
        da faixa — duas estatísticas diferentes — e por isso não provava o que
        afirmava. Aqui a comparação é p95 contra p95, e os dois regimes são
        medidos, inclusive aquele em que a estratificação ganha pouco.
    #>
    function Get-Deriva {
        param([int]$Bursts, [int]$BurstLen, [string]$Tag)
        $a = New-Day "2026-02-$Tag" -Samples 1440 -Bursts $Bursts -BurstLen $BurstLen -ThermalOffsetHigh 0 -Seed 7
        $b = New-Day "2026-05-$Tag" -Samples 1440 -Bursts $Bursts -BurstLen $BurstLen -ThermalOffsetHigh 8 -Seed 7
        $ra = New-WMDayRollup -Path $a -DayId 'a' -Bands $bands
        $rb = New-WMDayRollup -Path $b -DayId 'b' -Bands $bands
        [pscustomobject]@{
            Fracao = [math]::Round(100.0 * $Bursts * $BurstLen / 1440.0, 1)
            Dia    = [math]::Abs($rb.gpu['0'].tempCAllDay.p95 - $ra.gpu['0'].tempCAllDay.p95)
            Faixa  = [math]::Abs($rb.gpu['0'].tempCByLoad['b75'].p95 - $ra.gpu['0'].tempCByLoad['b75'].p95)
        }
    }

    $real = Get-Deriva -Bursts 2  -BurstLen 15 -Tag '01'   # ~2% do dia sob carga: servidor típico
    $alta = Get-Deriva -Bursts 10 -BurstLen 20 -Tag '02'   # ~14% do dia sob carga

    ""
    "      carga alta em {0,4}% do dia :  p95 do dia {1,5} C   p95 da faixa {2,5} C" -f $real.Fracao, $real.Dia, $real.Faixa
    "      carga alta em {0,4}% do dia :  p95 do dia {1,5} C   p95 da faixa {2,5} C" -f $alta.Fracao, $alta.Dia, $alta.Faixa
    ""

    Assert-LessThan    $real.Dia   1.0 'com 2% do dia sob carga, o p95 do dia inteiro é cego'
    Assert-GreaterThan $real.Faixa 6.0 'e a mesma faixa de carga revela a deriva inteira'
    Assert-GreaterThan $alta.Faixa 6.0 'com 14% sob carga a faixa continua enxergando'
    # Registrado como medida, não como asserção de vitória: neste regime o p95
    # do dia também enxerga, e a estratificação ganha pouco. Está no README.
    Assert-GreaterThan $alta.Dia   6.0 'e neste regime o p95 do dia TAMBÉM enxerga — o ganho depende do regime'

    # =====================================================================
    Start-TestGroup 'Contadores positivos: o valor diferente de zero  [MUTAÇÃO]'

    <#
        Havia asserção para "ausente é nulo" e para "presente e falso é zero",
        e nenhuma para "presente e verdadeiro é N". Consequência medida: desligar
        a contagem de contenção térmica e a detecção de reinício era invisível
        para a suíte inteira.
    #>
    $ft = New-Day '2026-01-13' -Samples 40 -Bursts 1 -BurstLen 10 -ThrottleFrom 5 -ThrottleCount 7 -Seed 71
    $rt = New-WMDayRollup -Path $ft -DayId '2026-01-13' -Bands $bands
    Assert-Equal 7  $rt.gpu['0'].throttle.thermal         'sete amostras com contenção térmica são contadas'
    Assert-Equal 40 $rt.gpu['0'].throttle.thermalMeasured 'e as 40 mediram o campo'

    $fr = New-Day '2026-01-14' -Samples 40 -Bursts 0 -RebootAt 20 -Seed 73
    $rr = New-WMDayRollup -Path $fr -DayId '2026-01-14' -Bands $bands
    Assert-Equal 1 $rr.reboots 'queda de uptime no meio do dia é um reinício'

    # =====================================================================
    Start-TestGroup 'Perdas silenciosas deixam rastro  [MUTAÇÃO]'

    # Carga fora de escala não pode sumir sem contador.
    $fo = New-Day '2026-01-15' -Samples 20 -Bursts 0 -Seed 81
    Add-Content -LiteralPath $fo -Encoding UTF8 -Value `
        '{"v":1,"host":"FIXTURE-HOST","at":"2026-01-15T23:58:00.000-03:00","mode":"patrol","upH":100,"cpu":{"util":150,"mhz":4000},"cov":{"ok":[],"gap":{}}}'
    $ro = New-WMDayRollup -Path $fo -DayId '2026-01-15' -Bands $bands
    Assert-Equal 1 $ro.cpu.outOfBand 'carga de 150% fica contada como fora de faixa'

    <#
        Faixa com amostras e nenhuma medida legível não pode desaparecer: isso
        faria "dez minutos em carga alta sem termômetro" ficar indistinguível
        de "não houve carga alta".
    #>
    $fv = Join-Path $tmp '2026-01-16.jsonl'
    $linhas = @()
    for ($i = 0; $i -lt 6; $i++) {
        $linhas += ('{{"v":1,"host":"FIXTURE-HOST","at":"2026-01-16T0{0}:00:00.000-03:00","mode":"patrol","upH":100,"gpu":[{{"idx":0,"util":90,"tempC":null}}],"cov":{{"ok":[],"gap":{{}}}}}}' -f $i)
    }
    [System.IO.File]::WriteAllLines($fv, $linhas, (New-Object System.Text.UTF8Encoding($false)))
    $rv = New-WMDayRollup -Path $fv -DayId '2026-01-16' -Bands $bands
    Assert-NotNull $rv.gpu['0'].tempCByLoad['b75']      'a faixa de carga alta continua visível'
    Assert-Equal 0 $rv.gpu['0'].tempCByLoad['b75'].n    'com zero medidas'
    Assert-Equal 6 $rv.gpu['0'].tempCByLoad['b75'].gaps 'e seis lacunas declaradas'

    # =====================================================================
    Start-TestGroup 'Guardas de integridade da janela  [MUTAÇÃO]'

    # Tabela de faixas furada tem que lançar, não agregar torto em silêncio.
    $erroBanda = $null
    try { New-WMDayRollup -Path $f1 -DayId 'x' -Bands @(@{id='a';min=0;max=25}, @{id='b';min=50;max=100}) | Out-Null }
    catch { $erroBanda = $_.Exception.Message }
    Assert-NotNull $erroBanda 'tabela de faixas com buraco é recusada'

    # Janela com dois hosts é erro de operação, não dado a fundir calado.
    $h1 = New-Day '2026-01-17' -Samples 20 -Bursts 0 -Seed 91
    $h2 = Join-Path $tmp '2026-01-18.jsonl'
    & $fixture -Day '2026-01-18' -Samples 20 -Bursts 0 -Seed 92 -MachineName 'OUTRA-MAQUINA' -OutFile $h2 | Out-Null
    $rh = New-WMDayRollup -Path @($h1, $h2) -DayId 'mix' -Bands $bands
    Assert-NotNull $rh.hostsMixed 'janela com dois hosts é sinalizada'
    Assert-Equal 2 $rh.hostsMixed.Count 'e os dois nomes ficam registrados'

    # Arquivo faltando na janela encolhe a amostra: precisa ficar contado.
    $rm = New-WMDayRollup -Path @($h1, (Join-Path $tmp 'nao-existe.jsonl')) -DayId 'falta' -Bands $bands
    Assert-Equal 1  $rm.missingFiles 'o arquivo ausente da janela foi contado'
    Assert-Equal 20 $rm.samples      'e só as amostras do arquivo presente entraram'

    # =====================================================================
    Start-TestGroup 'O caso decisivo: sala quente contra refrigeração degradando'

    <#
        Este é o argumento que o projeto realmente precisa, e que faltava.

        A suíte provava que a estratificação enxerga degradação. Não provava que
        ela é INSUBSTITUÍVEL — nas fixtures anteriores o simples máximo do dia
        enxergava igual, em todos os regimes.

        O caso que só a visão estratificada resolve é distinguir DUAS causas
        que produzem a mesma subida na estatística do dia:

          sala quente              a curva inteira sobe 8 °C
          refrigeração degradando  só a ponta de carga alta sobe 8 °C

        A primeira é o ar-condicionado; a segunda é o dissipador. A ação é
        completamente diferente, e qualquer número não-estratificado dá a mesma
        resposta para as duas.
    #>
    $base   = New-Day '2026-03-01' -Samples 1440 -Bursts 6 -BurstLen 20 -Seed 101
    $sala   = New-Day '2026-03-02' -Samples 1440 -Bursts 6 -BurstLen 20 -ThermalOffsetAll  8 -Seed 101
    $refrig = New-Day '2026-03-03' -Samples 1440 -Bursts 6 -BurstLen 20 -ThermalOffsetHigh 8 -Seed 101

    $rBase   = New-WMDayRollup -Path $base   -DayId 'b' -Bands $bands
    $rSala   = New-WMDayRollup -Path $sala   -DayId 's' -Bands $bands
    $rRefrig = New-WMDayRollup -Path $refrig -DayId 'r' -Bands $bands

    $maxSala   = $rSala.gpu['0'].tempCAllDay.max   - $rBase.gpu['0'].tempCAllDay.max
    $maxRefrig = $rRefrig.gpu['0'].tempCAllDay.max - $rBase.gpu['0'].tempCAllDay.max
    $baixaSala   = $rSala.gpu['0'].tempCByLoad['b00'].p50   - $rBase.gpu['0'].tempCByLoad['b00'].p50
    $baixaRefrig = $rRefrig.gpu['0'].tempCByLoad['b00'].p50 - $rBase.gpu['0'].tempCByLoad['b00'].p50
    $altaSala   = $rSala.gpu['0'].tempCByLoad['b75'].p95   - $rBase.gpu['0'].tempCByLoad['b75'].p95
    $altaRefrig = $rRefrig.gpu['0'].tempCByLoad['b75'].p95 - $rBase.gpu['0'].tempCByLoad['b75'].p95

    ""
    "                              sala quente   refrigeracao"
    "      maximo do dia          {0,8} C {1,10} C   -- iguais: nao distingue" -f $maxSala, $maxRefrig
    "      faixa ociosa  (b00)    {0,8} C {1,10} C   -- AQUI esta a diferenca" -f $baixaSala, $baixaRefrig
    "      faixa de carga (b75)   {0,8} C {1,10} C" -f $altaSala, $altaRefrig
    ""

    Assert-LessThan    ([math]::Abs($maxSala - $maxRefrig)) 1.5 'o máximo do dia sobe igual nos dois casos: não distingue'
    Assert-GreaterThan $baixaSala   6.0 'sala quente também esquenta a máquina ociosa'
    Assert-LessThan    $baixaRefrig 1.0 'refrigeração degradando NÃO muda nada em repouso'
    Assert-GreaterThan $altaSala    6.0 'sob carga, sala quente sobe'
    Assert-GreaterThan $altaRefrig  6.0 'sob carga, refrigeração degradando sobe igual'
    Assert-GreaterThan ($baixaSala - $baixaRefrig) 6.0 'só a visão por faixa separa as duas causas'

    <#
        O mesmo caso com degradação CONTÍNUA em vez de degrau.

        O teste acima usa um degrau que cai exatamente em carga 75 — a mesma
        fronteira usada para estratificar — o que garante zero na faixa ociosa
        por construção. Degradação real é proporcional à potência dissipada e
        não coincide com fronteira nenhuma. Aqui a margem encolhe, e é honesto
        que ela apareça encolhida.
    #>
    $refrigLin = New-Day '2026-03-04' -Samples 1440 -Bursts 6 -BurstLen 20 -ThermalOffsetHigh 8 -ThermalModel Linear -Seed 101
    $rLin = New-WMDayRollup -Path $refrigLin -DayId 'l' -Bands $bands
    $baixaLin = $rLin.gpu['0'].tempCByLoad['b00'].p50 - $rBase.gpu['0'].tempCByLoad['b00'].p50
    $altaLin  = $rLin.gpu['0'].tempCByLoad['b75'].p95 - $rBase.gpu['0'].tempCByLoad['b75'].p95
    "      modelo continuo:  b00 {0,5:N1} C   b75 {1,5:N1} C" -f $baixaLin, $altaLin
    ""
    <#
        A asserção é sobre a RAZÃO entre as faixas, não sobre graus absolutos.

        A afirmação física é "sala quente move as duas faixas igualmente;
        refrigeração degradando move quase só a alta" — isso é uma proporção, e
        vale em qualquer escala de degradação. Codificar como limiar absoluto
        ("b00 < 2,0 °C") amarra o teste ao coeficiente escolhido: com uma
        degradação de 24 °C em vez de 8, a asserção quebraria sem que a tese
        tivesse deixado de valer.
    #>
    $razaoSala   = $baixaSala  / $altaSala
    $razaoRefrig = $baixaRefrig / $altaRefrig
    $razaoLin    = $baixaLin    / $altaLin
    "      razao b00/b75:  sala {0,5:N2}   refrig degrau {1,5:N2}   refrig continua {2,5:N2}" -f $razaoSala, $razaoRefrig, $razaoLin
    ""
    Assert-GreaterThan $razaoSala   0.80 'sala quente move as duas faixas na mesma proporção'
    Assert-LessThan    $razaoRefrig 0.25 'refrigeração degradando move quase só a faixa alta'
    Assert-LessThan    $razaoLin    0.25 'e isso vale também com degradação contínua'
    Assert-GreaterThan $altaLin     6.0  'a degradação contínua aparece inteira sob carga'

    <#
        O regime em que a tese NÃO se aplica, afirmado em vez de escondido:
        máquina que nunca fica ociosa não tem faixa b00, e aí não há como
        separar sala quente de refrigeração degradando por este método.
    #>
    $semOcio = New-Day '2026-03-05' -Samples 300 -Bursts 0 -IdleMin 80 -IdleMax 96 -Seed 111
    $rSem = New-WMDayRollup -Path $semOcio -DayId 'so' -Bands $bands
    Assert-Null    $rSem.gpu['0'].tempCByLoad['b00'] 'máquina sem ócio não produz faixa ociosa'
    Assert-NotNull $rSem.gpu['0'].tempCByLoad['b75'] 'só a faixa de carga alta existe'

    # =====================================================================
    Start-TestGroup 'Datas não seguem o calendário da cultura  [MUTAÇÃO]'

    <#
        Numa máquina pt-BR esta correção é indistinguível de não tê-la feito, e
        por isso ela precisava de um teste que forçasse a cultura: reverter
        Get-WMDayId e Get-WMTimestamp para a cultura corrente passava verde.

        Sob th-TH o ano sai budista (2569) e sob ar-SA sai Hijri (1448). A ronda
        gravaria 2569-08-15.jsonl, o padrão de validação de nome casaria, e nada
        reclamaria — a série histórica simplesmente passaria a ser de outro
        calendário no meio do caminho.
    #>
    $culturaOriginal = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        $quando = [datetime]'2026-08-15T13:42:23'
        foreach ($cult in 'th-TH', 'ar-SA', 'en-US') {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = New-Object System.Globalization.CultureInfo $cult
            Assert-Equal '2026-08-15' (Get-WMDayId -When $quando) "Get-WMDayId é gregoriano sob $cult"
            Assert-True ((Get-WMTimestamp -When $quando).StartsWith('2026-08-15T13:42:23')) "Get-WMTimestamp é gregoriano sob $cult"
        }
    } finally {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $culturaOriginal
    }

    # =====================================================================
    Start-TestGroup 'NaN e Infinity não são medidas  [MUTAÇÃO]'

    Assert-Null (ConvertTo-WMNumber 'NaN')       '"NaN" é rejeitado'
    Assert-Null (ConvertTo-WMNumber 'Infinity')  '"Infinity" é rejeitado'
    Assert-Null (ConvertTo-WMNumber '-Infinity') '"-Infinity" é rejeitado'
    Assert-Null (ConvertTo-WMNumber ([double]::NaN)) 'double NaN também'

    <#
        NaN é double válido e TryParse o aceita. Se passar, ele conta como
        medida (n sobe, gaps fica em zero) e, como [Array]::Sort o põe na
        frente, corrompe mínimo e mediana — e o agregado contaminado relê sem
        erro, atravessando até a linha-base.
    #>
    $fnan = Join-Path $tmp '2026-04-01.jsonl'
    $ln = @()
    foreach ($t in 40, 41, 43, 44) {
        $ln += ('{{"v":1,"host":"FIXTURE-HOST","at":"2026-04-01T0{0}:00:00.000-03:00","mode":"patrol","upH":100,"gpu":[{{"idx":0,"util":10,"tempC":{1}}}],"cov":{{"ok":[],"gap":{{}}}}}}' -f ($t - 40), $t)
    }
    $ln += '{"v":1,"host":"FIXTURE-HOST","at":"2026-04-01T05:00:00.000-03:00","mode":"patrol","upH":100,"gpu":[{"idx":0,"util":10,"tempC":"NaN"}],"cov":{"ok":[],"gap":{}}}'
    [System.IO.File]::WriteAllLines($fnan, $ln, (New-Object System.Text.UTF8Encoding($false)))

    $rnan = New-WMDayRollup -Path $fnan -DayId '2026-04-01' -Bands $bands
    Assert-Equal 4  $rnan.gpu['0'].tempCAllDay.n    'o NaN não é contado como medida'
    Assert-Equal 1  $rnan.gpu['0'].tempCAllDay.gaps 'e fica registrado como lacuna'
    Assert-Equal 40 $rnan.gpu['0'].tempCAllDay.min  'o mínimo não é corrompido'
    Assert-Equal 42 $rnan.gpu['0'].tempCAllDay.p50  'nem a mediana'

    # =====================================================================
    Start-TestGroup 'Lacuna preservada em TODOS os subsistemas  [MUTAÇÃO]'

    <#
        A regra 2 do módulo diz que séries preservam buracos "até o fim, não só
        na função onde é conveniente". A suíte só verificava isso na CPU — e o
        caminho da GPU, idêntico e correto, podia ser apagado sem que nada
        acusasse. Um teste por subsistema.
    #>
    $fgap = New-Day '2026-04-02' -Samples 60 -Bursts 1 -BurstLen 5 -DropProbe gpu -DropFrom 7 -DropCount 1 -Seed 121
    $rgap = New-WMDayRollup -Path $fgap -DayId '2026-04-02' -Bands $bands
    Assert-Equal 1 $rgap.cpu.highLoadRuns        'a CPU, que não teve lacuna, conta sua janela'
    Assert-Equal 0 $rgap.gpu['0'].highLoadRuns   'a GPU, que teve, NÃO cola as duas metades'
    Assert-Equal 1 $rgap.probeGaps.gpu           'e a lacuna da GPU foi declarada'

    $fmem = New-Day '2026-04-03' -Samples 40 -Bursts 0 -DropProbe mem -DropFrom 10 -DropCount 6 -Seed 131
    $rmem = New-WMDayRollup -Path $fmem -DayId '2026-04-03' -Bands $bands
    Assert-Equal 34 $rmem.mem.usedPct.n    'memória: só as amostras medidas contam'
    Assert-Equal 6  $rmem.mem.usedPct.gaps 'memória: as seis lacunas ficam registradas'
    Assert-GreaterThan $rmem.mem.usedPct.min 0 'memória: lacuna não vira mínimo zero'

    $fsto = New-Day '2026-04-04' -Samples 40 -Bursts 0 -DropProbe sto -DropFrom 10 -DropCount 6 -Seed 141
    $rsto = New-WMDayRollup -Path $fsto -DayId '2026-04-04' -Bands $bands
    Assert-Equal 34 $rsto.sto.volFreeGB['C:'].n    'disco: só as amostras medidas contam'
    Assert-Equal 6  $rsto.sto.volFreeGB['C:'].gaps 'disco: as seis lacunas ficam registradas'
    Assert-GreaterThan $rsto.sto.volFreeGB['C:'].min 0 'disco: lacuna não vira espaço livre zero'

    # =====================================================================
    Start-TestGroup 'Mais de uma GPU  [MUTAÇÃO]'

    # A suíte inteira só tinha máquinas de uma GPU. Esta tem duas, e a segunda
    # nunca sai do ócio.
    $f2g = Join-Path $tmp '2026-04-05.jsonl'
    $l2 = @()
    for ($i = 0; $i -lt 10; $i++) {
        $l2 += ('{{"v":1,"host":"FIXTURE-HOST","at":"2026-04-05T00:{0:D2}:00.000-03:00","mode":"patrol","upH":100,"gpu":[{{"idx":0,"util":90,"tempC":78}},{{"idx":1,"util":4,"tempC":40}}],"cov":{{"ok":[],"gap":{{}}}}}}' -f $i)
    }
    [System.IO.File]::WriteAllLines($f2g, $l2, (New-Object System.Text.UTF8Encoding($false)))
    $r2g = New-WMDayRollup -Path $f2g -DayId '2026-04-05' -Bands $bands

    Assert-Equal 2 $r2g.gpu.Count 'as duas GPUs são agregadas separadamente'
    Assert-NotNull $r2g.gpu['0'].tempCByLoad['b75'] 'a GPU 0 tem faixa de carga alta'
    Assert-Null    $r2g.gpu['1'].tempCByLoad['b75'] 'a GPU 1, sempre ociosa, não tem'
    Assert-Equal 78 $r2g.gpu['0'].tempCByLoad['b75'].p50 'e cada uma fica com a SUA temperatura'
    Assert-Equal 40 $r2g.gpu['1'].tempCByLoad['b00'].p50 'sem misturar com a outra'

    # GPU ausente em algumas amostras: a série de temperatura precisa preservar
    # o buraco tanto quanto a de carga.
    $f2b = Join-Path $tmp '2026-04-09.jsonl'
    $l2b = @()
    for ($i = 0; $i -lt 6; $i++) {
        if ($i -lt 4) {
            $l2b += ('{{"v":1,"host":"FIXTURE-HOST","at":"2026-04-09T0{0}:00:00.000-03:00","mode":"patrol","upH":100,"gpu":[{{"idx":0,"util":10,"tempC":4{0}}}],"cov":{{"ok":[],"gap":{{}}}}}}' -f $i)
        } else {
            $l2b += ('{{"v":1,"host":"FIXTURE-HOST","at":"2026-04-09T0{0}:00:00.000-03:00","mode":"patrol","upH":100,"cov":{{"ok":[],"gap":{{"gpu":"sonda morta"}}}}}}' -f $i)
        }
    }
    [System.IO.File]::WriteAllLines($f2b, $l2b, (New-Object System.Text.UTF8Encoding($false)))
    $r2b = New-WMDayRollup -Path $f2b -DayId '2026-04-09' -Bands $bands
    Assert-Equal 4 $r2b.gpu['0'].tempCAllDay.n    'só as amostras com GPU contam na temperatura'
    Assert-Equal 2 $r2b.gpu['0'].tempCAllDay.gaps 'e as duas ausências ficam registradas como lacuna'
    Assert-Equal 2 $r2b.gpu['0'].util.gaps        'idem na série de carga'

    # =====================================================================
    Start-TestGroup 'Ordem dos arquivos não inventa reinício  [MUTAÇÃO]'

    # Uptime ENCADEADO: o dia B começa onde o A terminou, como numa máquina que
    # não reiniciou. Passados ao contrário, a emenda produziria um salto para
    # trás e um reinício que não houve.
    $o1 = New-Day '2026-04-06' -Samples 30 -Bursts 0 -UptimeStartH 100   -Seed 151
    $o2 = New-Day '2026-04-07' -Samples 30 -Bursts 0 -UptimeStartH 100.5 -Seed 152
    $rFwd = New-WMDayRollup -Path @($o1, $o2) -DayId 'f' -Bands $bands
    $rRev = New-WMDayRollup -Path @($o2, $o1) -DayId 'r' -Bands $bands
    Assert-Equal 0 $rFwd.reboots 'na ordem certa, nenhum reinício'
    Assert-Equal $rFwd.reboots $rRev.reboots 'e a ordem de entrada não muda o resultado'

    # =====================================================================
    Start-TestGroup 'outOfBand conta carga fora de escala, não ausência de CPU'

    $fnc = Join-Path $tmp '2026-04-08.jsonl'
    $lnc = @()
    for ($i = 0; $i -lt 5; $i++) {
        $lnc += ('{{"v":1,"host":"FIXTURE-HOST","at":"2026-04-08T00:{0:D2}:00.000-03:00","mode":"patrol","upH":100,"cov":{{"ok":[],"gap":{{"cpu":"sonda morta"}}}}}}' -f $i)
    }
    [System.IO.File]::WriteAllLines($fnc, $lnc, (New-Object System.Text.UTF8Encoding($false)))
    $rnc = New-WMDayRollup -Path $fnc -DayId '2026-04-08' -Bands $bands
    Assert-Equal 0 $rnc.cpu.outOfBand 'cinco amostras sem CPU não são cinco cargas fora de faixa'
    Assert-Equal 5 $rnc.probeGaps.cpu 'elas são cinco lacunas declaradas'

} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Show-TestSummary
exit (Get-TestExitCode)
