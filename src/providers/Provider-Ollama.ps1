#requires -Version 5.1
<#
    Provedor: Ollama local.

    Existe por dois motivos. Primeiro, permite testar o encanamento inteiro do
    parecer sem custo e sem chave. Segundo, é a saída para quem não quer que o
    dado da máquina saia dela.

    A RESSALVA QUE PRECISA FICAR REGISTRADA: rodar o modelo local NESTA máquina
    faz o monitor competir por VRAM com exatamente a carga que ele deveria estar
    medindo. Pior, se a GPU estiver com problema térmico, o cérebro do monitor
    está rodando na peça doente. Para desenvolvimento e teste, ótimo; para o
    laudo de produção de um servidor que hospeda agentes de IA, o provedor
    remoto é a escolha mais defensável.
#>
param(
    [Parameter(Mandatory)]$Package,
    [Parameter(Mandatory)]$Config,
    $Secrets,
    [string]$SystemPrompt,
    $Schema
)

$cfg = $Config.laudo.ollama

$endpoint = [string]$cfg.endpoint
if ($Secrets -and $Secrets.ollama -and $Secrets.ollama.endpoint) { $endpoint = [string]$Secrets.ollama.endpoint }
if ([string]::IsNullOrWhiteSpace($endpoint)) { $endpoint = 'http://localhost:11434' }

$corpo = [ordered]@{
    model    = [string]$cfg.model
    stream   = $false
    messages = @(
        @{ role = 'system'; content = $SystemPrompt }
        @{ role = 'user';   content = (ConvertTo-Json -InputObject $Package -Depth 14) }
    )
    options  = [ordered]@{ num_ctx = [int]$cfg.numCtx }
}

# O Ollama aceita um esquema JSON em 'format' para saída estruturada.
if ($Schema) { $corpo.format = $Schema }

$json = ConvertTo-Json -InputObject ([pscustomobject]$corpo) -Depth 20

try {
    $resp = Invoke-RestMethod -Method Post -Uri "$endpoint/api/chat" `
        -ContentType 'application/json' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) `
        -TimeoutSec ([int]$cfg.timeoutSec) `
        -ErrorAction Stop
} catch {
    return @{ ok = $false; reason = "chamada ao Ollama falhou: $($_.Exception.Message)" }
}

$texto = $null
if ($resp.message -and $resp.message.content) { $texto = [string]$resp.message.content }
if ([string]::IsNullOrWhiteSpace($texto)) {
    return @{ ok = $false; reason = 'Ollama respondeu sem conteúdo'; raw = $resp }
}

@{
    ok    = $true
    text  = $texto
    model = [string]$resp.model
    usage = [ordered]@{
        prompt_eval_count = $resp.prompt_eval_count
        eval_count        = $resp.eval_count
    }
    raw   = $resp
}
