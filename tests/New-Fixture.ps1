#requires -Version 5.1
<#
    Gerador de dia sintético de ronda.

    Sintético por dois motivos. Primeiro, fixture com dado real carregaria nome
    de host e modelos de disco para dentro de um repositório público. Segundo, e
    mais importante: dado sintético tem propriedades CONHECIDAS, então o teste
    afirma valores exatos em vez de conferir que "parece razoável".

    O modelo térmico é deliberadamente simples e explícito:

        temperatura = base + carga * ganho + ruído + (desvio, só na faixa alta)

    -ThermalOffsetHigh soma graus APENAS nas amostras de carga alta. É assim que
    se simula degradação — pasta secando, poeira acumulando — que é o defeito
    invisível para a estatística do dia e visível na comparação por faixa.

    OS INTERRUPTORES ADVERSARIAIS

    Uma versão anterior desta fixture era estruturalmente incapaz de detectar
    três defeitos reais, e por isso a suíte passava verde sobre código quebrado.
    Cada interruptor abaixo existe para tornar um deles detectável:

      -GpuAntiCorrelated  carga de GPU oposta à de CPU. Sem isso, estratificar
                          a temperatura da GPU pela carga da CPU dá o mesmo
                          resultado e o erro é invisível.
      -EdgeBurstEnd       rajada colada no fim do dia. Sem isso, nenhuma janela
                          de carga toca a virada e a fusão indevida entre dias
                          consecutivos nunca aparece.
      -DropProbe          amostras com um subsistema ausente e lacuna declarada,
                          que é o formato que Invoke-Patrol produz de verdade.
      -NoThrottleFields   modo degradado da sonda de GPU (FIELDS_MIN), em que a
                          máscara de contenção não existe.
#>
[CmdletBinding()]
param(
    [string]$Day = '2026-01-01',
    [int]$Samples = 1440,
    [int]$Bursts = 10,
    [int]$BurstLen = 20,
    [double]$ThermalOffsetHigh = 0,
    <#
        Somado a TODAS as amostras, não só às de carga alta.

        É o contraste que torna a estratificação insubstituível: sala quente
        desloca a curva inteira, refrigeração degradando desloca só a ponta de
        carga alta. Qualquer estatística do dia (máximo, p95) vê a MESMA subida
        nos dois casos e não sabe dizer qual aconteceu. A visão por faixa sabe.
    #>
    [double]$ThermalOffsetAll = 0,
    <#
        Forma da degradação.

        Step   degrau: soma tudo quando carga >= 75. Simples, mas o degrau cai
               EXATAMENTE na fronteira b50/b75 usada para estratificar, o que
               garante zero na faixa ociosa. Bom para o caso limpo.
        Linear proporcional à carga, com o valor cheio em 90%. É a forma real de
               dissipação degradando, e não coincide com nenhuma fronteira.
    #>
    [ValidateSet('Step', 'Linear')][string]$ThermalModel = 'Step',
    [switch]$GpuAntiCorrelated,
    # Faixa da carga "ociosa". Subir os dois produz um dia SEM ócio — o regime
    # em que não existe faixa b00 e a tese da estratificação não se aplica.
    [int]$IdleMin = 3,
    [int]$IdleMax = 16,
    [int]$RebootAt = -1,
    # Uptime no início do dia. Dias consecutivos de uma máquina que não
    # reiniciou precisam ENCADEAR: sem isso, todo dia começa em 100 h e a
    # emenda entre dois dias parece um reinício que não houve.
    [double]$UptimeStartH = 100,
    [int]$ThrottleFrom = -1,
    [int]$ThrottleCount = 0,
    [switch]$EdgeBurstStart,
    [switch]$EdgeBurstEnd,
    [ValidateSet('', 'cpu', 'mem', 'sto', 'gpu')][string]$DropProbe = '',
    [int]$DropFrom = -1,
    [int]$DropCount = 0,
    [switch]$NoThrottleFields,
    [int]$Seed = 20260101,
    # NÃO renomear para $Host: é variável automática do PowerShell, e nomes de
    # variável aqui são case-insensitive. Já custou um script morto neste projeto.
    [string]$MachineName = 'FIXTURE-HOST',
    [string]$OutFile
)

if ($IdleMin -ge $IdleMax) {
    throw "IdleMin ($IdleMin) precisa ser menor que IdleMax ($IdleMax). Invertidos, Get-Random emite um erro não-terminante por amostra e o dia sai com carga zero sem que nada reclame."
}

Get-Random -SetSeed $Seed | Out-Null

# ------------------------------------------------------- perfil de carga ----

$cload = New-Object 'double[]' $Samples
for ($i = 0; $i -lt $Samples; $i++) { $cload[$i] = Get-Random -Minimum $IdleMin -Maximum $IdleMax }

function Set-Burst {
    param([int]$Start, [int]$Len)
    for ($k = 0; $k -lt $Len; $k++) {
        $j = $Start + $k
        if ($j -ge 0 -and $j -lt $Samples) { $cload[$j] = Get-Random -Minimum 80 -Maximum 97 }
    }
}

# Rajadas internas, sempre com folga ociosa nas pontas.
$spacing = [int][math]::Floor($Samples / [math]::Max($Bursts, 1))
for ($b = 0; $b -lt $Bursts; $b++) { Set-Burst -Start ($b * $spacing + 5) -Len $BurstLen }

# Rajadas de borda: coladas na primeira e na última amostra do dia.
if ($EdgeBurstStart) { Set-Burst -Start 0 -Len $BurstLen }
if ($EdgeBurstEnd)   { Set-Burst -Start ($Samples - $BurstLen) -Len $BurstLen }

