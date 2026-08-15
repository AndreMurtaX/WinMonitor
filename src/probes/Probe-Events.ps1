#requires -Version 5.1
<#
    Sonda de eventos do Windows: erro de hardware (WHEA) e desligamento
    inesperado.

    É sonda de EXAME, não de ronda. Consultar o log de eventos custa muito mais
    que ler um contador CIM, e o dado muda em escala de dias — pagar isso a cada
    minuto seria o monitor virando a doença.

    A ARMADILHA QUE ORGANIZA ESTE ARQUIVO
    -------------------------------------
    Get-WinEvent lança exceção quando não encontra evento. Até aí, tudo bem. O
    problema é que ele lança a MESMA exceção, com o MESMO identificador
    (NoMatchingEventsFound), quando o log existe e simplesmente não pode ser
    lido por falta de privilégio. Medido nesta máquina:

        System   -> NoMatchingEventsFound   (não há evento WHEA: boa notícia)
        Security -> NoMatchingEventsFound   (log restrito: não pude olhar)

    Um try/catch ingênuo trata os dois como "zero erros de hardware" e reporta
    máquina saudável a partir de um log que nunca foi aberto. É exatamente o
    modo de falha que este projeto existe para não ter: ausência virando zero.

    O DISCRIMINADOR é Get-WinEvent -ListLog, que FALHA no log inaccessível e
    funciona no legível. Confirmada a legibilidade, aí sim zero resultado
    significa zero evento — e a sonda pode afirmar isso.

    Quando não dá para confirmar, o campo vai NULO e a razão fica registrada.
    Nulo aqui não é falta de capricho: é a diferença entre "não houve erro de
    hardware" e "não sei se houve".
#>
param(
    $Facts,
    <#
        Faz parte do contrato de sonda — Invoke-Exam passa o mesmo prazo para
        todas — mas ESTA sonda não tem como honrá-lo: Get-WinEvent não aceita
        tempo limite. Fica declarado aqui e em config.json em vez de dar a
        impressão de que há um teto que não existe. Quem impõe prazo de verdade
        é o ExecutionTimeLimit da tarefa agendada.
    #>
    [int]$TimeoutSec = 30,
    [int]$WindowDays = 30,
    [datetime]$Since,
    <#
        Existe para o teste, e a costura vale a pena: apontando para 'Security'
        — que numa sessão sem elevação é ilegível de verdade nesta máquina — dá
        para provar o comportamento de recusa contra um log REAL, em vez de
        contra um dublê que eu mesmo escreveria para concordar comigo.
    #>
    [string]$LogName = 'System',
    <#
        Teto de eventos por consulta. Costura de teste também: com -MaxEvents 1
        contra um log que tem mais de um evento, dá para exercitar a declaração
        de saturação sem esperar a máquina reiniciar duzentas vezes.
    #>
    [int]$MaxEvents = 200
)

if ($null -eq $Facts) { $Facts = Get-WMHostFacts }

<#
    Se -Since vier de fora, a janela DECLARADA passa a ser a janela real.
    Antes, gravava-se windowDays tal como recebido enquanto a consulta usava
    outro período: 365 dias declarados sobre uma janela de dois dias, e a
    contagem lida como se fosse anual. Contagem sem período é número sem
    significado — um desligamento inesperado em 30 dias e em 3 anos são
    diagnósticos diferentes.
#>
if ($PSBoundParameters.ContainsKey('Since')) {
    $WindowDays = [int][Math]::Ceiling(((Get-Date) - $Since).TotalDays)
} else {
    $Since = (Get-Date).AddDays(-$WindowDays)
}

<#
    O log está acessível E legível?

    Duas perguntas, porque -ListLog pode responder e a leitura ainda falhar.
    Um log com registros do qual não se consegue ler nenhum evento é um log
    inaccessível, por mais que os metadados apareçam.

    Sem parâmetro de prazo, e isso é declaração e não esquecimento: Get-WinEvent
    não aceita tempo limite. A versão anterior recebia um -Timeout e não o usava
    para nada. Limite que não limita é pior que limite nenhum — quem lê a
    configuração acredita nele.
