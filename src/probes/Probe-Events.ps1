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
    [int]$TimeoutSec = 30,
    [int]$WindowDays = 30,
    [datetime]$Since,
    <#
        Existe para o teste, e a costura vale a pena: apontando para 'Security'
        — que numa sessão sem elevação é ilegível de verdade nesta máquina — dá
        para provar o comportamento de recusa contra um log REAL, em vez de
        contra um dublê que eu mesmo escreveria para concordar comigo.
    #>
    [string]$LogName = 'System'
)

if ($null -eq $Facts) { $Facts = Get-WMHostFacts }
if (-not $PSBoundParameters.ContainsKey('Since')) { $Since = (Get-Date).AddDays(-$WindowDays) }

<#
    O log está acessível E legível?

    Duas perguntas, porque -ListLog pode responder e a leitura ainda falhar.
    Um log com registros do qual não se consegue ler nenhum evento é um log
    inaccessível, por mais que os metadados apareçam.
#>
function Test-LogReadable {
    param([string]$LogName, [int]$Timeout)

    try {
        $info = Get-WinEvent -ListLog $LogName -ErrorAction Stop
    } catch {
        return @{ ok = $false; reason = "log '$LogName' não pôde ser consultado (provavelmente exige privilégio): $($_.Exception.Message)" }
    }

    if ($null -eq $info) { return @{ ok = $false; reason = "log '$LogName' não devolveu metadados" } }

    # Log realmente vazio é legível e não tem o que ler.
    if ([int]$info.RecordCount -eq 0) { return @{ ok = $true; records = 0 } }

    try {
        $um = @(Get-WinEvent -LogName $LogName -MaxEvents 1 -ErrorAction Stop)
        if ($um.Count -eq 0) {
            return @{ ok = $false; reason = "log '$LogName' declara $($info.RecordCount) registros mas não devolveu nenhum: leitura negada" }
        }
    } catch {
        return @{ ok = $false; reason = "log '$LogName' tem $($info.RecordCount) registros e a leitura falhou: $($_.Exception.Message)" }
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
    param([hashtable]$Filter, [int]$Max = 200)

    try {
        $ev = @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction Stop)
        return @{ ok = $true; count = $ev.Count; events = $ev }
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

    $legivel = Test-LogReadable -LogName $LogName -Timeout $TimeoutSec

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

    <#
        Desligamento limpo (1074) entra como denominador. "Dois inesperados" diz
        pouco sozinho; "dois inesperados em quarenta desligamentos" e "dois em
        dois" são situações completamente diferentes.
    #>
    $limpo = Measure-Event @{ LogName = $LogName; Id = 1074; StartTime = $Since }
    $data.cleanShutdowns = $(if ($limpo.ok) { [int]$limpo.count } else { $null })
    if (-not $limpo.ok) { [void]$avisos.Add("consulta de desligamento limpo falhou: $($limpo.reason)") }

    @{ ok = $true; reason = $(if ($avisos.Count -gt 0) { $avisos -join ' ;; ' } else { $null }); data = $data }

} catch {
    @{ ok = $false; reason = $_.Exception.Message }
}
