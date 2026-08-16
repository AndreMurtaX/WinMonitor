#requires -Version 5.1
<#
    Testes de ponta a ponta dos scripts que orquestram: Invoke-Rollup.ps1 e
    New-Baseline.ps1.

    POR QUE ESTE ARQUIVO EXISTE
    ---------------------------
    Test-Rollup.ps1 cobre as funções puras e não invocava NENHUM dos dois
    scripts. Consequência medida: New-Baseline.ps1 continha um erro que o matava
    na primeira linha real de execução — uma variável $windowDays colidindo com
    o parâmetro [int]$WindowDays, que em PowerShell são a MESMA variável — e a
    suíte inteira passava verde. O defeito ficou escondido porque, sem nenhum
    dia completo de ronda, o script retornava antes de chegar na linha.

    Um script que nenhum teste executa é um script que nunca foi executado.

    DATAS RELATIVAS, NÃO FIXAS
    --------------------------
    Os dias são gerados a partir de hoje para trás. Datas fixas deixariam a
    suíte vermelha nos dias do ano em que uma delas coincidisse com o dia
    corrente, que New-Baseline exclui da janela — um vermelho por motivo nenhum,
    que é exatamente o tipo de coisa que faz alguém afrouxar a asserção.

    ISOLAMENTO
    ----------
    Cada teste roda contra uma CÓPIA do projeto num diretório temporário, com
    fixtures plantadas em data\patrol. Nada toca os dados reais da máquina.

      .\tests\Test-Drivers.ps1
#>
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TestKit.ps1')

$fixture = Join-Path $PSScriptRoot 'New-Fixture.ps1'
$tmp     = Join-Path ([System.IO.Path]::GetTempPath()) ('wm-drv-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

<#
    Cultura invariante aqui também, pelo mesmo motivo da produção — e por um
    adicional: se o teste calcular "hoje" pela cultura corrente enquanto a
    produção usa Get-WMDayId, os dois discordam de que dia é hoje sob th-TH e a
    suíte falha por assimetria, não por defeito.
#>
$INV  = [System.Globalization.CultureInfo]::InvariantCulture
$hoje = (Get-Date).ToString('yyyy-MM-dd', $INV)

# Dias consecutivos terminando ontem: nunca colidem com o dia corrente.
function Get-DayIds {
    param([int]$Count, [int]$EndDaysAgo = 1)
    $out = @()
    for ($i = $Count; $i -ge 1; $i--) {
        $out += (Get-Date).AddDays(-($EndDaysAgo + $i - 1)).ToString('yyyy-MM-dd', $INV)
    }
    $out
}

$projSeq = 0
function New-TempProject {
    $script:projSeq++
    $p = Join-Path $tmp ("proj{0}" -f $script:projSeq)
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'src')    -Destination $p -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $root 'config') -Destination $p -Recurse -Force
    New-Item -ItemType Directory -Path (Join-Path $p 'data\patrol') -Force | Out-Null
    $p
}

function Add-FixtureDay {
    param([string]$Proj, [string]$Day)
    $rest = $args
    & $fixture -Day $Day -OutFile (Join-Path $Proj "data\patrol\$Day.jsonl") @rest | Out-Null
}

