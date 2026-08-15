#requires -Version 5.1
<#
    Ronda — a coleta barata que roda a cada minuto, sem privilégio.

    A função da ronda NÃO é detectar problema. É capturar as janelas de carga
    alta, porque o dado que diagnostica refrigeração é a temperatura de quando
    a máquina estava trabalhando de verdade — e um exame agendado quase sempre
    pega a máquina em repouso.

    Este script nunca lança exceção para fora. Um monitor que morre é pior que
    um monitor que registra um buraco, porque o buraco é visível na série.

    Códigos de saída:  0 amostra gravada · 1 falha na coleta · 2 módulo ausente
#>
[CmdletBinding()]
param(
    [switch]$PassThru,
    [switch]$NoWrite
)

$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'WinMonitor.psm1') -Force -ErrorAction Stop
} catch {
    # Sem o módulo não há nem como registrar a falha. Sai com código próprio
    # para a tarefa agendada marcar o problema.
    exit 2
}

try {
    $cfg   = Get-WMConfig
    $facts = Get-WMHostFacts

    <#
        Respiro antes de amostrar. O arranque do próprio PowerShell é carga de
        CPU, e medir no instante do arranque enviesa a amostra para cima. O
        respiro reduz o viés; não o elimina — está registrado no README.
    #>
    $settle = 400
    if ($cfg.patrol.settleMs) { $settle = [int]$cfg.patrol.settleMs }
    if ($settle -gt 0) { Start-Sleep -Milliseconds $settle }

    $timeout = 8
    if ($cfg.patrol.probeTimeoutSec) { $timeout = [int]$cfg.patrol.probeTimeoutSec }

    $sample = [ordered]@{
        v    = 1
        host = $env:COMPUTERNAME
        at   = Get-WMTimestamp
        mode = 'patrol'
    }

    # Uptime dá contexto para quase tudo num servidor: vazamento de pool,
    # deriva térmica, reinício que ninguém pediu.
    try {
        $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec $timeout -ErrorAction Stop
        $sample.upH = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 2)
    } catch { }

    $ok  = @()
    $gap = [ordered]@{}

    foreach ($probe in $cfg.patrol.probes) {
        $r = Invoke-WMProbe -Name $probe.name -Arguments @{ Facts = $facts; TimeoutSec = $timeout }

        switch ($r.state) {
            'ok' {
                $ok += $probe.key
                $sample[$probe.key] = $r.data
            }
            'partial' {
                # Entregou parte: o dado entra, e a perda fica declarada.
                $ok += $probe.key
                $sample[$probe.key] = $r.data
                $gap[$probe.key] = $r.reason
            }
            default {
                $gap[$probe.key] = $r.reason
            }
        }
    }

    <#
        Bloco de cobertura. É o que impede "nenhum problema encontrado" de se
        confundir com "não consegui olhar" — sem ele, uma ronda que perdeu a
        GPU produz uma série que parece saudável.
    #>
    $sample.cov = [ordered]@{ ok = $ok; gap = $gap }

    if (-not $NoWrite) {
        $dir  = Confirm-WMDirectory (Get-WMPath $cfg.paths.patrol)
        $file = Join-Path $dir ('{0}.jsonl' -f (Get-Date -Format 'yyyy-MM-dd'))
        [void](Write-WMJsonLine -Path $file -Object $sample)

        # Retenção aplicada na escrita. Faxina agendada é faxina que um dia não
        # roda, e o monitor não pode ser a causa do disco cheio.
        [void](Invoke-WMRetention -Directory $dir -Days ([int]$cfg.retention.patrolRawDays))
        [void](Invoke-WMRetention -Directory (Get-WMPath $cfg.paths.logs) `
                                  -Days ([int]$cfg.retention.logDays) -Filter '*.log')
    }

    if ($gap.Count -gt 0) {
        Write-WMLog -Level warn -Source 'patrol' -Message ("lacunas: " + (($gap.Keys | ForEach-Object { "$_=$($gap[$_])" }) -join '; '))
    }

    if ($PassThru) { [pscustomobject]$sample }
    exit 0

} catch {
    try { Write-WMLog -Level error -Source 'patrol' -Message $_.Exception.Message } catch { }
    exit 1
}
