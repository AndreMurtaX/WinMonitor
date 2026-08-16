#requires -Version 5.1
<#
    Sonda de CPU.

    Usa classes CIM de performance em vez de Get-Counter de propósito: os nomes
    de contador do Windows são traduzidos para o idioma do sistema, então o
    caminho '\Processor Information(_Total)\% Processor Performance' não existe
    num Windows em português. As propriedades das classes CIM não são
    traduzidas, e por isso funcionam em qualquer idioma.
#>
param(
    $Facts,
    [int]$TimeoutSec = 8
)

<#
    O DEFAULT NAO CHAMA Get-WMHostFacts, e o parametro CONTINUA sendo usado.

    $Facts e lido mais abaixo, de verdade. O que saiu daqui foi o DEFAULT que
    o chamava sozinho: Get-WMHostFacts grava data\host.json como efeito
    colateral, e uma sonda de leitura nao escreve arquivo nenhum. Quem tem os
    fatos passa; quem nao tem fica sem o numero derivado, e a ausencia dele ja
    e tratada logo adiante.

    E o mesmo padrao que o cabecalho de Probe-DiskHealth condena desde a F3, e
    que continuou em duas das seis sondas porque nenhuma suite executava estes
    arquivos: a decima segunda verificacao mediu o buraco plantando um throw
    como primeira instrucao aqui - as oito suites continuaram verdes.
#>

try {
    $p = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation `
            -Filter "Name='_Total'" -OperationTimeoutSec $TimeoutSec -ErrorAction Stop |
         Select-Object -First 1

    if ($null -eq $p) {
        return @{ ok = $false; reason = "instância '_Total' ausente em ProcessorInformation" }
    }

    $data = [ordered]@{
        util    = [int]$p.PercentProcessorTime
        perfPct = [int]$p.PercentProcessorPerformance
    }

    <#
        Clock efetivo. PercentProcessorPerformance é relativo ao clock base e
        passa de 100 sob boost — é assim que o Gerenciador de Tarefas mostra
        4,96 GHz num chip de base 3,50 GHz.

        Este é o número que denuncia throttling térmico de CPU sem precisar de
        sensor nenhum: processador quente se defende baixando frequência, e a
        queda aparece aqui antes de qualquer termômetro estar disponível.
    #>
    $base = 0
    if ($Facts -and $Facts.cpuBaseMHz) { $base = [int]$Facts.cpuBaseMHz }
    if ($base -gt 0) {
        $data.mhz = [int][math]::Round($base * $p.PercentProcessorPerformance / 100.0)
    }

    # Fila de processador e contagem de processos: sinais baratos de saturação
    # e de vazamento em servidor com uptime longo.
    $warn = $null
    try {
        $s = Get-CimInstance Win32_PerfFormattedData_PerfOS_System `
                -OperationTimeoutSec $TimeoutSec -ErrorAction Stop |
             Select-Object -First 1
        $data.queue   = [int]$s.ProcessorQueueLength
        $data.procs   = [int]$s.Processes
        $data.threads = [int]$s.Threads
    } catch {
        $warn = "PerfOS_System indisponível: $($_.Exception.Message)"
    }

    @{ ok = $true; reason = $warn; data = $data }

} catch {
    @{ ok = $false; reason = $_.Exception.Message }
}
