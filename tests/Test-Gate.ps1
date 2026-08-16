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
    param([string]$Dir, [hashtable[]]$Lista, [int]$TimeoutSec = 60, [int]$TotalSec = 1800)

    $spec = ($Lista | ForEach-Object { "$($_.file):$($_.min)" }) -join ','

    <#
        Processo próprio: o portão chama 'exit', e invocá-lo com & derrubaria
        esta suíte junto — que é como o instrumento de medida destruiria o
        experimento.
    #>
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $txt = & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $portao `
                -SuiteDir $Dir -SuiteSpec $spec -SuiteTimeoutSec $TimeoutSec `
                -TotalTimeoutSec $TotalSec -Quiet 2>&1 | Out-String
    [pscustomobject]@{ text = $txt; aprovou = ($txt -match 'TODAS AS SUITES PASSARAM') }
}

<#
    Suíte sintética honesta: imprime UMA linha 'ok' por teste que declara.

    O portão agora confere o resumo contra as linhas impressas, então uma suíte
    de mentira que anuncia dez e imprime uma é reprovada — que é justamente a
    trava nova. As suítes deste arquivo precisam ser honestas para os cenários
    testarem o que dizem testar, e não a trava nova por acidente.
#>
function Suite-Ok {
    param([string]$Nome, [int]$N)
    @{ file = $Nome; body = "1..$N | ForEach-Object { `"   ok    teste `$_`" }`r`n'  $N passou, 0 falhou'`r`nexit 0`r`n" }
}

