#requires -Version 5.1
<#
    Parecer — driver.

    Atravessa a fronteira determinística: monta o pacote fechado, chama o
    provedor, e CONFERE o que voltou antes de aceitar.

    LAUDO REPROVADO NÃO É APRESENTADO COMO LAUDO
    --------------------------------------------
    Se a conferência numérica acusar fabricação, o laudo é reapresentado ao
    modelo com os números órfãos nomeados. Se falhar de novo, ele é marcado como
    rejeitado, gravado assim para perícia, e o que se mostra na tela são os
    Achados crus — que são verdade verificável — em vez de um texto bonito que
    contém número inventado.

    Um parecer que não passa na própria conferência é pior que nenhum parecer,
    porque tem a forma de uma resposta.

    Uso:
      .\src\Invoke-Laudo.ps1                    último dia com achados
      .\src\Invoke-Laudo.ps1 -Day 2026-08-14
      .\src\Invoke-Laudo.ps1 -Provider claude
      .\src\Invoke-Laudo.ps1 -DryRun            monta o pacote e para
#>
[CmdletBinding()]
param(
    [string]$Day,
    [ValidateSet('', 'claude', 'ollama')][string]$Provider = '',
    [switch]$DryRun,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'WinMonitor.psm1')        -Force
Import-Module (Join-Path $PSScriptRoot 'WinMonitor.Rollup.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WinMonitor.Rules.psm1')  -Force
Import-Module (Join-Path $PSScriptRoot 'WinMonitor.Laudo.psm1')  -Force

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

$cfg      = Get-WMConfig
$findDir  = Get-WMPath $cfg.paths.findings
$laudoDir = Confirm-WMDirectory (Get-WMPath $cfg.paths.laudo)

if (-not (Test-Path -LiteralPath $findDir)) {
    Write-Warning "não há achados em $findDir — rode .\src\Invoke-Rules.ps1 antes."
    return
}

# --- achados ---------------------------------------------------------------
$arquivos = @(
    Get-ChildItem -LiteralPath $findDir -Filter '*.json' -File |
        Where-Object { $_.BaseName -match '^\d{4}-\d{2}-\d{2}$' } |
        Sort-Object Name -Descending
)
if ($Day) { $arquivos = @($arquivos | Where-Object { $_.BaseName -eq $Day }) }
if ($arquivos.Count -eq 0) { Write-Warning 'nenhum arquivo de achados para o dia pedido.'; return }

$dia     = $arquivos[0].BaseName
$achados = Read-JsonFile $arquivos[0].FullName
if ($null -eq $achados) { Write-Warning "achados de $dia ilegíveis."; return }

# --- contexto ---------------------------------------------------------------
$baseline = Read-JsonFile (Join-Path (Get-WMPath $cfg.paths.baseline) 'baseline.json')
$hardware = Read-JsonFile (Get-WMPath 'data\host.json')

# Laudo anterior: o mais recente ANTES deste dia, para a continuidade.
$anterior = $null
$anteriores = @(
    Get-ChildItem -LiteralPath $laudoDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match '^\d{4}-\d{2}-\d{2}$' -and $_.BaseName -lt $dia } |
        Sort-Object Name -Descending
)
if ($anteriores.Count -gt 0) { $anterior = Read-JsonFile $anteriores[0].FullName }

$pacote = New-WMLaudoPackage -Findings $achados -Baseline $baseline -Previous $anterior -Hardware $hardware

if ($DryRun) {
    ConvertTo-Json -InputObject $pacote -Depth 14
    return
}

# --- provedor ---------------------------------------------------------------
$nome = $Provider
if ([string]::IsNullOrWhiteSpace($nome)) { $nome = [string]$cfg.laudo.provider }
$script = Join-Path $PSScriptRoot ("providers\Provider-{0}.ps1" -f ((Get-Culture).TextInfo.ToTitleCase($nome)))
if (-not (Test-Path -LiteralPath $script)) { Write-Warning "provedor desconhecido: $nome"; return }

$segredos = Get-WMSecrets
$sistema  = Get-WMLaudoSystemPrompt
$esquema  = Get-WMLaudoSchema

$maxTentativas = 1 + [int]$cfg.laudo.maxRetries
$laudo         = $null
$violacoes     = New-Object System.Collections.ArrayList
$entrada       = $pacote

<#
    O texto cru de cada tentativa reprovada. Sem ele o registro diz que houve
    fabricação e qual número sobrou, mas não a FRASE — e sem a frase não há
    perícia possível: não dá para saber se o modelo inventou uma medida, citou
    uma peça por um apelido, ou errou uma conta. Fica só no disco local, que é
    ignorado pelo git.
#>
$rejeitados = New-Object System.Collections.ArrayList

