#requires -Version 5.1
<#
    Canal: notificação nativa do Windows.

    POR QUE ELE EXISTE
    ------------------
    O canal de arquivo grava o relatório e não avisa ninguém; o de webhook avisa
    de longe e precisa de uma URL que é credencial. Entre os dois faltava o
    óbvio: a máquina avisando quem está sentado nela, sem conta, sem credencial,
    sem mandar dado nenhum para fora.

    Eu tratei "canal de notificação" como decisão do dono por várias sessões.
    Não era: a decisão é o canal REMOTO. Este aqui não tinha o que decidir e
    devia estar pronto desde o primeiro dia.

    O QUE ELE NÃO É
    ---------------
    Não substitui canal remoto. Notificação nativa aparece para quem está
    logado na máquina; se você estiver longe, ela some na Central de Ações e
    espera. Para um servidor que se acompanha de fora, o webhook continua sendo
    a resposta — este é o piso, não o teto.

    A MENSAGEM É CURTA DE PROPÓSITO
    -------------------------------
    Notificação não é relatório. Ela diz o veredito, quantos achados e se a
    cobertura está incompleta; o texto inteiro fica no arquivo, e o caminho vai
    na própria notificação para quem quiser ler.
#>
param(
    [Parameter(Mandatory)][string]$Text,
    [Parameter(Mandatory)]$Report,
    [Parameter(Mandatory)]$Config,
    $Secrets
)

try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
} catch {
    return @{ ok = $false; detail = "API de notificação do Windows indisponível: $($_.Exception.Message)" }
}

<#
    O identificador precisa ser de um aplicativo com atalho no menu Iniciar,
    senão o Windows descarta a notificação em silêncio. O do PowerShell existe
    em toda instalação e é o caminho honesto: a notificação vem de onde o
    monitor de fato roda.
#>
$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
if ($Config.notify.toast -and $Config.notify.toast.appId) { $appId = [string]$Config.notify.toast.appId }

$achados = @($Report.findings).Count
$titulo  = "WinMonitor — {0}" -f $Report.verdict

if (-not $Report.health.ok) {
    $titulo = 'WinMonitor — A COLETA PAROU'
}

$linhas = New-Object System.Collections.ArrayList
[void]$linhas.Add(("{0} achado(s) · cobertura {1}" -f $achados, $(if ($Report.coverageComplete) { 'completa' } else { 'INCOMPLETA' })))
[void]$linhas.Add(("motivo: {0}" -f $Report.decision.reason))
if (-not $Report.health.ok) { [void]$linhas.Add([string]$Report.health.reason) }

<#
    Escapar antes de montar o XML. Nome de disco, caminho de métrica e razão de
    lacuna carregam '&' e '<' com naturalidade, e um deles quebraria o
    documento — a notificação sumiria sem erro, que é o pior desfecho para um
    canal de aviso.
#>
function Protege { param([string]$s) [System.Security.SecurityElement]::Escape($s) }

$corpo = ($linhas | Where-Object { $_ } | ForEach-Object { Protege $_ }) -join "`n"

$xml = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$(Protege $titulo)</text>
      <text>$corpo</text>
    </binding>
  </visual>
</toast>
"@

try {
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    $notificacao = New-Object Windows.UI.Notifications.ToastNotification $doc
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($notificacao)
    @{ ok = $true; detail = 'notificação nativa apresentada' }
} catch {
    @{ ok = $false; detail = "falhou ao notificar: $($_.Exception.Message)" }
}
