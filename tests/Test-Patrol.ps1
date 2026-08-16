#requires -Version 5.1
<#
    Testes da RONDA e das sondas que ela chama a cada minuto.

    POR QUE ESTE ARQUIVO EXISTE
    ---------------------------
    A décima segunda verificação mediu o buraco em vez de estimá-lo: plantou
    'throw' como PRIMEIRA instrução executável de dez arquivos de produção,
    inserido pela AST logo depois do param() para todos continuarem parseáveis,
    e rodou o portão inteiro.

        147/150/170/37/93/81/115/78 passou, 0 falhou
        TODAS AS SUITES PASSARAM
        codigo=0

    916 linhas em que a mutação mais detectável que existe sobrevive. Entre elas
    src\Invoke-Patrol.ps1 — o caminho que roda A CADA MINUTO nesta máquina — e
    as quatro sondas que ele chama, 354 linhas.

    Se o 'throw' sobrevive, TODA mutação naquele arquivo sobrevive. Não é
    "falta cobertura": é que nenhuma linha dali jamais executou sob teste, e foi
    exatamente assim que o $windowDays do New-Baseline ficou escondido por
    semanas — o defeito que abriu Test-Drivers.ps1 com a frase que classifica
    isto: um script que nenhum teste executa é um script que nunca foi executado.

    O QUE ESTA SUÍTE MEDE, E O QUE ELA NÃO MEDE
    -------------------------------------------
    Ela executa contra a MÁQUINA REAL. As sondas leem contadores de desempenho
    do Windows, e injetar tudo faria o teste medir a injeção. O preço está dito
    em vez de negado: numa máquina sem contador de CPU ou sem volume fixo, as
    asserções de caminho feliz falham por motivo AMBIENTAL, não por defeito.

    O que NÃO depende da máquina — ausência declarada, efeito colateral, forma
    do contrato — é medido com injeção, e é onde estão as travas.

      .\tests\Test-Patrol.ps1
#>
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TestKit.ps1')

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wm-pat-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function New-ProjetoLimpo {
    param([string]$Nome)
    $p = Join-Path $tmp $Nome
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'src')    -Destination $p -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $root 'config') -Destination $p -Recurse -Force
    $p
}

<#
    TUDO RODA CONTRA UMA CÓPIA, com o MÓDULO DELA carregado.

    O módulo, porque em produção ele está sempre presente: é dele que sai
    Get-WMHostFacts, e uma sonda invocada sem ele mede um ambiente que não
    existe. Uma reversão do conserto do efeito colateral estouraria antes de
    escrever o arquivo, e a suíte morreria sem resumo em vez de acusar - o que
    a bateria classifica como INCONCLUSIVO, corretamente, mas que esconde qual
    trava está indefesa.

    A CÓPIA, porque com o módulo do repositório real qualquer escrita acidental
    cairia em data\ do repositório: fora do diretório que as asserções olham, e
    dentro dos dados de verdade da máquina. As duas coisas erradas de uma vez.
#>
$projBase = New-ProjetoLimpo 'base'
Import-Module (Join-Path $projBase 'src\WinMonitor.psm1') -Force

