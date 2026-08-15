#requires -Version 5.1
<#
    WinMonitor — módulo comum.

    Regra que vale para tudo aqui dentro: nada nesta camada pode derrubar a coleta.
    Falha de sonda vira lacuna declarada, nunca exceção que sobe. Um monitor que
    morre é pior que um monitor que registra um buraco, porque o buraco é visível.
#>

$script:Root   = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:Config = $null
$script:Facts  = $null

# ---------------------------------------------------------------- caminhos ---

function Get-WMRoot { $script:Root }

function Get-WMPath {
    param([Parameter(Mandatory)][string]$Relative)
    Join-Path -Path $script:Root -ChildPath $Relative
}

function Confirm-WMDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    $Path
}

# ------------------------------------------------------------ configuração ---

# Mescla recursiva de objetos de configuração. O override vence nas folhas.
function Merge-WMObject {
    param($Base, $Override)
    if ($null -eq $Override) { return $Base }
    if ($null -eq $Base)     { return $Override }
    if ($Override -isnot [pscustomobject]) { return $Override }

    $out = $Base.PSObject.Copy()
    foreach ($prop in $Override.PSObject.Properties) {
        if ($out.PSObject.Properties.Name -contains $prop.Name) {
            $out.$($prop.Name) = Merge-WMObject -Base $out.$($prop.Name) -Override $prop.Value
        } else {
            Add-Member -InputObject $out -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
        }
    }
    $out
}

<#
    Configuração em duas camadas:
      config\config.json        versionado, genérico, sem nada desta máquina
      config\config.local.json  fora do repositório, ajustes locais opcionais

    A separação existe para o repositório poder ser público sem carregar junto
    a descrição da máquina de quem o usa.
#>
function Get-WMConfig {
    param([switch]$Force)
    if ($script:Config -and -not $Force) { return $script:Config }

    $base = Get-WMPath 'config\config.json'
    $cfg  = Get-Content -LiteralPath $base -Raw -Encoding UTF8 | ConvertFrom-Json

    $local = Get-WMPath 'config\config.local.json'
    if (Test-Path -LiteralPath $local) {
        try {
            $ovr = Get-Content -LiteralPath $local -Raw -Encoding UTF8 | ConvertFrom-Json
            $cfg = Merge-WMObject -Base $cfg -Override $ovr
        } catch {
            Write-WMLog -Level warn -Source 'config' -Message "config.local.json ignorado: $($_.Exception.Message)"
        }
    }

    $script:Config = $cfg
    $cfg
}

<#
    Segredos ficam num arquivo próprio, sempre fora do repositório. Devolve
    $null quando não existe — quem chama decide se isso é fatal ou não.
#>
function Get-WMSecrets {
    $p = Get-WMPath 'config\secrets.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-WMLog -Level error -Source 'config' -Message "secrets.json ilegível: $($_.Exception.Message)"
        return $null
    }
}

# ------------------------------------------------------------------- tempo ---

<#
    ISO 8601 com deslocamento de fuso. Sem fuso, uma série histórica mente duas
    vezes por ano no horário de verão.

    CULTURA INVARIANTE, sempre. Sem ela, 'yyyy' usa o CALENDÁRIO da cultura
    corrente: numa máquina th-TH o ano sai budista e o carimbo vira
    2569-08-15, e num Windows ar-SA sai o calendário Hijri. O padrão do formato
    continua casando, então nada reclama — a série histórica simplesmente passa
    a ser de outro planeta.
#>
function Get-WMTimestamp {
    param([datetime]$When = (Get-Date))
    $When.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz', [System.Globalization.CultureInfo]::InvariantCulture)
}

# Identificador de dia (nome de arquivo diário). Mesmo motivo: calendário fixo.
function Get-WMDayId {
    param([datetime]$When = (Get-Date))
    $When.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
}

# --------------------------------------------------------------------- log ---

function Write-WMLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('info', 'warn', 'error')][string]$Level = 'info',
        [string]$Source = 'winmonitor'
    )
    try {
        $dir  = Confirm-WMDirectory (Get-WMPath 'logs')
        $file = Join-Path $dir ('{0}.log' -f (Get-WMDayId))
        $line = '{0} [{1}] {2}: {3}' -f (Get-WMTimestamp), $Level.ToUpper(), $Source, $Message
        $enc  = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($file, $line + [Environment]::NewLine, $enc)
    } catch {
        # Log que falha não pode derrubar coleta. Engole e segue.
    }
}

# ---------------------------------------------------------------- escrita ----

# Anexa uma linha JSON. UTF-8 sem BOM: o BOM quebra o parse da primeira linha
# de um JSONL em parsers estritos.
function Write-WMJsonLine {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object,
        [int]$Depth = 12
    )
    Confirm-WMDirectory (Split-Path -Parent $Path) | Out-Null
    $line = ConvertTo-Json -InputObject $Object -Depth $Depth -Compress
    $enc  = New-Object System.Text.UTF8Encoding($false)
    for ($i = 0; $i -lt 4; $i++) {
        try {
            [System.IO.File]::AppendAllText($Path, $line + "`r`n", $enc)
            return $true
        } catch {
            Start-Sleep -Milliseconds (40 * ($i + 1))
        }
    }
    Write-WMLog -Level error -Source 'write' -Message "não consegui anexar em $Path"
    return $false
}

# --------------------------------------------------- processo externo ------

<#
    Chama um executável com prazo máximo. Necessário porque o caso que mais
    interessa detectar — driver de vídeo travado — é exatamente o caso em que
    nvidia-smi pendura. Ler de forma assíncrona antes do WaitForExit evita o
    impasse clássico de buffer cheio.
