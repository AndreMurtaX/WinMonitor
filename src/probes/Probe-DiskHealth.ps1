#requires -Version 5.1
<#
    Sonda de saúde de disco — o que dá para saber SEM privilégio.

    POR QUE ELA EXISTE, DEPOIS DE EU TER DECLARADO ISTO BLOQUEADO
    -------------------------------------------------------------
    Eu media 'Get-StorageReliabilityCounter', via "acesso negado", e concluía
    que saúde de disco exigia elevação. A conclusão foi um passo além da
    medição — de novo. Medindo item por item, sem elevação:

        Get-PhysicalDisk  -> HealthStatus, OperationalStatus   OK
        Get-Disk          -> HealthStatus, OperationalStatus   OK
        MSStorageDriver_FailurePredictStatus (root\wmi)        NEGADO
        Get-StorageReliabilityCounter                          NEGADO

    O que exige administrador é a CONTAGEM (setores realocados, horas ligado,
    temperatura do disco). O VEREDITO de saúde, que o próprio Windows deriva do
    SMART, é legível por qualquer conta.

    O QUE ISSO É, E O QUE NÃO É
    ---------------------------
    'Healthy/Warning/Unhealthy' é grosso comparado a "a contagem de setores
    realocados subiu de 0 para 8 desde a linha-base". Um disco que começou a
    realocar setores ainda diz Healthy por um bom tempo.

    Então esta sonda não substitui a leitura SMART da F3 — ela cobre o degrau
    de baixo: quando o Windows já desistiu de chamar o disco de saudável, isso
    merece atenção imediata, e custa zero.

    A lacuna de granularidade continua declarada em exam.missing. Cobrir o
    degrau de baixo não pode virar pretexto para calar o de cima.
#>
param(
    $Facts,
    [int]$TimeoutSec = 30,
    [int]$WindowDays = 30,
    <#
        Costura de teste, e ela é necessária por um motivo medido: os três
        discos DESTA máquina estão Healthy, então o caminho de "disco doente" e
        o de "não consegui ler" nunca executam aqui. Sem injetar a lista, o
        teste só alcança o caminho feliz — e a mutação que troca a comparação
        por 'não é Unhealthy' sobrevive, porque com todos Healthy as duas
        expressões dão o mesmo resultado.

        -Discos injeta a lista; -Falhar força o caminho de leitura negada.
    #>
    $Discos,
    [switch]$Falhar
)

if ($null -eq $Facts) { $Facts = Get-WMHostFacts }

try {
    <#
        $lidos, e NÃO $discos: em PowerShell nomes de variável são
        insensíveis a caixa, então '$discos' e o parâmetro '$Discos' são A MESMA
        variável — e a linha que a inicializava com $null apagava a lista
        injetada antes de alguém lê-la.

        É a armadilha $windowDays/$WindowDays que este projeto documenta desde a
        F2, cometida pela terceira vez nesta sessão. Ela não avisa: o código
        roda, e o teste passa a medir o caminho errado.
    #>
    $lidos = $null
    try {
        if ($Falhar) { throw 'falha de leitura forçada pelo teste' }
        $lidos = if ($PSBoundParameters.ContainsKey('Discos')) { @($Discos) } else { @(Get-PhysicalDisk -ErrorAction Stop) }
    } catch {
        <#
            Falhou é NULO, nunca lista vazia. Uma lista vazia seria lida pela
            regra como "nenhum disco doente" — a ausência virando boa notícia,
            que é o modo de falha que este projeto inteiro existe para não ter.
        #>
        return @{ ok = $true; reason = "Get-PhysicalDisk falhou: $($_.Exception.Message)"; data = [ordered]@{
            readable = $false
            disks    = $null
            unhealthy = $null
        } }
    }

    if ($lidos.Count -eq 0) {
        return @{ ok = $true; reason = 'Get-PhysicalDisk respondeu sem nenhum disco: não há como afirmar saúde de nada'; data = [ordered]@{
            readable = $false
            disks    = $null
            unhealthy = $null
        } }
    }

    $lista = New-Object System.Collections.ArrayList
    $doentes = 0
    foreach ($d in $lidos) {
        $saude = [string]$d.HealthStatus
        $oper  = [string]$d.OperationalStatus

        <#
            'Healthy' é o único valor que conta como saudável. Qualquer outro —
            Warning, Unhealthy, ou um valor que a Microsoft acrescente depois —
            é contado como doente. Errar para o lado de perguntar é barato;
            errar para o lado de calar é o que este projeto não faz.
        #>
        $ok = ($saude -eq 'Healthy')
        if (-not $ok) { $doentes++ }

        [void]$lista.Add([ordered]@{
            id      = [string]$d.DeviceId
            name    = [string]$d.FriendlyName
            media   = [string]$d.MediaType
            health  = $saude
            oper    = $oper
        })
    }

    @{
        ok     = $true
        reason = $null
        data   = [ordered]@{
            readable  = $true
            disks     = @($lista)
            unhealthy = $doentes
        }
    }

} catch {
    @{ ok = $false; reason = $_.Exception.Message }
}
