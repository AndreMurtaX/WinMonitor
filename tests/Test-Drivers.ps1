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

    Um script que nunca foi executado por um teste é um script que nunca foi
    executado.

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

try {

    # =====================================================================
    Start-TestGroup 'Invoke-Rollup: um dia problemático não derruba o lote'

    $p1 = New-TempProject
    Add-FixtureDay $p1 '2026-01-01' -Samples 120 -Bursts 1 -BurstLen 10 -Seed 11
    Add-FixtureDay $p1 '2026-01-02' -Samples 120 -Bursts 1 -BurstLen 10 -Seed 12
    Add-FixtureDay $p1 '2026-01-03' -Samples 120 -Bursts 1 -BurstLen 10 -Seed 13

    # O dia do meio ganha um valor não-numérico em linha sintaticamente válida.
    Add-Content -LiteralPath (Join-Path $p1 'data\patrol\2026-01-02.jsonl') -Encoding UTF8 -Value `
        '{"v":1,"host":"FIXTURE-HOST","at":"2026-01-02T23:59:00.000-03:00","mode":"patrol","upH":100,"cpu":{"util":10,"mhz":"N/A"},"gpu":[{"idx":0,"util":10,"tempC":"N/A"}],"cov":{"ok":[],"gap":{}}}'

    & (Join-Path $p1 'src\Invoke-Rollup.ps1') | Out-Null

    foreach ($d in '2026-01-01', '2026-01-02', '2026-01-03') {
        Assert-True (Test-Path -LiteralPath (Join-Path $p1 "data\rollup\$d.json")) "dia $d foi agregado"
    }
    $r2 = Read-Json (Join-Path $p1 'data\rollup\2026-01-02.json')
    Assert-Equal 121 $r2.samples 'a amostra com valor ruim ainda conta como amostra'
    Assert-Equal 1   $r2.cpu.mhzByLoad.b00.gaps 'e o valor ilegível vira lacuna, não zero'

    # =====================================================================
    Start-TestGroup 'Invoke-Rollup: o dia corrente fica marcado parcial'

    $p2 = New-TempProject
    $hoje = Get-Date -Format 'yyyy-MM-dd'
    Add-FixtureDay $p2 $hoje -Samples 30 -Bursts 0 -Seed 21

    & (Join-Path $p2 'src\Invoke-Rollup.ps1') | Out-Null
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $p2 "data\rollup\$hoje.json"))) 'sem -Day, o dia corrente não é agregado'

    & (Join-Path $p2 'src\Invoke-Rollup.ps1') -Day $hoje | Out-Null
    $rh = Read-Json (Join-Path $p2 "data\rollup\$hoje.json")
    Assert-NotNull $rh 'com -Day explícito ele é agregado'
    Assert-True    $rh.partial 'e fica marcado como parcial'

    # Chegando mais amostras, o parcial é refeito em vez de congelar pela metade.
    Add-FixtureDay $p2 $hoje -Samples 90 -Bursts 0 -Seed 22
    & (Join-Path $p2 'src\Invoke-Rollup.ps1') -Day $hoje | Out-Null
    $rh2 = Read-Json (Join-Path $p2 "data\rollup\$hoje.json")
    Assert-Equal 90 $rh2.samples 'o agregado parcial foi refeito com o dado novo'

    # =====================================================================
    Start-TestGroup 'New-Baseline: EXECUTA (a linha que matava o script)'

    <#
        Qualquer execução que passe da determinação da janela já prova que a
        colisão $windowDays / [int]$WindowDays não existe mais. Antes, isto
        lançava ArgumentTransformationMetadataException.
    #>
    $p3 = New-TempProject
    for ($i = 1; $i -le 14; $i++) {
        Add-FixtureDay $p3 ('2026-02-{0:D2}' -f $i) -Samples 200 -Bursts 2 -BurstLen 10 -Seed (300 + $i)
    }
    & (Join-Path $p3 'src\Invoke-Rollup.ps1') | Out-Null

    $saida = & (Join-Path $p3 'src\New-Baseline.ps1') -CheckOnly 2>&1 | Out-String
    Assert-True ($saida -match 'Elegibilidade') 'o script chega a avaliar elegibilidade sem estourar'
    Assert-True ($saida -match 'Pronto para congelar') '14 dias com 28 janelas são elegíveis'

    # =====================================================================
    Start-TestGroup 'New-Baseline: congela e registra a janela exata'

    $b = & (Join-Path $p3 'src\New-Baseline.ps1') -Reason 'teste automatizado' 2>&1 | Out-String
    $bl = Read-Json (Join-Path $p3 'data\baseline\baseline.json')

    Assert-NotNull $bl 'a linha-base foi gravada'
    Assert-Equal 'teste automatizado' $bl.reason 'o motivo ficou registrado'
    Assert-Equal $false $bl.forced 'não foi forçada'
    Assert-Equal 14 $bl.window.days 'a janela tem os 14 dias'
    Assert-Equal 14 $bl.window.dayList.Count 'e os dias exatos ficaram gravados'
    Assert-Equal '2026-02-01' $bl.window.dayList[0]  'primeiro dia da janela'
    Assert-Equal '2026-02-14' $bl.window.dayList[-1] 'último dia da janela'
    Assert-Equal 28 $bl.evidence.highLoadRuns 'a evidência conta as 28 janelas de carga'
    Assert-NotNull $bl.profile.gpu.'0'.tempCByLoad.b75 'e o perfil TEM a faixa de carga alta'

    # A anterior vai para o arquivo, não para o lixo.
    & (Join-Path $p3 'src\New-Baseline.ps1') -Reason 'segunda vez' | Out-Null
    $arq = @(Get-ChildItem -LiteralPath (Join-Path $p3 'data\baseline\archive') -Filter '*.json' -ErrorAction SilentlyContinue)
    Assert-Equal 1 $arq.Count 'a linha-base anterior foi arquivada'

    # =====================================================================
    Start-TestGroup 'New-Baseline: as recusas'

    # Janela sem nenhuma carga alta.
    $p4 = New-TempProject
    for ($i = 1; $i -le 14; $i++) {
        Add-FixtureDay $p4 ('2026-02-{0:D2}' -f $i) -Samples 200 -Bursts 0 -Seed (400 + $i)
    }
    & (Join-Path $p4 'src\Invoke-Rollup.ps1') | Out-Null
    $s4 = & (Join-Path $p4 'src\New-Baseline.ps1') -Reason 'nao deveria congelar' 3>&1 2>&1 | Out-String
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $p4 'data\baseline\baseline.json'))) 'janela ociosa não congela'
    Assert-True ($s4 -match 'insuficiente') 'e a recusa é explicada'

    <#
        O caso residual da B-03: CPU com carga alta, GPU sempre ociosa.
        Uma versão anterior aceitava o b75 da CPU como substituto e congelava
        uma linha-base cuja referência térmica de GPU — o motivo do projeto —
        não existia, declarando-se íntegra.
    #>
    $p5 = New-TempProject
    for ($i = 1; $i -le 14; $i++) {
        Add-FixtureDay $p5 ('2026-02-{0:D2}' -f $i) -Samples 200 -Bursts 2 -BurstLen 10 -GpuAntiCorrelated:$false -Seed (500 + $i)
    }
    # Zera a carga da GPU em todas as amostras, mantendo a da CPU.
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
    Assert-True ($s5 -match 'faixa de carga alta') 'e a recusa nomeia a faixa que falta'

    # Dias curtos demais não contam como dia.
    $p6 = New-TempProject
    for ($i = 1; $i -le 14; $i++) {
        Add-FixtureDay $p6 ('2026-02-{0:D2}' -f $i) -Samples 10 -Bursts 1 -BurstLen 5 -Seed (600 + $i)
    }
    & (Join-Path $p6 'src\Invoke-Rollup.ps1') | Out-Null
    $s6 = & (Join-Path $p6 'src\New-Baseline.ps1') -CheckOnly 2>&1 | Out-String
    Assert-True ($s6 -match 'Ainda não há dado suficiente') '14 arquivos de 10 amostras não são 14 dias'

    # Sem motivo declarado, não congela.
    $s7 = & (Join-Path $p3 'src\New-Baseline.ps1') 3>&1 2>&1 | Out-String
    Assert-True ($s7 -match 'Reason') 'linha-base sem motivo é recusada'

} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Show-TestSummary
exit (Get-TestExitCode)