#>
function Invoke-WMProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [int]$TimeoutMs = 5000
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()

    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()

    if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill() } catch { }
        throw ("tempo esgotado após {0} ms: {1}" -f $TimeoutMs, $FilePath)
    }

    [pscustomobject]@{
        ExitCode = $p.ExitCode
        StdOut   = $outTask.Result
        StdErr   = $errTask.Result
    }
}

# ------------------------------------------------------- fatos da máquina ---

<#
    Fatos estáticos (nome da CPU, clock base, total de RAM, discos). Consultar
    Win32_Processor custa centenas de milissegundos, caro demais para repetir a
    cada 60 s — então coleta-se uma vez e lê-se do disco depois.
#>
function Get-WMHostFacts {
    param([switch]$Refresh)

    if ($script:Facts -and -not $Refresh) { return $script:Facts }

    $p = Get-WMPath 'data\host.json'
    if ((Test-Path -LiteralPath $p) -and -not $Refresh) {
        try {
            $script:Facts = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            return $script:Facts
        } catch {
            Write-WMLog -Level warn -Source 'facts' -Message "host.json ilegível, recoletando: $($_.Exception.Message)"
        }
    }

    $facts = [ordered]@{
        collectedAt = Get-WMTimestamp
        host        = $env:COMPUTERNAME
    }

    try {
        $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop
        $facts.os        = $os.Caption
        $facts.osBuild   = $os.BuildNumber
        $facts.memTotalMB = [int]($os.TotalVisibleMemorySize / 1KB)
    } catch {
        Write-WMLog -Level warn -Source 'facts' -Message "Win32_OperatingSystem: $($_.Exception.Message)"
    }

    try {
        $cpu = @(Get-CimInstance Win32_Processor -OperationTimeoutSec 10 -ErrorAction Stop)[0]
        $facts.cpuName     = $cpu.Name.Trim()
        $facts.cpuCores    = [int]$cpu.NumberOfCores
        $facts.cpuThreads  = [int]$cpu.NumberOfLogicalProcessors
        $facts.cpuBaseMHz  = [int]$cpu.MaxClockSpeed
    } catch {
        Write-WMLog -Level warn -Source 'facts' -Message "Win32_Processor: $($_.Exception.Message)"
    }

    try {
        $facts.disks = @(
            Get-PhysicalDisk -ErrorAction Stop | Sort-Object DeviceId | ForEach-Object {
                [ordered]@{
                    id     = [string]$_.DeviceId
                    name   = $_.FriendlyName
                    media  = [string]$_.MediaType
                    bus    = [string]$_.BusType
                    sizeGB = [int]($_.Size / 1GB)
                }
            }
        )
    } catch {
        Write-WMLog -Level warn -Source 'facts' -Message "Get-PhysicalDisk: $($_.Exception.Message)"
    }

    $script:Facts = [pscustomobject]$facts
    try {
        Confirm-WMDirectory (Split-Path -Parent $p) | Out-Null
        $json = ConvertTo-Json -InputObject $script:Facts -Depth 8
        [System.IO.File]::WriteAllText($p, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-WMLog -Level warn -Source 'facts' -Message "não gravei host.json: $($_.Exception.Message)"
    }

    $script:Facts
}

# -------------------------------------------------------- execução de sonda --

<#
    Invólucro padrão de sonda. Toda sonda devolve @{ ok = $true/$false;
    reason = '...'; data = @{...} } e esta função a converte no envelope
    canônico, cronometrando e capturando qualquer explosão.

    Estados: ok | partial | unavailable. "partial" existe porque uma sonda pode
    entregar metade do que sabe — e metade declarada é diferente de tudo certo.
#>
function Invoke-WMProbe {
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Arguments = @{}
    )

    $sw     = [System.Diagnostics.Stopwatch]::StartNew()
    $script = Get-WMPath ('src\probes\Probe-{0}.ps1' -f $Name)
    $res    = [ordered]@{ probe = $Name; state = 'unavailable'; reason = $null; ms = 0; data = $null }

    if (-not (Test-Path -LiteralPath $script)) {
        $res.reason = 'sonda não encontrada em src\probes'
        $res.ms     = [int]$sw.ElapsedMilliseconds
        return $res
    }

    try {
        $out = & $script @Arguments
        if ($null -eq $out) {
            $res.reason = 'sonda não retornou nada'
        } elseif ($out.ok) {
            $res.data  = $out.data
            $res.state = 'ok'
            if ($out.reason) {
                $res.state  = 'partial'
                $res.reason = [string]$out.reason
            }
        } else {
            $res.reason = [string]$out.reason
        }
    } catch {
        $res.reason = $_.Exception.Message
    }

    $res.ms = [int]$sw.ElapsedMilliseconds
    $res
}

# ---------------------------------------------------------------- retenção ---

# Retenção aplicada na escrita, não numa faxina posterior que pode nunca rodar.
# O monitor não pode ser a causa do disco cheio.
function Invoke-WMRetention {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][int]$Days,
        [string]$Filter = '*.jsonl'
    )
    if ($Days -le 0) { return 0 }
    if (-not (Test-Path -LiteralPath $Directory)) { return 0 }
    $cut = (Get-Date).AddDays(-$Days)
    $n = 0
    try {
        Get-ChildItem -LiteralPath $Directory -Filter $Filter -File -ErrorAction Stop |
            Where-Object { $_.LastWriteTime -lt $cut } |
            ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $n++ } catch { }
            }
    } catch { }
    $n
}

Export-ModuleMember -Function `
    Get-WMRoot, Get-WMPath, Confirm-WMDirectory, Get-WMConfig, Get-WMSecrets,
    Get-WMTimestamp, Get-WMDayId, Write-WMLog, Write-WMJsonLine, Invoke-WMProcess,
    Get-WMHostFacts, Invoke-WMProbe, Invoke-WMRetention
