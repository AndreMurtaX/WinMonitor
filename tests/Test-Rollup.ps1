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
    Assert-Equal 5 $rg.gaps.cpu 'as cinco lacunas declaradas foram contadas'
    Assert-Equal 0 $rg.cpu.highLoadRuns 'dia ocioso com lacuna não inventa janela de carga'

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

} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Show-TestSummary
exit (Get-TestExitCode)
