#requires -Version 5.1
<#
    Roda todas as suítes e devolve código de saída diferente de zero se
    qualquer uma falhar.

      .\tests\Run-All.ps1

    O PORTÃO JÁ MENTIU, E ISSO CONTAMINOU TUDO
    ------------------------------------------
    A versão anterior conferia $LASTEXITCODE depois de chamar a suíte. Quando a
    suíte ESTOURAVA antes de chegar no seu 'exit', $LASTEXITCODE guardava o zero
    da suíte ANTERIOR — e o portão imprimia "TODAS AS SUITES PASSARAM" com 135
    testes que nunca rodaram. Medido, não suposto.

    Uma suíte esvaziada — arquivo só com um comentário — também passava verde.

    Isso não é um defeito de teste: é um defeito no instrumento que declara que
    os testes passaram, e ele invalida retroativamente toda afirmação de verde
    deste projeto. Três defesas agora, porque uma só já se provou insuficiente:

      1. EXECUÇÃO ISOLADA. Cada suíte roda num processo próprio, cujo código de
         saída é dela e de mais ninguém. Estouro vira código != 0 de verdade.
      2. PISO DE TESTES. Cada suíte declara quantos testes ela tinha da última
         vez que este arquivo foi atualizado. Perder testes em silêncio — por
         arquivo esvaziado, por 'return' precoce, por bloco que deixou de rodar
         — passa a ser vermelho.
      3. RESUMO OBRIGATÓRIO. A linha 'N passou, M falhou' precisa existir e ser
         lida. Suíte que não a imprime não terminou, por mais que saia com zero.

    O piso é atualizado À MÃO quando testes são acrescentados. Isso é de
    propósito: se ele se ajustasse sozinho, não seria piso.
#>
[CmdletBinding()]
param(
    [switch]$Quiet,
    <#
        Costura para Test-Gate.ps1: o portão precisa poder rodar contra suítes
        sintéticas, senão ele é a única peça do projeto que ninguém consegue
        testar — e foi exatamente essa a situação em que ele mentiu.

        -SuiteDir troca o diretório; -SuiteSpec troca a lista, no formato
        'arquivo:piso' separado por vírgula. Nenhum dos dois é usado em produção.
    #>
    [string]$SuiteDir,
    [string]$SuiteSpec,
    [int]$SuiteTimeoutSec = 600
)

$suites = @(
    @{ file = 'Test-Rollup.ps1';      min = 147 }
    @{ file = 'Test-Rules.ps1';       min = 135 }
    @{ file = 'Test-Laudo.ps1';       min = 105 }
    @{ file = 'Test-LaudoDriver.ps1'; min = 23  }
    @{ file = 'Test-Report.ps1';      min = 60  }
    @{ file = 'Test-Exam.ps1';        min = 30  }
    @{ file = 'Test-Gate.ps1';        min = 16  }
    @{ file = 'Test-Drivers.ps1';     min = 56  }
)

if ($SuiteSpec) {
    $suites = @(
        $SuiteSpec -split ',' | Where-Object { $_ } | ForEach-Object {
            $par = $_ -split ':'
            @{ file = $par[0].Trim(); min = [int]$par[1] }
        }
    )
}

$dir     = if ($SuiteDir) { $SuiteDir } else { $PSScriptRoot }
$psExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$falhas  = New-Object System.Collections.ArrayList
$totalOk = 0

<#
    SUÍTE QUE EXISTE E NÃO ESTÁ NA LISTA É VERMELHO.

    O piso pega suíte esvaziada; não pegava suíte APAGADA DA LISTA. Medido: tirar
    uma entrada de $suites fazia 23 testes sumirem e o portão continuava verde,
    apenas com um total menor — e ninguém confere total de cabeça. Agora a lista
    é confrontada com o diretório: arquivo Test-*.ps1 que ninguém roda acusa.
#>
$naDisco = @(
    Get-ChildItem -LiteralPath $dir -Filter 'Test-*.ps1' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'TestKit.ps1' } | ForEach-Object { $_.Name }
)
$naLista = @($suites | ForEach-Object { $_.file })
foreach ($f in $naDisco) {
    if ($naLista -notcontains $f) { [void]$falhas.Add("$f existe em tests\ e não está na lista do portão: ninguém o executa") }
}

