#requires -Version 5.1
<#
    Sonda de memória.

    Além do uso, guarda os pools do kernel. Crescimento monotônico de
    PoolNonpaged ao longo de semanas de uptime é a assinatura clássica de
    vazamento de driver — invisível num retrato instantâneo, óbvio numa série.
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
    $m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory `
            -OperationTimeoutSec $TimeoutSec -ErrorAction Stop |
         Select-Object -First 1

    if ($null -eq $m) {
        return @{ ok = $false; reason = 'PerfOS_Memory não retornou instância' }
    }

    $data = [ordered]@{
        availMB        = [int]$m.AvailableMBytes
        committedMB    = [int]($m.CommittedBytes / 1MB)
        commitLimitMB  = [int]($m.CommitLimit / 1MB)
        pagesSec       = [int]$m.PagesPerSec
        poolNonpagedMB = [int]($m.PoolNonpagedBytes / 1MB)
        poolPagedMB    = [int]($m.PoolPagedBytes / 1MB)
    }

    if ($data.commitLimitMB -gt 0) {
        $data.commitPct = [math]::Round(100.0 * $data.committedMB / $data.commitLimitMB, 1)
    }

    $total = 0
    if ($Facts -and $Facts.memTotalMB) { $total = [int]$Facts.memTotalMB }
    if ($total -gt 0) {
        $data.usedPct = [math]::Round(100.0 * ($total - $data.availMB) / $total, 1)
    }

    @{ ok = $true; data = $data }

} catch {
    @{ ok = $false; reason = $_.Exception.Message }
}
