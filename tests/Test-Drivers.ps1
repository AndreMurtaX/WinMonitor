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

$hoje = Get-Date -Format 'yyyy-MM-dd'

# Dias consecutivos terminando ontem: nunca colidem com o dia corrente.
function Get-DayIds {
    param([int]$Count, [int]$EndDaysAgo = 1)
    $out = @()
    for ($i = $Count; $i -ge 1; $i--) {
        $out += (Get-Date).AddDays(-($EndDaysAgo + $i - 1)).ToString('yyyy-MM-dd')
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

    # Mas se NENHUMA GPU tiver referência, continua recusando.
    $p11 = New-TempProject
    foreach ($d in $d14) { Add-BlindGpuDay $p11 $d -Samples 200 }
    & (Join-Path $p11 'src\Invoke-Rollup.ps1') | Out-Null
    $s11 = & (Join-Path $p11 'src\New-Baseline.ps1') -Reason 'nenhuma gpu com referencia' 3>&1 2>&1 | Out-String
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $p11 'data\baseline\baseline.json'))) 'nenhuma GPU com referência ainda é recusa'
    Assert-True (Test-Saida $s11 'nenhuma GPU') 'e a recusa diz exatamente isso'

} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Show-TestSummary
exit (Get-TestExitCode)
