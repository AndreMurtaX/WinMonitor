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
         '   ok    nome' por teste que passa e uma '   FALHA nome' por teste que
         falha (mais uma linha de detalhe, que NÃO casa o padrão por ter recuo
         diferente). O resumo tem de bater com a contagem delas. Suíte que
         imprime o resumo sem rodar teste nenhum é pega aqui.
      5. VARREDURA DE DIRETÓRIO. Arquivo Test-*.ps1 que não está na lista é
         vermelho — senão apagar uma linha da lista some com uma suíte inteira.
      6. PRAZO, por suíte, no conjunto E na bateria. Suíte que trava não pode
         segurar o portão para sempre. A bateria rodava fora de todo teto: com
         teto global de 1 s ela seguia por 93 s, medido.
      7. A BATERIA DE MUTAÇÃO É JULGADA PELAS MESMAS DOUTRINAS. O portão lhe
         aplicava UMA das conferências — o código de saída — e nenhuma das
         outras. Bateria muda, bateria com zero mutantes e bateria que anuncia
         trava indefesa saindo com zero passavam todas: a bateria ESVAZIADA era
         aceita como prova de que toda trava tem defensor.

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
    [int]$SuiteTimeoutSec = 600,
    <#
        O teto do conjunto é PARÂMETRO, não derivado do prazo por suíte.

        Era [Math]::Max($SuiteTimeoutSec * 2, 900), e com o prazo curto que a
        aferição usa isso dava sempre 900 s — o teto global era inatingível por
        qualquer teste, em qualquer configuração. Trava que a costura de
        verificação não consegue exercitar é trava que ninguém sabe se funciona.
    #>
    [int]$TotalTimeoutSec = 1800,
    <#
        -Rapido pula a bateria de mutação, que recopia o projeto por mutante.
        Quem pula precisa dizer que pulou, e o portão diz.
    #>
    [switch]$Rapido,
    <#
        A BATERIA PRECISA SER ALCANÇÁVEL PELA AFERIÇÃO, e não era.

        O bloco dela estava guardado por '-not $SuiteDir', e Test-Gate SEMPRE
        passa -SuiteDir. Quatro mutantes sobreviviam ali — inclusive o que
        desliga a conferência inteira. Era o defeito que o cabeçalho deste
        arquivo condena ("trava que a costura de verificação não consegue
        exercitar é trava que ninguém sabe se funciona"), cometido na peça
        acrescentada para acabar com ele.

        -BateriaPath aponta para uma bateria sintética; -SemBateria pula por
        escolha explícita. Nenhum dos dois é usado em produção.

        -MutantesMin é o PISO da bateria, pela mesma razão do piso por suíte: a
        lista de mutantes é mantida à MÃO, e apagar entradas dela é exatamente
        como "defesa que só existe quando alguém lembra" volta. Medido: perder
        36 dos 37 ficava verde, porque o piso era um. Atualizado à mão — se ele
        se ajustasse sozinho, não seria piso.
    #>
    [string]$BateriaPath,
    [switch]$SemBateria,
    <#
        -SemSombra pula a varredura de sombra de parâmetro, pela mesma razão e
        com a mesma regra do -SemBateria: os cenários de Test-Gate invocam o
        portão dezenas de vezes, e varrer o repositório inteiro em cada uma custa
        minutos sem medir nada de novo. Quem pula precisa DIZER que pulou.

        O cenário que exercita a varredura de verdade — projeto copiado com uma
        colisão plantada — não passa este switch. É a diferença entre pular por
        economia e pular por conveniência.
    #>
    [switch]$SemSombra,
    [int]$BateriaTimeoutSec = 9000,
    [int]$MutantesMin = 103,
    <#
        Pisos das duas varreduras, pela mesma razão do piso por suíte: varredura
        que encolhe fica vacuamente verde. Medido: reduzir a guarda de LF a
        '.psm1', ou fazê-la pular tests\ e tools\, ou a varredura de sombra
        ignorar os módulos, passavam as três com o portão verde — porque cada
        cenário sabota UM arquivo, e alcançar aquele arquivo bastava.

        Atualizados à mão quando o projeto cresce. Se se ajustassem sozinhos,
        não seriam piso.
    #>
    [int]$ArquivosCrlfMin = 44,
    [int]$ArquivosSombraMin = 44
)