try {

    # =====================================================================
    Start-TestGroup 'As quatro sondas da ronda EXECUTAM  [MUTAÇÃO]'

    <#
        A asserção mais barata e a que faltava: cada arquivo é executado. Um
        'throw' na primeira linha de qualquer um deles agora tem onde morrer.
    #>
    foreach ($nome in 'Probe-Cpu', 'Probe-Memory', 'Probe-StorageUsage', 'Probe-GpuNvidia') {
        $r = & (Join-Path $projBase "src\probes\$nome.ps1")
        Assert-NotNull $r "$nome executa e devolve resultado"
        Assert-True (($r -is [System.Collections.IDictionary] -and $r.Contains('ok'))) "$nome devolve o campo 'ok' do contrato"
        <#
            'ok' pode ser falso legitimamente — a sonda de GPU numa máquina sem
            nvidia-smi, por exemplo. O que NÃO pode é ela explodir ou devolver
            forma diferente do contrato, e é isso que está sendo medido.
        #>
        if ($r.ok -eq $false) {
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$r.reason)) "$nome que falha DIZ por quê"
        }
    }

    # =====================================================================
    Start-TestGroup 'Sonda sem os fatos: ausência, nunca zero  [MUTAÇÃO]'

    <#
        Probe-Cpu e Probe-Memory derivam dois números dos fatos do hospedeiro —
        frequência efetiva e uso percentual de memória. Sem os fatos, esses
        números não existem: a sonda tem de OMITIR, nunca preencher com zero.

        Zero de frequência efetiva seria lido como processador parado; zero de
        uso de memória, como máquina vazia. As duas leituras são falsas e
        tranquilizadoras — a combinação que este projeto inteiro recusa.
    #>
    $cpuSemFatos = & (Join-Path $projBase 'src\probes\Probe-Cpu.ps1')
    Assert-True ($cpuSemFatos.ok) 'Probe-Cpu roda sem os fatos do hospedeiro'
    Assert-True ($cpuSemFatos.data.util -is [int] -or $cpuSemFatos.data.util -is [double]) 'e a utilização, que não depende deles, vem'
    Assert-True (-not $cpuSemFatos.data.Contains('mhz')) 'mas a frequência efetiva NÃO vira zero: ela simplesmente não é afirmada'

    $memSemFatos = & (Join-Path $projBase 'src\probes\Probe-Memory.ps1')
    Assert-True ($memSemFatos.ok) 'Probe-Memory roda sem os fatos do hospedeiro'
    Assert-True ($memSemFatos.data.availMB -gt 0) 'e a memória disponível, que não depende deles, vem'
    Assert-True (-not $memSemFatos.data.Contains('usedPct')) 'mas o uso percentual NÃO vira zero'

    # Com os fatos, os dois números aparecem: a omissão acima é falta de insumo,
    # não incapacidade da sonda.
    $fatos = [pscustomobject]@{ cpuBaseMHz = 3500; memTotalMB = 131072 }
    $cpuComFatos = & (Join-Path $projBase 'src\probes\Probe-Cpu.ps1') -Facts $fatos
    Assert-True ($cpuComFatos.data.mhz -gt 0) 'com os fatos, a frequência efetiva é calculada'
    $memComFatos = & (Join-Path $projBase 'src\probes\Probe-Memory.ps1') -Facts $fatos
    Assert-True ($memComFatos.data.usedPct -ge 0) 'e o uso percentual de memória também'

    # =====================================================================
    Start-TestGroup 'Sonda de leitura NÃO escreve arquivo  [MUTAÇÃO]'

    <#
        O default '$Facts = Get-WMHostFacts' gravava data\host.json como efeito
        colateral de um parâmetro que o chamador quase sempre já preenche. Uma
        sonda de LEITURA que escreve arquivo é um efeito invisível no caminho
        mais quente do projeto — e ele sobreviveu em duas das seis sondas porque
        nenhuma suíte executava estes arquivos.

        O projeto já tinha condenado exatamente isso, por escrito, no cabeçalho
        de Probe-DiskHealth.ps1. A condenação valia para uma sonda de seis.
    #>
    <#
        AS SONDAS RODAM NUM PROCESSO PRÓPRIO, com o MÓDULO DA CÓPIA carregado.

        Não é cerimônia. Em produção o módulo está sempre presente, e é dele que
        sai Get-WMHostFacts: invocar a sonda daqui, sem o módulo, mediria um
        ambiente que não existe — a reversão do conserto estouraria antes de
        escrever o arquivo, e a suíte morreria sem resumo em vez de acusar.

        E tem de ser o módulo DA CÓPIA. Com o do repositório real, a escrita
        cairia em data\host.json do repositório, fora do diretório que esta
        asserção observa: o efeito colateral aconteceria e o teste não veria.
    #>
    $projLimpo = New-ProjetoLimpo 'sem-efeito'
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $roteiro = Join-Path $projLimpo 'roda-sondas.ps1'
    [System.IO.File]::WriteAllText($roteiro, (@(
        "Import-Module (Join-Path '$projLimpo' 'src\WinMonitor.psm1') -Force"
        "`$null = & (Join-Path '$projLimpo' 'src\probes\Probe-Cpu.ps1')"
        "`$null = & (Join-Path '$projLimpo' 'src\probes\Probe-Memory.ps1')"
    ) -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))

    $saidaSondas = Join-Path $tmp 'sondas.txt'
    $pSondas = Start-Process -FilePath $psExe -PassThru -NoNewWindow -Wait:$false `
                   -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $roteiro `
                   -RedirectStandardOutput $saidaSondas -RedirectStandardError ($saidaSondas + '.err')
    $null = $pSondas.Handle
    $null = $pSondas.WaitForExit(120000)
    Assert-Equal 0 $pSondas.ExitCode 'as duas sondas rodam com o módulo carregado, sem estourar'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $projLimpo 'data\host.json'))) `
        'rodar as sondas de CPU e memória NÃO cria data\host.json'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $projLimpo 'data'))) `
        'nem o diretório de dados: leitura não escreve nada'

    # =====================================================================
    Start-TestGroup 'A ronda: a amostra que alimenta tudo  [MUTAÇÃO]'

    $am = & (Join-Path $projBase 'src\Invoke-Patrol.ps1') -NoWrite -PassThru
    Assert-NotNull $am 'Invoke-Patrol executa e devolve a amostra'
    Assert-Equal 1 $am.v 'a amostra declara a versão do formato'
    Assert-Equal 'patrol' $am.mode 'e o modo, para o armazém distinguir ronda de exame'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$am.host)) 'e a máquina de origem'

    <#
        O CARIMBO É INVARIANTE E COM DESLOCAMENTO. O armazém compara carimbos
        de dias diferentes; um carimbo na cultura corrente (th-TH escreve o ano
        budista) faria a comparação silenciosamente errada.
    #>
    Assert-True ($am.at -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}') 'o carimbo é ISO, ano gregoriano de quatro dígitos'
    Assert-True ($am.at -match '[+-]\d{2}:\d{2}$') 'e traz o deslocamento de fuso, para não virar hora ambígua'

    Assert-NotNull $am.cpu 'a amostra traz o bloco de CPU'
    Assert-NotNull $am.mem 'o de memória'
    Assert-True ($am.upH -gt 0) 'e o tempo ligado, que é o que denuncia reinício'

    <#
        A COBERTURA VEM NA PRÓPRIA AMOSTRA. É ela que permite ao armazém separar
        "a sonda mediu e deu zero" de "a sonda não mediu" — a distinção de que
        depende todo o resto do projeto.
    #>
    Assert-NotNull $am.cov 'a amostra declara a própria cobertura'
    Assert-True (@($am.cov.ok).Count -ge 1) 'com pelo menos uma sonda declarada como bem-sucedida'

    <#
        E A AMOSTRA ESCRITA TEM DE SER LEGÍVEL. Escrever JSON que não volta é a
        falha que descarta um dia inteiro de coleta sem ninguém perceber — e a
        vírgula decimal da cultura pt-BR já produziu exatamente isso neste
        projeto, descartando 196 de 200 linhas de uma fixture.
    #>
    $projRonda = New-ProjetoLimpo 'ronda'
    $null = & (Join-Path $projRonda 'src\Invoke-Patrol.ps1')
    $arqRonda = @(Get-ChildItem -LiteralPath (Join-Path $projRonda 'data\patrol') -Filter '*.jsonl' -ErrorAction SilentlyContinue)
    Assert-Equal 1 $arqRonda.Count 'a ronda grava exatamente um arquivo do dia'

    $linhas = @(Get-Content -LiteralPath $arqRonda[0].FullName)
    Assert-Equal 1 $linhas.Count 'com uma linha por execução'
    $volta = $linhas[0] | ConvertFrom-Json
    Assert-Equal 1 $volta.v 'e a linha volta do JSON inteira'
    Assert-Equal 'patrol' $volta.mode 'com o modo preservado'
    Assert-True ($volta.upH -gt 0) 'e o tempo ligado como NÚMERO, não como texto com vírgula'

    # Segunda execução ANEXA, não substitui: perder amostra é perder o dia.
    $null = & (Join-Path $projRonda 'src\Invoke-Patrol.ps1')
    $linhas2 = @(Get-Content -LiteralPath $arqRonda[0].FullName)
    Assert-Equal 2 $linhas2.Count 'a execução seguinte ANEXA em vez de substituir'
    Assert-Equal $linhas[0] $linhas2[0] 'e a amostra anterior fica intacta'

    # =====================================================================
    Start-TestGroup 'A ronda: sonda MORTA não pode virar sonda viva  [MUTAÇÃO]'

    <#
        AS TRÊS INVARIANTES QUE NENHUMA DAS NOVE SUÍTES DEFENDIA.

        A décima terceira verificação mediu, mutando a ronda e rodando o portão
        inteiro: zerar `cov.gap`, pôr sonda que FALHOU dentro de `cov.ok`, e
        trocar `exit 2` por `exit 0` — as três passavam verdes. De doze mutações
        na ronda, três morriam.

        E o bloco de cobertura é o que o próprio arquivo chama de razão de ser:
        "impede 'nenhum problema encontrado' de se confundir com 'não consegui
        olhar'". A frase estava lá, sem ninguém a segurando.

        O cenário planta uma sonda sintética que SEMPRE falha, com key própria, e
        exige que ela apareça como lacuna e NÃO como sucesso.
    #>
    $projFalha = New-ProjetoLimpo 'sonda-morta'
    [System.IO.File]::WriteAllText((Join-Path $projFalha 'src\probes\Probe-Morta.ps1'),
        "param(`$Facts, [int]`$TimeoutSec)`r`n@{ ok = `$false; reason = 'sonda sintetica que sempre falha' }`r`n",
        (New-Object System.Text.UTF8Encoding($true)))

    $cfgFalha = Join-Path $projFalha 'config\config.json'
    $jFalha = Get-Content -LiteralPath $cfgFalha -Raw -Encoding UTF8 | ConvertFrom-Json
    $jFalha.patrol.probes = @($jFalha.patrol.probes) + @([pscustomobject]@{ name = 'Morta'; key = 'mor' })
    [System.IO.File]::WriteAllText($cfgFalha, ($jFalha | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))

    <#
        PROCESSO PRÓPRIO, e não invocação daqui: o módulo já está carregado
        apontando para OUTRA cópia, e Get-WMPath resolveria os caminhos para
        ela — a amostra iria parar no projeto errado e este teste mediria o
        diretório errado. Medido: foi exatamente o que aconteceu na primeira
        versão deste cenário.
    #>
    $oF = Join-Path $tmp 'sonda-morta.txt'
    $pF = Start-Process -FilePath $psExe -PassThru -NoNewWindow -Wait:$false `
              -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', `
                            (Join-Path $projFalha 'src\Invoke-Patrol.ps1') `
              -RedirectStandardOutput $oF -RedirectStandardError ($oF + '.err')
    $null = $pF.Handle
    $null = $pF.WaitForExit(120000)

    $arqF = @(Get-ChildItem -LiteralPath (Join-Path $projFalha 'data\patrol') -Filter '*.jsonl')
    Assert-Equal 1 $arqF.Count 'a ronda com sonda morta ainda grava o dia'
    <#
        Leitura CRUA e não por linha. A invariante "uma linha por execução" é
        medida no grupo anterior, contra a ronda normal; aqui o que importa é o
        conteúdo da cobertura, e ler o arquivo inteiro torna este cenário imune
        à forma como a amostra foi quebrada.
    #>
    $amF = (Get-Content -LiteralPath $arqF[0].FullName -Raw) | ConvertFrom-Json

    $okF  = @($amF.cov.ok)
    $gapF = @($amF.cov.gap.PSObject.Properties.Name)

    Assert-True ($gapF -contains 'mor') 'sonda que falhou aparece como LACUNA declarada'
    Assert-True (-not ($okF -contains 'mor')) 'e NÃO aparece entre as bem-sucedidas'
    Assert-True ([string]$amF.cov.gap.mor -match 'sempre falha') 'com o motivo dela, não com silêncio'
    Assert-True ($okF.Count -ge 1) 'e as sondas que funcionaram continuam declaradas como tal'
    Assert-True (-not ($amF.PSObject.Properties.Name -contains 'mor')) 'a chave da sonda morta não vira bloco de dados vazio'

    <#
        O CÓDIGO DE SAÍDA É O CONTRATO COM O AGENDADOR. É por ele que o Windows
        registra "última execução: 0x2" e é a única coisa que alguém olha ao
        perguntar se a ronda está viva. 'exit 2' significa que o módulo não
        carregou — a ronda não rodou de forma nenhuma —, e trocá-lo por zero faz
        a tarefa agendada relatar sucesso para todo dia em que nada foi coletado.
    #>
    $projSemModulo = New-ProjetoLimpo 'sem-modulo'
    Remove-Item -LiteralPath (Join-Path $projSemModulo 'src\WinMonitor.psm1') -Force

    $oSm = Join-Path $tmp 'sem-modulo.txt'
    $pSm = Start-Process -FilePath $psExe -PassThru -NoNewWindow -Wait:$false `
               -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', `
                             (Join-Path $projSemModulo 'src\Invoke-Patrol.ps1') `
               -RedirectStandardOutput $oSm -RedirectStandardError ($oSm + '.err')
    $null = $pSm.Handle
    $null = $pSm.WaitForExit(120000)
    Assert-Equal 2 $pSm.ExitCode 'sem o módulo, a ronda sai com 2 — nem 0 nem 1'

    # E a execução normal sai com ZERO, senão o 2 acima seria vacuamente verdadeiro.
    $oOk = Join-Path $tmp 'ronda-ok.txt'
    $pOk = Start-Process -FilePath $psExe -PassThru -NoNewWindow -Wait:$false `
               -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', `
                             (Join-Path $projBase 'src\Invoke-Patrol.ps1'), '-NoWrite' `
               -RedirectStandardOutput $oOk -RedirectStandardError ($oOk + '.err')
    $null = $pOk.Handle
    $null = $pOk.WaitForExit(120000)
    Assert-Equal 0 $pOk.ExitCode 'e a ronda que roda inteira sai com zero'

    # =====================================================================
    Start-TestGroup 'A ferramenta que protege o acento NÃO pode destruí-lo  [MUTAÇÃO]'

    <#
        Repair-Encoding existe para que um .ps1 sem BOM não seja lido na página
        ANSI e corrompa acento. Medido pela décima terceira verificação: ela
        fazia exatamente o oposto.

        [Encoding]::UTF8.GetString() NUNCA falha — ele substitui cada byte
        inválido por U+FFFD e devolve a string. Gravar isso de volta torna a
        corrupção PERMANENTE, e a ferramenta anunciava 'BOM adicionado' como
        sucesso:

            antes  : ... 231 227 233 245 225 13 10   (5 acentos CP1252)
            depois : ... 239 191 189 (x5) 13 10      (5 U+FFFD)
            byte original 0xE7 ainda presente: False

        Nenhum arquivo do repositório foi danificado, porque todos já tinham BOM
        e ela nunca os reescreveu. O defeito era latente e destrutivo.
    #>
    $projEnc = New-ProjetoLimpo 'encoding'
    $dirTools = New-Item -ItemType Directory -Path (Join-Path $projEnc 'tools') -Force
    Copy-Item -LiteralPath (Join-Path $root 'tools\Repair-Encoding.ps1') -Destination $dirTools -Force

    $arqAnsi = Join-Path $projEnc 'src\Acentuado.ps1'
    [System.IO.File]::WriteAllBytes($arqAnsi, [byte[]](35, 32, 120, 32, 0xE7, 0xE3, 0xE9, 0xF5, 0xE1, 13, 10))
    $null = & (Join-Path $projEnc 'tools\Repair-Encoding.ps1')

    $textoRecuperado = [System.IO.File]::ReadAllText($arqAnsi)
    Assert-Equal 0 (@([regex]::Matches($textoRecuperado, [char]0xFFFD))).Count `
        'arquivo ANSI NÃO vira U+FFFD: a corrupção não é gravada como permanente'
    Assert-True ($textoRecuperado.Contains([char]0xE7)) 'e o cedilha volta, em vez de ser apagado'
    Assert-True ($textoRecuperado.Contains([char]0xE3)) 'e o til também'

    <#
        E O CONTRÁRIO: arquivo que JÁ é UTF-8 válido não pode ser lido como
        ANSI, senão a "correção" duplicaria cada byte acentuado. Sem esta
        asserção, trocar a detecção por "sempre ANSI" passaria no teste acima.
    #>
    $arqUtf8 = Join-Path $projEnc 'src\JaUtf8.ps1'
    $conteudoUtf8 = '# x ' + [char]0xE7 + [char]0xE3 + [char]0xE9 + "`r`n"
    [System.IO.File]::WriteAllText($arqUtf8, $conteudoUtf8, (New-Object System.Text.UTF8Encoding($false)))
    $null = & (Join-Path $projEnc 'tools\Repair-Encoding.ps1')
    $textoUtf8 = [System.IO.File]::ReadAllText($arqUtf8)
    Assert-True ($textoUtf8.Contains([char]0xE7 + [string][char]0xE3 + [string][char]0xE9)) 'arquivo que já era UTF-8 válido fica intacto'
    Assert-Equal 0 (@([regex]::Matches($textoUtf8, [char]0xFFFD))).Count 'sem U+FFFD nele tampouco'

    # =====================================================================
    Start-TestGroup 'A TERCEIRA sonda também não escreve arquivo  [MUTAÇÃO]'

    <#
        O commit anterior disse "as outras duas". Eram TRÊS: Probe-Events
        continuava com o default que chama Get-WMHostFacts, e $Facts não é usado
        em mais nenhuma linha daquele arquivo — a linha existia unicamente para
        produzir o efeito colateral.

        Ela escapou porque o exame SEMPRE passa -Facts: o ramo do default nunca
        executava sob o teste que exercita a sonda. Defensor de existência não é
        defensor de efeito colateral.
    #>
    $projEvt = New-ProjetoLimpo 'sem-efeito-evt'
    $roteiroEvt = Join-Path $projEvt 'roda-eventos.ps1'
    [System.IO.File]::WriteAllText($roteiroEvt, (@(
        "Import-Module (Join-Path '$projEvt' 'src\WinMonitor.psm1') -Force"
        "`$null = & (Join-Path '$projEvt' 'src\probes\Probe-Events.ps1') -WindowDays 1"
    ) -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))

    $saidaEvt = Join-Path $tmp 'eventos.txt'
    $pEvt = Start-Process -FilePath $psExe -PassThru -NoNewWindow -Wait:$false `
                -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $roteiroEvt `
                -RedirectStandardOutput $saidaEvt -RedirectStandardError ($saidaEvt + '.err')
    $null = $pEvt.Handle
    $null = $pEvt.WaitForExit(180000)
    Assert-Equal 0 $pEvt.ExitCode 'a sonda de eventos roda com o módulo carregado'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $projEvt 'data\host.json'))) `
        'e NÃO cria data\host.json: a terceira sonda também é leitura pura'

} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Show-TestSummary
exit (Get-TestExitCode)
