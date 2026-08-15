#requires -Version 5.1
<#
    Registra a ronda como tarefa agendada.

    Escolha deliberada: um processo novo a cada minuto, em vez de um laço
    residente. O laço é mais eficiente, mas se morrer fica morto até alguém
    perceber. A tarefa agendada se cura sozinha — se uma execução falhar, a do
    minuto seguinte roda do mesmo jeito. Num monitor, auto-recuperação vale mais
    que eficiência.

    Roda com prioridade 7 (abaixo do normal) para ceder passagem ao trabalho de
    verdade da máquina, e com principal S4U: executa sem login e sem guardar
    senha em lugar nenhum.
#>
[CmdletBinding()]
param(
    [string]$TaskPath = '\WinMonitor\',
    [string]$TaskName = 'Patrol',
    [int]$IntervalMinutes = 1,
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'

$full = ($TaskPath.TrimEnd('\')) + '\' + $TaskName

if ($Unregister) {
    try {
        Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        "Tarefa removida: $full"
    } catch {
        "Nada a remover em ${full}: $($_.Exception.Message)"
    }
    return
}

$root   = Split-Path -Parent $PSScriptRoot
$patrol = Join-Path $root 'src\Invoke-Patrol.ps1'

if (-not (Test-Path -LiteralPath $patrol)) {
    throw "não encontrei a ronda em $patrol"
}

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$action = New-ScheduledTaskAction -Execute $psExe -Argument (
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $patrol
)

<#
    Dois gatilhos: um começa agora, o outro no boot, e ambos repetem.
    New-ScheduledTaskTrigger só aceita repetição em gatilho -Once, então a
    repetição é copiada para o gatilho de inicialização.

    A duração NÃO usa [TimeSpan]::MaxValue: isso gera P99999999DT23H59M59S, que
    o Agendador de Tarefas recusa como fora de intervalo. Dez anos é
    efetivamente sem fim, e o gatilho de boot rearma tudo a cada reinício.
#>
$repeat   = New-TimeSpan -Minutes $IntervalMinutes
$forever  = New-TimeSpan -Days 3650

$now = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
          -RepetitionInterval $repeat -RepetitionDuration $forever

$boot = New-ScheduledTaskTrigger -AtStartup
$boot.Repetition = $now.Repetition

$principal = New-ScheduledTaskPrincipal `
                -UserId ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME) `
                -LogonType S4U -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
                -MultipleInstances IgnoreNew `
                -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
                -StartWhenAvailable `
                -DontStopOnIdleEnd `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -Priority 7

try {
    Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName `
        -Action $action -Trigger @($now, $boot) `
        -Principal $principal -Settings $settings `
        -Description 'WinMonitor — ronda de coleta barata, a cada minuto.' `
        -Force -ErrorAction Stop | Out-Null

    "Tarefa registrada: $full"
    "Intervalo: $IntervalMinutes min · início: 1 min a partir de agora e a cada boot"
    "Para conferir:  Get-ScheduledTask -TaskPath '$TaskPath'"
    "Para remover:   .\tools\Register-PatrolTask.ps1 -Unregister"
} catch {
    Write-Error @"
Falhou o registro da tarefa: $($_.Exception.Message)

Se a mensagem for de acesso negado, rode este script numa janela do PowerShell
aberta como administrador. O registro precisa de elevação; a ronda em si, não.
"@
}
