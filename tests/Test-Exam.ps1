#requires -Version 5.1
<#
    Testes do exame: a sonda de eventos e o driver.

    A pergunta central desta suíte é uma só, e é a mesma que decide se o projeto
    inteiro vale alguma coisa: **quando a sonda não consegue olhar, ela diz que
    não conseguiu, ou diz que está tudo bem?**

    Get-WinEvent torna isso difícil de propósito, sem querer: devolve o mesmo
    erro (NoMatchingEventsFound) para "não há evento" e para "não pude ler o
    log". Um try/catch ingênuo transforma privilégio insuficiente em atestado de
    saúde de hardware.

    O teste usa o log 'Security', que numa sessão sem elevação é ilegível DE
    VERDADE nesta máquina. Não é dublê: é a condição real, e por isso o teste
    prova alguma coisa.

      .\tests\Test-Exam.ps1
#>
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TestKit.ps1')

Import-Module (Join-Path $root 'src\WinMonitor.psm1') -Force

$sonda = Join-Path $root 'src\probes\Probe-Events.ps1'

function Test-Elevada {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

try {

    # =====================================================================
    Start-TestGroup 'Sonda de eventos: o log legível'

    $r = & $sonda -WindowDays 30
    Assert-True $r.ok 'a sonda roda contra o log System'
    Assert-True ($r.data.logReadable -eq $true) 'e declara o log como legível'
    Assert-True ($r.data.wheaErrors -is [int]) 'com o log legível, a contagem WHEA é um número'
    Assert-True ($r.data.cleanShutdowns -is [int]) 'e a de desligamentos limpos também'
    Assert-True ($null -ne $r.data.since) 'a janela examinada é declarada'
    Assert-True ($r.data.since -match '^\d{4}-\d{2}-\d{2}T') 'em formato invariante'

    <#
        A JANELA IMPORTA. Uma contagem sem período é um número sem significado:
        "um desligamento inesperado" em 30 dias e em 3 anos são diagnósticos
        diferentes. Se a janela encolhe, a contagem não pode crescer.
    #>
    $curto = & $sonda -WindowDays 1
    $longo = & $sonda -WindowDays 365
    Assert-True ($curto.data.cleanShutdowns -le $longo.data.cleanShutdowns) 'janela menor nunca conta mais que a maior'

    <#
        A JANELA DECLARADA TEM DE SER A JANELA CONSULTADA. Antes, -Since e
        -WindowDays podiam discordar e o arquivo gravava o segundo enquanto a
        consulta usava o primeiro: 365 dias declarados sobre dois dias de dado.
    #>
    $comSince = & $sonda -WindowDays 365 -Since ((Get-Date).AddDays(-2))
    Assert-True ($comSince.data.windowDays -le 3) 'com -Since, windowDays reflete a janela REAL, não o parâmetro ignorado'
    Assert-True ($comSince.data.cleanShutdowns -le $longo.data.cleanShutdowns) 'e a contagem é a dos dois dias'

    <#
        SATURAÇÃO DECLARADA, NOS QUATRO CONTADORES.

        Com o teto atingido, a contagem vale exatamente o teto — e gravar isso
        como número afirma "foram 200" quando o certo é "foram pelo menos 200".
        A declaração estava escrita DENTRO da função compartilhada mas só era
        usada por dois dos quatro chamadores: o comentário cobria tudo, o efeito
        cobria metade. E o contador que ficava de fora era justamente o
        denominador que dá sentido ao numerador.
    #>
    $satur = & $sonda -WindowDays 365 -MaxEvents 1

    <#
        OS QUATRO CONTADORES, um a um.

        A versão anterior deste grupo se chamava "nos QUATRO contadores" e
        assertava sobre UM. Medido pela verificação: três dos quatro mutantes
        sobreviviam — a declaração existia no código e não no teste, que é a
        forma mais cara de trava porque parece pronta.

        Cada contador precisa da sua asserção, e cada uma declara a condição de
        que depende: só há saturação se houver evento daquele tipo na máquina.
    #>
    foreach ($par in @(
        @{ campo = 'cleanTruncated';         conta = 'cleanShutdowns';      nome = 'desligamento limpo' }
        @{ campo = 'unexpectedTruncated';    conta = 'unexpectedShutdowns'; nome = 'desligamento inesperado' }
        @{ campo = 'kernelPower41Truncated'; conta = 'kernelPower41';       nome = 'Kernel-Power 41' }
    )) {
        $temEvento = ([int]$satur.data.($par.conta) -ge 1)
        if ($temEvento) {
            Assert-True ($satur.data.($par.campo) -eq $true) "saturação de $($par.nome) é declarada"
        } else {
            Add-TestResult -Ok $true -Name "$($par.nome): esta máquina não tem evento do tipo, condição declarada" -Detail ''
        }
    }
    Assert-True ($satur.reason -match 'PELO MENOS') 'e a razão diz que é um piso, não uma contagem exata'

    <#
        WHEA é o quarto, e nesta máquina ele é ZERO — não dá para saturá-lo com
        dado real. O teste declara isso em vez de fingir que verificou: um
        'ok' silencioso aqui seria a mesma ausência-virando-zero que a sonda
        inteira existe para impedir.
    #>
    if ([int]$satur.data.wheaErrors -ge 1) {
        Assert-True ($satur.data.wheaTruncated -eq $true) 'saturação de WHEA é declarada'
    } else {
        Add-TestResult -Ok $true -Name 'WHEA: zero erros nesta máquina, saturação NÃO verificável aqui — declarado' -Detail ''
    }

    $semSat = & $sonda -WindowDays 365
    Assert-True ($null -eq $semSat.data.cleanTruncated) 'sem saturar, nenhuma ressalva é inventada'
    Assert-True ($null -eq $semSat.data.unexpectedTruncated) 'nem para desligamento inesperado'

    # =====================================================================
    Start-TestGroup 'Sonda de eventos: o log ILEGÍVEL  [o teste que importa]'

    if (Test-Elevada) {
        Add-TestResult -Ok $true -Name 'sessão elevada: o log Security é legível, teste não aplicável' -Detail ''
    } else {
        $s = & $sonda -LogName 'Security' -WindowDays 30

        Assert-True $s.ok 'a sonda NÃO explode com log inacessível'
        Assert-True ($s.data.logReadable -eq $false) 'ela declara o log como ilegível'

        <#
            O CORAÇÃO DE TUDO. Zero seria uma afirmação: "não houve erro de
            hardware". Nulo é a verdade: "não sei se houve". As duas coisas
            entram na regra de formas completamente diferentes — zero satisfaz
            'wheaErrors gt 0' como falso e vira laudo de máquina sã.
        #>
        Assert-True ($null -eq $s.data.wheaErrors) 'wheaErrors é NULO, não zero'
        Assert-True ($null -eq $s.data.unexpectedShutdowns) 'unexpectedShutdowns é NULO, não zero'
        Assert-True ($null -eq $s.data.cleanShutdowns) 'cleanShutdowns é NULO, não zero'
        Assert-True (-not [string]::IsNullOrWhiteSpace($s.reason)) 'e o motivo fica registrado'
        Assert-True ($s.reason -match 'privil|Security') 'dizendo qual log e por quê'

        <#
            MUTAÇÃO: trocar os nulos por 0 nesta sonda faz o bloco acima ficar
            vermelho e NADA MAIS no projeto reclamar — a regra passaria, o
            veredito sairia 'normal', o laudo diria que não há erro de hardware,
            e as quatro conferências do laudo aprovariam, porque o zero veio
            mesmo do pacote. Esta é a única linha de defesa contra esse caminho.
        #>
        Assert-True ($s.data.wheaErrors -isnot [int]) 'e não é um inteiro disfarçado de ausência'
    }

    # =====================================================================
    Start-TestGroup 'Sonda de eventos: o log DESABILITADO  [MUTAÇÃO]'

    <#
        A verificação adversarial mediu que este caminho não tinha teste nenhum:
        revertendo a recusa de log desabilitado, OU restaurando o atalho antigo
        de RecordCount igual a zero, a suíte continuava verde. O código estava
        certo e a trava tinha nascido morta.

        Log desabilitado devolve RecordCount NULO, e [int]$null é 0 em
        PowerShell — era assim que os 84 logs desabilitados desta máquina
        passavam por "legível e vazio", fazendo a sonda afirmar zero
        desligamento inesperado a partir de um log que ela nunca abriu.

        O teste usa um log desabilitado DE VERDADE, escolhido em tempo de
        execução. Se a máquina não tiver nenhum, ele diz isso em vez de fingir
        que verificou.
    #>
    <#
        try/catch e não só -ErrorAction: com $ErrorActionPreference = 'Stop',
        um único log que recuse metadados derruba a suíte inteira, e enumerar
        mil logos garante que algum recuse. O erro aqui é esperado e irrelevante
        — o que importa é achar UM desabilitado.
    #>
    <#
        SEM 'Select-Object -First' aqui. Ele para o pipeline lançando uma
        exceção interna de parada que NÃO é pega por um catch comum: ela sobe,
        executa o finally da suíte e o script termina sem imprimir o resumo —
        e o portão então acusa "não chegou ao fim", que é o diagnóstico certo
        para o sintoma errado. Custou uma rodada de depuração descobrir isso.
    #>
    $desabilitado = @()
    try {
        $todos = @(Get-WinEvent -ListLog * -ErrorAction SilentlyContinue)
        $desabilitado = @($todos | Where-Object { -not $_.IsEnabled })
    } catch { }

    if ($desabilitado.Count -eq 0) {
        Add-TestResult -Ok $false -Name 'nenhum log desabilitado nesta máquina: o caminho ficou SEM verificação' -Detail 'declarado, não escondido'
    } else {
        $nome = $desabilitado[0].LogName
        $dd = & $sonda -LogName $nome -WindowDays 30

        Assert-True $dd.ok "a sonda não explode com log desabilitado ($nome)"
        Assert-True ($dd.data.logReadable -eq $false) 'log desabilitado NÃO é declarado legível'
        Assert-True ($null -eq $dd.data.wheaErrors) 'e wheaErrors é NULO, não zero'
        Assert-True ($null -eq $dd.data.unexpectedShutdowns) 'unexpectedShutdowns idem'
        Assert-True ($dd.reason -match 'DESABILITADO') 'e a razão diz que o log está desabilitado'
    }

    # =====================================================================
    Start-TestGroup 'Invoke-Exam: sonda ausente vira lacuna, nunca silêncio'

    $ex = & (Join-Path $root 'src\Invoke-Exam.ps1') -PassThru -NoWrite

    Assert-True ($null -ne $ex) 'o exame roda'
    Assert-True ($null -ne $ex.evt) 'e traz o bloco de eventos'
    Assert-True ($ex.complete -eq $false) 'e se declara INCOMPLETO enquanto faltar sonda'

    <#
        -PassThru devolve o objeto ANTES de passar por JSON, e aí coverage ainda
        é um dicionário ordenado, não um PSCustomObject: PSObject.Properties não
        enxerga chave nenhuma. Depois de gravado e relido, é o contrário. O teste
        precisa ler os dois, senão passa a verificar o tipo em vez do conteúdo.
    #>
    $chaves = if ($ex.coverage -is [System.Collections.IDictionary]) { @($ex.coverage.Keys) }
              else { @($ex.coverage.PSObject.Properties.Name) }
    Assert-True ($chaves -contains 'smart')   'SMART consta como lacuna declarada'
    Assert-True ($chaves -contains 'cpuTemp') 'temperatura de CPU também'
    Assert-True (($ex.coverage['smart'] -match 'eleva') -or ($ex.coverage.smart -match 'eleva')) 'e a lacuna do SMART diz que falta elevação'

    <#
        O exame nunca inventa o bloco de uma sonda que FALHOU. Um {} vazio seria
        lido por qualquer regra seguinte como "rodou e não achou nada".

        A asserção anterior aqui era VAZIA: conferia $ex.smart, e 'smart' está em
        exam.missing, não em exam.probes — a chave nunca chega a ser escrita, e
        o teste passava com qualquer implementação. Medido pelo verificador:
        trocar as três atribuições $null por @{} em Invoke-Exam não deixava a
        suíte vermelha.

        Agora o teste planta uma sonda que falha DE VERDADE e confere o que sai.
    #>
    <#
        CÓPIA DO PROJETO, não o projeto.

        A versão anterior reescrevia config\config.json DE PRODUÇÃO e restaurava
        no finally. Funcionava — até o portão ganhar prazo e passar a MATAR a
        suíte que estoura o tempo: TerminateProcess não roda finally, e a
        configuração real ficaria apontando para uma sonda que não existe.

        A trava nova de um lugar abriu a janela em outro. Copiar o projeto custa
        centésimos de segundo e fecha a categoria inteira.
    #>
    $proj = Join-Path ([System.IO.Path]::GetTempPath()) ('wm-exam-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root 'src')    -Destination $proj -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $root 'config') -Destination $proj -Recurse -Force

        [System.IO.File]::WriteAllText((Join-Path $proj 'src\probes\Probe-TesteQueFalha.ps1'),
            "param(`$Facts, `$TimeoutSec, `$WindowDays)`r`n@{ ok = `$false; reason = 'falha proposital' }`r`n",
            (New-Object System.Text.UTF8Encoding($true)))

        $cfgP = Join-Path $proj 'config\config.json'
        $c = (Get-Content $cfgP -Raw -Encoding UTF8) | ConvertFrom-Json
        $c.exam.probes = @([pscustomobject]@{ name = 'TesteQueFalha'; key = 'ruim' })
        [System.IO.File]::WriteAllText($cfgP, (ConvertTo-Json -InputObject $c -Depth 14), (New-Object System.Text.UTF8Encoding($false)))

        $ex2 = & (Join-Path $proj 'src\Invoke-Exam.ps1') -PassThru -NoWrite

        Assert-True ($null -eq $ex2.ruim) 'sonda que falhou deixa NULO, não objeto vazio'
        Assert-True ((@($ex2.PSObject.Properties.Name) -contains 'ruim')) 'mas a chave existe, para a ausência ser visível'
        $motivo = if ($ex2.coverage -is [System.Collections.IDictionary]) { $ex2.coverage['ruim'] } else { $ex2.coverage.ruim }
        Assert-True ($motivo -match 'falha proposital') 'e o motivo da falha fica na cobertura'
        Assert-True ($ex2.complete -eq $false) 'e o exame se declara incompleto'

        # E a prova de que o teste não encostou no projeto de verdade.
        Assert-True (-not (Test-Path (Join-Path $root 'src\probes\Probe-TesteQueFalha.ps1'))) 'a sonda de teste nunca entrou no projeto real'

        <#
            CONFIG DEGRADADO NÃO PODE MATAR O EXAME.

            Os dois recuos deste driver eram CÓDIGO MORTO: '@($cfg.exam.probes)
            .Count -eq 0' nunca é verdade quando o bloco falta, porque
            @($null).Count é UM. Medido: com exam.probes ausente o driver MORRIA
            montando a amostra com chave vazia — "o valor do argumento name não
            é válido". E exam.missing ausente produzia lacuna de chave vazia e
            motivo vazio: buraco anônimo, que parece declaração e não é.

            Monitor que morre é pior que monitor que registra um buraco: quem
            morre não deixa nem o registro de que tentou.
        #>
        $degradados = @(
            @{ nome = 'sem exam.probes';  acao = { param($c) $c.exam.PSObject.Properties.Remove('probes') } }
            @{ nome = 'sem exam.missing'; acao = { param($c) $c.exam.PSObject.Properties.Remove('missing') } }
            @{ nome = 'sem bloco exam';   acao = { param($c) $c.PSObject.Properties.Remove('exam') } }
            @{ nome = 'probe sem key';    acao = { param($c) $c.exam.probes = @([pscustomobject]@{ name = 'Events' }) } }
        )
        <#
            Cada caso parte do config ÍNTEGRO. Reler o arquivo já degradado fazia
            as degradações se acumularem, e o segundo caso morria tentando mexer
            num bloco que o primeiro havia removido — a suíte terminava sem
            resumo e o portão acusava "não chegou ao fim".
        #>
        $cfgIntegro = Get-Content $cfgP -Raw -Encoding UTF8

        foreach ($caso in $degradados) {
            $c2 = $cfgIntegro | ConvertFrom-Json
            & $caso.acao $c2
            [System.IO.File]::WriteAllText($cfgP, (ConvertTo-Json -InputObject $c2 -Depth 14), (New-Object System.Text.UTF8Encoding($false)))

            $ex3 = $null
            try { $ex3 = & (Join-Path $proj 'src\Invoke-Exam.ps1') -PassThru -NoWrite } catch { }
            Assert-True ($null -ne $ex3) "config degradado ($($caso.nome)) NÃO mata o exame"

            if ($null -ne $ex3) {
                $cob = if ($ex3.coverage -is [System.Collections.IDictionary]) { @($ex3.coverage.Keys) }
                       else { @($ex3.coverage.PSObject.Properties.Name) }
                Assert-True (@($cob | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) "($($caso.nome)) nenhuma lacuna de nome vazio"
                Assert-True ($ex3.complete -eq $false) "($($caso.nome)) e o exame se declara INCOMPLETO"
            }
        }
    } finally {
        Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue
    }

} finally { }

Show-TestSummary
exit (Get-TestExitCode)