<#
    ERRO DE USO SAI CRU NO STDERR, e não por Write-Error.

    O formatador de erro do PowerShell quebra a mensagem na largura do console —
    120 colunas — e a posição da quebra depende do COMPRIMENTO DO CAMINHO do
    script, que entra no cabeçalho do ErrorRecord. O resultado é uma frase
    partida ao meio, e uma asserção que casava com ela passa a falhar conforme
    ONDE o projeto está no disco.

    Medido pela décima primeira verificação, mesma árvore e mesmo commit:

        comprimento de tests\Run-All.ps1 = 55  ->  88 passou, 0 falhou
                                         = 70  ->  88 passou, 0 falhou
                                         = 87  ->  81 passou, 7 falhou

    A faixa que reprova é de 72 a 91 caracteres. O repositório do autor tem 35 e
    passa; um zip do GitHub descompactado como '...\Projetos\WinMonitor-main'
    tem 76 e REPROVA. O verde dependia do lugar do projeto no disco, e nada
    nesta suíte tinha como perceber.

    Eu já declarei isso consertado uma vez, trocando a captura de saída por
    redirecionamento em arquivo. Aquilo curou o vácuo do EAP — que era real — e
    não curou isto: o texto continuava chegando partido. Duas causas, um sintoma,
    e eu parei na primeira.
#>
function Write-WMErroDeUso {
    param([string]$Mensagem)
    [Console]::Error.WriteLine("ERRO: $Mensagem")
}

<#
    LER SAIDA DE PROCESSO FILHO SEM ADIVINHAR A CODIFICACAO.

    Este projeto ja errou nos DOIS sentidos, e a segunda vez foi por a primeira
    medicao ter envelhecido:

      1. A versao original lia com -Encoding UTF8. Medido byte a byte: o filho
         escrevia CP850, e a leitura UTF8 DESTRUIA o acento. Trocado para OEM,
         com a medicao escrita no comentario.

      2. Depois a pagina de codigo do console desta maquina passou a ser 65001
         (UTF-8). O filho passou a escrever UTF-8, a leitura OEM passou a
         destruir o acento, e SETE assercoes do Test-Gate ficaram vermelhas -
         todas as que casavam palavra acentuada, e nenhuma das que nao casavam.

    Nas duas vezes o codigo estava correto para a maquina onde foi medido e
    errado para a maquina do lado. O verde dependia de 'chcp', que e ambiente,
    e nao de codigo.

    Agora nao se escolhe: leem-se os BYTES e tenta-se UTF-8 ESTRITO. Conteudo
    que nao e UTF-8 lanca - em vez de virar U+FFFD em silencio - e ai e lido na
    pagina OEM. E o mesmo desenho de tools\Repair-Encoding.ps1, pelo mesmo
    motivo. A duplicacao deste bloco entre os arquivos e deliberada: o portao
    nao depende de src\, para poder julgar src\.

    O QUE ISTO NAO RESOLVE, dito em vez de negado: uma sequencia CP850 que por
    acaso seja UTF-8 valido seria lida como UTF-8. Para texto latino com uma ou
    duas letras acentuadas isso e improvavel, e nao ha como distinguir sem
    perguntar ao filho qual codificacao ele usou - coisa que a API nao oferece.