#>
function Test-LogReadable {
    param([string]$LogName)

    try {
        $info = Get-WinEvent -ListLog $LogName -ErrorAction Stop
    } catch {
        return @{ ok = $false; reason = "log '$LogName' não pôde ser consultado (provavelmente exige privilégio): $($_.Exception.Message)" }
    }

    if ($null -eq $info) { return @{ ok = $false; reason = "log '$LogName' não devolveu metadados" } }

    if (-not $info.IsEnabled) {
        return @{ ok = $false; reason = "log '$LogName' está DESABILITADO: nada foi registrado nele, e ausência de registro não é ausência de evento" }
    }

    <#
        NUNCA sair daqui sem ter LIDO.

        Havia um atalho: RecordCount igual a zero devolvia "legível, vazio" sem
        tentar leitura nenhuma. Dois problemas medidos:

          - [int]$null é 0 em PowerShell, e log desabilitado devolve RecordCount
            nulo. Havia 84 logs assim nesta máquina. Todos passavam por "legível
            e vazio", e a sonda então afirmava 0 desligamento inesperado em 30
            dias a partir de um log que ela nunca abriu.
          - Mesmo com RecordCount 0 de verdade, zero registros AGORA não prova
            que a leitura seria permitida. Limpar o log de eventos é ação de
            rotina, e depois dela a sonda atestaria saúde sobre histórico
            inexistente.

        É a ausência virando zero dentro da função escrita para impedir que a
        ausência vire zero. Agora a legibilidade é sempre confirmada por leitura:
        NoMatchingEventsFound aqui é resposta legítima — o log respondeu, e a
        resposta foi "não tenho nada".
    #>
    try {
        $um = @(Get-WinEvent -LogName $LogName -MaxEvents 1 -ErrorAction Stop)
        if ($um.Count -eq 0) {
            return @{ ok = $false; reason = "log '$LogName' não devolveu nenhum evento e nem sinalizou vazio: leitura negada" }
        }
    } catch {
        if ([string]$_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
            # O log respondeu que está vazio. Isso é legível.
            return @{ ok = $true; records = 0; empty = $true }
        }
        return @{ ok = $false; reason = "log '$LogName' não pôde ser lido: $($_.Exception.Message)" }
    }

    @{ ok = $true; records = [int]$info.RecordCount }
}

<#
    Conta eventos de um filtro, sabendo distinguir zero de não-sei.

    Só é chamada DEPOIS de Test-LogReadable confirmar o log. Aqui,
    NoMatchingEventsFound significa mesmo zero — e o identificador é usado em
    vez da mensagem porque a mensagem é traduzida: nesta máquina ela vem em
    português, e comparar texto localizado quebraria em qualquer outro idioma.
#>
function Measure-Event {
    param([hashtable]$Filter, [int]$Max = $MaxEvents)

    try {
        $ev = @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction Stop)
        <#
            SATURAÇÃO É DECLARADA. Com o teto atingido, $ev.Count vale exatamente
            $Max — e gravar isso como contagem afirma "foram 200" quando o certo
            é "foram pelo menos 200". Numa máquina reiniciando várias vezes por
            dia, ou com WHEA torrencial, é justamente o caso em que o número
            importa, e era o caso em que ele mentia.
        #>
        return @{ ok = $true; count = $ev.Count; events = $ev; truncated = ($ev.Count -ge $Max) }
    } catch {
        if ([string]$_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
            return @{ ok = $true; count = 0; events = @() }
        }
        return @{ ok = $false; reason = $_.Exception.Message }
    }
}