function Suite-ComFalha {
    param([string]$Nome, [int]$Ok, [int]$Falha, [int]$Codigo = 1)
    $b = "1..$Ok | ForEach-Object { `"   ok    teste `$_`" }`r`n"
    if ($Falha -gt 0) { $b += "1..$Falha | ForEach-Object { `"   FALHA teste `$_`" }`r`n" }
    $b += "'  $Ok passou, $Falha falhou'`r`nexit $Codigo`r`n"
    @{ file = $Nome; body = $b }
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

    $d = New-Cenario @((Suite-Ok 'Test-A.ps1' 10), (Suite-Ok 'Test-B.ps1' 3))
    $r = Invoke-Portao -Dir $d -Lista @(@{file='Test-A.ps1';min=10}, @{file='Test-B.ps1';min=5})
    Assert-True (-not $r.aprovou) 'suíte abaixo do piso reprova'
    Assert-True ($r.text -match 'testes sumiram') 'e o motivo diz que testes sumiram'

    $d = New-Cenario @((Suite-ComFalha 'Test-A.ps1' 10 2 0))
    $r = Invoke-Portao -Dir $d -Lista @(@{file='Test-A.ps1';min=10})
    Assert-True (-not $r.aprovou) 'suíte que sai 0 COM falhas reprova'

    <#
        CÓDIGO DE SAÍDA. A conferência de código != 0 não tinha teste — a
        mutação que a removia sobrevivia, porque a suíte que estoura já era pega
        pelo "não imprimiu resumo". Este cenário imprime resumo COERENTE e sai
        com 1: só a conferência de código o pega.
    #>
    $d = New-Cenario @((Suite-ComFalha 'Test-A.ps1' 10 0 1))
    $r = Invoke-Portao -Dir $d -Lista @(@{file='Test-A.ps1';min=10})
    Assert-True (-not $r.aprovou) 'resumo coerente mas código de saída 1 reprova'
    Assert-True ($r.text -match 'código de saída') 'e o motivo nomeia o código'

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
        4. RESUMO FALSO SEM RODAR TESTE.

        Este arquivo afirmava que o portão "NÃO pega, e não tem como". Era
        falso, e a verificação adversarial mostrou como: TestKit imprime uma
        linha por teste, então basta conferir o resumo contra a contagem delas.
        Eu tinha declarado uma limitação que era só a implementação que faltava.
    #>
    $d = New-Cenario @(@{ file = 'Test-A.ps1'; body = "'  10 passou, 0 falhou'`r`nexit 0`r`n" })
    $r = Invoke-Portao -Dir $d -Lista @(@{file='Test-A.ps1';min=10})
    Assert-True (-not $r.aprovou) 'resumo sem nenhuma linha de teste reprova'
    Assert-True ($r.text -match 'não bate com o que rodou') 'e o motivo diz que o resumo não bate'

    # Resumo que infla a contagem também não passa.
    $d = New-Cenario @(@{ file = 'Test-A.ps1'; body = "'   ok    um so'`r`n'  10 passou, 0 falhou'`r`nexit 0`r`n" })
    $r = Invoke-Portao -Dir $d -Lista @(@{file='Test-A.ps1';min=10})
    Assert-True (-not $r.aprovou) 'resumo que infla a contagem reprova'

    <#
        5. O TETO GLOBAL DE TEMPO. Ele era derivado do prazo por suíte —
        Max(prazo*2, 900) — e com o prazo curto que esta aferição usa dava
        sempre 900 s: a trava era inatingível por qualquer teste, em qualquer
        configuração. Virou parâmetro próprio, e agora dá para exercitá-la.

        Duas suítes que dormem 2 s cada, com teto de 1 s: a primeira roda, o
        teto estoura, a segunda nem começa.
    #>
    $lenta = { param($n) @{ file = $n; body = "Start-Sleep -Seconds 2`r`n'   ok    um'`r`n'  1 passou, 0 falhou'`r`nexit 0`r`n" } }
    $d = New-Cenario @((& $lenta 'Test-A.ps1'), (& $lenta 'Test-B.ps1'))
    $r = Invoke-Portao -Dir $d -Lista @(@{file='Test-A.ps1';min=1}, @{file='Test-B.ps1';min=1}) -TimeoutSec 30 -TotalSec 1
    Assert-True (-not $r.aprovou) 'o conjunto que passa do teto global reprova'
    Assert-True ($r.text -match 'no total e parou antes de') 'e o motivo diz que parou por tempo, dizendo onde'

    # =====================================================================
    Start-TestGroup 'Portão: a lista de suítes é validada  [MUTAÇÃO]'

    <#
        O portão aprovava tendo rodado ZERO suítes: '-SuiteSpec a:b' fazia
        [int]'b' lançar erro não fatal, a lista saía vazia, o piso global virava
        0 e ele imprimia TODAS AS SUITES PASSARAM. O defeito que este arquivo
        existe para não ter, dentro do próprio instrumento de medida.
    #>
    <#
        try/catch obrigatório: o portão usa Write-Error para spec ilegível, e
        stderr de comando nativo sob $ErrorActionPreference='Stop' derruba ESTA
        suíte — que então morre sem imprimir resumo, e o portão de fora acusa
        "não chegou ao fim". Diagnóstico certo para o sintoma errado, de novo.
    #>
    function Invoke-Spec {
        param([string]$Dir, [string]$Spec)
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        try {
            (& $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $portao `
                 -SuiteDir $Dir -SuiteSpec $Spec -Quiet 2>&1 | Out-String)
        } catch { [string]$_ }
    }

    <#
        A ASSERÇÃO CONFERE QUAL TRAVA DISPAROU, não só que reprovou.

        Antes eram todas da forma 'não aprovou', e por isso cada trava era
        satisfeita por uma vizinha: sabotar a validação de spec deixava a recusa
        de lista vazia pegar no lugar, sabotar o confinamento de caminho deixava
        o "arquivo não existe" pegar — e as três mutações sobreviviam com a
        suíte verde. Teste que só confere o resultado não distingue a trava que
        ele existe para defender.
    #>
    $d = New-Cenario @((Suite-Ok 'Test-A.ps1' 10))
    foreach ($caso in @(
        @{ spec = 'a:b';            motivo = 'ilegível' }
        @{ spec = 'semdoispontos';  motivo = 'ilegível' }
        @{ spec = 'Test-A.ps1:';    motivo = 'ilegível' }
        @{ spec = ':10';            motivo = 'sem nome de arquivo' }
        @{ spec = 'Test-A.ps1:-5';  motivo = 'piso negativo' }
    )) {
        $t = Invoke-Spec -Dir $d -Spec $caso.spec
        Assert-True (-not ($t -match 'TODAS AS SUITES PASSARAM')) "spec inválida '$($caso.spec)' não aprova nada"
        Assert-True ($t -match [regex]::Escape($caso.motivo)) "e a trava que pegou foi a certa: $($caso.motivo)"
    }

    # Lista vazia tem de ter motivo PRÓPRIO, não ser pega pela validação de spec.
    $t = Invoke-Spec -Dir $d -Spec ','
    Assert-True ($t -match 'nenhuma suíte a executar') 'lista vazia reprova com motivo próprio'

    <#
        CONFINAMENTO DE CAMINHO — a única trava de segurança do conjunto, e a
        única que continuava na forma antiga.

        Medido: removendo a validação de caminho, o "arquivo não existe"
        satisfazia a asserção 'não aprovou' e a mutação sobrevivia. Ou seja, a
        trava que impede o portão de executar arquivo de fora do diretório de
        suítes estava sendo conferida por acidente, por uma vizinha.

        O teste planta o arquivo de fora DE VERDADE — senão "não existe" e "não
        pode" continuam indistinguíveis.
    #>
    $fora = Join-Path $tmp 'Fora.ps1'
    [System.IO.File]::WriteAllText($fora, "'   ok    executei de fora'`r`n'  1 passou, 0 falhou'`r`nexit 0`r`n", $enc)

    $t = Invoke-Spec -Dir $d -Spec '..\Fora.ps1:1'
    Assert-True (-not ($t -match 'TODAS AS SUITES PASSARAM')) 'spec com caminho é recusada'
    Assert-True ($t -match 'caminho') 'e a trava que pegou foi a de caminho, não a de arquivo ausente'
    Assert-True (-not ($t -match 'executei de fora')) 'o arquivo de fora NÃO chegou a ser executado'

    # =====================================================================
    Start-TestGroup 'Portão: o diagnóstico acentuado chega inteiro  [MUTAÇÃO]'

    <#
        O ENCODING DA LEITURA JÁ MUDOU DUAS VEZES SEM TESTE, e a segunda vez
        PIOROU o problema. Quem escreve o arquivo é a redireção de console do
        powershell.exe filho, na página de código do console; ler como UTF8
        funde dois bytes num caractere e destrói informação que o padrão
        preservava.

        As contagens são ASCII e não notam. Quem nota é a pessoa que lê por que
        reprovou — e era exatamente essa parte que chegava como lixo.

        Toda suíte sintética deste arquivo era ASCII pura, então nenhuma
        exercitava a diferença. Esta tem acento de verdade.
    #>
    $acento = 'CONFER' + [char]0x00CA + 'NCIA: eleva' + [char]0x00E7 + [char]0x00E3 + 'o t' + [char]0x00E9 + 'rmica'
    $d = New-Cenario @(@{ file = 'Test-A.ps1'
                          body = "'   ok    $acento'`r`n'  1 passou, 0 falhou'`r`nexit 1`r`n" })
    $r = Invoke-Portao -Dir $d -Lista @(@{file='Test-A.ps1';min=1})

    Assert-True (-not $r.aprovou) 'a suíte com saída acentuada e código 1 reprova'
    Assert-True ($r.text -match [regex]::Escape($acento)) 'e o texto acentuado chega ao portão INTEIRO, sem se perder na leitura'

    <#
        O stderr TAMBÉM, e ele não tinha teste: a âncora da bateria casava as
        duas leituras de uma vez, então reverter só a de erro deixava a suíte
        verde. Metade da trava vivia indefesa, escondida por uma âncora
        casada-em-bloco.

        E o stderr é justamente por onde sai o diagnóstico de uma suíte que
        estourou — o texto que mais importa quando algo deu errado.
    #>
    $d = New-Cenario @(@{ file = 'Test-A.ps1'
                          body = "[Console]::Error.WriteLine('$acento')`r`n'   ok    um'`r`n'  1 passou, 0 falhou'`r`nexit 1`r`n" })
    $r = Invoke-Portao -Dir $d -Lista @(@{file='Test-A.ps1';min=1})
    Assert-True ($r.text -match [regex]::Escape($acento)) 'o texto acentuado do STDERR também chega inteiro'

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
