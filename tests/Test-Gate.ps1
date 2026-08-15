#requires -Version 5.1
<#
    Testes do PORTÃO — tests\Run-All.ps1.

    POR QUE ESTE ARQUIVO EXISTE
    ---------------------------
    Uma busca por 'Run-All' no projeto inteiro devolvia duas ocorrências, ambas
    em texto de uso. Nada executava o instrumento que declara todo o resto verde,
    e por construção nenhuma mutação nele podia ser detectada.

    Isso é pior que uma suíte sem teste: é a régua sem aferição. O portão já
    mentiu uma vez — contava suíte que estourava no meio como PASSOU — e o
    conserto daquilo também não tinha quem o defendesse.

    COMO FUNCIONA
    -------------
    O portão aceita -SuiteDir para rodar contra um diretório de suítes
    sintéticas. Cada teste aqui planta um cenário de sabotagem num diretório
    temporário e confere o veredito. As suítes falsas imitam o contrato real:
    imprimem 'N passou, M falhou' e saem com 0 ou 1.

    O QUE O PORTÃO NÃO CONSEGUE PEGAR, e está dito em vez de negado: teste que
    virou vácuo. Uma suíte com vinte 'Assert-True $true' imprime vinte passou e
    é indistinguível de vinte testes de verdade — nenhuma contagem separa as
    duas. Só leitura humana ou análise de mutação separa, e é por isso que a
    verificação adversarial de fase existe.

      .\tests\Test-Gate.ps1
#>
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'TestKit.ps1')