for ($tentativa = 1; $tentativa -le $maxTentativas; $tentativa++) {

    <#
        O provedor é isolado. Ele faz rede, e sob $ErrorActionPreference='Stop'
        qualquer coisa que escape de lá matava o driver — sem arquivo de
        reprovação, sem registro, sem nada. Um parecer que não sai precisa
        deixar rastro do mesmo jeito.
    #>
    $r = $null
    try {
        $r = & $script -Package $entrada -Config $cfg -Secrets $segredos -SystemPrompt $sistema -Schema $esquema
    } catch {
        $r = @{ ok = $false; reason = "provedor lançou exceção: $($_.Exception.Message)" }
    }
    if ($null -eq $r) { $r = @{ ok = $false; reason = 'provedor não devolveu nada' } }

    <#
        DOIS CAMINHOS QUE PERDIAM A PERÍCIA E PULAVAM A REAPRESENTAÇÃO.

        Os 'continue' daqui saltavam por cima do registro do texto cru E do
        bloco que anexa o motivo ao pacote. Consequência medida: com o provedor
        falhando ou devolvendo não-JSON, o arquivo saía com attempts vazio — o
        registro dizia que houve reprovação e não guardava a FRASE, e sem a
        frase não há perícia nenhuma. Pior, a segunda tentativa ia sem
        rejectedBecause: exatamente o "refaça" sozinho que este arquivo diz,
        algumas linhas abaixo, que não corrige nada.

        Agora todo caminho de falha passa pelo mesmo lugar.
    #>
    $porque    = @()
    $candidato = $null

    if (-not $r.ok) {
        $porque = @("provedor: $($r.reason)")
    } else {
        try { $candidato = $r.text | ConvertFrom-Json } catch {
            $porque = @('a resposta não é JSON válido')
        }
    }

    if ($porque.Count -gt 0) {
        [void]$violacoes.Add("tentativa $tentativa - " + ($porque -join ' | '))
        [void]$rejeitados.Add([ordered]@{
            attempt = $tentativa
            why     = @($porque)
            orphans = @()
            text    = $r.text
        })
        $entrada = $pacote | ConvertTo-Json -Depth 14 | ConvertFrom-Json
        Add-Member -InputObject $entrada -NotePropertyName rejectedBecause -NotePropertyValue @($porque) -Force
        continue
    }

    # --- as quatro conferências ------------------------------------------
    $texto = Get-WMLaudoText -Laudo $candidato
    $num   = Test-WMLaudoNumbers  -Text $texto      -Package $pacote
    $reg   = Test-WMLaudoRuleIds  -Text $texto      -Package $pacote
    $ach   = Test-WMLaudoFindings -Laudo $candidato -Package $pacote
    $frm   = Test-WMLaudoShape    -Laudo $candidato -Package $pacote

    if ($num.ok -and $reg.ok -and $ach.ok -and $frm.ok) {
        $laudo = $candidato
        Add-Member -InputObject $laudo -NotePropertyName providerModel -NotePropertyValue $r.model -Force
        Add-Member -InputObject $laudo -NotePropertyName usage -NotePropertyValue $r.usage -Force
        Add-Member -InputObject $laudo -NotePropertyName attempts -NotePropertyValue $tentativa -Force
        break
    }

    $porque = @()
    if (-not $num.ok) { $porque += ("números que não vieram do pacote: " + ($num.orphans -join ', ')) }
    if (-not $reg.ok) { $porque += ("regras citadas que não existem: " + ($reg.invented -join ', ')) }
    if (-not $ach.ok) {
        if (@($ach.invented).Count -gt 0) { $porque += ("achados relatados que o pacote NÃO trouxe: " + ($ach.invented -join ', ')) }
        if (@($ach.omitted).Count  -gt 0) { $porque += ("achados do pacote que o laudo APAGOU: "      + ($ach.omitted  -join ', ')) }
    }
    if (-not $frm.ok) { $porque += ("obrigações do laudo não cumpridas: " + ($frm.missing -join ' ; ')) }
    [void]$violacoes.Add("tentativa $tentativa - " + ($porque -join ' | '))
    [void]$rejeitados.Add([ordered]@{
        attempt = $tentativa
        why     = @($porque)
        orphans = @($num.orphans)
        text    = $r.text
    })

    <#
        Reapresentação: o modelo recebe o mesmo pacote mais o motivo exato da
        rejeição. Dizer QUAIS números sobraram é o que torna a segunda tentativa
        útil — "refaça" sozinho não corrige nada.
    #>
    $entrada = $pacote | ConvertTo-Json -Depth 14 | ConvertFrom-Json
    Add-Member -InputObject $entrada -NotePropertyName rejectedBecause -NotePropertyValue @($porque) -Force
}

# --- gravação ---------------------------------------------------------------
$destino = Join-Path $laudoDir "$dia.json"

