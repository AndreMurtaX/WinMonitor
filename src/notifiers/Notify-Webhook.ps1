#requires -Version 5.1
<#
    Canal: HTTP POST genérico.

    Um webhook cobre quase todo destino que interessa aqui sem escrever um
    provedor para cada um: ntfy.sh, Discord, Slack, Teams, Gotify, ou qualquer
    endpoint próprio. O que muda entre eles é o formato do corpo, e isso é
    configuração, não código.

    bodyTemplate diz onde o texto entra. {{text}} é substituído pelo relatório;
    {{title}} por uma linha de assunto curta. Vazio manda o texto puro, que é o
    que o ntfy espera.

      Discord : {"content": "{{text}}"}
      Slack   : {"text": "{{text}}"}
      ntfy    : (vazio)

    A URL vive em secrets.json, nunca em config.json: ela costuma SER a
    credencial — quem tem a URL do webhook publica na sua sala.

    ESTE CANAL NÃO ESTÁ CONFIGURADO POR PADRÃO, e essa recusa é barulhenta de
    propósito. Um canal de alerta que falha calado é pior que não ter canal: ele
    produz a mesma caixa de entrada vazia de uma máquina saudável.
#>
param(
    [Parameter(Mandatory)][string]$Text,
    [Parameter(Mandatory)]$Report,
    [Parameter(Mandatory)]$Config,
    $Secrets
)

$cfg = $Config.notify.webhook

$url = $null
if ($Secrets -and $Secrets.webhook -and $Secrets.webhook.url) { $url = [string]$Secrets.webhook.url }
if ([string]::IsNullOrWhiteSpace($url)) {
    return @{
        ok     = $false
        detail = 'sem URL: preencha webhook.url em config\secrets.json (copie de secrets.example.json). A URL do webhook é credencial e não entra em config.json.'
    }
}

$titulo = "WinMonitor {0} — {1} — {2}" -f $Report.host, $Report.window, $Report.verdict
if (-not $Report.health.ok) { $titulo = "WinMonitor {0} — COLETA PARADA" -f $Report.host }

$corpo   = $Text
$tipo    = 'text/plain; charset=utf-8'
$modelo  = [string]$cfg.bodyTemplate

if (-not [string]::IsNullOrWhiteSpace($modelo)) {
    <#
        O texto entra num JSON, então precisa ser escapado como string JSON.
        Concatenar cru quebraria no primeiro caractere de aspas ou quebra de
        linha — e o relatório é cheio das duas. ConvertTo-Json de uma string
        devolve a string JÁ com as aspas externas; elas saem porque o modelo
        já as tem.
    #>
    $escapa = {
        param($s)
        $j = ConvertTo-Json -InputObject ([string]$s)
        $j.Substring(1, $j.Length - 2)
    }
    $corpo = $modelo.Replace('{{text}}',  (& $escapa $Text)).
                     Replace('{{title}}', (& $escapa $titulo))
    $tipo  = 'application/json; charset=utf-8'
}

$cabecalhos = @{}
if ($cfg -and $cfg.titleHeader) { $cabecalhos[[string]$cfg.titleHeader] = $titulo }

try {
    $resp = Invoke-WebRequest -Method Post -Uri $url `
        -ContentType $tipo `
        -Headers $cabecalhos `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($corpo)) `
        -TimeoutSec ([int]$(if ($cfg -and $cfg.timeoutSec) { $cfg.timeoutSec } else { 30 })) `
        -UseBasicParsing -ErrorAction Stop

    @{ ok = $true; detail = "HTTP $($resp.StatusCode)" }
} catch {
    <#
        A URL NÃO entra na mensagem de erro. Ela é credencial, e mensagem de
        erro vai parar em log, que é lido por gente e por ferramenta.
    #>
    @{ ok = $false; detail = "POST falhou: $($_.Exception.Message)" }
}