$portao = Join-Path $PSScriptRoot 'Run-All.ps1'
$tmp    = Join-Path ([System.IO.Path]::GetTempPath()) ('wm-gate-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$enc    = New-Object System.Text.UTF8Encoding($true)

$cenSeq = 0
function New-Cenario {
    param([hashtable[]]$Suites)
    $script:cenSeq++
    $d = Join-Path $tmp ("c{0}" -f $script:cenSeq)
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    foreach ($s in $Suites) {
        [System.IO.File]::WriteAllText((Join-Path $d $s.file), $s.body, $enc)
    }
    $d
}

<#
    Roda o portão contra um cenário. Devolve o texto e se ele aprovou.

    O portão é invocado num processo próprio: ele chama 'exit', e chamá-lo com
    o operador & derrubaria esta suíte junto.
#>
function Invoke-Portao {
    param([string]$Dir, [hashtable[]]$Lista, [int]$TimeoutSec = 60)

    $spec = ($Lista | ForEach-Object { "$($_.file):$($_.min)" }) -join ','

    <#
        Processo próprio: o portão chama 'exit', e invocá-lo com & derrubaria
        esta suíte junto — que é como o instrumento de medida destruiria o
        experimento.
    #>
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $txt = & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $portao `
                -SuiteDir $Dir -SuiteSpec $spec -SuiteTimeoutSec $TimeoutSec -Quiet 2>&1 | Out-String
    [pscustomobject]@{ text = $txt; aprovou = ($txt -match 'TODAS AS SUITES PASSARAM') }
}

function Suite-Ok {
    param([string]$Nome, [int]$N)
    @{ file = $Nome; body = "'   ok    teste sintetico'`r`n'  $N passou, 0 falhou'`r`nexit 0`r`n" }
}

try {

    # =====================================================================
    Start-TestGroup 'Portão: o caminho feliz'

    $d = New-Cenario @((Suite-Ok 'Test-A.ps1' 10), (Suite-Ok 'Test-B.ps1' 5))
    $r = Invoke-Portao -Dir $d -Lista @(@{file='Test-A.ps1';min=10}, @{file='Test-B.ps1';min=5})
    Assert-True $r.aprovou 'duas suítes verdes: aprova'
    Assert-True ($r.text -match 'total de testes que passaram: 15') 'e soma o total'

    # =====================================================================
    Start-TestGroup 'Portão: as falhas que ele JÁ pegava  [REGRESSÃO]'

    <#
        O defeito original: suíte que estoura antes do próprio 'exit' deixava
        $LASTEXITCODE com o zero da anterior, e o portão dizia que passou.
    #>
    $d = New-Cenario @((Suite-Ok 'Test-A.ps1' 10),
                       @{ file = 'Test-B.ps1'; body = "throw 'estourei'`r`n" })
    $r = Invoke-Portao -Dir $d -Lista @(@{file='Test-A.ps1';min=10}, @{file='Test-B.ps1';min=5})
    Assert-True (-not $r.aprovou) 'suíte que ESTOURA reprova o portão'
    Assert-True ($r.text -match 'não chegou ao fim') 'e o motivo diz que ela não terminou'

    $d = New-Cenario @((Suite-Ok 'Test-A.ps1' 10),
                       @{ file = 'Test-B.ps1'; body = "'  3 passou, 0 falhou'`r`nexit 0`r`n" })
    $r = Invoke-Portao -Dir $d -Lista @(@{file='Test-A.ps1';min=10}, @{file='Test-B.ps1';min=5})
    Assert-True (-not $r.aprovou) 'suíte abaixo do piso reprova'
    Assert-True ($r.text -match 'testes sumiram') 'e o motivo diz que testes sumiram'

    $d = New-Cenario @(@{ file = 'Test-A.ps1'; body = "'  10 passou, 2 falhou'`r`nexit 0`r`n" })
    $r = Invoke-Portao -Dir $d -Lista @(@{file='Test-A.ps1';min=10})
    Assert-True (-not $r.aprovou) 'suíte que sai 0 COM falhas reprova'

    # =====================================================================
    Start-TestGroup 'Portão: os quatro vazamentos medidos  [MUTAÇÃO]'

    <#
        1. SUÍTE APAGADA DA LISTA. O piso por suíte não via isto: 23 testes
           sumiam e o portão continuava verde, só com um total menor — e ninguém
           confere total de cabeça.
    #>
    $d = New-Cenario @((Suite-Ok 'Test-A.ps1' 10), (Suite-Ok 'Test-B.ps1' 5))
    $r = Invoke-Portao -Dir $d -Lista @(@{file='Test-A.ps1';min=10})
    Assert-True (-not $r.aprovou) 'suíte que existe e não está na lista reprova'
    Assert-True ($r.text -match 'ninguém o executa') 'e o motivo diz que ninguém a executa'

    <#
        2. SUÍTE QUE TRAVA. O portão esperava para sempre e depois declarava
           verde. Agora tem prazo, e prazo estourado é vermelho.
    #>
    $d = New-Cenario @(@{ file = 'Test-A.ps1'; body = "Start-Sleep -Seconds 30`r`n'  10 passou, 0 falhou'`r`nexit 0`r`n" })
    $r = Invoke-Portao -Dir $d -Lista @(@{file='Test-A.ps1';min=10}) -TimeoutSec 3
    Assert-True (-not $r.aprovou) 'suíte que trava reprova por prazo'
    Assert-True ($r.text -match 'prazo') 'e o motivo nomeia o prazo'

    <#
        3. DUAS LINHAS DE RESUMO. O portão lia a primeira: uma suíte podia
           imprimir '99 passou, 0 falhou' e depois o resumo verdadeiro com
           falhas.
    #>
    $d = New-Cenario @(@{ file = 'Test-A.ps1'; body = "'  99 passou, 0 falhou'`r`n'  2 passou, 7 falhou'`r`nexit 0`r`n" })
    $r = Invoke-Portao -Dir $d -Lista @(@{file='Test-A.ps1';min=10})
    Assert-True (-not $r.aprovou) 'duas linhas de resumo reprovam'
    Assert-True ($r.text -match 'linhas de resumo') 'e o motivo diz por quê'

    <#
        4. RESUMO FALSO SEM RODAR TESTE. Este o portão NÃO pega, e não tem como:
           uma suíte que imprime o resumo certo é indistinguível de uma que o
           mereceu. O que o piso garante é que o NÚMERO não pode encolher — a
           fraude teria de manter a contagem, e continuaria invisível.

           Fica registrado como limitação medida, não como defesa imaginária.
    #>
    $d = New-Cenario @(@{ file = 'Test-A.ps1'; body = "'  10 passou, 0 falhou'`r`nexit 0`r`n" })
    $r = Invoke-Portao -Dir $d -Lista @(@{file='Test-A.ps1';min=10})
    Assert-True $r.aprovou 'limitação declarada: resumo sem teste nenhum passa — só leitura humana separa'

    # =====================================================================
    Start-TestGroup 'Portão: arquivo que sumiu'

    $d = New-Cenario @((Suite-Ok 'Test-A.ps1' 10))
    $r = Invoke-Portao -Dir $d -Lista @(@{file='Test-A.ps1';min=10}, @{file='Test-Sumiu.ps1';min=5})
    Assert-True (-not $r.aprovou) 'suíte listada que não existe reprova'
    Assert-True ($r.text -match 'não existe') 'e o motivo diz isso'

} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Show-TestSummary
exit (Get-TestExitCode)
