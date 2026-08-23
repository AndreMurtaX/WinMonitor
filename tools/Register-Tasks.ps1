#requires -Version 5.1
<#
    Registra as TRES tarefas do WinMonitor de uma vez.

    POR QUE ELE EXISTE
    ------------------
    Medido em 22/08, com oito dias de maquina monitorada:

        patrol     8 dias, vivo, gravando a cada minuto
        rollup     15/08, 16/08     <- parou seis dias atras
        findings   15/08, 16/08
        report     15/08, 16/08
        exam       15/08, 16/08

    A ronda tinha tarefa agendada. A cadeia que TRANSFORMA aquilo em diagnostico
    nao tinha nenhuma: ela rodou nos dois primeiros dias porque alguem a invocou
    a mao, e parou quando essa pessoa parou.

    O que a maquina tinha era um gravador de caixa-preta excelente com ninguem
    lendo a fita. Coletar nao e monitorar.

    OS HORARIOS, E POR QUE ELES NAO SAO ARBITRARIOS
    -----------------------------------------------
    O exame grava o arquivo do dia CORRENTE. A cadeia diaria fecha o dia
    ANTERIOR. Rodar os dois juntos depois da meia-noite deixaria todo dia sem
    exame, e as duas regras de falha de hardware cairiam em "sem dado" para
    sempre - em silencio, com o veredito saindo 'normal'.

        23:50  exame     ainda dentro do dia que ele descreve
        00:20  cadeia    fecha o dia anterior, cujo exame ja existe

    A folga de 30 min existe porque o exame le o log de eventos, que e a unica
    sonda deste projeto sem prazo confiavel: Get-WinEvent nao aceita tempo
    limite, e quem impoe prazo de verdade e o ExecutionTimeLimit da tarefa.

    O QUE ELE NAO FAZ, dito em vez de negado: nao cria bot, nao pede senha e nao
    guarda credencial. O token do Telegram continua em ~\.claude\, fora do
    repositorio, e este script nem o le.

      .\tools\Register-Tasks.ps1            registra as tres
      .\tools\Register-Tasks.ps1 -Simular   imprime o plano, nao registra nada
      .\tools\Register-Tasks.ps1 -Unregister
#>
[CmdletBinding()]
param(
    [string]$TaskPath = '\WinMonitor\',
    [switch]$Elevado,
    [switch]$Simular,
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'

$root  = Split-Path -Parent $PSScriptRoot
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$conta = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME

<#
    As duas tarefas diarias. A ronda tem script proprio, porque o desenho dela
    e diferente: repeticao por minuto em vez de disparo diario.
#>
$diarias = @(
    @{ nome = 'Exam';   script = 'src\Invoke-Exam.ps1';   hora = '23:50'; limite = 20
       porque = 'le o log de eventos e os contadores de disco; grava o arquivo do DIA CORRENTE' }
    @{ nome = 'Daily';  script = 'src\Invoke-Diario.ps1'; hora = '00:20'; limite = 30
       porque = 'agrega, avalia as regras e entrega o relatorio do dia ANTERIOR' }
)

if ($Unregister) {
    foreach ($t in $diarias) {
        $alvo = ($TaskPath.TrimEnd('\')) + '\' + $t.nome
        $null = schtasks /delete /tn $alvo /f 2>&1
        if ($LASTEXITCODE -eq 0) { "Removida: $alvo" } else { "Nada a remover: $alvo" }
    }
    & (Join-Path $PSScriptRoot 'Register-PatrolTask.ps1') -Unregister
    return
}

$nivel = if ($Elevado) { 'Highest' } else { 'Limited' }

if ($Simular) {
    "PLANO (nada foi registrado - -Simular)"
    ""
    "1. Ronda: delegada a Register-PatrolTask.ps1"
    & (Join-Path $PSScriptRoot 'Register-PatrolTask.ps1') -Simular -Elevado:$Elevado |
        ForEach-Object { "   $_" }
    ""
    foreach ($t in $diarias) {
        $i = [array]::IndexOf($diarias, $t) + 2
        "$i. $($t.nome) - todo dia as $($t.hora)"
        "   executa : $($t.script)"
        "   porque  : $($t.porque)"
        "   teto    : $($t.limite) min  ·  nivel $nivel  ·  conta $conta"
        ""
    }
    "Os horarios NAO sao intercambiaveis: o exame grava o dia corrente e a cadeia"
    "fecha o dia anterior. Invertidos, todo dia ficaria sem exame e as regras de"
    "falha de hardware cairiam em 'sem dado' em silencio."
    return
}

<#
    A RONDA PRIMEIRO, porque ela e quem alimenta as outras duas. Se o registro
    dela falhar, registrar as diarias produziria tarefas que rodam sobre dado
    que ninguem esta coletando.
#>
"### ronda ###"
& (Join-Path $PSScriptRoot 'Register-PatrolTask.ps1') -Elevado:$Elevado

foreach ($t in $diarias) {
    "### $($t.nome) ###"
    $alvo = Join-Path $root $t.script
    if (-not (Test-Path -LiteralPath $alvo)) {
        Write-Error "nao encontrei $($t.script) em $alvo"
        continue
    }

    $acao = New-ScheduledTaskAction -Execute $psExe -Argument (
        '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $alvo
    )
    $gatilho = New-ScheduledTaskTrigger -Daily -At $t.hora

    <#
        StartWhenAvailable: maquina desligada as 23:50 roda o exame quando
        voltar. Sem isso, um dia desligado vira um dia sem exame para sempre - e
        a lacuna apareceria como "sem dado" sem ninguem saber por que.

        Prioridade 7 pelo mesmo motivo da ronda: o monitor cede passagem ao
        trabalho de verdade da maquina.
    #>
    $opcoes = New-ScheduledTaskSettingsSet `
                  -MultipleInstances IgnoreNew `
                  -ExecutionTimeLimit (New-TimeSpan -Minutes $t.limite) `
                  -StartWhenAvailable `
                  -DontStopOnIdleEnd `
                  -AllowStartIfOnBatteries `
                  -DontStopIfGoingOnBatteries `
                  -Priority 7

    $principal = New-ScheduledTaskPrincipal -UserId $conta -LogonType S4U -RunLevel $nivel

    Register-ScheduledTask -TaskPath $TaskPath -TaskName $t.nome `
        -Action $acao -Trigger $gatilho -Principal $principal -Settings $opcoes `
        -Description "WinMonitor - $($t.porque)" -Force -ErrorAction Stop | Out-Null

    "Registrada: $($TaskPath.TrimEnd('\'))\$($t.nome) - todo dia as $($t.hora), teto $($t.limite) min"
}

""
"Para conferir:  schtasks /query /tn ""\WinMonitor\Daily"""
"Para remover:   .\tools\Register-Tasks.ps1 -Unregister"
