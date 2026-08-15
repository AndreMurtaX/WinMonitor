#requires -Version 5.1
<#
    Exame — a cadência lenta.

    A ronda roda a cada minuto e só toca em contador barato. O exame roda sob
    demanda ou uma vez por dia, e faz o que é caro demais para repetir sempre:
    ler o log de eventos, e — quando houver privilégio e ferramenta — SMART e
    sensores.

    POR QUE SEPARADO DA RONDA
    -------------------------
    Consultar o log de eventos do Windows custa ordens de grandeza mais que ler
    uma classe CIM, e o dado muda em escala de dias. Pagar isso a cada minuto
    seria o monitor virando exatamente a carga que ele deveria estar medindo.

    O QUE ESTE EXAME AINDA NÃO FAZ
    ------------------------------
    SMART e temperatura de CPU. Os dois exigem coisas que não estão aqui:
    Get-StorageReliabilityCounter precisa de elevação (medido: falha com
    "acesso a um recurso CIM não estava disponível" numa sessão comum), e
    temperatura de CPU precisa de driver de kernel que ainda não foi baixado
    nem testado contra o antivírus desta máquina.

    Isso NÃO é tratado como detalhe pendente: cada sonda que não roda entra no
    arquivo com o motivo, e as regras que dependem dela continuam declaradas
    como não verificadas. O exame incompleto se anuncia incompleto.

    Uso:
      .\src\Invoke-Exam.ps1
      .\src\Invoke-Exam.ps1 -PassThru -NoWrite | ConvertTo-Json -Depth 8
#>
[CmdletBinding()]
param(
    [int]$WindowDays = 30,
    [switch]$NoWrite,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'WinMonitor.psm1') -Force

$cfg   = Get-WMConfig
$fatos = Get-WMHostFacts

<#
    O recuo era CÓDIGO MORTO, e o caminho que ele existia para cobrir matava o
    driver.

    '@($cfg.exam.probes).Count -eq 0' nunca é verdade quando o bloco falta:
    @($null).Count é UM. Então, com exam.probes ausente do config, a lista saía
    com um elemento nulo, o recuo não disparava, e o exame morria montando a
    amostra com uma chave vazia — 'o valor do argumento name não é válido'.

    Monitor que morre é pior que monitor que registra um buraco: quem morre não
    deixa nem o registro de que tentou.
#>
$sondas = @($cfg.exam.probes | Where-Object { $_ -and $_.name -and $_.key })
$houveRecuo = ($sondas.Count -eq 0)
if ($houveRecuo) { $sondas = @([pscustomobject]@{ name = 'Events'; key = 'evt' }) }

$amostra = [ordered]@{
    v    = 1
    host = $env:COMPUTERNAME
    at   = Get-WMTimestamp
    mode = 'exam'
}

$cobertura = [ordered]@{}
if ($houveRecuo) {
    $cobertura['config'] = 'exam.probes ausente ou ilegivel no config: o exame recuou para a sonda de eventos apenas. Nao ha como saber o que mais deveria ter sido examinado.'
}

foreach ($s in $sondas) {
    $nome = [string]$s.name
    $chave = [string]$s.key
    $script = Join-Path $PSScriptRoot ("probes\Probe-{0}.ps1" -f $nome)

    if (-not (Test-Path -LiteralPath $script)) {
        $cobertura[$chave] = "sonda '$nome' não existe neste projeto"
        $amostra[$chave] = $null
        continue
    }

    $r = $null
    try {
        $r = & $script -Facts $fatos -TimeoutSec ([int]$(if ($cfg.exam.probeTimeoutSec) { $cfg.exam.probeTimeoutSec } else { 30 })) -WindowDays $WindowDays
    } catch {
        $cobertura[$chave] = "sonda '$nome' lançou exceção: $($_.Exception.Message)"
        $amostra[$chave] = $null
        continue
    }

    if ($null -eq $r -or -not $r.ok) {
        $motivo = if ($r) { [string]$r.reason } else { 'sonda não devolveu nada' }
        $cobertura[$chave] = "sonda '$nome' falhou: $motivo"
        <#
            Falhou é NULO, nunca objeto vazio. Um {} no lugar de um resultado é
            lido como "rodou e não achou nada" pela regra que vier depois.
        #>
        $amostra[$chave] = $null
        continue
    }

    $amostra[$chave] = $r.data
    if ($r.reason) { $cobertura[$chave] = "sonda '$nome' com ressalva: $($r.reason)" }
}

<#
    As sondas que este exame ainda não tem, ditas por nome e por motivo.

    O filtro não é zelo: sem ele, exam.missing ausente produzia @($null) com um
    elemento, e a cobertura saía com uma lacuna de chave vazia e motivo vazio —
    um buraco anônimo, que é pior que buraco nenhum porque parece declaração.
#>
foreach ($p in @($cfg.exam.missing | Where-Object { $_ -and $_.key })) {
    $cobertura[[string]$p.key] = [string]$p.reason
}

$amostra.coverage = $cobertura
$amostra.complete = ($cobertura.Count -eq 0)

$obj = [pscustomobject]$amostra

if (-not $NoWrite) {
    $dir  = Confirm-WMDirectory (Get-WMPath $cfg.paths.exam)
    $arq  = Join-Path $dir ("{0}.json" -f (Get-WMDayId))
    $json = ConvertTo-Json -InputObject $obj -Depth 10
    [System.IO.File]::WriteAllText($arq, $json, (New-Object System.Text.UTF8Encoding($false)))
    if (-not $PassThru) { "exame gravado em $arq" }
}

if ($PassThru) { $obj }