#>
function Read-WMSaidaFilho {
    param([string]$Caminho)
    if (-not (Test-Path -LiteralPath $Caminho)) { return '' }
    <#
        FileShare.ReadWrite, e NAO ReadAllBytes.

        [IO.File]::ReadAllBytes abre sem compartilhamento e estoura se outro
        processo ainda segura o arquivo. Medido pelo mutante BL-92: com ele, o
        portao filho nao espera a bateria terminar, o processo dela continua com
        o handle de redirecao aberto, e a leitura estourava - derrubando a suite
        sem resumo, o que a bateria classifica como INCONCLUSIVO.

        Get-Content, que estava aqui antes, lia COMPARTILHADO. A troca por
        ReadAllBytes consertou a codificacao e trouxe esta fragilidade junto. Foi
        a propria bateria que a encontrou, no mutante seguinte.

        Falha de leitura devolve vazio em vez de lancar, como o
        '-ErrorAction SilentlyContinue' que havia antes: um auxiliar de leitura
        que derruba quem o chama transforma diagnostico em morte.
    #>
    $bytes = $null
    try {
        $fs = New-Object System.IO.FileStream($Caminho, [System.IO.FileMode]::Open,
                                              [System.IO.FileAccess]::Read,
                                              [System.IO.FileShare]::ReadWrite)
        try {
            $bytes = New-Object byte[] $fs.Length
            [void]$fs.Read($bytes, 0, $bytes.Length)
        } finally { $fs.Dispose() }
    } catch { return '' }
    if ($null -eq $bytes -or $bytes.Length -eq 0) { return '' }
    try {
        $estrito = New-Object System.Text.UTF8Encoding($false, $true)
        return $estrito.GetString($bytes)
    } catch {
        $oem = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
        return $oem.GetString($bytes)
    }
}

$suites = @(
    @{ file = 'Test-Rollup.ps1';      min = 147 }
    @{ file = 'Test-Rules.ps1';       min = 150 }
    @{ file = 'Test-Laudo.ps1';       min = 170 }
    @{ file = 'Test-LaudoDriver.ps1'; min = 37  }
    @{ file = 'Test-Report.ps1';      min = 127 }
    @{ file = 'Test-Exam.ps1';        min = 129 }
    @{ file = 'Test-Gate.ps1';        min = 143 }
    @{ file = 'Test-Drivers.ps1';     min = 105 }
    @{ file = 'Test-Patrol.ps1';      min = 52  }
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
            Write-WMErroDeUso "SuiteSpec ilegível em '$item' — o formato é arquivo:piso"
            exit 2
        }
        $arq = $par[0].Trim()
        if ([string]::IsNullOrWhiteSpace($arq)) {
            Write-WMErroDeUso "SuiteSpec sem nome de arquivo em '$item'"
            exit 2
        }
        if ($arq -match '[\\/]' -or $arq -match '\.\.') {
            Write-WMErroDeUso "SuiteSpec com caminho em '$arq' — só nome de arquivo dentro do diretório de suítes"
            exit 2
        }
        if ($piso -lt 0) {
            Write-WMErroDeUso "SuiteSpec com piso negativo em '$item' — piso é contagem de testes"
            exit 2
        }
        [void]$lista.Add(@{ file = $arq; min = $piso })
    }
    $suites = @($lista)
}

if (@($suites).Count -eq 0) {
    Write-WMErroDeUso 'nenhuma suíte a executar: um portão sem suíte não aprova nada'
    exit 2
}

<#
    -BateriaPath É COSTURA DE AFERIÇÃO, e agora está confinado a ela.

    O parâmetro aponta um arquivo qualquer e o portão o EXECUTA. Enquanto ele
    valia em qualquer invocação, o instrumento que declara o projeto verde
    aceitava rodar um executável arbitrário — a mesma classe de brecha que o
    confinamento de -SuiteSpec fechou, na mesma peça, sem eu ter aplicado aqui.

    Toda invocação de teste passa -SuiteDir; nenhuma invocação de produção
    passa. É por isso que exigir os dois juntos confina sem tirar nada.