# Carga de GPU: por padrão acompanha a da CPU; anti-correlacionada quando
# pedido, para que estratificar pela carga errada produza resultado errado.
$gload = New-Object 'double[]' $Samples
for ($i = 0; $i -lt $Samples; $i++) {
    if ($GpuAntiCorrelated) { $gload[$i] = [math]::Max(2, 99 - $cload[$i]) }
    else                    { $gload[$i] = $cload[$i] }
}

# ------------------------------------------------------------- geração ------

$lines = New-Object System.Collections.ArrayList
$t0    = [datetime]::ParseExact($Day, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)

$dropTo = -1
if ($DropProbe -and $DropCount -gt 0 -and $DropFrom -ge 0) { $dropTo = $DropFrom + $DropCount - 1 }

for ($i = 0; $i -lt $Samples; $i++) {
    $cl = $cload[$i]
    $gl = $gload[$i]

    $dropping = ($i -ge $DropFrom -and $i -le $dropTo -and $DropProbe -ne '')

    $gpuTemp = 35.0 + $gl * 0.45 + (Get-Random -Minimum -10 -Maximum 11) / 10.0
    $gpuTemp += $ThermalOffsetAll
    if ($ThermalModel -eq 'Linear') {
        # Proporcional à carga, valor cheio em 90%: não coincide com fronteira
        # nenhuma, então não favorece a estratificação por construção.
        $gpuTemp += $ThermalOffsetHigh * ($gl / 90.0)
    } elseif ($gl -ge 75) {
        $gpuTemp += $ThermalOffsetHigh
    }

    $cpuMhz = 3504 * (0.55 + $cl / 100.0 * 0.90)

    # Uptime reinicia: o agregado tem que detectar o reinício no meio do dia.
    $up = $UptimeStartH + $i / 60.0
    if ($RebootAt -ge 0 -and $i -ge $RebootAt) { $up = ($i - $RebootAt) / 60.0 }

    $throttling = ($ThrottleCount -gt 0 -and $ThrottleFrom -ge 0 -and
                   $i -ge $ThrottleFrom -and $i -lt ($ThrottleFrom + $ThrottleCount))

    $sample = [ordered]@{
        v    = 1
        host = $MachineName
        at   = $t0.AddMinutes($i).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
        mode = 'patrol'
        upH  = [math]::Round($up, 2)
    }

    $ok  = New-Object System.Collections.ArrayList
    $gap = [ordered]@{}

    if ($dropping -and $DropProbe -eq 'cpu') {
        $gap['cpu'] = 'sonda indisponivel (fixture)'
    } else {
        [void]$ok.Add('cpu')
        $sample.cpu = [ordered]@{
            util = [int]$cl; perfPct = [int](($cpuMhz / 3504) * 100); mhz = [int]$cpuMhz
            queue = 0; procs = 300 + ($i % 7); threads = 5000 + ($i % 31)
        }
    }

    if ($dropping -and $DropProbe -eq 'mem') {
        $gap['mem'] = 'sonda indisponivel (fixture)'
    } else {
        [void]$ok.Add('mem')
        $sample.mem = [ordered]@{
            availMB = 90000 - ($i % 500); committedMB = 60000 + ($i % 900)
            commitLimitMB = 139071; pagesSec = 0
            poolNonpagedMB = 2600 + [int]($i / 200)      # crescimento lento, de propósito
            poolPagedMB = 4000 + ($i % 40)
            commitPct = [math]::Round(43.0 + ($i % 600) / 100.0, 1)
            usedPct = [math]::Round(30.0 + ($i % 500) / 100.0, 1)
        }
    }

    if ($dropping -and $DropProbe -eq 'sto') {
        $gap['sto'] = 'sonda indisponivel (fixture)'
    } else {
        [void]$ok.Add('sto')
        $sample.sto = [ordered]@{
            vol  = @([ordered]@{ id = 'C:'; freeGB = [math]::Round(400.0 - $i * 0.01, 2); sizeGB = 1862.1; freePct = 21.5 })
            disk = @([ordered]@{ id = '0 C:'; busyPct = [int]([math]::Min(100, $cl / 2)); queue = 0 })
        }
    }

    if ($dropping -and $DropProbe -eq 'gpu') {
        $gap['gpu'] = 'nvidia-smi indisponivel (fixture)'
    } else {
        [void]$ok.Add('gpu')
        $g = [ordered]@{
            idx     = 0
            tempC   = [math]::Round($gpuTemp, 1)
            util    = [int]$gl
            memMB   = 1800 + ($i % 300)
            memTotMB= 10240
            watts   = [math]::Round(30.0 + $gl * 2.9, 2)
            coreMHz = [int](210 + $gl * 17)
            fanPct  = [int]([math]::Max(0, ($gpuTemp - 50) * 2))
        }
        # Modo degradado: sem a máscara, os campos de contenção não existem.
        if (-not $NoThrottleFields) {
            $termico      = ($throttling -or $gpuTemp -gt 83)
            $g.thrMask    = $(if ($termico) { '0x40' } else { '0x1' })
            $g.thr        = $(if ($termico) { @('HwThermalSlowdown') } else { @('GpuIdle') })
            $g.thrThermal = $termico
            $g.thrHard    = $false
        }
        $sample.gpu = @($g)
    }

    $sample.cov = [ordered]@{ ok = @($ok); gap = $gap }

    [void]$lines.Add((ConvertTo-Json -InputObject $sample -Depth 10 -Compress))
}

if ($OutFile) {
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllLines($OutFile, $lines, (New-Object System.Text.UTF8Encoding($false)))
    "fixture: {0}  ({1} amostras)" -f $OutFile, $lines.Count
} else {
    $lines
}