try {
    $data   = [ordered]@{}
    $avisos = New-Object System.Collections.ArrayList

    $data.windowDays = $WindowDays
    $data.since      = $Since.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)

    $legivel = Test-LogReadable -LogName $LogName

    if (-not $legivel.ok) {
        <#
            Sem o log, TODOS os campos vão nulos. Não há meio-termo aqui: um
            'wheaErrors = 0' ao lado de um aviso de acesso negado seria lido como
            boa notícia por qualquer regra e por qualquer pessoa apressada.
        #>
        $data.logReadable         = $false
        $data.wheaErrors          = $null
        $data.unexpectedShutdowns = $null
        $data.cleanShutdowns      = $null
        $data.lastUnexpectedAt    = $null
        [void]$avisos.Add($legivel.reason)

        return @{ ok = $true; reason = ($avisos -join ' ;; '); data = $data }
    }

    $data.logReadable = $true

    # --- erro de hardware (WHEA) --------------------------------------------
    $whea = Measure-Event @{ LogName = $LogName; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Level = 1, 2; StartTime = $Since }
    if ($whea.ok) {
        $data.wheaErrors = [int]$whea.count
        if ($whea.truncated) {
            $data.wheaTruncated = $true
            [void]$avisos.Add("a contagem WHEA atingiu o teto da consulta: foram PELO MENOS $($whea.count), nao exatamente $($whea.count)")
        }
        if ($whea.count -gt 0) {
            $data.lastWheaAt = $whea.events[0].TimeCreated.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }
    } else {
        $data.wheaErrors = $null
        [void]$avisos.Add("consulta WHEA falhou: $($whea.reason)")
    }

    <#
        --- desligamento inesperado ---
        6008 (EventLog) é "o desligamento anterior foi inesperado". Kernel-Power
        41 é "o sistema reiniciou sem desligar direito". Os dois costumam vir em
        par no mesmo incidente, então contar a soma inflaria: usa-se 6008 como
        contagem e o 41 fica como corroboração.
    #>
    $ines = Measure-Event @{ LogName = $LogName; Id = 6008; StartTime = $Since }
    if ($ines.ok) {
        $data.unexpectedShutdowns = [int]$ines.count
        if ($ines.truncated) {
            $data.unexpectedTruncated = $true
            [void]$avisos.Add("a contagem de desligamento inesperado atingiu o teto: foram PELO MENOS $($ines.count)")
        }
        if ($ines.count -gt 0) {
            $data.lastUnexpectedAt = $ines.events[0].TimeCreated.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }
    } else {
        $data.unexpectedShutdowns = $null
        [void]$avisos.Add("consulta de desligamento inesperado falhou: $($ines.reason)")
    }

    $kp = Measure-Event @{ LogName = $LogName; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $Since }
    $data.kernelPower41 = $(if ($kp.ok) { [int]$kp.count } else { $null })
    if (-not $kp.ok) { [void]$avisos.Add("consulta Kernel-Power 41 falhou: $($kp.reason)") }
    if ($kp.truncated) { $data.kernelPower41Truncated = $true; [void]$avisos.Add("Kernel-Power 41 atingiu o teto: PELO MENOS $($kp.count)") }

    <#
        Desligamento limpo (1074) entra como denominador. "Dois inesperados" diz
        pouco sozinho; "dois inesperados em quarenta desligamentos" e "dois em
        dois" são situações completamente diferentes.
    #>
    $limpo = Measure-Event @{ LogName = $LogName; Id = 1074; StartTime = $Since }
    $data.cleanShutdowns = $(if ($limpo.ok) { [int]$limpo.count } else { $null })
    if (-not $limpo.ok) { [void]$avisos.Add("consulta de desligamento limpo falhou: $($limpo.reason)") }
    <#
        O denominador tambem satura, e ele e o numero que da sentido ao
        numerador: "dois inesperados em quarenta" e "dois em dois" sao situacoes
        diferentes. A declaracao de saturacao estava escrita DENTRO da funcao
        compartilhada, valendo so para dois dos quatro chamadores - o comentario
        cobria o codigo todo e o efeito cobria metade.
    #>
    if ($limpo.truncated) { $data.cleanTruncated = $true; [void]$avisos.Add("a contagem de desligamento limpo atingiu o teto: PELO MENOS $($limpo.count)") }

    @{ ok = $true; reason = $(if ($avisos.Count -gt 0) { $avisos -join ' ;; ' } else { $null }); data = $data }

} catch {
    @{ ok = $false; reason = $_.Exception.Message }
}
