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
                -SuiteDir $Dir -SuiteSpec $spec -SuiteTimeoutSec $TimeoutSec -SemBateria -SemSombra `
                -TotalTimeoutSec $TotalSec -Quiet 2>&1 | Out-String
    [pscustomobject]@{ text = $txt; aprovou = ($txt -match 'TODAS AS SUITES PASSARAM') }
}

<#
    Invoca o portão com uma lista crua de argumentos, lendo stdout E stderr de
    ARQUIVO.

    Existe separado de Invoke-Portao porque os cenários de validação de
    parâmetro fazem o portão chamar Write-Error, e stderr de comando nativo sob
    $ErrorActionPreference='Stop' derruba ESTA suíte — a mesma armadilha que já
    tinha posto sete asserções no vácuo neste arquivo.

    O parâmetro NÃO se chama $Args: esse é nome automático do PowerShell, e a
    varredura de sombra existe justamente porque colisão de nome não avisa.
#>
function Invoke-PortaoArgs {
    param([string[]]$Argumentos)
    $psE = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $o = [System.IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath $psE -PassThru -NoNewWindow -Wait:$false `
             -ArgumentList (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $portao) + $Argumentos) `
             -RedirectStandardOutput $o -RedirectStandardError ($o + '.err')
    $null = $p.Handle
    $fim = $p.WaitForExit(300000)
    $cod = if ($fim) { $p.ExitCode } else { try { $p.Kill() } catch { }; -1 }
    $t = [string](Get-Content -LiteralPath $o -Raw -Encoding OEM -ErrorAction SilentlyContinue) + "`n" +
         [string](Get-Content -LiteralPath ($o + '.err') -Raw -Encoding OEM -ErrorAction SilentlyContinue)
    Remove-Item -LiteralPath $o, ($o + '.err') -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{ text = $t; codigo = $cod; aprovou = ($t -match 'TODAS AS SUITES PASSARAM') }
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
        E PELO MOTIVO CERTO. "Reprovou" sozinho não distingue a trava que este
        cenário mede de qualquer outra que dispare junto — o cenário passaria
        igual se a suíte estivesse sendo pega pelo piso, pela varredura ou pelo
        prazo, e a trava real ficaria indefesa com aparência de coberta.
    #>
    Assert-True ($r.text -match 'teste\(s\) falharam') 'e o motivo é a falha declarada, não outra trava qualquer'

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
    Assert-True ($r.text -match 'não bate com o que rodou') 'e o motivo é o resumo inflado, não o piso'

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
        O try/catch COM '2>&1 | Out-String' PUNHA SETE ASSERÇÕES EM VÁCUO.

        Sob $ErrorActionPreference='Stop', o primeiro registro de stderr de um
        comando nativo é terminante: o pipeline morre, o STDOUT INTEIRO é
        descartado, e o catch devolve só a primeira linha do erro. Como nestes
        cenários o portão sempre escreve em stderr, toda asserção da forma
        'não aprova' passava a ser impossível de falhar — inclusive a de
        SEGURANÇA, que confere que o arquivo de fora do diretório não foi
        executado.

        Provado: um filho que imprime 'TODAS AS SUITES PASSARAM' no stdout E
        escreve em stderr fazia a asserção devolver verdadeiro.

        E a mesma causa produzia reprovação dependente do CAMINHO: o PowerShell
        quebra a linha de erro em 120 colunas, então com o repositório num
        caminho longo a mensagem cai na segunda linha e some do texto capturado.
        Mesmo commit, 56/0 em C:\curto e 48/8 no caminho longo — vermelho por
        motivo nenhum, que é o que este projeto identifica como a causa de
        alguém desligar o portão.

        A correção é a mesma que o portão já usa para as suítes: processo com
        saída redirecionada para arquivo. Nada de pipeline, nada de EAP.
    #>
    function Invoke-Spec {
        param([string]$Dir, [string]$Spec)
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $out = [System.IO.Path]::GetTempFileName()
        try {
            $p = Start-Process -FilePath $psExe -PassThru -NoNewWindow -Wait:$false `
                     -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $portao,
                                   '-SuiteDir', $Dir, '-SuiteSpec', $Spec, '-SemBateria', '-Quiet' `
                     -RedirectStandardOutput $out -RedirectStandardError ($out + '.err')
            $null = $p.Handle
            [void]$p.WaitForExit(120000)
            (Get-Content -LiteralPath $out -Raw -Encoding OEM -ErrorAction SilentlyContinue) + "`n" +
            (Get-Content -LiteralPath ($out + '.err') -Raw -Encoding OEM -ErrorAction SilentlyContinue)
        } finally {
            Remove-Item -LiteralPath $out, ($out + '.err') -Force -ErrorAction SilentlyContinue
        }
    }

    <#
        E a prova de que a captura não é mais vácuo: um filho que imprime a
        linha de aprovação E escreve em stderr tem de aparecer INTEIRO. Sem
        esta asserção, as sete abaixo voltam a não poder falhar sem que nada
        acuse.
    #>
    $dVac = New-Cenario @((Suite-Ok 'Test-A.ps1' 3))
    $fakeVac = Join-Path $dVac 'Fake.ps1'
    [System.IO.File]::WriteAllText($fakeVac, "'TODAS AS SUITES PASSARAM'`r`n[Console]::Error.WriteLine('erro qualquer')`r`nexit 1`r`n", $enc)
    $psV = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $outV = [System.IO.Path]::GetTempFileName()
    $pv = Start-Process -FilePath $psV -PassThru -NoNewWindow -Wait:$false `
              -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $fakeVac `
              -RedirectStandardOutput $outV -RedirectStandardError ($outV + '.err')
    $null = $pv.Handle; [void]$pv.WaitForExit(30000)
    $txtV = (Get-Content -LiteralPath $outV -Raw -Encoding OEM -ErrorAction SilentlyContinue) + "`n" +
            (Get-Content -LiteralPath ($outV + '.err') -Raw -Encoding OEM -ErrorAction SilentlyContinue)
    Remove-Item -LiteralPath $outV, ($outV + '.err') -Force -ErrorAction SilentlyContinue

    Assert-True ($txtV -match 'TODAS AS SUITES PASSARAM') 'o stdout sobrevive ao stderr: a captura não é vácuo'
    Assert-True ($txtV -match 'erro qualquer') 'e o stderr também chega'

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
    Start-TestGroup 'Portão: a bateria de mutação é julgada, não acreditada  [MUTAÇÃO]'

    <#
        ESTE GRUPO NÃO PODIA EXISTIR ATÉ AGORA, e é esse o ponto.

        O bloco da bateria era guardado por '-not $SuiteDir', e toda invocação
        daqui passa -SuiteDir: a peça acrescentada para acabar com "trava que
        ninguém consegue exercitar" era exatamente isso. Quatro mutantes
        sobreviviam ali.

        E o portão aplicava à bateria UMA das suas seis conferências — o código
        de saída. Medido: bateria reduzida a 'exit 0', bateria anunciando trava
        indefesa e saindo com zero, e bateria declarando "TODOS OS 0 MUTANTES
        MORRERAM" passavam todas. A bateria ESVAZIADA era aceita como prova de
        que toda trava tem defensor.
    #>
    function Invoke-ComBateria {
        param([string]$Corpo, [int]$PrazoBateria = 60, [int]$Piso = 1)
        $d = New-Cenario @((Suite-Ok 'Test-A.ps1' 3))
        $fake = Join-Path $d '_bateria.ps1'
        [System.IO.File]::WriteAllText($fake, $Corpo, $enc)
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        <#
            -MutantesMin 1: o piso de produção é a lista real de mutantes, e uma
            bateria sintética de um mutante esbarraria nele por um motivo que não
            é o que estes cenários medem. O piso tem cenário próprio, abaixo.
        #>
        $txt = & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $portao `
                   -SuiteDir $d -SuiteSpec 'Test-A.ps1:3' -BateriaPath $fake `
                   -BateriaTimeoutSec $PrazoBateria -MutantesMin $Piso -SemSombra -Quiet 2>&1 | Out-String
        [pscustomobject]@{ text = $txt; aprovou = ($txt -match 'TODAS AS SUITES PASSARAM') }
    }

    $r = Invoke-ComBateria "'  morto  X'`r`n'TODOS OS 1 MUTANTES MORRERAM'`r`nexit 0`r`n"
    Assert-True $r.aprovou 'bateria honesta com 1 mutante morto: o portão aprova'

    $r = Invoke-ComBateria "'  VIVO   X'`r`n'1 trava(s) indefesa(s)'`r`nexit 1`r`n"
    Assert-True (-not $r.aprovou) 'bateria que acusa trava indefesa reprova o portão'
    Assert-True ($r.text -match 'trava indefesa ou inconclusiva') 'e o motivo é o veredito dela, não outra conferência'

    <#
        Os três casos que passavam. Cada um é a bateria não tendo provado nada.
    #>
    $r = Invoke-ComBateria "exit 0`r`n"
    Assert-True (-not $r.aprovou) 'bateria MUDA que sai com zero não prova nada'
    Assert-True ($r.text -match 'não declarou quantos') 'e o motivo diz que ela não declarou'

    $r = Invoke-ComBateria "'TODOS OS 0 MUTANTES MORRERAM'`r`nexit 0`r`n"
    Assert-True (-not $r.aprovou) 'bateria com ZERO mutantes é vacuamente verdadeira, não é prova'
    Assert-True ($r.text -match 'ZERO mutantes') 'e o motivo nomeia isso'

    $r = Invoke-ComBateria "'  morto  X'`r`n'TODOS OS 9 MUTANTES MORRERAM'`r`nexit 0`r`n"
    Assert-True (-not $r.aprovou) 'bateria que infla a contagem reprova, como qualquer suíte'
    Assert-True ($r.text -match 'não bate com o que rodou') 'e pelo mesmo motivo'

    <#
        O PISO DA LISTA DE MUTANTES. Ela é mantida à MÃO, e apagar entradas é
        exatamente como "defesa que só existe quando alguém lembra" volta.
        Medido antes do piso: perder 36 dos 37 mutantes ficava verde.

        O cenário roda uma bateria honesta de 3 mutantes contra um piso de 5.
        Nada nela está errado — o que está errado é ela ter encolhido.
    #>
    $corpo3 = "'  morto  A'`r`n'  morto  B'`r`n'  morto  C'`r`n'TODOS OS 3 MUTANTES MORRERAM'`r`nexit 0`r`n"
    $r = Invoke-ComBateria $corpo3 -Piso 5
    Assert-True (-not $r.aprovou) 'bateria honesta que ENCOLHEU abaixo do piso reprova'
    Assert-True ($r.text -match 'a lista encolheu') 'e o motivo diz que a lista encolheu'

    $r = Invoke-ComBateria $corpo3 -Piso 3
    Assert-True $r.aprovou 'e a mesma bateria no piso exato aprova: o piso é piso, não igualdade'

    <#
        RESUMO ÚNICO. [regex]::Match pegava o PRIMEIRO resumo, então uma bateria
        que imprimisse 'TODOS OS 1' e depois 'TODOS OS 99' saía aprovada pela
        primeira linha — o instrumento lendo só o começo do que mediu.
    #>
    $r = Invoke-ComBateria "'  morto  A'`r`n'TODOS OS 1 MUTANTES MORRERAM'`r`n'TODOS OS 99 MUTANTES MORRERAM'`r`nexit 0`r`n"
    Assert-True (-not $r.aprovou) 'bateria com DOIS resumos reprova: não dá para saber qual vale'
    Assert-True ($r.text -match 'resumos') 'e o motivo nomeia isso'

    # A bateria também tem prazo — antes rodava fora de todo teto do portão.
    $r = Invoke-ComBateria "Start-Sleep -Seconds 30`r`n'TODOS OS 1 MUTANTES MORRERAM'`r`nexit 0`r`n" -PrazoBateria 2
    Assert-True (-not $r.aprovou) 'bateria que trava reprova por prazo'
    Assert-True ($r.text -match 'prazo') 'e o motivo nomeia o prazo'

    <#
        -BateriaPath É COSTURA, e costura tem de ficar confinada à aferição.
        Solto, ele fazia o portão executar um arquivo arbitrário — a brecha que
        o confinamento de -SuiteSpec já tinha fechado na mesma peça.
    #>
    $rConf = Invoke-PortaoArgs @('-SuiteSpec', 'Test-A.ps1:1', '-BateriaPath', (Join-Path $tmp 'nao-existe.ps1'), '-SemSombra', '-Quiet')
    Assert-True ($rConf.text -match 'aceito junto de -SuiteDir') '-BateriaPath sem -SuiteDir é recusado na entrada'
    Assert-True (-not $rConf.aprovou) 'e nada é executado'
    Assert-Equal 2 $rConf.codigo 'com código de erro de uso, não de suíte reprovada'

    # Bateria ausente é vermelho: sem ela, nada prova que as travas têm defensor.
    $d = New-Cenario @((Suite-Ok 'Test-A.ps1' 3))
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $t = & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $portao `
             -SuiteDir $d -SuiteSpec 'Test-A.ps1:3' -BateriaPath (Join-Path $d 'nao-existe.ps1') -Quiet 2>&1 | Out-String
    Assert-True (-not ($t -match 'TODAS AS SUITES PASSARAM')) 'bateria ausente reprova'

    # E pular tem de ser DITO, não silencioso.
    $t = & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $portao `
             -SuiteDir $d -SuiteSpec 'Test-A.ps1:3' -SemBateria -Quiet 2>&1 | Out-String
    Assert-True ($t -match 'PULADA') 'pular a bateria é anunciado em voz alta'

    # =====================================================================
    Start-TestGroup 'A bateria julga a si mesma  [MUTAÇÃO]'

    <#
        A ferramenta que decide se o portão aprova era a ÚNICA peça do
        repositório impossível de sabotar: o sandbox dela copiava src, config e
        tests, nunca tools. Nenhum mutante podia apontar para ela, e os dois
        consertos que ela recebeu — o INCONCLUSIVO e a âncora obsoleta —
        sobreviviam à reversão por construção.

        Agora tools entra na cópia, e estes testes exercitam a lógica dela
        DIRETAMENTE, com uma bateria de um mutante só.
    #>
    $bateria = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\Test-Mutantes.ps1'
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    Assert-True (Test-Path $bateria) 'a bateria existe'

    <#
        try/catch: a bateria usa Write-Error, e stderr de comando nativo sob
        $ErrorActionPreference='Stop' derruba ESTA suíte — que morre sem resumo,
        e a própria bateria classifica como INCONCLUSIVO. A trava nova acusando
        o teste da trava nova.
    #>
    $saidaAnc = ''
    try {
        $saidaAnc = & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $bateria -Somente 'NAO-EXISTE-ESTE-ID' 2>&1 | Out-String
    } catch { $saidaAnc = [string]$_ }
    Assert-True ($saidaAnc -match 'nenhum mutante casa') 'filtro que não casa nenhum mutante é erro, não silêncio'

    <#
        E o sandbox precisa mesmo copiar tools: sem isso, um mutante apontado
        para a própria ferramenta não teria o que mutar. Confere-se lendo o
        código dela, porque o efeito só aparece num mutante que ainda não
        existe — e "ainda não existe" é exatamente como esta lacuna sobreviveu.
    #>
    <#
        A asserção olha a LINHA do laço, não o arquivo inteiro: a bateria contém
        a própria string que ela muta, guardada no campo 'de' do mutante, e uma
        busca no texto todo casava com essa definição — o mutante sobrevivia
        porque o teste encontrava a evidência no lugar errado.
    #>
    $linhaCopia = @(Get-Content -LiteralPath $bateria -Encoding UTF8 |
                        Where-Object { $_ -match '^\s*foreach \(\$d in ' })
    Assert-Equal 1 $linhaCopia.Count 'há exatamente um laço de cópia no sandbox da bateria'
    Assert-True ($linhaCopia[0] -match "'tools'") 'e ele copia tools: a bateria pode ser mutada como qualquer outra peça'

    <#
        SILÊNCIO É INCONCLUSIVO — conferido por COMPORTAMENTO, não por texto.

        A asserção anterior lia o arquivo inteiro procurando 'INCONCLUSIVO'. A
        palavra ocorre quatro vezes ali, três delas em COMENTÁRIO — duas
        escritas pelo mesmo commit que criou a asserção. Apagando todo o código,
        ela continuava verde: o teste encontrava a evidência no lugar errado.

        É o defeito que eu diagnostiquei e corrigi para a asserção vizinha, cinco
        linhas acima, e não apliquei a esta.

        Agora a bateria é EXECUTADA contra um mutante cuja suíte declarada não
        existe — o caso em que nada roda. Ela tem de dizer inconclusivo e sair
        com código diferente de zero.
    #>
    $dInc = New-Cenario @((Suite-Ok 'Test-A.ps1' 1))
    $batInc = Join-Path $dInc 'bateria-inconclusiva.ps1'
    $projInc = Join-Path $dInc 'proj'
    New-Item -ItemType Directory -Path $projInc -Force | Out-Null
    foreach ($sub in 'src', 'config', 'tests', 'tools') {
        Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) $sub) -Destination $projInc -Recurse -Force
    }
    # Um mutante que aponta para uma suíte inexistente: nada roda.
    $bat2 = Join-Path $projInc 'tools\Test-Mutantes.ps1'
    $srcBat = [System.IO.File]::ReadAllText($bat2)
    $srcBat = $srcBat -replace "suite='Test-Laudo\.ps1' \}", "suite='Test-Nao-Existe.ps1' }"
    [System.IO.File]::WriteAllText($bat2, $srcBat, $enc)

    $outI = [System.IO.Path]::GetTempFileName()
    $pi = Start-Process -FilePath $psExe -PassThru -NoNewWindow -Wait:$false `
              -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $bat2, '-Somente', 'BL-1a' `
              -RedirectStandardOutput $outI -RedirectStandardError ($outI + '.err')
    $null = $pi.Handle
    $terminou = $pi.WaitForExit(180000)
    $codI = if ($terminou) { $pi.ExitCode } else { try { $pi.Kill() } catch { }; -1 }
    $txtI = (Get-Content -LiteralPath $outI -Raw -Encoding OEM -ErrorAction SilentlyContinue)
    Remove-Item -LiteralPath $outI, ($outI + '.err') -Force -ErrorAction SilentlyContinue

    Assert-True ($txtI -match 'INCONCLUSIVO') 'suíte que não roda é INCONCLUSIVO, não morte — conferido executando'
    Assert-True ($codI -ne 0) 'e a bateria sai com código diferente de zero'
    Assert-True (-not ($txtI -match 'TODOS OS \d+ MUTANTES MORRERAM')) 'sem anunciar sucesso'

    # =====================================================================
    Start-TestGroup 'Sombra de parâmetro: a armadilha que mordeu três vezes  [MUTAÇÃO]'

    <#
        A DEFESA MECÂNICA, E ELA MESMA ATACADA ANTES DE SER DECLARADA PRONTA.

        '$discos = $null' e o parâmetro '$Discos' são A MESMA variável — nomes em
        PowerShell são insensíveis a caixa. F2, F5 e F3 caíram nisso; a terceira
        com a armadilha JÁ escrita no repositório, na mesma sessão que citava as
        duas anteriores.

        A primeira versão da varredura descartava colisões com '-eq', que é
        insensível a caixa: ela descartava exatamente o que procurava e nascia
        MORTA, limpa contra as duas sabotagens históricas. É o motivo destes
        testes existirem em vez de um "conferi à mão" no comentário.
    #>
    $sombra = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\Find-ParamShadow.ps1'
    Assert-True (Test-Path $sombra) 'a varredura de sombra de parâmetro existe'

    function Invoke-Sombra {
        param([string]$Corpo)
        $script:cenSeq++
        $d = Join-Path $tmp ("sombra{0}" -f $script:cenSeq)
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $d 'Alvo.ps1'), $Corpo, $enc)
        $o = [System.IO.Path]::GetTempFileName()
        $p = Start-Process -FilePath $psExe -PassThru -NoNewWindow -Wait:$false `
                 -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $sombra, '-Caminho', $d `
                 -RedirectStandardOutput $o -RedirectStandardError ($o + '.err')
        $null = $p.Handle
        $fim = $p.WaitForExit(60000)
        $cod = if ($fim) { $p.ExitCode } else { try { $p.Kill() } catch { }; -1 }
        $t = (Get-Content -LiteralPath $o -Raw -Encoding OEM -ErrorAction SilentlyContinue)
        Remove-Item -LiteralPath $o, ($o + '.err') -Force -ErrorAction SilentlyContinue
        [pscustomobject]@{ texto = [string]$t; codigo = $cod }
    }

    # A colisão real, na forma exata em que ela apareceu três vezes.
    $r = Invoke-Sombra "param([object]`$Discos)`r`n`$discos = `$null`r`n`$discos = @(`$Discos)`r`n"
    Assert-True ($r.codigo -ne 0) 'variável local que difere do parâmetro só na caixa é acusada'
    Assert-True ($r.texto -match '\$discos colide com o parametro \$Discos') 'e a acusação nomeia as duas'

    <#
        AS TRÊS FORMAS QUE ELA NÃO VIA, cada uma medida executando o PowerShell
        antes de virar teste — as três apagam o parâmetro de verdade.

        A de scriptblock não é hipótese: está em uso HOJE na produção deste
        projeto, em Report.psm1, Laudo.psm1 (duas vezes) e Rollup.psm1. A
        varredura passava limpa por cima dos quatro.
    #>
    $r = Invoke-Sombra "function F (`$Discos) {`r`n  `$discos = `$null`r`n  `$discos`r`n}`r`n"
    Assert-True ($r.codigo -ne 0) 'parâmetro INLINE na assinatura da função também é alcançado'
    Assert-True ($r.texto -match 'F: \$discos') 'e a acusação nomeia a função'

    $r = Invoke-Sombra "param([object]`$Discos)`r`n`$script:discos = `$null`r`n"
    Assert-True ($r.codigo -ne 0) 'prefixo de escopo script: apaga o parâmetro e é acusado'
    Assert-True ($r.texto -match '\$script:discos') 'e a acusação mostra o prefixo'

    $r = Invoke-Sombra "`$b = { param([object]`$Discos)`r`n  `$discos = `$null`r`n  `$discos`r`n }`r`n"
    Assert-True ($r.codigo -ne 0) 'scriptblock com param() próprio é escopo, e a colisão nele é acusada'
    Assert-True ($r.texto -match 'scriptblock') 'e a acusação diz que foi num scriptblock'

    <#
        E O PREFIXO QUE **NÃO** COLIDE: 'global:' escreve noutro escopo, e
        acusá-lo seria o falso positivo de sempre. A distinção precisa de teste
        porque ela mora na mesma linha de código que a de 'script:'.
    #>
    $r = Invoke-Sombra "param([object]`$Discos)`r`n`$global:discos = `$null`r`n"
    Assert-Equal 0 $r.codigo 'prefixo global: NÃO toca o parâmetro do script, e não é acusado'

    <#
        O IDIOMA MAIS COMUM DO POWERSHELL, e a varredura era cega para ele.

        A versão anterior AFIRMAVA, em comentário, que '| ForEach-Object { $x = 1 }'
        escreve no escopo do bloco. É falso, e o modelo foi implementado contra
        essa frase sem ninguém medi-la. Medido, executando:

            ForEach-Object { $discos = }   MUDOU o de quem chamou
            Where-Object   { $discos = }   MUDOU
            @(1).ForEach({ $discos = })    MUDOU
            . { $discos = }                MUDOU
            $local: / $private:            MUDOU
            & { $discos = }                ORIGINAL  <- o unico com escopo proprio

        Superfície que isso deixava cega nesta árvore: 98 scriptblocks, 163
        linhas, 26 dos 39 arquivos. A única defesa mecânica contra a armadilha
        que mordeu três vezes chegava com metade do alcance que declarava.
    #>
    $r = Invoke-Sombra "function A { param(`$Discos); 1 | ForEach-Object { `$discos = 2 } }`r`n"
    Assert-True ($r.codigo -ne 0) 'ForEach-Object é TRANSPARENTE: a colisão dentro dele é acusada'

    $r = Invoke-Sombra "function A { param(`$Discos); 1 | Where-Object { `$discos = 2; `$true } }`r`n"
    Assert-True ($r.codigo -ne 0) 'Where-Object também'

    $r = Invoke-Sombra "function A { param(`$Discos); @(1).ForEach({ `$discos = 2 }) }`r`n"
    Assert-True ($r.codigo -ne 0) 'e o método .ForEach() também'

    $r = Invoke-Sombra "function A { param(`$Discos); . { `$discos = 2 } }`r`n"
    Assert-True ($r.codigo -ne 0) 'dot-source de scriptblock escreve no escopo de quem chama, e é acusado'

    $r = Invoke-Sombra "function A { param(`$Discos); `$local:discos = 2 }`r`n"
    Assert-True ($r.codigo -ne 0) 'prefixo local: escreve no escopo corrente, e é acusado'

    $r = Invoke-Sombra "function A { param(`$Discos); `$private:discos = 2 }`r`n"
    Assert-True ($r.codigo -ne 0) 'prefixo private: também'

    <#
        E O ÚNICO QUE ABRE ESCOPO PRÓPRIO. Sem esta asserção, a correção acima
        poderia ter sido "acusar todo scriptblock", que passaria nos seis testes
        anteriores e encheria o relatório de falso positivo — o outro jeito de a
        varredura morrer.
    #>
    $r = Invoke-Sombra "function A { param(`$Discos); & { `$discos = 2 } }`r`n"
    Assert-Equal 0 $r.codigo '& { } abre escopo PRÓPRIO: ali nasce variável nova, e não é acusado'

    <#
        FALHA FECHADA. A versão anterior fazia Substring supondo que todo
        arquivo está sob a raiz; com -Caminho fora dela a chamada estourava, a
        exceção sumia no stderr e ela declarava LIMPO, código 0, havendo colisão
        no arquivo. Falha aberta é pior que trava nenhuma: ausência ninguém
        confia, falha aberta todo mundo.
    #>
    $r = Invoke-Sombra "param([object]`$Discos)`r`n`$discos = `$null`r`nfunction {{{`r`n"
    Assert-Equal 2 $r.codigo 'arquivo que não dá para analisar é VERMELHO, não silêncio'
    Assert-True ($r.texto -match 'ILEGIVEL') 'e ele é nomeado como ilegível'
    Assert-True ($r.texto -match 'nao olhar nao e nao ter nada') 'com o motivo dito por extenso'


    <#
        A CONTAGEM DE ARQUIVOS SAI NOS DOIS DESFECHOS, porque é ela que o portão
        confere contra o piso. Se ela só saísse no caminho limpo, o piso seria
        inconferível justamente quando há algo a esconder.
    #>
    $r = Invoke-Sombra "param([object]`$Discos)`r`n`$discos = `$null`r`n"
    Assert-True ($r.texto -match '\(\d+ arquivo') 'a varredura declara quantos arquivos varreu MESMO acusando colisão'

    # Dentro de função também: o escopo do param() é o corpo dela.
    $r = Invoke-Sombra "function F {`r`n  param([int]`$WindowDays)`r`n  `$windowDays = 1`r`n  `$windowDays`r`n}`r`n"
    Assert-True ($r.codigo -ne 0) 'a colisão dentro de função também é acusada'
    Assert-True ($r.texto -match 'F:') 'e o relatório diz em qual função'

    <#
        E O FALSO POSITIVO, que é o que torna a varredura utilizável: reatribuir
        o parâmetro com a MESMA grafia é legítimo e frequente. Sem esta asserção
        a varredura poderia acusar tudo e continuar "verde" no teste acima.
    #>
    $r = Invoke-Sombra "param([object]`$Alvo)`r`n`$Alvo = @(`$Alvo)`r`n`$Alvo`r`n"
    Assert-Equal 0 $r.codigo 'reatribuir o parâmetro com a mesma grafia NÃO é acusado'

    $r = Invoke-Sombra "param([int]`$N)`r`n`$outra = `$N + 1`r`n`$outra`r`n"
    Assert-Equal 0 $r.codigo 'variável de nome diferente não é acusada'

    <#
        E O ESCOPO PARA NA PORTA DA FUNÇÃO. Atribuir '$discos' DENTRO de uma
        função cria variável nova no escopo dela — o parâmetro do script
        continua intacto. Acusar isso seria falso positivo, e falso positivo é
        o outro jeito de a varredura morrer: pelo relatório que ninguém lê.
    #>
    $r = Invoke-Sombra "param([object]`$Discos)`r`nfunction G {`r`n  `$discos = 1`r`n  `$discos`r`n}`r`nG`r`n"
    Assert-Equal 0 $r.codigo 'local dentro de função NÃO colide com parâmetro do script'

    # E a mesma grafia FORA da função continua acusada: o recuo é do escopo, não da regra.
    $r = Invoke-Sombra "param([object]`$Discos)`r`nfunction G { 1 }`r`n`$discos = 1`r`n`$discos`r`n"
    Assert-True ($r.codigo -ne 0) 'e a mesma grafia no corpo do script continua acusada'

    <#
        A VARREDURA ENTRA NO PORTÃO, e isto confere que entrou.

        Ferramenta em tools\ que ninguém invoca é documentação com extensão .ps1
        — precisamente a forma como as três ocorrências passaram. O portão de um
        projeto SABOTADO tem de ficar vermelho por causa dela.
    #>
    $dSom = New-Cenario @((Suite-Ok 'Test-A.ps1' 1))
    $projSom = Join-Path $dSom 'proj'
    New-Item -ItemType Directory -Path $projSom -Force | Out-Null
    foreach ($sub in 'src', 'config', 'tests', 'tools') {
        Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) $sub) -Destination $projSom -Recurse -Force
    }
    $alvoSom = Join-Path $projSom 'src\probes\Probe-DiskHealth.ps1'
    $txtSom = [System.IO.File]::ReadAllText($alvoSom).Replace('$lidos = $null', '$discos = $null')
    [System.IO.File]::WriteAllText($alvoSom, $txtSom, $enc)

    $oSom = [System.IO.Path]::GetTempFileName()
    $pSom = Start-Process -FilePath $psExe -PassThru -NoNewWindow -Wait:$false `
                -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', `
                              (Join-Path $projSom 'tests\Run-All.ps1'), '-SuiteDir', $dSom, `
                              '-SuiteSpec', 'Test-A.ps1:1', '-SemBateria', '-Quiet' `
                -RedirectStandardOutput $oSom -RedirectStandardError ($oSom + '.err')
    $null = $pSom.Handle
    $fimSom = $pSom.WaitForExit(180000)
    if (-not $fimSom) { try { $pSom.Kill() } catch { } }
    $tSom = (Get-Content -LiteralPath $oSom -Raw -Encoding OEM -ErrorAction SilentlyContinue)
    Remove-Item -LiteralPath $oSom, ($oSom + '.err') -Force -ErrorAction SilentlyContinue

    Assert-True (-not ($tSom -match 'TODAS AS SUITES PASSARAM')) 'projeto com sombra de parâmetro NÃO passa no portão'
    Assert-True ($tSom -match 'sombra de par') 'e o motivo nomeia a sombra de parâmetro'

    # =====================================================================
    Start-TestGroup 'O ALCANCE das duas guardas é conferido, não suposto  [MUTAÇÃO]'

    <#
        O PADRÃO QUE ESTA SÉRIE JÁ NOMEOU: a regra nasce com o alcance do
        defeito que a gerou.

        As três armadilhas históricas foram .ps1 com bloco param() explícito, e
        os cenários de sabotagem tocam UM arquivo cada. Consequência medida pela
        décima primeira verificação: reduzir a guarda de LF a '.psm1', ou fazê-la
        pular tests\ e tools\, ou a varredura de sombra ignorar os módulos —
        as TRÊS passavam com o portão verde. A terceira tira os cinco módulos,
        cerca de 3,4 mil linhas, da única defesa mecânica que existe.

        Cada cenário abaixo encolhe o alcance sem tocar em nenhum arquivo
        sabotado, e exige que o piso acuse. É a mesma doutrina que o portão já
        aplica à bateria: ZERO — ou menos que o piso — é vacuamente verdadeiro.
    #>
    function Invoke-PortaoDeProjeto {
        param([hashtable[]]$Mudancas, [switch]$ComSombra)
        $script:cenSeq++
        $dc = New-Cenario @((Suite-Ok 'Test-A.ps1' 1))
        $proj = Join-Path $dc 'proj'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        foreach ($sub in 'src', 'config', 'tests', 'tools') {
            Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) $sub) -Destination $proj -Recurse -Force
        }
        foreach ($m in $Mudancas) {
            $alvo = Join-Path $proj $m.arquivo
            $txt = [System.IO.File]::ReadAllText($alvo)
            if (-not $txt.Contains($m.de)) { throw "ancora ausente em $($m.arquivo): $($m.de)" }
            [System.IO.File]::WriteAllText($alvo, $txt.Replace($m.de, $m.para), $enc)
        }
        $args = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
                  (Join-Path $proj 'tests\Run-All.ps1'), '-SuiteDir', $dc, '-SuiteSpec', 'Test-A.ps1:1', '-SemBateria', '-Quiet')
        if (-not $ComSombra) { $args += '-SemSombra' }
        $o = [System.IO.Path]::GetTempFileName()
        $p = Start-Process -FilePath $psExe -PassThru -NoNewWindow -Wait:$false -ArgumentList $args `
                 -RedirectStandardOutput $o -RedirectStandardError ($o + '.err')
        $null = $p.Handle
        if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch { } }
        $t = [string](Get-Content -LiteralPath $o -Raw -Encoding OEM -ErrorAction SilentlyContinue)
        Remove-Item -LiteralPath $o, ($o + '.err') -Force -ErrorAction SilentlyContinue
        [pscustomobject]@{ text = $t; aprovou = ($t -match 'TODAS AS SUITES PASSARAM') }
    }

    # Guarda de LF reduzida aos módulos: 5 arquivos em vez de 39.
    $r = Invoke-PortaoDeProjeto @(@{ arquivo = 'tests\Run-All.ps1'
                                     de = "`$EXT_CRLF = @('.ps1', '.psm1', '.psd1')"
                                     para = "`$EXT_CRLF = @('.psm1')" })
    Assert-True (-not $r.aprovou) 'guarda de LF reduzida a .psm1 NÃO passa: o piso acusa'
    Assert-True ($r.text -match 'a varredura encolheu') 'e o motivo diz que ela encolheu'

    # Guarda de LF ignorando tests\ e tools\ — todo teste e toda ferramenta fora.
    $r = Invoke-PortaoDeProjeto @(@{ arquivo = 'tests\Run-All.ps1'
                                     de = "-notmatch '\\(data|logs|\.git)\\' })"
                                     para = "-notmatch '\\(data|logs|\.git|tests|tools)\\' })" })
    Assert-True (-not $r.aprovou) 'guarda de LF que pula tests\ e tools\ NÃO passa'

    <#
        E o alcance da varredura de sombra, conferido pelo portão DE FORA: a
        contagem que ela declara é confrontada com o piso. Instrumento não
        confere o próprio alcance — quem confere é quem o consome.
    #>
    $r = Invoke-PortaoDeProjeto -ComSombra @(@{ arquivo = 'tools\Find-ParamShadow.ps1'
                                                de = "`$EXT  = @('.ps1', '.psm1', '.psd1')"
                                                para = "`$EXT  = @('.ps1')" })
    Assert-True (-not $r.aprovou) 'varredura de sombra que ignora os módulos NÃO passa: o piso acusa'
    Assert-True ($r.text -match 'o alcance encolheu') 'e o motivo diz que o alcance encolheu'

    <#
        E a varredura que deixa de declarar quantos arquivos leu: sem o número,
        o piso é inconferível, e "inconferível" não pode virar aprovação — é a
        mesma decisão que a bateria toma com resumo ausente.
    #>
    $r = Invoke-PortaoDeProjeto -ComSombra @(@{ arquivo = 'tools\Find-ParamShadow.ps1'
                                                de = "`$resumo = `"(`$(`$arquivos.Count) arquivo(s) varrido(s))`""
                                                para = "`$resumo = 'varredura concluida'" })
    <#
        E O PORTÃO DISTINGUE OS DOIS DESFECHOS. Ele mapeava qualquer código ≠ 0
        para "há variável colidindo" — vermelho na direção segura com
        diagnóstico factualmente FALSO, jogando fora a distinção que a própria
        varredura tinha acabado de criar.
    #>
    $rIleg = Invoke-PortaoDeProjeto -ComSombra @(@{ arquivo = 'src\WinMonitor.psm1'
                                                    de = '#requires -Version 5.1'
                                                    para = "#requires -Version 5.1`r`nfunction {{{" })
    Assert-True (-not $rIleg.aprovou) 'projeto com script insintático NÃO passa no portão'
    Assert-True ($rIleg.text -match 'NÃO conseguiu analisar|NAO conseguiu analisar') 'e o motivo diz que ela não conseguiu ANALISAR'
    Assert-True (-not ($rIleg.text -match 'colidindo com parametro')) 'sem afirmar colisão que ela não encontrou'
    Assert-True (-not $r.aprovou) 'varredura que não declara quantos arquivos leu NÃO passa'
    Assert-True ($r.text -match 'não declarou quantos arquivos') 'e o motivo nomeia isso'

    # =====================================================================
    Start-TestGroup 'Quebra de linha: os bytes executados são os publicados  [MUTAÇÃO]'

    <#
        O .gitattributes declara '*.ps1 text eol=crlf' e a árvore de trabalho
        estava em LF — os 46 arquivos. Quem clonasse recebia bytes que nunca
        tinham rodado aqui, e todo verde deste projeto valia para uma versão que
        só existia nesta máquina.

        O hábito que produz isso não é de terceiros: é meu. Edição em lote com
        WriteAllText junta linhas com "`n" e reintroduz a divergência em
        silêncio, um arquivo por vez.

        O cenário copia o projeto (cópia byte a byte preserva CRLF), reescreve
        UM arquivo em LF e exige que o portão daquela cópia fique vermelho.
    #>
    $dQbr = New-Cenario @((Suite-Ok 'Test-A.ps1' 1))
    $projQbr = Join-Path $dQbr 'proj'
    New-Item -ItemType Directory -Path $projQbr -Force | Out-Null
    foreach ($sub in 'src', 'config', 'tests', 'tools') {
        Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) $sub) -Destination $projQbr -Recurse -Force
    }
    $alvoQbr = Join-Path $projQbr 'src\WinMonitor.psm1'
    $bytesQbr = [System.IO.File]::ReadAllBytes($alvoQbr)
    $textoQbr = [System.Text.Encoding]::UTF8.GetString($bytesQbr).Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText($alvoQbr, $textoQbr, $enc)

    <#
        A sabotagem tem de ser REAL: se a cópia já viesse em LF, o cenário
        estaria medindo o estado do repositório e não a trava. Conferido nos
        bytes, aqui, antes de rodar o portão.
    #>
    $bQbr = [System.IO.File]::ReadAllBytes($alvoQbr)
    $lfSolto = 0
    for ($i = 0; $i -lt $bQbr.Length; $i++) {
        if ($bQbr[$i] -eq 10 -and ($i -eq 0 -or $bQbr[$i - 1] -ne 13)) { $lfSolto++ }
    }
    Assert-True ($lfSolto -gt 0) 'o arquivo sabotado ficou mesmo com LF solto'

    $oQbr = [System.IO.Path]::GetTempFileName()
    $pQbr = Start-Process -FilePath $psExe -PassThru -NoNewWindow -Wait:$false `
                -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', `
                              (Join-Path $projQbr 'tests\Run-All.ps1'), '-SuiteDir', $dQbr, `
                              '-SuiteSpec', 'Test-A.ps1:1', '-SemBateria', '-SemSombra', '-Quiet' `
                -RedirectStandardOutput $oQbr -RedirectStandardError ($oQbr + '.err')
    $null = $pQbr.Handle
    if (-not $pQbr.WaitForExit(180000)) { try { $pQbr.Kill() } catch { } }
    $tQbr = (Get-Content -LiteralPath $oQbr -Raw -Encoding OEM -ErrorAction SilentlyContinue)
    Remove-Item -LiteralPath $oQbr, ($oQbr + '.err') -Force -ErrorAction SilentlyContinue

    Assert-True (-not ($tQbr -match 'TODAS AS SUITES PASSARAM')) 'projeto com script em LF NÃO passa no portão'
    Assert-True ($tQbr -match 'quebra de linha') 'e o motivo nomeia a quebra de linha'
    Assert-True ($tQbr -match 'WinMonitor\.psm1') 'dizendo QUAL arquivo divergiu'

    <#
        Pular tem de ser DITO. Todo cenário deste arquivo passa -SemSombra por
        economia — varrer o repositório inteiro dezenas de vezes custa minutos e
        não mede nada de novo — e é justamente por isso que o silêncio seria
        perigoso: o verde deles não fala sobre parâmetro apagado.
    #>
    $dPul = New-Cenario @((Suite-Ok 'Test-A.ps1' 1))
    $tPul = & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $portao `
                -SuiteDir $dPul -SuiteSpec 'Test-A.ps1:1' -SemBateria -SemSombra -Quiet 2>&1 | Out-String
    Assert-True ($tPul -match 'sombra de par.metro PULADA') 'pular a varredura de sombra é anunciado em voz alta'
    Assert-True ($tPul -match 'TODAS AS SUITES PASSARAM') 'e pular não reprova: é escolha explícita, como a bateria'

    # =====================================================================
    Start-TestGroup 'A bateria sabe dizer VIVO, e não só sucesso  [MUTAÇÃO]'

    <#
        O RAMO **VIVO** ERA A ÚNICA DECISÃO DA BATERIA SEM DEFENSOR.

        Este arquivo já defendia o ramo do silêncio (INCONCLUSIVO) e o do
        veredito final. Faltava o do meio, e ele é o que importa: trocá-lo por
        '$false' deixava Test-Gate em 88/0. Medido pela décima primeira
        verificação, com um mutante que não muda nada:

            bateria intacta : VIVO ... "1 trava(s) indefesa(s)"   exit=1
            bateria mutada  : morto ... "TODOS OS 1 MUTANTES MORRERAM"  exit=0

        A régua da régua vira uma máquina que só sabe anunciar sucesso total, e
        as outras cinquenta travas passam a ser "defendidas" por um instrumento
        que não sabe reprovar. É a terceira porta da mesma sala — silêncio não é
        morte, inconclusivo conta, e agora: VERDE NÃO É MORTE.

        O cenário planta um mutante NO-OP: 'para' idêntico a 'de'. A suíte fica
        verde porque nada mudou, e é exatamente aí que a bateria tem de gritar.
    #>
    $dViv = New-Cenario @((Suite-Ok 'Test-A.ps1' 1))
    $projViv = Join-Path $dViv 'proj'
    New-Item -ItemType Directory -Path $projViv -Force | Out-Null
    foreach ($sub in 'src', 'config', 'tests', 'tools') {
        Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) $sub) -Destination $projViv -Recurse -Force
    }
    $batViv = Join-Path $projViv 'tools\Test-Mutantes.ps1'
    $srcViv = [System.IO.File]::ReadAllText($batViv)
    $deViv  = "de='disks    = `$null'; para='disks    = @()'"
    Assert-True $srcViv.Contains($deViv) 'a âncora do mutante no-op existe na bateria'
    [System.IO.File]::WriteAllText($batViv,
        $srcViv.Replace($deViv, "de='disks    = `$null'; para='disks    = `$null'"), $enc)

    $oViv = [System.IO.Path]::GetTempFileName()
    $pViv = Start-Process -FilePath $psExe -PassThru -NoNewWindow -Wait:$false `
                -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $batViv, '-Somente', 'BL-D2' `
                -RedirectStandardOutput $oViv -RedirectStandardError ($oViv + '.err')
    $null = $pViv.Handle
    $fimViv = $pViv.WaitForExit(300000)
    $codViv = if ($fimViv) { $pViv.ExitCode } else { try { $pViv.Kill() } catch { }; -1 }
    $tViv = [string](Get-Content -LiteralPath $oViv -Raw -Encoding OEM -ErrorAction SilentlyContinue)
    Remove-Item -LiteralPath $oViv, ($oViv + '.err') -Force -ErrorAction SilentlyContinue

    Assert-True ($tViv -match 'VIVO') 'mutação que não muda nada é declarada VIVA — conferido executando'
    Assert-True ($codViv -ne 0) 'e a bateria sai com código diferente de zero'
    Assert-True (-not ($tViv -match 'TODOS OS \d+ MUTANTES MORRERAM')) 'sem anunciar que todas as travas têm defensor'
    Assert-True ($tViv -match 'trava\(s\) indefesa\(s\)') 'e o motivo nomeia a trava indefesa'

    # =====================================================================
    Start-TestGroup 'O verde não pode depender de ONDE o projeto está no disco  [MUTAÇÃO]'

    <#
        A REPROVAÇÃO DEPENDENTE DO CAMINHO, que eu já declarei consertada uma vez.

        O formatador de erro do PowerShell quebra a mensagem em 120 colunas, e a
        posição da quebra depende do comprimento do caminho do script, que entra
        no cabeçalho do ErrorRecord. Medido pela décima primeira verificação, na
        mesma árvore e no mesmo commit:

            comprimento de tests\Run-All.ps1 = 55  ->  88 passou, 0 falhou
                                             = 70  ->  88 passou, 0 falhou
                                             = 87  ->  81 passou, 7 falhou

        Faixa que reprova: 72 a 91 caracteres. O repositório do autor tem 35 e
        passa. Um zip do GitHub descompactado como '...\Projetos\WinMonitor-main'
        tem 76 e REPROVA — um usuário chegaria com o portão vermelho na primeira
        execução, por causa do nome da pasta onde descompactou.

        Este cenário copia o projeto para um caminho ARMADO dentro da faixa e
        exige que a mensagem de uso chegue inteira.
    #>
    $alvoLen = 80
    $sufixo  = '\tests\Run-All.ps1'
    $baseLen = $tmp.Length + 1 + $sufixo.Length
    $pad     = [Math]::Max(1, $alvoLen - $baseLen)
    $dirLongo = Join-Path $tmp ('L' * $pad)
    New-Item -ItemType Directory -Path $dirLongo -Force | Out-Null
    foreach ($sub in 'src', 'config', 'tests', 'tools') {
        Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) $sub) -Destination $dirLongo -Recurse -Force
    }
    $portaoLongo = Join-Path $dirLongo 'tests\Run-All.ps1'
    Assert-True ($portaoLongo.Length -ge 72 -and $portaoLongo.Length -le 91) `
        "o caminho armado ($($portaoLongo.Length) caracteres) cai na faixa que reprovava"

    $oLng = [System.IO.Path]::GetTempFileName()
    $pLng = Start-Process -FilePath $psExe -PassThru -NoNewWindow -Wait:$false `
                -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $portaoLongo, `
                              '-SuiteSpec', 'Test-A.ps1:1', '-BateriaPath', (Join-Path $tmp 'nao-existe.ps1'), '-SemSombra', '-Quiet' `
                -RedirectStandardOutput $oLng -RedirectStandardError ($oLng + '.err')
    $null = $pLng.Handle
    if (-not $pLng.WaitForExit(180000)) { try { $pLng.Kill() } catch { } }
    $tLng = [string](Get-Content -LiteralPath $oLng -Raw -Encoding OEM -ErrorAction SilentlyContinue) + "`n" +
            [string](Get-Content -LiteralPath ($oLng + '.err') -Raw -Encoding OEM -ErrorAction SilentlyContinue)
    Remove-Item -LiteralPath $oLng, ($oLng + '.err') -Force -ErrorAction SilentlyContinue

    <#
        A frase INTEIRA, numa linha só. É ela que quebrava ao meio: com o
        formatador, chegava 'aceito junto de -SuiteDir: é\ncostura de' e a
        asserção falhava por causa do nome da pasta.
    #>
    Assert-True ($tLng -match 'aceito junto de -SuiteDir') 'a mensagem de uso chega INTEIRA de um caminho longo'
    Assert-True ($tLng -match 'ERRO: ') 'e ela sai crua no stderr, sem passar pelo formatador'

    <#
        E A BATERIA, NO MESMO CAMINHO ARMADO — o segundo lugar, que eu consertei
        sem defensor próprio.

        Medido pela décima terceira verificação: sabotar o conserto de
        tools\Test-Mutantes.ps1, voltando para Write-Error, ficava VERDE numa
        raiz de 24 caracteres e só reprovava com 166. A trava contra dependência
        de caminho era ela própria dependente do caminho — e a raiz do autor tem
        35, dentro da faixa em que a sabotagem passa despercebida.

        Por isso esta asserção roda a partir do caminho ARMADO, e não do
        repositório: um defensor que só funciona onde o defeito não aparece não
        é defensor.
    #>
    $oBat = [System.IO.Path]::GetTempFileName()
    $pBat = Start-Process -FilePath $psExe -PassThru -NoNewWindow -Wait:$false `
                -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', `
                              (Join-Path $dirLongo 'tools\Test-Mutantes.ps1'), '-Somente', 'NAO-EXISTE-ESTE-ID' `
                -RedirectStandardOutput $oBat -RedirectStandardError ($oBat + '.err')
    $null = $pBat.Handle
    if (-not $pBat.WaitForExit(120000)) { try { $pBat.Kill() } catch { } }
    $tBat = [string](Get-Content -LiteralPath $oBat -Raw -Encoding OEM -ErrorAction SilentlyContinue) + "`n" +
            [string](Get-Content -LiteralPath ($oBat + '.err') -Raw -Encoding OEM -ErrorAction SilentlyContinue)
    Remove-Item -LiteralPath $oBat, ($oBat + '.err') -Force -ErrorAction SilentlyContinue

    Assert-True ($tBat -match 'nenhum mutante casa') 'a mensagem da BATERIA também chega inteira de um caminho longo'
    Assert-True ($tBat -match 'ERRO: ') 'e ela também sai crua, pelo mesmo motivo'
    Assert-True (-not ($tLng -match 'TODAS AS SUITES PASSARAM')) 'e o portão continua reprovando pelo motivo certo'

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
