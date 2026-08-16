#requires -Version 5.1
<#
    Compara modelos do Ollama no trabalho que este projeto pede.

    POR QUE MEDIR EM VEZ DE ESCOLHER PELA FICHA TÉCNICA
    ---------------------------------------------------
    O laudo tem uma exigência incomum: passar em quatro conferências
    determinísticas que rejeitam número inventado, achado inventado, achado
    apagado e lacuna calada. Um modelo pode ser excelente em prosa e reprovar em
    todas — foi o que aconteceu com o gemma3:4b, que inventou achados em TODAS
    as tentativas de TODAS as execuções.

    E o inverso também: passar nas guardas não é escrever bem. O mistral passa e
    produz texto mecânico, listando identificador de regra em vez de explicar.

    Então o critério tem duas partes, e as duas são medidas aqui:

      1. APROVA?  passou nas quatro conferências, em quantas tentativas
      2. EXPLICA? o resumo fala de máquina, ou recita identificador?

    A segunda é heurística e está declarada como tal: conta identificadores de
    regra e caminhos de métrica no resumo, e mede o tamanho. Texto que é só
    R-ISTO e gpu.0.aquilo não explica nada a uma pessoa. Não substitui leitura
    humana — ordena os candidatos para que a leitura seja curta.

      .\tools\Compare-Modelos.ps1
      .\tools\Compare-Modelos.ps1 -Modelos 'mistral:latest','qwen2.5:7b'
#>
[CmdletBinding()]
param(
    [string[]]$Modelos = @('mistral:latest', 'qwen2.5:7b', 'gemma3:4b'),
    [string]$Day
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

$cfgPath  = Join-Path $raiz 'config\config.json'
$original = [System.IO.File]::ReadAllText($cfgPath)
$enc      = New-Object System.Text.UTF8Encoding($false)

$resultados = New-Object System.Collections.ArrayList

try {
    foreach ($m in $Modelos) {
        ""
        "################  $m  ################"

        $c = $original | ConvertFrom-Json
        $c.laudo.provider     = 'ollama'
        $c.laudo.ollama.model = $m
        [System.IO.File]::WriteAllText($cfgPath, (ConvertTo-Json -InputObject $c -Depth 14), $enc)

        <#
            Splat com hashtable, não array. '@(if ($Day) { ... })' devolve um
            array VAZIO quando não há dia, e array vazio vira argumento
            POSICIONAL — que casa com -Day e falha a conversão. O parâmetro
            opcional some sozinho quando a chave não existe.
        #>
        $arg = @{}
        if ($Day) { $arg['Day'] = $Day }

        $t0 = [System.Diagnostics.Stopwatch]::StartNew()
        $saida = & (Join-Path $raiz 'src\Invoke-Laudo.ps1') @arg 2>&1 | Out-String
        $t0.Stop()

        $arq = Join-Path $raiz ('data\laudo\' + $(if ($Day) { $Day } else { (Get-Date).ToString('yyyy-MM-dd') }) + '.json')
        $laudo = $null
        if (Test-Path $arq) { $laudo = Get-Content $arq -Raw -Encoding UTF8 | ConvertFrom-Json }

        $aprovou   = ($laudo -and $laudo.rejected -eq $false)
        $resumo    = [string]$laudo.summary
        $tentativas = $laudo.attempts

        <#
            Heurística de legibilidade, declarada como heurística: identificador
            de regra e caminho de métrica são o vocabulário da MÁQUINA. Um
            resumo feito deles não explica nada a quem lê.
        #>
        $ids     = @([regex]::Matches($resumo, '(?i)\bR[-_][\p{L}\d]+[-_][\p{L}\d_-]+')).Count
        $metrica = @([regex]::Matches($resumo, '\b[a-z]+\.[a-z0-9]+\.[a-zA-Z0-9.]+')).Count
        $palavras = @($resumo -split '\s+' | Where-Object { $_ }).Count

        [void]$resultados.Add([pscustomobject]@{
            modelo     = $m
            aprovou    = $aprovou
            tentativas = $tentativas
            segundos   = [math]::Round($t0.Elapsed.TotalSeconds, 1)
            palavras   = $palavras
            jargao     = $ids + $metrica
            resumo     = $resumo
        })

        if ($aprovou) { "APROVADO em $tentativas tentativa(s), $([math]::Round($t0.Elapsed.TotalSeconds,1))s" }
        else          { "REPROVADO — " + (@($laudo.violations) -join ' ;; ') }
        if ($resumo) { ""; "resumo: $resumo" }
    }
} finally {
    [System.IO.File]::WriteAllText($cfgPath, $original, $enc)
    ""
    "(config restaurado)"
}

""
"=============== COMPARAÇÃO ==============="
$resultados |
    Select-Object modelo, aprovou, tentativas, segundos, palavras,
                  @{ n = 'jargao'; e = { $_.jargao } } |
    Format-Table -AutoSize | Out-String

<#
    A recomendação é ORDENAÇÃO, não veredito: aprovar é eliminatório, e entre os
    que aprovam vence quem explica mais e recita menos. Quem decide de fato é
    quem lê os resumos impressos acima.
#>
$bons = @($resultados | Where-Object { $_.aprovou })
if ($bons.Count -eq 0) {
    "Nenhum modelo passou nas quatro conferências. O provedor remoto continua sendo a saída."
} else {
    $vencedor = @($bons | Sort-Object jargao, @{ e = 'palavras'; Descending = $true })[0]
    "Sugerido: $($vencedor.modelo) — aprovou, $($vencedor.palavras) palavras, $($vencedor.jargao) termo(s) de máquina no resumo."
    "Leia os resumos acima antes de fixar: a contagem ordena, não julga."
}