foreach ($s in $suites) {
    $p = Join-Path $dir $s.file
    ""
    "##################  $($s.file)  ##################"

    if (-not (Test-Path -LiteralPath $p)) {
        [void]$falhas.Add("$($s.file): o arquivo não existe")
        "ARQUIVO AUSENTE"
        continue
    }

    <#
        Processo próprio, COM PRAZO. O código de saída é desta suíte, não da
        anterior — e uma suíte que trava não pode segurar o portão para sempre:
        medido, o portão esperava indefinidamente e depois declarava verde.
    #>
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $proc = Start-Process -FilePath $psExe -PassThru -NoNewWindow -Wait:$false `
                -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $p `
                -RedirectStandardOutput $tmpOut -RedirectStandardError ($tmpOut + '.err')

    <#
        Tocar em .Handle ANTES de esperar. Sem isto, Start-Process -PassThru
        devolve um objeto cujo ExitCode vem VAZIO depois do término, e a
        comparação 'código de saída diferente de zero' passa a reprovar tudo —
        inclusive suíte verde. É a armadilha clássica do -PassThru, e ela
        transformaria o portão em ruído até alguém desligá-lo.
    #>
    $null = $proc.Handle

    if (-not $proc.WaitForExit($SuiteTimeoutSec * 1000)) {
        try { $proc.Kill() } catch { }
        [void]$falhas.Add("$($s.file): estourou o prazo de $SuiteTimeoutSec s e foi morta")
        Remove-Item -LiteralPath $tmpOut, ($tmpOut + '.err') -Force -ErrorAction SilentlyContinue
        continue
    }
    $codigo = $proc.ExitCode
    $texto  = (Get-Content -LiteralPath $tmpOut -Raw -ErrorAction SilentlyContinue) + "`n" +
              (Get-Content -LiteralPath ($tmpOut + '.err') -Raw -ErrorAction SilentlyContinue)
    Remove-Item -LiteralPath $tmpOut, ($tmpOut + '.err') -Force -ErrorAction SilentlyContinue

    if ($Quiet) { ($texto -split "`n" | Select-Object -Last 6) -join "`n" } else { $texto }

    $ms = @([regex]::Matches($texto, '(\d+)\s+passou,\s+(\d+)\s+falhou'))

    if ($ms.Count -eq 0) {
        [void]$falhas.Add("$($s.file): não imprimiu o resumo — a suíte não chegou ao fim (código $codigo)")
        continue
    }
    <#
        MAIS DE UM RESUMO também é vermelho. O portão lia o primeiro e ignorava
        o resto: uma suíte que imprimisse '99 passou, 0 falhou' e depois o
        resumo verdadeiro com falhas passava. Resumo é um, ou não é resumo.
    #>
    if ($ms.Count -gt 1) {
        [void]$falhas.Add("$($s.file): imprimiu $($ms.Count) linhas de resumo — não dá para saber qual é a verdadeira")
        continue
    }
    $m = $ms[0]

    $passou = [int]$m.Groups[1].Value
    $falhou = [int]$m.Groups[2].Value
    $totalOk += $passou

    if ($codigo -ne 0) { [void]$falhas.Add("$($s.file): código de saída $codigo") }
    if ($falhou -gt 0) { [void]$falhas.Add("$($s.file): $falhou teste(s) falharam") }
    if ($passou -lt [int]$s.min) {
        [void]$falhas.Add("$($s.file): rodou $passou testes, o piso é $($s.min) — testes sumiram")
    }
}

<#
    PISO GLOBAL, além do piso por suíte. É a rede que pega perda de teste em
    qualquer lugar — inclusive nos casos que o piso por suíte não vê, porque a
    suíte inteira deixou de ser executada.
#>
# Soma à mão: Measure-Object -Property não enxerga CHAVE de hashtable, só
# propriedade de objeto — e falha em vez de devolver zero.
$pisoTotal = 0
foreach ($s in $suites) { $pisoTotal += [int]$s.min }
if (-not $SuiteDir -and $totalOk -lt $pisoTotal) {
    [void]$falhas.Add("total de $totalOk testes, abaixo do piso global de $pisoTotal")
}

""
"total de testes que passaram: $totalOk   (piso global: $pisoTotal)"
if ($falhas.Count -eq 0) {
    "TODAS AS SUITES PASSARAM"
    exit 0
} else {
    foreach ($f in $falhas) { "  x $f" }
    "$($falhas.Count) problema(s) no portão"
    exit 1
}
