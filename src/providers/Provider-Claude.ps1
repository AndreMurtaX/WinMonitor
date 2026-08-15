#requires -Version 5.1
<#
    Provedor: API da Anthropic, por HTTP direto.

    HTTP e não SDK porque não existe SDK oficial da Anthropic para PowerShell —
    é o caso em que a chamada crua é a escolha certa, não um atalho.

    QUATRO DETALHES QUE A REFERÊNCIA DA API CORRIGIU, e que eu teria errado de
    memória:

      1. No Opus 5 o raciocínio (thinking) é LIGADO POR PADRÃO. Omitir o campo
         não o desliga — é o contrário do que valia nos modelos anteriores. E
         max_tokens limita raciocínio MAIS resposta somados, então um teto
         apertado trunca o laudo no meio.
      2. budget_tokens foi removido e retorna 400. A profundidade se controla
         por output_config.effort.
      3. temperature, top_p e top_k são REJEITADOS com 400. Não existe "baixar a
         temperatura para reduzir variação" aqui; o controle é o texto da
         instrução.
      4. A resposta pode voltar com HTTP 200 e stop_reason "refusal". Código que
         lê content[0] direto quebra. Confere-se o stop_reason ANTES do conteúdo.
#>
param(
    [Parameter(Mandatory)]$Package,
    [Parameter(Mandatory)]$Config,
    $Secrets,
    [string]$SystemPrompt,
    $Schema
)

$cfg = $Config.laudo.claude

$chave = $null
if ($Secrets -and $Secrets.claude) { $chave = [string]$Secrets.claude.apiKey }
if ([string]::IsNullOrWhiteSpace($chave)) { $chave = $env:ANTHROPIC_API_KEY }
if ([string]::IsNullOrWhiteSpace($chave)) {
    return @{ ok = $false; reason = 'sem chave: preencha claude.apiKey em config\secrets.json ou defina ANTHROPIC_API_KEY' }
}

$corpo = [ordered]@{
    model      = [string]$cfg.model
    max_tokens = [int]$cfg.maxTokens
    system     = $SystemPrompt
    messages   = @(
        @{ role = 'user'; content = (ConvertTo-Json -InputObject $Package -Depth 14) }
    )
}

# effort e format convivem dentro de output_config; effort vazio não é enviado.
$saida = [ordered]@{}
if (-not [string]::IsNullOrWhiteSpace([string]$cfg.effort)) { $saida.effort = [string]$cfg.effort }
if ($Schema) { $saida.format = [ordered]@{ type = 'json_schema'; schema = $Schema } }
if ($saida.Count -gt 0) { $corpo.output_config = $saida }

$json = ConvertTo-Json -InputObject ([pscustomobject]$corpo) -Depth 20

try {
    $resp = Invoke-RestMethod -Method Post -Uri 'https://api.anthropic.com/v1/messages' `
        -Headers @{
            'x-api-key'         = $chave
            'anthropic-version' = '2023-06-01'
        } `
        -ContentType 'application/json' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) `
        -TimeoutSec ([int]$cfg.timeoutSec) `
        -ErrorAction Stop
} catch {
    return @{ ok = $false; reason = "chamada falhou: $($_.Exception.Message)" }
}

<#
    stop_reason ANTES do conteúdo. Uma recusa volta com HTTP 200 e content
    vazio (recusa antes de qualquer saída) ou parcial (recusa no meio) — nos
    dois casos, ler content[0] direto estoura ou entrega meio laudo como se
    fosse inteiro.
#>
if ($resp.stop_reason -eq 'refusal') {
    $cat = 'sem categoria'
    if ($resp.stop_details -and $resp.stop_details.category) { $cat = [string]$resp.stop_details.category }
    return @{ ok = $false; reason = "o modelo recusou a requisição (categoria: $cat)"; raw = $resp }
}

$texto = ($resp.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n"
if ([string]::IsNullOrWhiteSpace($texto)) {
    return @{ ok = $false; reason = "resposta sem texto (stop_reason: $($resp.stop_reason))"; raw = $resp }
}

if ($resp.stop_reason -eq 'max_tokens') {
    # Truncado: o laudo pode estar pela metade e o JSON, inválido.
    return @{ ok = $false; reason = 'resposta truncada em max_tokens; aumente laudo.claude.maxTokens'; raw = $resp }
}

@{
    ok    = $true
    text  = $texto
    model = [string]$resp.model
    usage = $resp.usage
    raw   = $resp
}