function Read-Json {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

<#
    Procura um trecho na saída de um script, ignorando como ela foi quebrada.

    Write-Warning quebra o texto na largura do console, então uma frase pode
    chegar partida ao meio por uma quebra de linha e a busca literal falha
    dependendo do tamanho da janela. Isso já produziu um vermelho que não era
    defeito nenhum.
#>
function Test-Saida {
    param([string]$Texto, [string]$Padrao)
    ($Texto -replace '\s+', ' ') -match $Padrao
}

<#
    Dia em que a GPU trabalha e o termômetro nunca responde.

    DUAS rajadas por dia, de propósito: com carga constante o dia inteiro vira
    uma janela só, 14 dias dariam 14 janelas, e a linha-base seria recusada por
    ELEGIBILIDADE em vez de pela guarda de faixa — o teste passaria verde
    testando outra coisa.
#>
function Add-BlindGpuDay {
    param([string]$Proj, [string]$Day, [int]$Samples = 200)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $l = @()
    for ($i = 0; $i -lt $Samples; $i++) {
        $alta = (($i -ge 5 -and $i -lt 25) -or ($i -ge 105 -and $i -lt 125))
        $u = $(if ($alta) { 90 } else { 5 })

        <#
            O uptime é formatado com cultura INVARIANTE de propósito.

            O operador -f usa a cultura corrente: num Windows pt-BR, 100.02 sai
            como "100,02" e produz  "upH":100,02  — JSON inválido. Numa versão
            anterior deste auxiliar, 196 das 200 linhas do dia eram descartadas
            como corrompidas e só as quatro em que o uptime calhava de ser
            inteiro sobreviviam. O teste ficava vermelho por um motivo que não
            tinha nada a ver com o que ele testava.
        #>
        $up = (100 + $i / 60.0).ToString('0.00', $inv)

        $l += ('{{"v":1,"host":"FIXTURE-HOST","at":"{0}T{1:D2}:{2:D2}:00.000-03:00","mode":"patrol","upH":{3},"cpu":{{"util":{4},"mhz":4800}},"gpu":[{{"idx":0,"util":{4},"tempC":null}}],"cov":{{"ok":[],"gap":{{}}}}}}' -f `
              $Day, [int]($i / 60), ($i % 60), $up, $u)
    }
    [System.IO.File]::WriteAllLines((Join-Path $Proj "data\patrol\$Day.jsonl"), $l, (New-Object System.Text.UTF8Encoding($false)))
}

<#
    Dia de máquina com DUAS GPUs: a principal trabalha, a secundária (uma
    integrada, ou uma placa só de vídeo) nunca sai do ócio. É a configuração
    mais comum em servidor e desktop, e a que expôs uma linha-base impossível.
#>
function Add-TwoGpuDay {
    param([string]$Proj, [string]$Day, [int]$Samples = 200)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $l = @()
    for ($i = 0; $i -lt $Samples; $i++) {
        $alta = (($i -ge 5 -and $i -lt 25) -or ($i -ge 105 -and $i -lt 125))
        $u    = $(if ($alta) { 90 } else { 5 })
        $t0   = $(if ($alta) { 79 } else { 42 })
        $up   = (100 + $i / 60.0).ToString('0.00', $inv)
        $l += ('{{"v":1,"host":"FIXTURE-HOST","at":"{0}T{1:D2}:{2:D2}:00.000-03:00","mode":"patrol","upH":{3},"cpu":{{"util":{4},"mhz":4800}},"gpu":[{{"idx":0,"util":{4},"tempC":{5}}},{{"idx":1,"util":3,"tempC":38}}],"cov":{{"ok":[],"gap":{{}}}}}}' -f `
              $Day, [int]($i / 60), ($i % 60), $up, $u, $t0)
    }
    [System.IO.File]::WriteAllLines((Join-Path $Proj "data\patrol\$Day.jsonl"), $l, (New-Object System.Text.UTF8Encoding($false)))
}

<#
    Dia de máquina GPU-bound: a placa trabalha em rajadas e o processador nunca
    passa de 20%. É o perfil de um servidor de inferência ou de transcodificação
    — e é o caso em que contar janelas de carga só na CPU deixa a linha-base
    permanentemente inelegível.
#>
function Add-GpuBoundDay {
    param([string]$Proj, [string]$Day, [int]$Samples = 200)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $l = @()
    for ($i = 0; $i -lt $Samples; $i++) {
        $alta = (($i -ge 5 -and $i -lt 25) -or ($i -ge 105 -and $i -lt 125))
        $gu   = $(if ($alta) { 90 } else { 4 })
        $gt   = $(if ($alta) { 79 } else { 39 })
        $up   = (100 + $i / 60.0).ToString('0.00', $inv)
        $l += ('{{"v":1,"host":"FIXTURE-HOST","at":"{0}T{1:D2}:{2:D2}:00.000-03:00","mode":"patrol","upH":{3},"cpu":{{"util":20,"mhz":3900}},"gpu":[{{"idx":0,"util":{4},"tempC":{5}}}],"cov":{{"ok":[],"gap":{{}}}}}}' -f `
              $Day, [int]($i / 60), ($i % 60), $up, $gu, $gt)
    }
    [System.IO.File]::WriteAllLines((Join-Path $Proj "data\patrol\$Day.jsonl"), $l, (New-Object System.Text.UTF8Encoding($false)))
}

try {

    # =====================================================================
    Start-TestGroup 'Invoke-Rollup: valor ilegível não para o lote nem vira medida'

    <#
        O nome deste grupo era "um dia problemático não derruba o lote", o que
        deixou de ser verdade no bom sentido: depois da conversão segura, valor
        ilegível não derruba nada. O try/catch por dia continua no script como
        defesa contra falhas futuras, mas não é ele que este teste exercita.
    #>
    $d3 = Get-DayIds -Count 3
    $p1 = New-TempProject
    foreach ($d in $d3) { Add-FixtureDay $p1 $d -Samples 120 -Bursts 1 -BurstLen 10 -Seed 11 }

    Add-Content -LiteralPath (Join-Path $p1 "data\patrol\$($d3[1]).jsonl") -Encoding UTF8 -Value `
        ('{{"v":1,"host":"FIXTURE-HOST","at":"{0}T23:59:00.000-03:00","mode":"patrol","upH":100,"cpu":{{"util":10,"mhz":"N/A"}},"gpu":[{{"idx":0,"util":10,"tempC":"NaN"}}],"cov":{{"ok":[],"gap":{{}}}}}}' -f $d3[1])

    & (Join-Path $p1 'src\Invoke-Rollup.ps1') | Out-Null

    foreach ($d in $d3) {
        Assert-True (Test-Path -LiteralPath (Join-Path $p1 "data\rollup\$d.json")) "dia $d foi agregado"
    }
    $r2 = Read-Json (Join-Path $p1 "data\rollup\$($d3[1]).json")
    Assert-Equal 121 $r2.samples 'a amostra com valor ruim ainda conta como amostra'
    Assert-Equal 1   $r2.cpu.mhzByLoad.b00.gaps 'o "N/A" vira lacuna, não zero'
    Assert-Equal 1   $r2.gpu.'0'.tempCAllDay.gaps 'e o "NaN" também'

    # =====================================================================
    Start-TestGroup 'Invoke-Rollup: o dia corrente fica marcado parcial'

    $p2 = New-TempProject
    Add-FixtureDay $p2 $hoje -Samples 30 -Bursts 0 -Seed 21

    & (Join-Path $p2 'src\Invoke-Rollup.ps1') | Out-Null
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $p2 "data\rollup\$hoje.json"))) 'sem -Day, o dia corrente não é agregado'

    & (Join-Path $p2 'src\Invoke-Rollup.ps1') -Day $hoje | Out-Null
    $rh = Read-Json (Join-Path $p2 "data\rollup\$hoje.json")
    Assert-NotNull $rh 'com -Day explícito ele é agregado'
    Assert-True    $rh.partial 'e fica marcado como parcial'

    Add-FixtureDay $p2 $hoje -Samples 90 -Bursts 0 -Seed 22
    & (Join-Path $p2 'src\Invoke-Rollup.ps1') -Day $hoje | Out-Null
    Assert-Equal 90 (Read-Json (Join-Path $p2 "data\rollup\$hoje.json")).samples 'o agregado parcial foi refeito com o dado novo'

    # =====================================================================
    Start-TestGroup 'New-Baseline: EXECUTA (a linha que matava o script)'

    $d14 = Get-DayIds -Count 14
    $p3  = New-TempProject
    foreach ($d in $d14) { Add-FixtureDay $p3 $d -Samples 200 -Bursts 2 -BurstLen 10 -Seed 33 }
    & (Join-Path $p3 'src\Invoke-Rollup.ps1') | Out-Null

    $saida = & (Join-Path $p3 'src\New-Baseline.ps1') -CheckOnly 2>&1 | Out-String
    Assert-True (Test-Saida $saida 'Elegibilidade')        'o script chega a avaliar elegibilidade sem estourar'
    Assert-True (Test-Saida $saida 'Pronto para congelar') '14 dias com 28 janelas são elegíveis'

    # =====================================================================
    Start-TestGroup 'New-Baseline: congela e registra a janela exata'

    & (Join-Path $p3 'src\New-Baseline.ps1') -Reason 'teste automatizado' | Out-Null
    $bl = Read-Json (Join-Path $p3 'data\baseline\baseline.json')

    Assert-NotNull $bl 'a linha-base foi gravada'
    Assert-Equal 'teste automatizado' $bl.reason 'o motivo ficou registrado'
    Assert-Equal $false $bl.forced 'não foi forçada'
    Assert-Equal 14 $bl.window.days 'a janela tem os 14 dias'
    Assert-Equal $d14[0]  $bl.window.dayList[0]  'primeiro dia da janela'
    Assert-Equal $d14[-1] $bl.window.dayList[-1] 'último dia da janela'
    Assert-Equal 28 $bl.evidence.highLoadRuns 'a evidência conta as 28 janelas de carga'
    Assert-NotNull $bl.profile.gpu.'0'.tempCByLoad.b75 'e o perfil TEM a faixa de carga alta'

    & (Join-Path $p3 'src\New-Baseline.ps1') -Reason 'segunda vez' | Out-Null
    $arq = @(Get-ChildItem -LiteralPath (Join-Path $p3 'data\baseline\archive') -Filter '*.json' -ErrorAction SilentlyContinue)
    Assert-GreaterThan $arq.Count 0 'a linha-base anterior foi arquivada, não descartada'

    # =====================================================================
    Start-TestGroup 'New-Baseline: o dia corrente fica FORA da janela'

    $p7 = New-TempProject
    foreach ($d in $d14) { Add-FixtureDay $p7 $d -Samples 200 -Bursts 2 -BurstLen 10 -Seed 44 }
    Add-FixtureDay $p7 $hoje -Samples 200 -Bursts 2 -BurstLen 10 -Seed 45
    & (Join-Path $p7 'src\Invoke-Rollup.ps1') | Out-Null
    & (Join-Path $p7 'src\New-Baseline.ps1') -Reason 'sem o dia de hoje' | Out-Null

    $b7 = Read-Json (Join-Path $p7 'data\baseline\baseline.json')
    Assert-NotNull $b7 'congelou'
    Assert-True (-not ($b7.window.dayList -contains $hoje)) 'e o dia corrente, incompleto, não entrou na janela'
    Assert-Equal $d14[-1] $b7.window.dayList[-1] 'o último dia da janela é ontem'

    # =====================================================================
    Start-TestGroup 'New-Baseline: elegibilidade olha só a janela'

    <#
        O bloqueador da primeira rodada: elegibilidade medida sobre TODOS os
        agregados existentes e perfil construído sobre os últimos brutos. Aqui
        há 20 agregados e só 14 dias de bruto — a evidência tem que contar 14.
    #>
    $d20 = Get-DayIds -Count 20
    $p8  = New-TempProject
    foreach ($d in $d20) { Add-FixtureDay $p8 $d -Samples 200 -Bursts 2 -BurstLen 10 -Seed 55 }
    & (Join-Path $p8 'src\Invoke-Rollup.ps1') | Out-Null

    # Remove o bruto dos 6 dias mais antigos; os agregados deles permanecem.
    foreach ($d in $d20[0..5]) { Remove-Item -LiteralPath (Join-Path $p8 "data\patrol\$d.jsonl") -Force }
    Assert-Equal 20 (@(Get-ChildItem -LiteralPath (Join-Path $p8 'data\rollup') -Filter '*.json')).Count '20 agregados no disco'

    & (Join-Path $p8 'src\New-Baseline.ps1') -Reason 'janela restrita' | Out-Null
    $b8 = Read-Json (Join-Path $p8 'data\baseline\baseline.json')
    Assert-Equal 14 $b8.window.days 'a janela usa só os 14 dias com bruto'
    Assert-Equal 14 $b8.evidence.validDays 'e a evidência conta 14 dias, não 20'
    Assert-Equal 28 $b8.evidence.highLoadRuns 'as janelas de carga são as da janela, não as de todo o histórico'

    # =====================================================================
    Start-TestGroup 'New-Baseline: as recusas'

    # Janela sem nenhuma carga alta.
    $p4 = New-TempProject
    foreach ($d in $d14) { Add-FixtureDay $p4 $d -Samples 200 -Bursts 0 -Seed 66 }
    & (Join-Path $p4 'src\Invoke-Rollup.ps1') | Out-Null
    $s4 = & (Join-Path $p4 'src\New-Baseline.ps1') -Reason 'nao deveria congelar' 3>&1 2>&1 | Out-String
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $p4 'data\baseline\baseline.json'))) 'janela ociosa não congela'
    Assert-True (Test-Saida $s4 'insuficiente') 'e a recusa é explicada'

    <#
        O residual da B-03: CPU com carga alta, GPU sempre ociosa. Uma versão
        anterior aceitava o b75 da CPU como substituto e congelava uma
        linha-base cuja referência térmica de GPU não existia.
    #>
    $p5 = New-TempProject
    foreach ($d in $d14) { Add-FixtureDay $p5 $d -Samples 200 -Bursts 2 -BurstLen 10 -Seed 77 }
    Get-ChildItem -LiteralPath (Join-Path $p5 'data\patrol') -Filter '*.jsonl' | ForEach-Object {
        $novo = Get-Content -LiteralPath $_.FullName -Encoding UTF8 | ForEach-Object {
            $o = $_ | ConvertFrom-Json
            $o.gpu[0].util = 5
            ConvertTo-Json -InputObject $o -Depth 10 -Compress
        }
        [System.IO.File]::WriteAllLines($_.FullName, $novo, (New-Object System.Text.UTF8Encoding($false)))
    }
    & (Join-Path $p5 'src\Invoke-Rollup.ps1') | Out-Null
    $s5 = & (Join-Path $p5 'src\New-Baseline.ps1') -Reason 'gpu sempre ociosa' 3>&1 2>&1 | Out-String
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $p5 'data\baseline\baseline.json'))) 'CPU com carga alta NÃO substitui a GPU sem carga alta'
    Assert-True (Test-Saida $s5 'faixa de carga alta') 'e a recusa nomeia a faixa que falta'

    <#
        Faixa de carga alta EXISTINDO mas sem nenhuma medida (n=0): a GPU
        trabalhou e o termômetro nunca respondeu. Uma referência assim pareceria
        íntegra e não serviria para comparar nada.
    #>
    $p9 = New-TempProject
    foreach ($d in $d14) { Add-BlindGpuDay $p9 $d -Samples 200 }
    & (Join-Path $p9 'src\Invoke-Rollup.ps1') | Out-Null
    $s9 = & (Join-Path $p9 'src\New-Baseline.ps1') -Reason 'gpu sem termometro' 3>&1 2>&1 | Out-String
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $p9 'data\baseline\baseline.json'))) 'faixa alta com zero medidas não serve de referência'
    Assert-True (Test-Saida $s9 'faixa de carga alta') 'e a recusa diz por quê'

    <#
        Piso de amostras por dia, ISOLADO.

        Não basta encher a janela de dias curtos: o piso os descarta ANTES de
        contar as janelas de carga deles, então a recusa viria pelo critério de
        janelas e o teste passaria verde testando outra coisa. (Um teste
        anterior fazia exatamente isso — remover o piso inteiro não mudava o
        resultado.)

        A montagem que isola: 10 dias longos com 3 rajadas cada (30 janelas, bem
        acima do mínimo de 20) mais 4 dias curtos. Com o piso, sobram 10 dias
        válidos e a recusa é POR DIAS. Sem o piso, seriam 14 dias e a linha-base
        congelaria.
    #>
    $p6 = New-TempProject
    foreach ($d in $d14[0..9])  { Add-FixtureDay $p6 $d -Samples 200 -Bursts 3 -BurstLen 10 -Seed 88 }
    foreach ($d in $d14[10..13]) { Add-FixtureDay $p6 $d -Samples 30 -Bursts 2 -BurstLen 5 -Seed 89 }
    & (Join-Path $p6 'src\Invoke-Rollup.ps1') | Out-Null
    $s6 = & (Join-Path $p6 'src\New-Baseline.ps1') -CheckOnly 2>&1 | Out-String
    Assert-True (Test-Saida $s6 '30\s*/\s*20')  'as 30 janelas de carga satisfazem o critério de carga'
    Assert-True (Test-Saida $s6 '10\s*/\s*14')  'mas só 10 dias passam o piso de amostras'
    Assert-True (Test-Saida $s6 'Ainda não há dado suficiente') 'e por isso a linha-base é recusada'

    # Sem motivo declarado, não congela.
    $s7 = & (Join-Path $p3 'src\New-Baseline.ps1') 3>&1 2>&1 | Out-String
    Assert-True (Test-Saida $s7 'Reason') 'linha-base sem motivo é recusada'

    # =====================================================================
    Start-TestGroup 'New-Baseline: segunda GPU ociosa NÃO impede a linha-base'

    <#
        A correção da guarda de faixa exigia b75 de TODAS as GPUs, o que criava
        um impasse permanente: uma integrada ou uma secundária ociosa nunca
        passa de 75%, e a máquina ficava sem conseguir congelar referência
        nenhuma mesmo com a GPU principal completa. Basta uma placa com
        referência; as demais ficam registradas.
    #>
    $p10 = New-TempProject
    foreach ($d in $d14) { Add-TwoGpuDay $p10 $d -Samples 200 }
    & (Join-Path $p10 'src\Invoke-Rollup.ps1') | Out-Null
    & (Join-Path $p10 'src\New-Baseline.ps1') -Reason 'duas gpus, a segunda ociosa' 3>&1 2>&1 | Out-Null

    $b10 = Read-Json (Join-Path $p10 'data\baseline\baseline.json')
    Assert-NotNull $b10 'a linha-base congela com a GPU principal referenciada'
    Assert-NotNull $b10.profile.gpu.'0'.tempCByLoad.b75 'a GPU 0 tem faixa de carga alta'
    Assert-Null    $b10.profile.gpu.'1'.tempCByLoad.b75 'a GPU 1, sempre ociosa, não tem'
    Assert-Equal 1 @($b10.evidence.gpusWithoutReference).Count 'e fica registrado que uma GPU ficou sem referência'
    Assert-Equal '1' @($b10.evidence.gpusWithoutReference)[0] 'nomeando qual'

    # =====================================================================
    Start-TestGroup 'New-Baseline: máquina GPU-bound fica elegível'

    <#
        Contar janelas de carga só na CPU deixava um servidor de inferência
        permanentemente inelegível: placa a 90% o dia inteiro, processador a
        20%, evidência 0/20, e a única saída era -Force — que grava a fraqueza
        dentro da linha-base. Agora a janela conta em qualquer subsistema, com
        o máximo por dia para não contar a mesma rajada duas vezes.
    #>
    $p12 = New-TempProject
    foreach ($d in $d14) { Add-GpuBoundDay $p12 $d -Samples 200 }
    & (Join-Path $p12 'src\Invoke-Rollup.ps1') | Out-Null

    $s12 = & (Join-Path $p12 'src\New-Baseline.ps1') -CheckOnly 2>&1 | Out-String
    Assert-True (Test-Saida $s12 'Pronto para congelar') 'GPU trabalhando com CPU ociosa é evidência válida'
    Assert-True (Test-Saida $s12 'gpu0=28')              'e a origem das janelas fica declarada'

    & (Join-Path $p12 'src\New-Baseline.ps1') -Reason 'servidor gpu-bound' 3>&1 2>&1 | Out-Null
    $b12 = Read-Json (Join-Path $p12 'data\baseline\baseline.json')
    Assert-NotNull $b12 'e a linha-base congela sem -Force'
    Assert-Equal $false $b12.forced 'sem carregar fraqueza registrada'
    Assert-Equal 28 $b12.evidence.highLoadRuns 'com as 28 janelas da GPU como evidência'
    Assert-NotNull $b12.profile.gpu.'0'.tempCByLoad.b75 'e a referência térmica da placa está lá'

    # =====================================================================
    Start-TestGroup 'New-Baseline: as recusas que continuam valendo'

    # Mas se NENHUMA GPU tiver referência, continua recusando.
    $p11 = New-TempProject
    foreach ($d in $d14) { Add-BlindGpuDay $p11 $d -Samples 200 }
    & (Join-Path $p11 'src\Invoke-Rollup.ps1') | Out-Null
    $s11 = & (Join-Path $p11 'src\New-Baseline.ps1') -Reason 'nenhuma gpu com referencia' 3>&1 2>&1 | Out-String
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $p11 'data\baseline\baseline.json'))) 'nenhuma GPU com referência ainda é recusa'
    Assert-True (Test-Saida $s11 'nenhuma GPU') 'e a recusa diz exatamente isso'

    # =====================================================================
    Start-TestGroup 'Invoke-Rules: o filtro de hardware recebe o que precisa'

    <#
        Este teste existe por causa de uma desconexão real: o motor de regras
        filtra por modelo de GPU, e nada em produção populava o nome da placa.
        Toda regra de fabricante caía em "não se aplica" — que tem cara de
        resposta legítima e era, na verdade, o limiar nunca sendo conferido.

        O que se testa aqui é a LIGAÇÃO entre host.json e o motor, que é onde a
        falha morava. A lógica do filtro em si é testada em Test-Rules.ps1.
    #>
    $p13 = New-TempProject
    # @(...) obrigatório: com um item só, o array desenrola para string e o
    # índice [0] devolveria o primeiro CARACTERE da data.
    $d1  = @(Get-DayIds -Count 1)[0]
    Add-FixtureDay $p13 $d1 -Samples 200 -Bursts 2 -BurstLen 10 -Seed 99
    & (Join-Path $p13 'src\Invoke-Rollup.ps1') | Out-Null

    # host.json no formato que Get-WMHostFacts grava, com a placa do limiar.
    $hostJson = '{"collectedAt":"2026-08-15T00:00:00.000-03:00","host":"FIXTURE-HOST",' +
                '"os":"Windows 11 Pro","cpuName":"CPU de teste","cpuBaseMHz":3504,' +
                '"gpuNames":["NVIDIA GeForce RTX 3080","Intel(R) UHD Graphics 750"]}'
    [System.IO.File]::WriteAllText((Join-Path $p13 'data\host.json'), $hostJson, (New-Object System.Text.UTF8Encoding($false)))

    & (Join-Path $p13 'src\Invoke-Rules.ps1') -Quiet | Out-Null
    $ach = Read-Json (Join-Path $p13 "data\findings\$d1.json")

    Assert-NotNull $ach 'os achados foram gravados'
    $naoAplica = @($ach.coverage.notApplicable.PSObject.Properties.Name)
    Assert-True (-not ($naoAplica -contains 'R-GPU-TEMP-SPEC-3080')) 'a regra da RTX 3080 NÃO cai em "hardware não confere" numa máquina que tem a placa'
    Assert-True (@($ach.coverage.evaluated) -contains 'R-GPU-TEMP-SPEC-3080') 'ela consta como efetivamente avaliada'

    # E numa máquina sem a placa, aí sim não se aplica.
    $p14 = New-TempProject
    Add-FixtureDay $p14 $d1 -Samples 200 -Bursts 2 -BurstLen 10 -Seed 99
    & (Join-Path $p14 'src\Invoke-Rollup.ps1') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $p14 'data\host.json'),
        ($hostJson -replace 'NVIDIA GeForce RTX 3080', 'AMD Radeon RX 7900 XTX'),
        (New-Object System.Text.UTF8Encoding($false)))

    & (Join-Path $p14 'src\Invoke-Rules.ps1') -Quiet | Out-Null
    $ach2 = Read-Json (Join-Path $p14 "data\findings\$d1.json")
    $naoAplica2 = @($ach2.coverage.notApplicable.PSObject.Properties.Name)
    Assert-True ($naoAplica2 -contains 'R-GPU-TEMP-SPEC-3080') 'noutra placa, a regra fica declarada como não aplicável'
    Assert-True (-not $ach2.coverage.complete) 'e isso conta como lacuna de cobertura'

    # =====================================================================
    Start-TestGroup 'A PONTE exame→regras, executada de verdade  [MUTAÇÃO]'

    <#
        ESTE GRUPO EXISTE PORQUE A PONTE NUNCA TINHA RODADO SOB TESTE.

        `Invoke-Rules.ps1` enxerta o bloco do exame (`evt`, `dsk`) na raiz do
        objeto que o motor avalia. É o único caminho de produção que faz isso, e
        a décima primeira verificação mediu: acrescentar 'dsk' e 'evt' à lista de
        chaves descartadas deixava as OITO suítes verdes — 822 de 822. Um
        `throw` dentro do bloco provava o resto: Test-Drivers 56 passou, 0
        falhou. Nenhuma linha dali jamais executou sob teste, porque nenhuma
        suíte escrevia `data\exam\<dia>.json`.

        Em produção isso desliga as DUAS regras de falha de hardware do projeto
        — R-WHEA-HARDWARE-ERROR e R-DISK-HEALTH-DEGRADED. Elas caem em "sem
        dado", o veredito continua "normal", e o portão continua verde: a forma
        exata de silêncio que este projeto existe para não ter.

        E `Test-Exam.ps1` AFIRMAVA que as três mutações estavam defendidas. A do
        meio não estava: aquele teste fazia o enxerto ele mesmo, com Add-Member,
        em vez de executar o `Invoke-Rules.ps1`. Testar a própria imitação do
        código não é testar o código.
    #>
    $dEx = @(Get-DayIds -Count 1)[0]
    $pEx = New-TempProject
    Add-FixtureDay $pEx $dEx -Samples 200 -Bursts 2 -BurstLen 10 -Seed 77
    & (Join-Path $pEx 'src\Invoke-Rollup.ps1') | Out-Null

    <#
        Sem exame no disco, as duas regras têm de ficar SEM DADO — nunca
        aprovadas. Esta metade é o contraste que dá sentido à outra: se elas já
        disparassem sem exame, o enxerto não estaria sendo medido.
    #>
    & (Join-Path $pEx 'src\Invoke-Rules.ps1') -Quiet | Out-Null
    $semExame = Read-Json (Join-Path $pEx "data\findings\$dEx.json")
    $semDado = @($semExame.coverage.noData.PSObject.Properties.Name)
    Assert-True ($semDado -contains 'R-WHEA-HARDWARE-ERROR') 'sem exame, a regra de WHEA fica SEM DADO'
    Assert-True ($semDado -contains 'R-DISK-HEALTH-DEGRADED') 'e a de saúde de disco também'
    Assert-True (-not (@($semExame.findings | ForEach-Object { $_.ruleId }) -contains 'R-WHEA-HARDWARE-ERROR')) 'e nenhuma das duas dispara sem dado'

    <#
        Agora COM exame no disco, escrito no formato que Invoke-Exam grava. As
        chaves 'v', 'host', 'at', 'mode', 'coverage' e 'complete' são as que o
        enxerto descarta; 'evt' e 'dsk' são as que ele precisa levar adiante.
    #>
    $exameJson = [ordered]@{
        v = 1; host = 'FIXTURE'; at = "$dEx`T12:00:00-03:00"; mode = 'exam'
        evt = [ordered]@{ windowDays = 30; logReadable = $true; wheaErrors = 3; unexpectedShutdowns = 0; kernelPower41 = 0; cleanShutdowns = 10 }
        dsk = [ordered]@{ readable = $true; unhealthy = 2; disks = @(@{ id = 0; health = 'Warning'; name = 'FIXTURE DISK' }) }
        coverage = [ordered]@{ smart = 'lacuna sintetica do teste' }
        complete = $false
    }
    New-Item -ItemType Directory -Path (Join-Path $pEx 'data\exam') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $pEx "data\exam\$dEx.json"),
        ($exameJson | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

    & (Join-Path $pEx 'src\Invoke-Rules.ps1') -Quiet | Out-Null
    $comExame = Read-Json (Join-Path $pEx "data\findings\$dEx.json")
    $disparadas = @($comExame.findings | ForEach-Object { $_.ruleId })
    $avaliadas  = @($comExame.coverage.evaluated)

    Assert-True ($avaliadas -contains 'R-WHEA-HARDWARE-ERROR') 'com exame no disco, a regra de WHEA é efetivamente AVALIADA'
    Assert-True ($avaliadas -contains 'R-DISK-HEALTH-DEGRADED') 'e a de saúde de disco também'
    Assert-True ($disparadas -contains 'R-WHEA-HARDWARE-ERROR') 'e ela DISPARA: 3 erros de hardware não passam despercebidos'
    Assert-True ($disparadas -contains 'R-DISK-HEALTH-DEGRADED') 'e a de disco dispara com 2 discos fora de Healthy'

    <#
        E o veredito sobe até a severidade da mais grave. Sem esta asserção o
        enxerto poderia levar o dado adiante e o resultado morrer na saída — que
        é a forma de defeito da nona rodada: a trava parando na fronteira do
        módulo em vez de acompanhar a consequência.
    #>
    Assert-Equal 'parar' $comExame.verdict 'e o veredito do dia sobe para a severidade do WHEA'
    <#
        A asserção olha o CAMPO da evidência, não o texto dela. Uma versão
        anterior fazia '[string]$evid -match 2' — e evidence é um array de
        objetos, cuja conversão para texto dá o nome do tipo. Ela teria passado
        ou falhado por motivo nenhum, e é o mesmo defeito que fez um mutante
        sobreviver duas horas atrás: conferir a renderização em vez do valor.
    #>
    $evid = @(($comExame.findings | Where-Object { $_.ruleId -eq 'R-DISK-HEALTH-DEGRADED' }).evidence)
    Assert-Equal 'dsk.unhealthy' $evid[0].metric 'a evidência da regra de disco aponta a métrica que a sonda escreveu'
    Assert-Equal 2 $evid[0].value 'com o valor medido, vindo do exame que o enxerto trouxe'

    # =====================================================================
    Start-TestGroup 'Registro da ronda: o que ele PROMETE ao dono da máquina  [MUTAÇÃO]'

    <#
        ESTE GRUPO NASCEU DE UMA PERGUNTA DO DONO DA MÁQUINA.

        Registrei a ronda em modo Interactive, sem elevação, e não disse que
        isso faz o Windows criar uma janela de console a cada disparo — uma
        piscada por minuto na tela dele. Ele notou sozinho no dia seguinte e
        teve de perguntar o que era.

        A ressalva não é cosmética: é a diferença entre uma escolha e uma
        surpresa. E ressalva sem teste é ressalva que some no próximo commit.

        -Simular imprime o plano e não registra nada — é o que torna isto
        testável sem alterar a configuração do sistema de quem roda a suíte.
    #>
    $registrador = Join-Path $root 'tools\Register-PatrolTask.ps1'
    Assert-True (Test-Path $registrador) 'o registrador da ronda existe'

    $planoInterativo = (& $registrador -CurrentUserOnly -Simular -TaskName 'PatrolTesteSimulado' | Out-String)
    Assert-True ($planoInterativo -match 'nada foi registrado') '-Simular anuncia que não registrou nada'
    Assert-True ($planoInterativo -match 'piscada por minuto') 'o modo Interactive DECLARA a janela que pisca a cada disparo'
    Assert-True ($planoInterativo -match 'WindowStyle Hidden nao evita') 'e diz que o argumento óbvio não resolve'

    <#
        E O CONTRASTE, que é o que dá sentido à ressalva: no modo S4U não há
        janela nenhuma, e carimbar a ressalva nos dois lugares seria tão errado
        quanto omiti-la — o dono decidiria contra um custo que não existe.
    #>
    $planoS4U = (& $registrador -Simular -TaskName 'PatrolTesteSimulado' | Out-String)
    Assert-True (-not ($planoS4U -match 'piscada por minuto')) 'o modo S4U NÃO carrega a ressalva: nele não há janela para piscar'
    Assert-True ($planoS4U -match 'S4U') 'e ele se identifica como S4U'
    Assert-True ($planoS4U -match 'Limited') 'sem -Elevado o nível é Limited'
    Assert-True ($planoS4U -match 'lacuna DECLARADA') 'e a lacuna do SMART detalhado segue declarada, não calada'

    <#
        A asserção olha a linha do PRINCIPAL — 'nivel Highest' —, que imprime o
        valor que vai ser registrado, e não a frase explicativa.

        Medido: com a asserção casando só 'Highest' em qualquer lugar do texto,
        um mutante que forçava o nível a Limited SOBREVIVIA. O plano anunciava
        "Nivel Highest" enquanto registrava Limited, porque a frase derivava da
        intenção de quem chamou e não do valor. Conferir a promessa em vez do
        valor é o defeito que este projeto inteiro existe para não ter.
    #>
    $planoElevado = (& $registrador -Elevado -Simular -TaskName 'PatrolTesteSimulado' | Out-String)
    Assert-True ($planoElevado -match 'nivel Highest') 'com -Elevado o PRINCIPAL sai com nível Highest'
    Assert-True ($planoElevado -match 'SMART detalhado e temperatura de CPU') 'e o plano diz o que isso destrava'
    Assert-True ($planoS4U -match 'nivel Limited') 'e sem -Elevado o principal sai com nível Limited'

    <#
        O QUE NÃO TEM MUTANTE, dito em vez de negado: a guarda '-Simular' em si.
        Um mutante que a desligasse faria ESTA suíte registrar tarefa de verdade
        na máquina de quem a roda. Teste não altera configuração de sistema de
        ninguém, e um defeito que só se manifesta causando o dano não vale o
        dano. A asserção abaixo pega a quebra depois de acontecida; ela não a
        previne, e isso está escrito aqui em vez de ficar subentendido.
    #>
    <#
        A consulta passa por cmd.exe com stderr descartado NA ORIGEM, e não por
        '2>&1' aqui: stderr de comando nativo sob $ErrorActionPreference='Stop'
        vira ErrorRecord e derruba a suíte inteira. Foi assim que sete asserções
        de Test-Gate ficaram no vácuo, e a armadilha é a mesma aqui — 'tarefa
        não encontrada' é justamente o desfecho que eu espero, e ele chega pelo
        canal que mata o processo.
    #>
    & cmd.exe /c 'schtasks /query /tn "\WinMonitor\PatrolTesteSimulado" >nul 2>&1'
    Assert-True ($LASTEXITCODE -ne 0) 'quatro simulações não deixaram tarefa nenhuma registrada'

} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Show-TestSummary
exit (Get-TestExitCode)
