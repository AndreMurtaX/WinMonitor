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

    OS DOIS MODOS, E POR QUE O SEGUNDO EXISTE
    -----------------------------------------
    O modo padrão usa S4U, que é o certo para um servidor: a ronda roda mesmo
    com ninguém logado. O preço é que REGISTRAR uma tarefa S4U exige elevação —
    e enquanto ninguém abrir um PowerShell como administrador, nada é coletado,
    nenhuma linha-base se forma, e metade das regras fica sem referência para
    sempre. O projeto inteiro fica parado esperando um clique.

    -CurrentUserOnly registra com logon Interactive, que NÃO exige elevação. A
    ronda passa a rodar só enquanto a conta estiver logada. Numa máquina que
    fica logada — que é o caso de um desktop usado como servidor — a diferença
    prática é pequena, e coletar com essa ressalva é muito melhor que não
    coletar. O exame completo da F3 (SMART, WHEA) continua precisando de SYSTEM;
    este modo cobre a ronda barata, que é o que alimenta a linha-base.
#>
[CmdletBinding()]
param(
    [string]$TaskPath = '\WinMonitor\',
    [string]$TaskName = 'Patrol',
    [int]$IntervalMinutes = 1,
    [switch]$CurrentUserOnly,
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'

$full = ($TaskPath.TrimEnd('\')) + '\' + $TaskName

if ($Unregister) {
    <#
        Remove nas DUAS posições: a da pasta e a achatada na raiz. Quem instalou
        sem elevação tem a segunda, e um -Unregister que só olha a primeira
        deixaria a tarefa rodando com a impressão de ter sido removida.

        schtasks em vez de Unregister-ScheduledTask porque este último recusou
        a remoção com "XML fora do intervalo" numa tarefa que ele mesmo havia
        criado — medido.
    #>
    $removeu = $false
    foreach ($alvo in $full, ('\' + $TaskPath.Trim('\') + '-' + $TaskName)) {
        $saida = schtasks /delete /tn $alvo /f 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { "Tarefa removida: $alvo"; $removeu = $true }
    }
    if (-not $removeu) { "Nada a remover: nenhuma tarefa do WinMonitor encontrada." }
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
$conta = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME

$repeat   = New-TimeSpan -Minutes $IntervalMinutes
$forever  = New-TimeSpan -Days 3650

$now = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
          -RepetitionInterval $repeat -RepetitionDuration $forever

<#
    O SEGUNDO GATILHO DEPENDE DO MODO, e a medição foi cirúrgica.

    Testei os três isoladamente, sem elevação, registrando na raiz:

        só o gatilho Once (repetindo)   OK
        Once + AtStartup                NEGADO
        Once + AtLogOn                  OK

    Ou seja: o que exige administrador é o gatilho DE BOOT, e mais nada. Nem a
    tarefa, nem a repetição, nem o principal — só ele.

    Eu tinha lido "acesso negado" no conjunto e concluído que registrar tarefa
    agendada exigia elevação, e repeti isso por várias sessões como se fosse um
    bloqueio do projeto. Era um dos três elementos.

    No modo -CurrentUserOnly a tarefa roda com a conta logada, então rearmar no
    LOGON é o equivalente exato de rearmar no boot — e não pede nada.
#>
$boot = if ($CurrentUserOnly) {
    New-ScheduledTaskTrigger -AtLogOn -User $conta
} else {
    New-ScheduledTaskTrigger -AtStartup
}
$boot.Repetition = $now.Repetition

$conta = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME

$principal = if ($CurrentUserOnly) {
    New-ScheduledTaskPrincipal -UserId $conta -LogonType Interactive -RunLevel Limited
} else {
    New-ScheduledTaskPrincipal -UserId $conta -LogonType S4U -RunLevel Limited
}

$settings = New-ScheduledTaskSettingsSet `
                -MultipleInstances IgnoreNew `
                -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
                -StartWhenAvailable `
                -DontStopOnIdleEnd `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -Priority 7

<#
    O RECUO PARA A RAIZ, e a correção de uma conclusão errada minha.

    Eu escrevi aqui, e cheguei a comitar, que "o que exige elevação é a PASTA".
    Errado, e pela terceira vez o mesmo erro de raciocínio: li um "acesso
    negado" que vinha de um conjunto de três coisas e atribuí a causa à que eu
    tinha em mente. Medido depois, isolando um elemento por vez:

        só o gatilho Once (repetindo)   OK
        Once + AtStartup                NEGADO
        Once + AtLogOn                  OK

    A pasta '\WinMonitor\' registra sem elevação nenhuma — desde que o gatilho
    de boot não esteja junto. Antes disso eu tinha passado sessões inteiras
    dizendo ao dono da máquina que o projeto dependia de um clique de
    administrador. Dependia de trocar um gatilho.

    O recuo para a raiz fica, porque é barato e cobre políticas de grupo que
    restrinjam a criação de pastas — mas ele nunca foi o que faltava aqui.
#>
$usouRaiz = $false
try {
    Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName `
        -Action $action -Trigger @($now, $boot) `
        -Principal $principal -Settings $settings `
        -Description 'WinMonitor — ronda de coleta barata, a cada minuto.' `
        -Force -ErrorAction Stop | Out-Null

    "Tarefa registrada: $full"
    "Intervalo: $IntervalMinutes min · início: 1 min a partir de agora e a cada boot"
    if ($CurrentUserOnly) {
        "Modo: Interactive — roda SÓ com a conta $conta logada. Sem elevação."
    } else {
        "Modo: S4U — roda mesmo sem ninguém logado."
    }
    "Para conferir:  Get-ScheduledTask -TaskPath '$TaskPath'"
    "Para remover:   .\tools\Register-PatrolTask.ps1 -Unregister"
} catch {
    $msg = $_.Exception.Message

    <#
        Recuo para a raiz: o nome achatado ('WinMonitor-Patrol') evita a criação
        de pasta, que é a única parte que pede elevação.
    #>
    if ($msg -match 'denied|negado|0x80070005') {
        $nomePlano = ($TaskPath.Trim('\') + '-' + $TaskName)
        try {
            Register-ScheduledTask -TaskPath '\' -TaskName $nomePlano `
                -Action $action -Trigger @($now, $boot) `
                -Principal $principal -Settings $settings `
                -Description 'WinMonitor — ronda de coleta barata, a cada minuto.' `
                -Force -ErrorAction Stop | Out-Null

            $usouRaiz = $true
            "Tarefa registrada: \$nomePlano"
            "  (a pasta '$TaskPath' exigiria elevação; a tarefa na raiz não exige, e faz o mesmo)"
            "Intervalo: $IntervalMinutes min · início: 1 min a partir de agora e a cada boot"
            if ($CurrentUserOnly) {
                "Modo: Interactive — roda SÓ com a conta $conta logada. Sem elevação."
            } else {
                "Modo: S4U — roda mesmo sem ninguém logado."
            }
            "Para conferir:  schtasks /query /tn `"\$nomePlano`""
            "Para remover:   .\tools\Register-PatrolTask.ps1 -Unregister"
        } catch {
            Write-Error "acesso negado também na raiz: $($_.Exception.Message)"
        }
    }

    if (-not $usouRaiz -and -not $CurrentUserOnly -and $msg -match 'denied|negado|0x80070005') {
        Write-Error @"
Acesso negado ao registrar a tarefa: $msg

O modo padrão usa S4U (roda sem login) e isso exige elevação. Duas saídas:

  1. Sem elevação, agora — a ronda roda enquanto esta conta estiver logada:
       .\tools\Register-PatrolTask.ps1 -CurrentUserOnly

  2. Com elevação, para rodar mesmo sem ninguém logado:
       Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$PSCommandPath'

A ronda em si nunca precisou de elevação; só o registro desta tarefa precisa.
"@
    } else {
        Write-Error "Falhou o registro da tarefa: $msg"
    }
}