if ($null -eq $laudo) {
    $reprovado = [pscustomobject][ordered]@{
        v          = 1
        window     = $dia
        host       = $achados.host
        verdict    = $achados.verdict
        rejected   = $true
        violations = @($violacoes)
        <#
            'attempts' é a CONTAGEM nos dois arquivos, e o registro das
            tentativas mora em 'attemptLog'. Antes o mesmo campo era Int32 no
            laudo aprovado e Object[] no reprovado — quem lesse o diretório para
            fazer estatística ganhava um tipo diferente conforme o desfecho, que
            é a pior hora para descobrir uma diferença de esquema.
        #>
        attempts   = @($rejeitados).Count
        attemptLog = @($rejeitados)
        madeAt     = Get-WMTimestamp
    }
    $json = ConvertTo-Json -InputObject $reprovado -Depth 10
    [System.IO.File]::WriteAllText($destino, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-WMLog -Level error -Source 'laudo' -Message "laudo de $dia REPROVADO: $($violacoes -join ' ;; ')"

    ""
    "LAUDO REPROVADO NA CONFERÊNCIA — não será apresentado."
    foreach ($v in $violacoes) { "  $v" }
    ""
    "O que está verificado, sem intermediário:"
    "  dia      : $dia"
    "  veredito : $($achados.verdict)"
    "  cobertura: {0}" -f $(if ($achados.coverage.complete) { 'completa' } else { 'INCOMPLETA' })
    foreach ($a in @($achados.findings)) { "  [{0,-8}] {1}" -f $a.severity, $a.claim }
    ""
    "registro em: $destino"
    if ($PassThru) { $reprovado }
    return
}

# O veredito vem das REGRAS, nunca do modelo.
Add-Member -InputObject $laudo -NotePropertyName v       -NotePropertyValue 1 -Force
Add-Member -InputObject $laudo -NotePropertyName window  -NotePropertyValue $dia -Force
Add-Member -InputObject $laudo -NotePropertyName host    -NotePropertyValue $achados.host -Force
Add-Member -InputObject $laudo -NotePropertyName verdict -NotePropertyValue $achados.verdict -Force
Add-Member -InputObject $laudo -NotePropertyName coverageComplete -NotePropertyValue $achados.coverage.complete -Force
Add-Member -InputObject $laudo -NotePropertyName rejected -NotePropertyValue $false -Force
Add-Member -InputObject $laudo -NotePropertyName madeAt  -NotePropertyValue (Get-WMTimestamp) -Force

$json = ConvertTo-Json -InputObject $laudo -Depth 12
[System.IO.File]::WriteAllText($destino, $json, (New-Object System.Text.UTF8Encoding($false)))

<#
    --- saída ---

    A ORDEM É DEFESA, NÃO ESTÉTICA. O determinístico vem primeiro: veredito,
    cobertura, e os Achados com o texto CRU das regras. Só depois entra a prosa
    do modelo.

    Existe porque a prosa conseguiu contradizer o veredito e ser apresentada: um
    resumo dizendo "nada mereceu atenção, a máquina está saudável" saiu logo
    abaixo de "Veredito : agir". As guardas conferem número, regra, achado e
    forma — nenhuma confere se uma frase sem número nega o que as regras
    concluíram, e não há aritmética que confira isso.

    O que dá para fazer sem julgamento de modelo é não deixar a prosa ser a
    primeira coisa lida, nem a única. Quem abre o parecer vê o veredito e os
    achados medidos antes de qualquer frase escrita por LLM — e se as duas
    coisas discordarem, a discordância fica visível em vez de ficar plausível.
#>
""
"PARECER — $dia"
"Veredito : $($laudo.verdict)   (calculado pelas regras, não pelo modelo)"
"Cobertura: {0}" -f $(if ($laudo.coverageComplete) { 'completa' } else { 'INCOMPLETA' })
""
if (@($achados.findings).Count -gt 0) {
    "Achados medidos pelas regras ($(@($achados.findings).Count)):"
    foreach ($a in @($achados.findings)) { "  [{0,-8}] {1}" -f $a.severity, $a.claim }
    ""
} else {
    "Achados medidos pelas regras: nenhum."
    ""
}

"Não verificado:"
if (@($laudo.notVerified).Count -eq 0) {
    "  (nada declarado)"
} else {
    foreach ($n in @($laudo.notVerified)) {
        if ($n -is [string]) { "  - $n" } else { "  - {0}: {1}" -f $n.ruleId, $n.note }
    }
}
""

"Leitura do modelo:"
"  $($laudo.summary)"
""
if (@($laudo.findings).Count -gt 0) {
    foreach ($a in @($laudo.findings)) {
        "  - $($a.reading)"
        "    o que fazer: $($a.action)"
    }
    ""
}
if ($laudo.changedSinceLast) { "Desde o laudo anterior:"; "  $($laudo.changedSinceLast)"; "" }
if (@($laudo.observations).Count -gt 0) {
    "Observações (hipóteses, NÃO verificadas):"
    foreach ($o in @($laudo.observations)) { "  - $o" }
    ""
}
"modelo: $($laudo.providerModel)   tentativas: $($laudo.attempts)   gravado em: $destino"

if ($PassThru) { $laudo }
