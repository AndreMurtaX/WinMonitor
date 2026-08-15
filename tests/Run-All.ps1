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
    deste projeto. As defesas foram crescendo à medida que cada verificação
    adversarial furou a anterior:

      1. EXECUÇÃO ISOLADA. Cada suíte roda num processo próprio, cujo código de
         saída é dela e de mais ninguém. Estouro vira código != 0 de verdade.
      2. PISO POR SUÍTE. Cada uma declara quantos testes tinha da última vez que
         este arquivo foi atualizado. Perder testes em silêncio vira vermelho.
      3. RESUMO OBRIGATÓRIO, E ÚNICO. A linha 'N passou, M falhou' precisa
         existir e ser uma só. Duas linhas de resumo é vermelho: não dá para
         saber qual é a verdadeira.
      4. RESUMO CONFERIDO CONTRA AS LINHAS IMPRESSAS. TestKit imprime uma linha
         por teste; o resumo tem de bater com a contagem delas. Suíte que
         imprime o resumo sem rodar teste nenhum é pega aqui.
      5. VARREDURA DE DIRETÓRIO. Arquivo Test-*.ps1 que não está na lista é
         vermelho — senão apagar uma linha da lista some com uma suíte inteira.
      6. PISO GLOBAL sobre o total, como rede para o que os pisos por suíte não
         veem.
      7. PRAZO, por suíte e no conjunto. Suíte que trava não pode segurar o
         portão para sempre, e a soma dos prazos não pode virar horas.

    O piso é atualizado À MÃO quando testes são acrescentados. Isso é de
    propósito: se ele se ajustasse sozinho, não seria piso.

    O QUE O PORTÃO NÃO PEGA, e está dito em vez de negado: teste que virou
    vácuo. Vinte 'Assert-True $true' imprimem vinte linhas legítimas, e nenhuma
    contagem os separa de vinte testes de verdade — só leitura humana ou
    análise de mutação, que é a razão de a verificação adversarial existir.
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
    @{ file = 'Test-Laudo.ps1';       min = 117 }
    @{ file = 'Test-LaudoDriver.ps1'; min = 23  }
    @{ file = 'Test-Report.ps1';      min = 60  }
    @{ file = 'Test-Exam.ps1';        min = 33  }
    @{ file = 'Test-Gate.ps1';        min = 27  }
    @{ file = 'Test-Drivers.ps1';     min = 56  }
)

if ($SuiteSpec) {
    <#
        SPEC ILEGÍVEL É ERRO FATAL, não lista vazia.

        Medido no código anterior: '-SuiteSpec a:b' fazia [int]'b' lançar erro
        NÃO fatal, a lista saía vazia, o piso global virava 0, e o portão
        imprimia "TODAS AS SUITES PASSARAM" tendo rodado ZERO suítes. É a forma
        exata do defeito que este arquivo existe para não ter — desta vez dentro
        do próprio instrumento de medida.

        Nome de suíte é confinado ao diretório: sem separador de caminho, sem
        '..'. A costura de teste não pode virar um jeito de o portão executar
        arquivo arbitrário.
    #>
    $lista = New-Object System.Collections.ArrayList
    foreach ($item in ($SuiteSpec -split ',')) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        $par = $item -split ':'
        $piso = 0
        if ($par.Count -ne 2 -or -not [int]::TryParse($par[1].Trim(), [ref]$piso)) {
            Write-Error "SuiteSpec ilegível em '$item' — o formato é arquivo:piso"
            exit 2
        }
        $arq = $par[0].Trim()
        if ($arq -match '[\\/]' -or $arq -match '\.\.') {
            Write-Error "SuiteSpec com caminho em '$arq' — só nome de arquivo dentro do diretório de suítes"
            exit 2
        }
        [void]$lista.Add(@{ file = $arq; min = $piso })
    }
    $suites = @($lista)
}

if (@($suites).Count -eq 0) {
    Write-Error 'nenhuma suíte a executar: um portão sem suíte não aprova nada'
    exit 2
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
# O filtro nunca devolve TestKit.ps1 — a exclusão que havia aqui era código
# morto com cara de defesa, e isso é pior que não ter defesa nenhuma.
$naDisco = @(
    Get-ChildItem -LiteralPath $dir -Filter 'Test-*.ps1' -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name }
)
$naLista = @($suites | ForEach-Object { $_.file })
foreach ($f in $naDisco) {
    if ($naLista -notcontains $f) { [void]$falhas.Add("$f existe em tests\ e não está na lista do portão: ninguém o executa") }
}

<#
    TETO GLOBAL DE TEMPO. Com prazo só por suíte, oito suítes travadas custavam
    oito prazos somados — 80 minutos antes de qualquer veredito, que é o mesmo
    que não ter portão numa integração contínua.
#>
$relogio = [System.Diagnostics.Stopwatch]::StartNew()
$tetoGlobalSeg = [Math]::Max($SuiteTimeoutSec * 2, 900)

foreach ($s in $suites) {
    if ($relogio.Elapsed.TotalSeconds -gt $tetoGlobalSeg) {
        [void]$falhas.Add("o portão passou de $tetoGlobalSeg s no total e parou antes de $($s.file)")
        break
    }
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

    <#
        O RESUMO É CONFERIDO CONTRA AS LINHAS IMPRESSAS.

        Eu havia escrito, no teste deste portão, que uma suíte capaz de imprimir
        o resumo sem rodar teste nenhum era indetectável e "não tem como" pegar.
        Era falso, e a verificação adversarial mostrou como: TestKit imprime
        exatamente uma linha por teste — '   ok    nome' ou '   FALHA nome'.
        Contar essas linhas e comparar com o resumo separa a suíte que trabalhou
        da que só disse ter trabalhado.

        Continua fora do alcance: teste que virou vácuo. Vinte 'Assert-True
        $true' imprimem vinte linhas legítimas e nenhuma contagem os distingue —
        só leitura humana ou análise de mutação. ESSA limitação é real, e agora
        é a única.
    #>
    $linhasOk    = @([regex]::Matches($texto, '(?m)^\s+ok\s')).Count
    $linhasFalha = @([regex]::Matches($texto, '(?m)^\s+FALHA\s')).Count

    if ($linhasOk -ne $passou -or $linhasFalha -ne $falhou) {
        [void]$falhas.Add(
            "$($s.file): o resumo diz $passou/$falhou mas imprimiu $linhasOk/$linhasFalha linhas de teste — o resumo não bate com o que rodou")
    }

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

    SEM a condição '-not $SuiteDir' que havia aqui. Ela desligava o piso global
    justamente no modo que Test-Gate.ps1 usa para aferir o portão — a costura
    construída para testar a trava era a mesma coisa que a desligava, e a
    mutação que a removia passava com dezesseis testes verdes. Não há motivo
    para a exceção: o piso é somado DA LISTA recebida, então vale igual para
    lista sintética.
#>
# Soma à mão: Measure-Object -Property não enxerga CHAVE de hashtable, só
# propriedade de objeto — e falha em vez de devolver zero.
$pisoTotal = 0
foreach ($s in $suites) { $pisoTotal += [int]$s.min }
if ($totalOk -lt $pisoTotal) {
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
