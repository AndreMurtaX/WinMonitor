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
param([switch]$Quiet)

$suites = @(
    @{ file = 'Test-Rollup.ps1';  min = 147 }
    @{ file = 'Test-Rules.ps1';   min = 135 }
    @{ file = 'Test-Laudo.ps1';       min = 93 }
    @{ file = 'Test-LaudoDriver.ps1'; min = 21 }
    @{ file = 'Test-Report.ps1';      min = 60 }
    @{ file = 'Test-Exam.ps1';        min = 25 }
    @{ file = 'Test-Drivers.ps1'; min = 56  }
)

$psExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$falhas  = New-Object System.Collections.ArrayList
$totalOk = 0

foreach ($s in $suites) {
    $p = Join-Path $PSScriptRoot $s.file
    ""
    "##################  $($s.file)  ##################"

    if (-not (Test-Path -LiteralPath $p)) {
        [void]$falhas.Add("$($s.file): o arquivo não existe")
        "ARQUIVO AUSENTE"
        continue
    }

    # Processo próprio: o código de saída é desta suíte, não da anterior.
    $saida = & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $p 2>&1
    $codigo = $LASTEXITCODE

    if ($Quiet) { $saida | Select-Object -Last 6 } else { $saida }

    $texto = ($saida | Out-String)
    $m = [regex]::Match($texto, '(\d+)\s+passou,\s+(\d+)\s+falhou')

    if (-not $m.Success) {
        [void]$falhas.Add("$($s.file): não imprimiu o resumo — a suíte não chegou ao fim (código $codigo)")
        continue
    }

    $passou = [int]$m.Groups[1].Value
    $falhou = [int]$m.Groups[2].Value
    $totalOk += $passou

    if ($codigo -ne 0) { [void]$falhas.Add("$($s.file): código de saída $codigo") }
    if ($falhou -gt 0) { [void]$falhas.Add("$($s.file): $falhou teste(s) falharam") }
    if ($passou -lt [int]$s.min) {
        [void]$falhas.Add("$($s.file): rodou $passou testes, o piso é $($s.min) — testes sumiram")
    }
}

""
"total de testes que passaram: $totalOk"
if ($falhas.Count -eq 0) {
    "TODAS AS SUITES PASSARAM"
    exit 0
} else {
    foreach ($f in $falhas) { "  x $f" }
    "$($falhas.Count) problema(s) no portão"
    exit 1
}
