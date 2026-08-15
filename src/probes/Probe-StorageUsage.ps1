#requires -Version 5.1
<#
    Sonda de uso de armazenamento.

    Coleta espaço por volume e ocupação por disco físico. Latência de I/O ficou
    de fora de propósito: a classe CIM formatada tipa AvgDisksecPerRead como
    inteiro, e latências de sub-segundo podem truncar para zero. Latência entra
    no exame (F3), com leitura de contador feita direito, em vez de entrar aqui
    valendo sempre zero e parecendo um disco perfeito.

    Volumes removíveis somem sem aviso (pendrive, HD externo). Desaparecer não é
    erro: a sonda simplesmente deixa de reportar o volume.
#>
param(
    $Facts,
    [int]$TimeoutSec = 8
)

$warn = @()

try {
    $volumes = @()
    try {
        $logical = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' `
                      -OperationTimeoutSec $TimeoutSec -ErrorAction Stop
        foreach ($d in $logical) {
            $size = [double]$d.Size
            $v = [ordered]@{
                id     = [string]$d.DeviceID
                freeGB = [math]::Round($d.FreeSpace / 1GB, 1)
                sizeGB = [math]::Round($size / 1GB, 1)
            }
            if ($size -gt 0) {
                $v.freePct = [math]::Round(100.0 * $d.FreeSpace / $size, 1)
            }
            $volumes += ,([pscustomobject]$v)
        }
    } catch {
        $warn += "volumes: $($_.Exception.Message)"
    }

    $disks = @()
    try {
        $perf = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk `
                   -OperationTimeoutSec $TimeoutSec -ErrorAction Stop
        foreach ($d in $perf) {
            if ($d.Name -eq '_Total') { continue }
            $disks += ,([pscustomobject][ordered]@{
                id      = [string]$d.Name          # ex.: "0 C:"
                busyPct = [int](100 - [int]$d.PercentIdleTime)
                queue   = [int]$d.CurrentDiskQueueLength
            })
        }
    } catch {
        $warn += "discos: $($_.Exception.Message)"
    }

    if ($volumes.Count -eq 0 -and $disks.Count -eq 0) {
        return @{ ok = $false; reason = ($warn -join ' | ') }
    }

    $reason = $null
    if ($warn.Count -gt 0) { $reason = ($warn -join ' | ') }

    @{
        ok     = $true
        reason = $reason
        data   = [ordered]@{ vol = $volumes; disk = $disks }
    }

} catch {
    @{ ok = $false; reason = $_.Exception.Message }
}