#>
if ($BateriaPath -and -not $SuiteDir) {
    Write-WMErroDeUso '-BateriaPath só é aceito junto de -SuiteDir: é costura de aferição, não configuração do portão'
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

foreach ($s in $suites) {
    if ($relogio.Elapsed.TotalSeconds -gt $TotalTimeoutSec) {
        [void]$falhas.Add("o portão passou de $TotalTimeoutSec s no total e parou antes de $($s.file)")
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
    <#
        A CODIFICACAO NAO E ESCOLHIDA AQUI: ela e DETECTADA, e este comentario
        e o registro de por que.

        Quem escreve o arquivo e a redirecao de console do powershell.exe filho,
        que usa a pagina de codigo do CONSOLE - nao a doutrina de UTF-8 deste
        projeto, que vale para os arquivos que ele mesmo grava.

        A versao original lia com UTF8 e destruia o acento. Medido byte a byte,
        com o console em cp850:

            bytes no arquivo (cp850) : 210,135,198,130
            lido como UTF8           : 1159,386          dois chars, irreversivel
            lido como OEM            : 202,231,227,233   CORRETO

        Trocado para OEM, com a medicao escrita aqui. E a medicao ENVELHECEU: a
        pagina de codigo desta maquina passou a ser 65001, o filho passou a
        escrever UTF-8, e a leitura OEM passou a destruir o acento - sete
        assercoes do Test-Gate vermelhas, todas as que casavam palavra
        acentuada e nenhuma das que nao casavam.

        Nas duas vezes o codigo estava certo para a maquina onde foi medido e
        errado para a do lado. O verde dependia de 'chcp', que e ambiente.

        Read-WMSaidaFilho nao escolhe: tenta UTF-8 ESTRITO e cai para OEM quando
        os bytes nao sao UTF-8 validos.
    #>
    $codigo = $proc.ExitCode
    $texto  = (Read-WMSaidaFilho $tmpOut) + "`n" +
              (Read-WMSaidaFilho ($tmpOut + '.err'))
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

        O padrão casa o FORMATO EXATO do TestKit — três espaços, 'ok', quatro
        espaços — e não '\s+ok\s'. Com o padrão frouxo, qualquer linha do código
        sob teste que começasse parecido inflava a contagem e o portão acusava a
        suíte de mentir sobre si mesma. Vermelho por motivo nenhum é o que faz
        alguém desligar o portão, e aí ele não guarda mais nada.

        Continua fora do alcance: teste que virou vácuo. Vinte 'Assert-True
        $true' imprimem vinte linhas legítimas e nenhuma contagem os distingue —
        só leitura humana ou análise de mutação.
    #>
    $linhasOk    = @([regex]::Matches($texto, '(?m)^   ok    ')).Count
    $linhasFalha = @([regex]::Matches($texto, '(?m)^   FALHA ')).Count

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
    O TOTAL ESPERADO É INFORMAÇÃO, NÃO TRAVA — e isso foi medido, não suposto.

    Havia aqui um "piso global" anunciado como "a rede que pega perda de teste
    em qualquer lugar". Ele não pegava nada que já não fosse pego: sendo
    pisoTotal a soma dos pisos e totalOk a soma dos passou, a soma só fica
    abaixo se alguma suíte ficou abaixo do próprio piso, ou não foi executada,
    ou não existe — e TODOS esses caminhos já registram falha própria. Por
    construção, ele nunca pode ser a causa única de uma reprovação.

    Duas verificações seguidas mostraram a mutação que o removia passando com a
    suíte inteira verde, e a segunda mostrou por quê. Manter uma trava que não
    tem como disparar sozinha é pior que não ter: ela dá a impressão de cobrir
    um caso que na verdade está coberto por outra coisa, e alguém confia nela.

    O número continua sendo impresso, porque conferir o total de cabeça contra o
    esperado é útil para quem lê. Ele só não finge ser defesa.
#>
# Soma à mão: Measure-Object -Property não enxerga CHAVE de hashtable, só
# propriedade de objeto — e falha em vez de devolver zero.
$totalEsperado = 0
foreach ($s in $suites) { $totalEsperado += [int]$s.min }

$projRaiz = Split-Path -Parent $PSScriptRoot

<#
    OS BYTES QUE EU EXECUTO TÊM DE SER OS BYTES QUE EU PUBLICO.

    O .gitattributes deste projeto declara '*.ps1 text eol=crlf' e a árvore de
    trabalho estava em LF. Quem clonasse receberia arquivos com quebra de linha
    diferente de tudo que rodou aqui: o verde valia para uma versão que só
    existia nesta máquina. Medido, não temido — 46 arquivos, todos divergentes.

    E o hábito que produz isso é MEU. Toda edição em lote que eu escrevo com
    [System.IO.File]::WriteAllText junta as linhas com "`n" e reintroduz a
    divergência em silêncio, num arquivo por vez. Lembrete não segura isso;
    por isso é conferência, dentro do portão, sobre os bytes.

    O QUE ELA NÃO PEGA, dito em vez de negado: divergência de CODIFICAÇÃO. BOM
    ausente num .ps1 corrompe acento sem mudar quebra de linha nenhuma — quem
    cuida disso é tools\Repair-Encoding.ps1, e ele não roda daqui.

    E ELA SÓ VALE PARA O QUE O .gitattributes GOVERNA.

    A primeira versão varria tudo, e reprovava README.md e config.json vindos em
    LF de um clone com core.eol=lf — que é entrega LEGÍTIMA, porque esses dois
    são 'text=auto' e não 'eol=crlf'. Vermelho com a mensagem errada é pior que
    trava nenhuma: é assim que alguém aprende a desligar o portão.

    A causa era um filtro que não filtra: com -LiteralPath e -Recurse, o
    Get-ChildItem do PowerShell 5.1 IGNORA -Include. Medido nesta árvore: 46
    arquivos com -Include, 39 filtrando de verdade, e os 7 intrusos eram
    .gitattributes, .gitignore, LICENSE, README.md e os três JSONs.

    O projeto tem doutrina explícita sobre isso — "código morto com cara de
    defesa é pior que defesa nenhuma" — e eu escrevi as duas travas novas com
    um filtro morto.
#>
$EXT_CRLF = @('.ps1', '.psm1', '.psd1')

$varridos = @(Get-ChildItem -LiteralPath $projRaiz -Recurse -File -ErrorAction SilentlyContinue |
                  Where-Object { $EXT_CRLF -contains $_.Extension -and $_.FullName -notmatch '\\(data|logs|\.git)\\' })

<#
    PISO DE ARQUIVOS VARRIDOS, pela mesma razão do piso por suíte e do piso de
    mutantes: varredura que não varre nada é vacuamente verdadeira.

    Medido antes do piso: reduzir a guarda a '.psm1', ou fazê-la pular tests\ e
    tools\, deixava o portão VERDE. O cenário de sabotagem tocava um arquivo só,
    então bastava alcançar aquele arquivo para o teste passar — a regra nasceu
    com o alcance do defeito que a gerou, de novo.
#>
if ($varridos.Count -lt $ArquivosCrlfMin) {
    [void]$falhas.Add("quebra de linha: varreu $($varridos.Count) script(s), o piso é $ArquivosCrlfMin — a varredura encolheu e o verde dela não vale")
}

$lfSoltos = New-Object System.Collections.ArrayList
foreach ($arq in $varridos) {
    $bytes = [System.IO.File]::ReadAllBytes($arq.FullName)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 10 -and ($i -eq 0 -or $bytes[$i - 1] -ne 13)) {
            $rel = if ($arq.FullName.StartsWith($projRaiz, [StringComparison]::OrdinalIgnoreCase)) {
                       $arq.FullName.Substring($projRaiz.Length).TrimStart('\')
                   } else { $arq.FullName }
            [void]$lfSoltos.Add($rel)
            break
        }
    }
}
if ($lfSoltos.Count -gt 0) {
    [void]$falhas.Add("quebra de linha: $($lfSoltos.Count) script(s) com LF solto e o .gitattributes declara CRLF — o que roda aqui não é o que o clone recebe: $($lfSoltos -join ', ')")
}

<#
    VARREDURA DE SOMBRA DE PARÂMETRO — a única armadilha que mordeu TRÊS vezes.

    '$discos = $null' e o parâmetro '$Discos' são A MESMA variável: nomes em
    PowerShell são insensíveis a caixa. A atribuição local apaga o parâmetro
    sem erro, sem aviso, e o teste passa a medir o caminho errado.

    F2 ($windowDays), F5 ($Suites) e F3 ($discos) — a terceira aconteceu com a
    armadilha já DOCUMENTADA no repositório, na mesma sessão que citava as duas
    anteriores. Documentar armadilha não previne armadilha; só varredura
    mecânica previne, e só se ela rodar sem ninguém lembrar dela.

    Por isso ela entra no portão em vez de ficar em tools\ esperando convite.
#>
$sombra = Join-Path $projRaiz 'tools\Find-ParamShadow.ps1'
if ($SemSombra) {
    ""
    "(varredura de sombra de parâmetro PULADA: o verde abaixo não diz nada sobre parâmetro apagado)"
} elseif (-not (Test-Path -LiteralPath $sombra)) {
    [void]$falhas.Add('a varredura de sombra de parâmetro não existe: a armadilha que mordeu três vezes voltou a não ter guarda')
} else {
    ""
    "##################  sombra de parâmetro  ##################"
    $somOut = [System.IO.Path]::GetTempFileName()
    $psom = Start-Process -FilePath $psExe -PassThru -NoNewWindow -Wait:$false `
                -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $sombra `
                -RedirectStandardOutput $somOut -RedirectStandardError ($somOut + '.err')
    $null = $psom.Handle
    if (-not $psom.WaitForExit(120000)) {
        try { $psom.Kill() } catch { }
        [void]$falhas.Add('varredura de sombra de parâmetro: estourou o prazo e foi morta')
    } else {
        $txtSom = (Read-WMSaidaFilho $somOut) + "`n" +
                  (Read-WMSaidaFilho ($somOut + '.err'))
        if (-not $Quiet) { $txtSom.TrimEnd() }
        <#
            OS DOIS DESFECHOS SAO DIFERENTES, e o portao jogava fora a distincao
            que a propria varredura passou a fazer.

            Codigo 1 e colisao encontrada. Codigo 2 e arquivo que ela NAO
            CONSEGUIU analisar - a falha fechada que substituiu a falha aberta.
            Mapear os dois para "ha variavel colidindo" produz vermelho na
            direcao segura com diagnostico factualmente FALSO, e a doutrina
            escrita neste repositorio e que vermelho com mensagem errada e
            exatamente como alguem aprende a desligar o portao.
        #>
        if ($psom.ExitCode -eq 2) {
            [void]$falhas.Add('varredura de sombra de parametro: ha script que ela NAO conseguiu analisar - nao olhar nao e nao ter nada')
        } elseif ($psom.ExitCode -ne 0) {
            [void]$falhas.Add('varredura de sombra de parametro: ha variavel local colidindo com parametro so na caixa')
        }
        <#
            E O PISO DELA TAMBÉM É CONFERIDO AQUI, do lado de fora.

            A varredura declara quantos arquivos leu; sem conferir esse número,
            reduzi-la a um subconjunto deixava o portão verde. Medido: fazê-la
            ignorar os .psm1 tirava os cinco módulos — cerca de 3,4 mil linhas,
            Laudo, Report, Rollup, Rules e WinMonitor — da única defesa mecânica
            contra a armadilha que mordeu três vezes, e nada acusava.

            A conferência é do lado de FORA porque a varredura é quem seria
            sabotada: instrumento não confere o próprio alcance.
        #>
        $mSom = [regex]::Match($txtSom, '\((\d+) arquivo')
        if (-not $mSom.Success) {
            [void]$falhas.Add('varredura de sombra de parâmetro: não declarou quantos arquivos varreu — não dá para saber se ela encolheu')
        } elseif ([int]$mSom.Groups[1].Value -lt $ArquivosSombraMin) {
            [void]$falhas.Add("varredura de sombra de parâmetro: varreu $($mSom.Groups[1].Value) arquivo(s), o piso é $ArquivosSombraMin — o alcance encolheu")
        }
    }
    Remove-Item -LiteralPath $somOut, ($somOut + '.err') -Force -ErrorAction SilentlyContinue
}

<#
    A BATERIA DE MUTACAO ENTRA NO PORTAO.

    Ela e a regua da regua: prova que cada trava tem quem a defenda. E ficava
    fora de tudo - Run-All nao a citava, a varredura so cobre tests\Test-*.ps1,
    e o README nao a mencionava. Ou seja, a ferramenta anti-"defesa que so existe
    quando alguem lembra" era, ela propria, uma defesa que so existia quando
    alguem lembrava. Medido pela verificacao, nao temido.
#>
if ($Rapido -or $SemBateria) {
    ""
    "(bateria de mutação PULADA: o verde abaixo não diz nada sobre travas indefesas)"
} else {
    ""
    "##################  bateria de mutação  ##################"
    $bat = if ($BateriaPath) { $BateriaPath }
           else { Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\Test-Mutantes.ps1' }

    if (-not (Test-Path -LiteralPath $bat)) {
        [void]$falhas.Add('a bateria de mutação não existe: nada prova que as travas são defendidas')
    } else {
        <#
            A BATERIA É JULGADA PELAS MESMAS DOUTRINAS QUE AS SUÍTES.

            O portão aplicava a ela UMA das suas seis conferências — o código de
            saída — e nenhuma das outras cinco. Medido: bateria reduzida a
            'exit 0', bateria que anuncia trava indefesa e sai com zero, e
            bateria que declara "TODOS OS 0 MUTANTES MORRERAM" passavam todas.
            A bateria ESVAZIADA era aceita como prova de que toda trava tem quem
            a defenda — "etapa que não roda contando como verde", um nível acima,
            no commit cuja manchete era exatamente isso.

            E ela rodava fora de qualquer prazo: com teto global de 1 s, o laço
            parava e a bateria seguia por 93 s.
        #>
        $batOut = [System.IO.Path]::GetTempFileName()
        $pb = Start-Process -FilePath $psExe -PassThru -NoNewWindow -Wait:$false `
                  -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $bat `
                  -RedirectStandardOutput $batOut -RedirectStandardError ($batOut + '.err')
        $null = $pb.Handle

        if (-not $pb.WaitForExit($BateriaTimeoutSec * 1000)) {
            try { $pb.Kill() } catch { }

            <#
                PRAZO ESTOURADO NÃO PODE APAGAR O QUE JÁ FOI MEDIDO.

                A versão anterior zerava $saidaBat aqui. Consequência medida: a
                bateria rodou 90 minutos, avaliou dezenas de mutantes, foi morta
                — e o portão imprimiu "estourou o prazo" e MAIS NADA. Se houvesse
                uma trava indefesa entre os avaliados, ela ficaria invisível
                justamente na execução que mais demorou a chegar nela.

                O processo escreve num arquivo enquanto roda, e esse arquivo
                sobrevive à morte dele. Ler o parcial é a diferença entre "não
                terminou" e "não sei nada".

                A leitura é compartilhada (Read-WMSaidaFilho) porque o handle do
                filho morto pode não ter sido liberado ainda — foi assim que o
                BL-92 derrubou a suíte inteira uma vez.
            #>
            $saidaBat = (Read-WMSaidaFilho $batOut) + "`n" +
                        (Read-WMSaidaFilho ($batOut + '.err'))
            $avaliados = @([regex]::Matches($saidaBat, '(?m)^\s+(morto|VIVO|\?\?)')).Count
            [void]$falhas.Add("bateria de mutação: estourou o prazo de $BateriaTimeoutSec s e foi morta apos avaliar $avaliados mutante(s) - o parcial dela vai abaixo")
            $codBat = -1
        } else {
            $codBat = $pb.ExitCode
            $saidaBat = (Read-WMSaidaFilho $batOut) + "`n" +
                        (Read-WMSaidaFilho ($batOut + '.err'))
        }
        Remove-Item -LiteralPath $batOut, ($batOut + '.err') -Force -ErrorAction SilentlyContinue

        <#
            O FILTRO DO -Quiet NÃO PODE ESCONDER EVIDÊNCIA DE FALHA.

            Ele existe para o caminho feliz: com tudo morto, cem linhas de
            'morto BL-xx' não acrescentam nada. Mas quando a bateria foi MORTA
            por prazo, as linhas que ela alcançou a imprimir são exatamente o
            que o operador precisa — e o filtro as descartava, deixando só o
            aviso de prazo.

            Medido: 101 mutantes, 90 minutos de trabalho, e a saída visível era
            uma linha dizendo que estourou.
        #>
        if ($Quiet -and $codBat -ne -1) {
            ($saidaBat -split "`n" | Where-Object { $_ -match 'MUTANTES|indefesa|VIVO|INCONCLUSIVO|prazo' }) -join "`n"
        } else { $saidaBat }

        if ($codBat -ne 0) {
            [void]$falhas.Add("bateria de mutação: há trava indefesa ou inconclusiva (código $codBat)")
        }

        <#
            RESUMO OBRIGATÓRIO, e CONFERIDO — as duas doutrinas que faltavam.
            Bateria que não declara quantos mutantes rodou não provou nada, e
            zero mutante é o caso em que "todos morreram" é vacuamente verdade.
        #>
        <#
            RESUMO ÚNICO e PISO — as duas doutrinas que faltavam, e eu tinha
            escrito que a bateria era julgada por todas as seis. Medido: quatro.

              - [regex]::Match pegava o PRIMEIRO resumo: uma bateria imprimindo
                'TODOS OS 1' e depois 'TODOS OS 99' saía com zero.
              - o piso era UM. Perder 36 dos 37 mutantes de uma lista mantida à
                mão ficava verde — e "defesa que só existe quando alguém lembra"
                é justamente o que a bateria existe para impedir.
        #>
        $mbs = @([regex]::Matches($saidaBat, 'TODOS OS (\d+) MUTANTES MORRERAM'))
        if ($mbs.Count -gt 1) {
            [void]$falhas.Add("bateria de mutação: imprimiu $($mbs.Count) resumos — não dá para saber qual é o verdadeiro")
        } elseif ($mbs.Count -eq 0) {
            if ($codBat -eq 0) {
                [void]$falhas.Add('bateria de mutação: saiu com zero mas não declarou quantos mutantes morreram')
            }
        } else {
            $qtd = [int]$mbs[0].Groups[1].Value
            $mortos = @([regex]::Matches($saidaBat, '(?m)^\s+morto\s')).Count
            <#
                ZERO é uma falha DIFERENTE de "a lista encolheu", e por isso tem
                mensagem própria: com zero mutantes, "todos morreram" é vacuamente
                verdadeiro — a bateria não provou nada, nem pouco.
            #>
            if ($qtd -lt 1) {
                [void]$falhas.Add('bateria de mutação: declarou ZERO mutantes — "todos morreram" é vacuamente verdadeiro e não prova nada')
            } elseif ($qtd -lt $MutantesMin) {
                [void]$falhas.Add("bateria de mutação: declarou $qtd mutante(s), o piso é $MutantesMin — a lista encolheu")
            }
            if ($mortos -ne $qtd) {
                [void]$falhas.Add("bateria de mutação: diz $qtd mortos e imprimiu $mortos linha(s) de mutante — o resumo não bate com o que rodou")
            }
        }
    }
}

""
"total de testes que passaram: $totalOk   (soma dos pisos: $totalEsperado)"
if ($falhas.Count -eq 0) {
    "TODAS AS SUITES PASSARAM"
    exit 0
} else {
    foreach ($f in $falhas) { "  x $f" }
    "$($falhas.Count) problema(s) no portão"
    exit 1
}
