#requires -Version 5.1
<#
    Sonda de GPU NVIDIA via nvidia-smi.

    É a sonda mais valiosa do conjunto e a mais barata: nvidia-smi acompanha o
    driver, não exige privilégio, e entrega o motivo pelo qual a placa se
    conteve. Isso não é inferir problema térmico a partir da temperatura — é a
    própria placa declarando que reduziu clock por calor.

    A chamada tem prazo máximo porque o caso mais interessante de detectar —
    driver de vídeo travado — é justamente o caso em que nvidia-smi pendura.
#>
param(
    $Facts,
    [int]$TimeoutSec = 8
)

$FIELDS_FULL = @(
    'index', 'name', 'temperature.gpu', 'utilization.gpu', 'utilization.memory',
    'memory.used', 'memory.total', 'power.draw', 'clocks.current.graphics',
    'clocks.current.memory', 'fan.speed', 'clocks_throttle_reasons.active'
)

# Conjunto reduzido para quando o driver não suporta algum campo do conjunto
# completo. Perder detalhe é aceitável; perder a sonda inteira não é.
$FIELDS_MIN = @(
    'index', 'name', 'temperature.gpu', 'utilization.gpu', 'memory.used', 'memory.total'
)

<#
    Máscara de motivos de contenção. Os benignos são maioria e disparariam
    alarme falso a cada minuto se "diferente de zero" fosse tratado como
    defeito: GpuIdle sozinho significa placa ociosa, não placa doente.
#>
$REASON_BITS = @(
    @{ bit = 1;   name = 'GpuIdle';             class = 'benign'  }
    @{ bit = 2;   name = 'AppClocksSetting';    class = 'benign'  }
    @{ bit = 4;   name = 'SwPowerCap';          class = 'benign'  }
    @{ bit = 8;   name = 'HwSlowdown';          class = 'hard'    }
    @{ bit = 16;  name = 'SyncBoost';           class = 'benign'  }
    @{ bit = 32;  name = 'SwThermalSlowdown';   class = 'thermal' }
    @{ bit = 64;  name = 'HwThermalSlowdown';   class = 'thermal' }
    @{ bit = 128; name = 'HwPowerBrake';        class = 'hard'    }
    @{ bit = 256; name = 'DisplayClockSetting'; class = 'benign'  }
)

function ConvertTo-Num {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    # nvidia-smi devolve '[N/A]' e '[Not Supported]' para campos que a placa
    # não expõe. Ausente não é zero.
    if ($t -like '`[*`]') { return $null }

    <#
        SEMPRE cultura invariante. nvidia-smi emite '36.45' com ponto decimal,
        e TryParse sensível à cultura num Windows pt-BR lê isso como 3645 —
        trata o ponto como separador de milhar e *tem sucesso*. O erro não
        aparece como falha: aparece como 36 W virando 3645 W na série histórica.
    #>
    $n = 0.0
    if ([double]::TryParse($t,
                           [System.Globalization.NumberStyles]::Float,
                           [System.Globalization.CultureInfo]::InvariantCulture,
                           [ref]$n)) {
        return $n
    }
    return $null
}

function Invoke-Smi {
    param([string[]]$Fields, [int]$TimeoutMs)
    # Não usar $args aqui: é variável automática do PowerShell.
    $smiArgs = '--query-gpu={0} --format=csv,noheader,nounits' -f ($Fields -join ',')
    $r = Invoke-WMProcess -FilePath 'nvidia-smi' -Arguments $smiArgs -TimeoutMs $TimeoutMs
    if ($r.ExitCode -ne 0) {
        throw ("nvidia-smi saiu com código {0}: {1}" -f $r.ExitCode, $r.StdErr.Trim())
    }
    $r.StdOut
}

try {
    $timeoutMs = $TimeoutSec * 1000
    $fields    = $FIELDS_FULL
    $warn      = $null
    $raw       = $null

    try {
        $raw = Invoke-Smi -Fields $FIELDS_FULL -TimeoutMs $timeoutMs
    } catch {
        # Degrada em vez de sumir: tenta o conjunto reduzido e declara a perda.
        $warn   = "conjunto completo recusado, usando reduzido: $($_.Exception.Message)"
        $fields = $FIELDS_MIN
        $raw    = Invoke-Smi -Fields $FIELDS_MIN -TimeoutMs $timeoutMs
    }

    $gpus = @()
    foreach ($line in ($raw -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $cols = $line -split ','
        $map  = @{}
        for ($i = 0; $i -lt $fields.Count -and $i -lt $cols.Count; $i++) {
            $map[$fields[$i]] = $cols[$i].Trim()
        }

        $g = [ordered]@{
            idx     = [int](ConvertTo-Num $map['index'])
            tempC   = ConvertTo-Num $map['temperature.gpu']
            util    = ConvertTo-Num $map['utilization.gpu']
            memUtil = ConvertTo-Num $map['utilization.memory']
            memMB   = ConvertTo-Num $map['memory.used']
            memTotMB= ConvertTo-Num $map['memory.total']
            watts   = ConvertTo-Num $map['power.draw']
            coreMHz = ConvertTo-Num $map['clocks.current.graphics']
            memMHz  = ConvertTo-Num $map['clocks.current.memory']
            fanPct  = ConvertTo-Num $map['fan.speed']
        }

        if ($g.memMB -ne $null -and $g.memTotMB -gt 0) {
            $g.memPct = [math]::Round(100.0 * $g.memMB / $g.memTotMB, 1)
        }

        # Decodificação da máscara de contenção.
        $rawMask = $map['clocks_throttle_reasons.active']
        if (-not [string]::IsNullOrWhiteSpace($rawMask) -and $rawMask -notlike '`[*`]') {
            try {
                $hex  = $rawMask.Trim()
                if ($hex.StartsWith('0x')) { $hex = $hex.Substring(2) }
                $mask = [Convert]::ToUInt64($hex, 16)

                $names   = @()
                $thermal = $false
                $hard    = $false
                foreach ($b in $REASON_BITS) {
                    if (($mask -band $b.bit) -ne 0) {
                        $names += $b.name
                        if ($b.class -eq 'thermal') { $thermal = $true }
                        if ($b.class -eq 'hard')    { $hard    = $true }
                    }
                }

                $g.thrMask    = '0x{0:X}' -f $mask
                $g.thr        = $names
                $g.thrThermal = $thermal
                $g.thrHard    = $hard
            } catch {
                $warn = "máscara de contenção ilegível ('$rawMask'): $($_.Exception.Message)"
            }
        }

        $gpus += ,([pscustomobject]$g)
    }

    if ($gpus.Count -eq 0) {
        return @{ ok = $false; reason = 'nvidia-smi não retornou nenhuma GPU' }
    }

    # Array direto: a amostra fica sample.gpu[0], não sample.gpu.gpu[0].
    @{ ok = $true; reason = $warn; data = @($gpus) }

} catch {
    @{ ok = $false; reason = $_.Exception.Message }
}
