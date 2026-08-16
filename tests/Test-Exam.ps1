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

Import-Module (Join-Path $root 'src\WinMonitor.psm1')        -Force
Import-Module (Join-Path $root 'src\WinMonitor.Rollup.psm1') -Force
Import-Module (Join-Path $root 'src\WinMonitor.Rules.psm1')  -Force

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
    Start-TestGroup 'Saúde de disco: o degrau que não exige privilégio  [MUTAÇÃO]'

    <#
        Eu tinha declarado saúde de disco bloqueada por elevação. A conclusão
        estava um passo além da medição — de novo. Item por item, sem elevação:

            Get-PhysicalDisk -> HealthStatus            OK
            Get-StorageReliabilityCounter               NEGADO
            MSStorageDriver_FailurePredictStatus        NEGADO

        O que exige administrador é a CONTAGEM de setores realocados. O
        VEREDITO de saúde, que o Windows deriva do SMART, é legível por
        qualquer conta.
    #>
    $sondaDisco = Join-Path $root 'src\probes\Probe-DiskHealth.ps1'
    $rd = & $sondaDisco

    <#
        ESTAS ASSERÇÕES DEPENDEM DA MÁQUINA, e isso está dito em vez de negado:
        elas exigem pelo menos um disco físico visível para a conta que roda a
        suíte. Numa VM sem disco enumerável, ou num contêiner, elas falham por
        motivo AMBIENTAL e não por defeito do código.

        Não são o teste da lógica — a lógica é medida logo abaixo, com discos
        injetados por -Discos, inclusive o caso de ZERO disco, que é justamente
        o que estas aqui não conseguem alcançar nesta máquina. O que elas
        acrescentam é a ponta que injeção nenhuma cobre: que a chamada real ao
        Windows funciona SEM elevação — a afirmação que estava em disputa.
    #>
    Assert-True $rd.ok 'a sonda de saúde de disco roda sem elevação'
    Assert-True ($rd.data.readable -eq $true) 'e declara que conseguiu ler'
    Assert-True (@($rd.data.disks).Count -ge 1) 'com pelo menos um disco'
    Assert-True ($rd.data.unhealthy -is [int]) 'e a contagem de doentes é um número'

    foreach ($d in @($rd.data.disks)) {
        Assert-True (-not [string]::IsNullOrWhiteSpace($d.health)) "o disco $($d.id) traz veredito de saúde"
        Assert-True (-not [string]::IsNullOrWhiteSpace($d.name))   'e o nome, para o laudo poder citá-lo'
    }

    <#
        A TRAVA QUE IMPORTA: só 'Healthy' conta como saudável.

        Qualquer outro valor — Warning, Unhealthy, ou um que a Microsoft
        acrescente amanhã — é contado como doente. Errar para o lado de
        perguntar é barato; errar para o lado de calar é o que este projeto não
        faz. E é ela que a regra R-DISK-HEALTH-DEGRADED consome.
    #>
    $contados = @($rd.data.disks | Where-Object { $_.health -ne 'Healthy' }).Count
    Assert-Equal $contados $rd.data.unhealthy 'a contagem de doentes bate com os discos que não estão Healthy'

    <#
        OS RAMOS QUE A MÁQUINA REAL NÃO ALCANÇA.

        Os três discos daqui estão Healthy, então o caminho de disco doente e o
        de leitura negada nunca executam — e as duas mutações sobreviviam:
        com todos Healthy, '-eq Healthy' e '-ne Unhealthy' dão o mesmo
        resultado. O teste media o caminho feliz e declarava a trava defendida.

        'Warning' é o degrau que o Windows usa para avisar ANTES de desistir do
        disco. Aceitá-lo como saudável é perder exatamente o aviso.
    #>
    $sinteticos = @(
        [pscustomobject]@{ DeviceId='0'; FriendlyName='Disco Sao';      MediaType='SSD'; HealthStatus='Healthy';   OperationalStatus='OK' }
        [pscustomobject]@{ DeviceId='1'; FriendlyName='Disco Avisando'; MediaType='HDD'; HealthStatus='Warning';   OperationalStatus='Degraded' }
        [pscustomobject]@{ DeviceId='2'; FriendlyName='Disco Morrendo'; MediaType='HDD'; HealthStatus='Unhealthy'; OperationalStatus='Lost Communication' }
    )
    $rs = & $sondaDisco -Discos $sinteticos
    Assert-Equal 2 $rs.data.unhealthy 'Warning E Unhealthy contam como doentes — não só Unhealthy'
    Assert-True ($rs.data.readable -eq $true) 'e a leitura continua declarada como bem-sucedida'

    # Valor que a Microsoft acrescente amanhã também conta como doente.
    $futuro = @([pscustomobject]@{ DeviceId='9'; FriendlyName='X'; MediaType='SSD'; HealthStatus='ValorNovoQueAindaNaoExiste'; OperationalStatus='?' })
    Assert-Equal 1 (& $sondaDisco -Discos $futuro).data.unhealthy 'valor desconhecido conta como doente: errar para o lado de perguntar'

    <#
        E o caminho de leitura negada: NULO, nunca lista vazia. Lista vazia
        seria lida pela regra como "nenhum disco doente" — a ausência virando
        boa notícia, que é o modo de falha que este projeto existe para não ter.
    #>
    $rf = & $sondaDisco -Falhar
    Assert-True ($rf.ok) 'a sonda não explode quando a leitura falha'
    Assert-True ($rf.data.readable -eq $false) 'ela declara que não conseguiu ler'
    Assert-True ($null -eq $rf.data.disks) 'e a lista é NULA, não vazia'
    Assert-True ($null -eq $rf.data.unhealthy) 'e a contagem é NULA, não zero'
    Assert-True (-not [string]::IsNullOrWhiteSpace($rf.reason)) 'com o motivo registrado'

    <#
        E O RAMO IRMÃO: Get-PhysicalDisk respondendo SEM NENHUM disco.

        Ele tem justificativa própria escrita no arquivo e não tinha teste — o
        mutante que o desligava sobrevivia. Com ele desligado, lista vazia vira
        'readable=true, unhealthy=0' e a regra AFIRMA máquina sã sobre um
        subsistema que não respondeu. Alcançável de verdade: VM ou contêiner com
        a pilha de armazenamento vazia, ou indisponibilidade transitória.
    #>
    $rz = & $sondaDisco -Discos @()
    Assert-True ($rz.data.readable -eq $false) 'zero discos NÃO é leitura bem-sucedida'
    Assert-True ($null -eq $rz.data.unhealthy) 'e a contagem é NULA, não zero: ausência não vira boa notícia'
    Assert-True ($rz.reason -match 'nenhum disco') 'com o motivo dizendo exatamente isso'

    # Caixa: 'healthy' minúsculo não pode contar como saudável.
    $rmin = & $sondaDisco -Discos @([pscustomobject]@{ DeviceId='9'; FriendlyName='X'; MediaType='SSD'; HealthStatus='healthy'; OperationalStatus='OK' })
    Assert-Equal 1 $rmin.data.unhealthy "'healthy' em minúsculas conta como doente: a comparação é sensível a caixa"

    <#
        A CADEIA DA REGRA, do config até o veredito — e ela não tinha defensor
        nenhum. Três mutações independentes a desligavam com a suíte INTEIRA
        verde: trocar a métrica na tabela, descartar a chave 'dsk' no enxerto do
        exame, e tirar a sonda de exam.probes.

        A manchete era sobre a REGRA e a defesa toda estava na SONDA.
    #>
    $cfgReal = Get-Content (Join-Path $root 'config\config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $sondasCfg = @($cfgReal.exam.probes | ForEach-Object { "$($_.name):$($_.key)" })
    Assert-True ($sondasCfg -contains 'DiskHealth:dsk') 'a sonda de disco está no exame, com a chave que a regra consome'

    $limiares = Get-Content (Join-Path $root 'config\thresholds.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $rdisk = @($limiares.rules | Where-Object { $_.id -eq 'R-DISK-HEALTH-DEGRADED' })
    Assert-Equal 1 $rdisk.Count 'a regra existe na tabela'
    Assert-Equal 'dsk.unhealthy' $rdisk[0].metric 'e aponta para a métrica que a sonda produz'

    # E a ponta: a regra tem de ser EFETIVAMENTE avaliada contra o exame real.
    $exReg = & (Join-Path $root 'src\Invoke-Exam.ps1') -PassThru -NoWrite
    $raizRegra = [pscustomobject]@{ v = 1; day = '2026-08-16'; host = 'T' }
    Add-Member -InputObject $raizRegra -NotePropertyName 'dsk' -NotePropertyValue $exReg.dsk -Force
    $res = Invoke-WMRules -Rollup $raizRegra -Rules $limiares
    Assert-True (@($res.coverage.evaluated) -contains 'R-DISK-HEALTH-DEGRADED') 'e é AVALIADA contra o dado real da sonda, não fica em lacuna'

    # E a granularidade que continua faltando permanece DECLARADA, não sumida.
    $exDisco = & (Join-Path $root 'src\Invoke-Exam.ps1') -PassThru -NoWrite
    $cobDisco = if ($exDisco.coverage -is [System.Collections.IDictionary]) { @($exDisco.coverage.Keys) }
                else { @($exDisco.coverage.PSObject.Properties.Name) }
    Assert-True ($cobDisco -contains 'smartDetalhado') 'cobrir o degrau de baixo NÃO cala o de cima: a contagem SMART fina segue declarada como lacuna'
    Assert-True ($null -ne $exDisco.dsk) 'e o exame traz o bloco de saúde de disco'

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
    Assert-True ($chaves -contains 'smartDetalhado') 'a contagem SMART fina consta como lacuna declarada'
    Assert-True ($chaves -contains 'cpuTemp') 'temperatura de CPU também'
    <#
        A LACUNA MUDOU DE MOTIVO, E A ASSERÇÃO TINHA DE MUDAR JUNTO.

        Ela cobrava a palavra 'eleva' — e estava certa enquanto o que faltava
        era elevação. Depois que a ronda passou a rodar com RunLevel
        HighestAvailable e a sonda SmartDetail entrou, elevação deixou de ser o
        que falta: o que falta é a tabela de decodificação por fabricante dos
        512 bytes crus, que não existe publicada para citar.

        Uma asserção que continuasse cobrando 'eleva' obrigaria o texto a mentir
        para ficar verde. Ela agora cobra o motivo VERDADEIRO, e proíbe o antigo:
        culpar elevação depois que ela existe seria lacuna declarada com razão
        obsoleta, que é pior que lacuna sem razão — parece medida e não é.
    #>
    $razaoSmart = if ($ex.coverage -is [System.Collections.IDictionary]) { [string]$ex.coverage['smartDetalhado'] } else { [string]$ex.coverage.smartDetalhado }
    Assert-True ($razaoSmart -match 'SETORES REALOCADOS') 'e ela nomeia o que de fato ainda falta: contagem por setor realocado'
    Assert-True (-not ($razaoSmart -match 'exigem elevacao')) 'e NÃO culpa mais a elevação, que deixou de ser o obstáculo'

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

    # =====================================================================
    Start-TestGroup 'SMART fino: ausência POR CAMPO, e cobertura parcial declarada  [MUTAÇÃO]'

    <#
        A SONDA NASCE DO QUE A MÁQUINA REAL ENTREGOU, não do que a documentação
        promete. Medido nesta máquina, com a ronda já rodando elevada:

            disco 0: temp=38  horas=13006  erros=0     desgaste=0
            disco 2: temp=35  horas=4053   erros=0     desgaste=0
            disco 1: temp=50  horas=VAZIO  erros=VAZIO desgaste=0

        O disco 1 responde temperatura e não responde horas nem erros — e é o
        mais quente dos três. Se a sonda somasse campos, aquele vazio viraria
        zero, e "zero erro de leitura" é a leitura mais tranquilizadora possível
        para um disco que NÃO INFORMOU erro de leitura.

        Os sintéticos abaixo reproduzem exatamente essa máquina.
    #>
    $sondaSmart = Join-Path $root 'src\probes\Probe-SmartDetail.ps1'
    Assert-True (Test-Path $sondaSmart) 'a sonda de SMART fino existe'

    $discosS = @(
        [pscustomobject]@{ DeviceId = '0'; FriendlyName = 'NVMe do sistema' }
        [pscustomobject]@{ DeviceId = '1'; FriendlyName = 'NVMe calado' }
        [pscustomobject]@{ DeviceId = '2'; FriendlyName = 'SSD de dados' }
    )
    $contadoresS = @(
        [pscustomobject]@{ DeviceId = '0'; Temperature = 38; PowerOnHours = 13006; ReadErrorsTotal = 0;  Wear = 0 }
        [pscustomobject]@{ DeviceId = '1'; Temperature = 50; PowerOnHours = '';    ReadErrorsTotal = ''; Wear = 0 }
        [pscustomobject]@{ DeviceId = '2'; Temperature = 35; PowerOnHours = 4053;  ReadErrorsTotal = 0;  Wear = 0 }
    )
    $previsaoS = @([pscustomobject]@{ InstanceName = 'disco0'; PredictFailure = $false })

    $rs = & $sondaSmart -Discos $discosS -Contadores $contadoresS -Previsao $previsaoS
    Assert-True $rs.data.readable 'com contadores respondendo, a leitura é declarada bem-sucedida'
    $ds = @($rs.data.disks)
    Assert-Equal 3 $ds.Count 'os três discos entram'

    Assert-Equal 50 $ds[1].temperatureC 'o disco calado informa temperatura'
    Assert-Null $ds[1].powerOnHours 'e horas ligado fica NULO, não zero'
    Assert-Null $ds[1].readErrorsTotal 'e erros de leitura também: ausência não é boa notícia'
    Assert-True (@($ds[1].unanswered) -contains 'powerOnHours') 'e o campo sem resposta é DECLARADO'
    Assert-True (@($ds[1].unanswered) -contains 'readErrorsTotal') 'os dois, nominalmente'
    Assert-Equal 0 (@($ds[0].unanswered)).Count 'o disco que responde tudo não declara ausência nenhuma'

    Assert-Equal 50 $rs.data.hottestC 'o mais quente é o disco que menos informa sobre si'
    Assert-Equal 0 $rs.data.readErrorsMax 'e o maior erro de leitura vem só dos discos que responderam'

    <#
        COBERTURA PARCIAL DECLARADA. A classe de previsão respondeu por UM dos
        três discos. "Nenhum disco prevê falha" seria verdade sobre o coberto e
        silêncio sobre os outros dois — cobertura parcial com cara de cobertura
        total é o defeito que este projeto existe para não ter.
    #>
    Assert-Equal 1 $rs.data.predictCovered 'a previsão de falha cobre um disco'
    Assert-Equal 3 $rs.data.predictTotal 'de três que existem'
    Assert-Equal 0 $rs.data.predictFailing 'e nenhum dos cobertos prevê falha'
    Assert-True ($rs.reason -match 'cobre 1 de 3') 'e a razão DIZ que a cobertura é parcial'

    <#
        O CASAMENTO É POR DeviceId, NÃO POR POSIÇÃO. Se um disco não devolve
        contador, casar por posição faz todos os seguintes deslizarem e cada
        número passa a descrever o disco errado — o pior desfecho possível,
        porque tudo continua parecendo medido.
    #>
    $foraDeOrdem = @(
        [pscustomobject]@{ DeviceId = '2'; Temperature = 35; PowerOnHours = 4053;  ReadErrorsTotal = 7; Wear = 0 }
        [pscustomobject]@{ DeviceId = '0'; Temperature = 38; PowerOnHours = 13006; ReadErrorsTotal = 0; Wear = 0 }
    )
    $rf = & $sondaSmart -Discos $discosS -Contadores $foraDeOrdem -Previsao $previsaoS
    $df = @($rf.data.disks)
    Assert-Equal 13006 $df[0].powerOnHours 'contador fora de ordem chega no disco certo'
    Assert-Equal 7 $df[2].readErrorsTotal 'e o do disco 2 também, com o valor dele'
    Assert-Null $df[1].temperatureC 'o disco SEM contador fica nulo em vez de herdar o do vizinho'
    Assert-Equal 4 (@($df[1].unanswered)).Count 'com os quatro campos declarados sem resposta'
    Assert-Equal 7 $rf.data.readErrorsMax 'e o maior erro de leitura é o que de fato foi lido'

    <#
        SEM ELEVAÇÃO, NADA DE ZEROS. É o caminho que esta máquina percorre em
        sessão comum, e o desfecho tem de ser "não consegui ler" — nunca uma
        lista de contadores zerados, que a regra leria como disco impecável.
    #>
    $rn = & $sondaSmart -Falhar
    Assert-True $rn.ok 'a sonda não explode quando a leitura falha'
    Assert-True (-not $rn.data.readable) 'ela declara que não conseguiu ler'
    Assert-Null $rn.data.disks 'a lista é NULA, não vazia'
    Assert-Null $rn.data.hottestC 'não há disco mais quente quando não se leu disco nenhum'
    Assert-Null $rn.data.readErrorsMax 'nem maior erro de leitura'
    Assert-Null $rn.data.predictCovered 'nem cobertura de previsão'

    # Zero disco não é zero contador: é ausência de objeto a medir.
    $rz = & $sondaSmart -Discos @() -Contadores @() -Previsao @()
    Assert-True (-not $rz.data.readable) 'zero disco NÃO é leitura bem-sucedida'
    Assert-Null $rz.data.hottestC 'e não produz temperatura nenhuma'

    # A lacuna que CONTINUA aberta, e continua declarada.
    $cfgSmt = Get-Content (Join-Path $root 'config\config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $lacunasSmt = @($cfgSmt.exam.missing | ForEach-Object { $_.key })
    Assert-True ($lacunasSmt -contains 'smartDetalhado') 'cobrir o degrau de baixo NÃO fecha a lacuna do setor realocado'
    $razaoSmt = ($cfgSmt.exam.missing | Where-Object { $_.key -eq 'smartDetalhado' }).reason
    Assert-True ($razaoSmt -match 'SETORES REALOCADOS') 'e a lacuna agora nomeia exatamente o que ainda falta'
    Assert-True ($razaoSmt -match 'inventar numero') 'dizendo por que decodificar sem fonte não é opção'

    # E a sonda está registrada no exame, com a chave que as regras consomem.
    $sondasCfg = @($cfgSmt.exam.probes | ForEach-Object { "$($_.name):$($_.key)" })
    Assert-True ($sondasCfg -contains 'SmartDetail:smt') 'a sonda de SMART fino está no exame'

} finally { }

Show-TestSummary
exit (Get-TestExitCode)
