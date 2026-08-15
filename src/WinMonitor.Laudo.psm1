#requires -Version 5.1
<#
    WinMonitor — camada de parecer, parte determinística.

    Este módulo NÃO fala com modelo nenhum. Ele faz as duas coisas que precisam
    ser verificáveis sem depender de julgamento:

      1. MONTA o pacote fechado que o modelo recebe.
      2. CONFERE o laudo que o modelo devolve.

    O PACOTE É FECHADO DE PROPÓSITO
    -------------------------------
    O modelo não recebe acesso à máquina, nem ao agregado bruto, nem à tabela de
    limiares. Recebe os Achados, as fatias de série relacionadas a eles, o bloco
    de cobertura e as conclusões do laudo anterior. Ele não pode discutir o que
    não está no pacote — e o que não está no pacote ele não tem como inventar
    com aparência de dado.

    A CONFERÊNCIA NÃO PRECISA DE MODELO
    -----------------------------------
    A defesa mais forte contra número inventado é aritmética, não julgamento:
    extraem-se os números do texto do laudo e confere-se cada um contra o
    conjunto de valores que o pacote continha. Número órfão é fabricação, e isso
    é regex e teoria dos conjuntos — roda de graça, roda sempre, e não depende de
    um segundo modelo concordar.

    ATÉ ONDE ESSA EXTRAÇÃO VAI. O cabeçalho já afirmou "todo número do texto", e
    era falso: notação científica, milhar com ponto e número por extenso passavam
    inteiros. Os três foram fechados. Continuam de fora fração por extenso
    ("meio grau"), algarismo romano e número escrito em outro idioma. A guarda é
    forte, não é total — e a diferença fica escrita aqui em vez de ser negada.

    Um verificador adversarial por modelo continua valendo para as afirmações
    semânticas, mas ele é a segunda linha. Esta é a primeira.
#>

Set-StrictMode -Off

# ------------------------------------------------------------- pacote -------

<#
    Monta o pacote de entrada do parecer.

    -Findings   saída de Invoke-WMRules (achados + cobertura + veredito)
    -Rollup     o agregado do dia, para extrair só as fatias citadas
    -Baseline   a linha-base, idem
    -Previous   o laudo anterior, para dar continuidade
    -Hardware   fatos estáticos da máquina

    Só entram no pacote as séries REFERENCIADAS por algum achado. Despejar o
    agregado inteiro daria ao modelo material para correlacionar coisas que
    nenhuma regra examinou — e o laudo passaria a discutir o que não foi
    verificado.
#>
function New-WMLaudoPackage {
    param(
        [Parameter(Mandatory)]$Findings,
        $Rollup,
        $Baseline,
        $Previous,
        $Hardware
    )

    $pacote = [ordered]@{
        v       = 1
        window  = $Findings.window
        host    = $Findings.host
        verdict = $Findings.verdict
    }

    # --- hardware: só o que ajuda a explicar, nada de identificação ---------
    if ($Hardware) {
        $hw = [ordered]@{}
        foreach ($c in 'os', 'cpuName', 'cpuCores', 'cpuThreads', 'cpuBaseMHz', 'memTotalMB') {
            if ($null -ne $Hardware.$c) { $hw[$c] = $Hardware.$c }
        }
        if ($Hardware.gpuNames) { $hw.gpus = @($Hardware.gpuNames) }
        if ($Hardware.disks)    { $hw.disks = @($Hardware.disks) }
        if ($hw.Count -gt 0)    { $pacote.hardware = $hw }
    }

    $pacote.findings = @($Findings.findings)
    $pacote.coverage = $Findings.coverage

    <#
        Continuidade. Sem isto o parecer não consegue dizer "isto já foi
        apontado há dois meses e piorou" — frase que nenhum retrato instantâneo
        produz, e que costuma ser a informação mais útil do laudo.
    #>
    if ($Previous) {
        $pacote.previous = [ordered]@{
            window   = $Previous.window
            verdict  = $Previous.verdict
            ruleIds  = @($Previous.findings | ForEach-Object { $_.ruleId } | Sort-Object -Unique)
            summary  = $Previous.summary
        }
    }

    # --- séries: só as citadas pelos achados --------------------------------
    $series = [ordered]@{}
    foreach ($a in @($Findings.findings)) {
        foreach ($e in @($a.evidence)) {
            if ($null -eq $e.metric) { continue }
            if ($series.Contains($e.metric)) { continue }
            $series[$e.metric] = [ordered]@{
                today    = $e.value
                baseline = $null
            }
        }
    }
    # Preenche a coluna da linha-base quando a métrica existe lá.
    if ($Baseline -and $Baseline.profile) {
        foreach ($m in @($series.Keys)) {
            $b = @(Resolve-WMMetric -Root $Baseline.profile -Path $m)
            if ($b.Count -gt 0) { $series[$m].baseline = (ConvertTo-WMNumber $b[0].value) }
        }
    }
    if ($series.Count -gt 0) { $pacote.series = $series }

    [pscustomobject]$pacote
}

# ------------------------------------------- conferência determinística -----

<#
    Extrai os números "permitidos" de um pacote: tudo que o laudo pode
    legitimamente citar.

    Inclui valores de evidência, limiares, séries, e as CONTAGENS derivadas —
    quantidade de achados, de regras não avaliadas, de itens por severidade.
    Sem as contagens, uma frase correta como "três achados" seria acusada de
    fabricação.
#>
<#
    Todas as STRINGS de um nó do pacote.

    ISTO JÁ FOI Get-WMNumbersDeep, E ERA UM BURACO
    ----------------------------------------------
    A versão anterior devolvia os NÚMEROS embutidos nos nomes de peça e os
    despejava no conjunto de permitidos, para que "RTX 3080" deixasse de ser
    acusado de invenção. Resolvia o falso positivo e abria coisa muito pior,
    medida no host.json desta máquina:

      o disco chama-se ST10000NM001G-2MW103. Dele saía o 103. Com a tolerância
      de 5%, o 103 liberava a faixa CONTÍNUA de 98 a 108 — exatamente onde mora
      uma temperatura de CPU plausível. Um laudo afirmando "a CPU chegou a 100
      graus" passava nas quatro guardas contra um pacote com zero achados e
      nenhuma temperatura.

    A ironia mede o tamanho do erro: R-CPU-TEMP-SPEC está desligada porque a
    procedência do 100 °C era post de comunidade e escrevê-lo na tabela seria
    inventar fonte. A guarda então aceitava o modelo escrevendo 100 no laudo.

    A CORREÇÃO é não liberar número nenhum por causa de hardware. Em vez disso,
    remove-se do texto o NOME DA PEÇA como frase — ver Get-WMHardwarePhrases.
    "RTX 3080" some porque é frase de nome; "100 graus" continua exposto porque
    não é.

    Nota para quem for mexer aqui: a razão registrada antes — de que percorrer
    as séries liberaria o 75 de b75 e o 95 de p95 — estava ERRADA. Esta função
    nunca percorreu NOME de chave, só valor, então caminho de métrica jamais
    teve por onde entrar. A política de restringir ao hardware continua certa; o
    perigo real era o outro, e foi o que quase passou.
#>
function Get-WMStringsDeep {
    param($Node, [int]$Depth = 0)

    if ($null -eq $Node -or $Depth -gt 6) { return }

    if ($Node -is [string]) { $Node; return }
    if ($Node -is [ValueType]) { return }

    <#
        Dicionário ANTES de IEnumerable: IDictionary também é IEnumerable, e
        cair no ramo de lista faria o nó ser percorrido como DictionaryEntry —
        arrastando junto os dígitos dos NOMES DE CHAVE. Só os valores entram.
    #>
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in $Node.Keys) { Get-WMStringsDeep -Node $Node[$k] -Depth ($Depth + 1) }
        return
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($item in $Node) { Get-WMStringsDeep -Node $item -Depth ($Depth + 1) }
        return
    }
    foreach ($k in (Get-WMNodeKeys $Node)) {
        Get-WMStringsDeep -Node (Get-WMNodeChild $Node $k) -Depth ($Depth + 1)
    }
}

<#
    As frases de nome de peça que devem sumir do texto antes da extração.

    O critério separa dois tipos de pedaço, e a separação é a defesa inteira:

      TOKEN MISTO (letra e dígito juntos): 'i9-11900K', 'ST10000NM001G-2MW103',
      'MP600'. Sai sozinho, porque ninguém confunde isso com uma medida. Nenhuma
      temperatura se escreve 'ST10000NM001G-2MW103'.

      TOKEN SÓ DE DÍGITO: '3080', '750'. Só sai acompanhado — como parte de uma
      frase de dois ou mais tokens do nome ('RTX 3080', 'Graphics 750'). Sozinho
      NÃO sai, e é isso que impede que o 103 do nome do disco vire licença para
      escrever 100, 103 ou 104 como se fossem graus.

    O modelo escrevendo "RTX 3080" continua passando. O modelo escrevendo "103
    graus" vira órfão e derruba o laudo, que é o comportamento que se quer.
#>
function Get-WMHardwarePhrases {
    param($Hardware)

    $frases = New-Object System.Collections.ArrayList
    if ($null -eq $Hardware) { return @() }

    foreach ($texto in (Get-WMStringsDeep -Node $Hardware)) {
        if ([string]::IsNullOrWhiteSpace($texto)) { continue }
        [void]$frases.Add($texto)

        $tokens = @($texto -split '\s+' | Where-Object { $_ })

        foreach ($t in $tokens) {
            # Misto letra+dígito: identificador, não medida. Sai sozinho.
            if ($t -match '\d' -and $t -match '[A-Za-z]') { [void]$frases.Add($t) }
        }

        # Sequências de 2+ tokens: é o que permite "RTX 3080" sem permitir "3080".
        for ($i = 0; $i -lt $tokens.Count; $i++) {
            for ($n = 2; $i + $n -le $tokens.Count; $n++) {
                [void]$frases.Add(($tokens[$i..($i + $n - 1)] -join ' '))
            }
        }
    }

    @($frases | Where-Object { $_.Length -ge 2 } | Sort-Object -Unique)
}

function Get-WMAllowedNumbers {
    param([Parameter(Mandatory)]$Package)

    $set = New-Object System.Collections.Generic.HashSet[double]
    function Add-N { param($v) $n = ConvertTo-WMNumber $v; if ($null -ne $n) { [void]$set.Add([double]$n) } }

    foreach ($a in @($Package.findings)) {
        Add-N $a.rule.threshold
        foreach ($e in @($a.evidence)) { Add-N $e.value }
    }

    if ($Package.series) {
        foreach ($k in (Get-WMNodeKeys $Package.series)) {
            $s = Get-WMNodeChild $Package.series $k
            Add-N $s.today
            Add-N $s.baseline
        }
    }

    <#
        Hardware: SÓ os campos que são medida de verdade — núcleos, threads,
        clock base, memória total. O nome da peça NÃO entra aqui.

        Já entrou, e foi um buraco: os dígitos de ST10000NM001G-2MW103 viravam o
        número 103, e a tolerância de 5% transformava isso na faixa 98–108,
        justamente onde mora uma temperatura de CPU plausível. Nome de peça agora
        é tratado por remoção de frase no texto, não por liberação de número.
    #>
    if ($Package.hardware) {
        foreach ($c in 'cpuCores', 'cpuThreads', 'cpuBaseMHz', 'memTotalMB') {
            Add-N (Get-WMNodeChild $Package.hardware $c)
        }
        foreach ($d in @($Package.hardware.disks)) {
            foreach ($c in 'sizeGB', 'freeGB') { Add-N (Get-WMNodeChild $d $c) }
        }
    }

    # --- contagens derivadas -------------------------------------------------
    $achados = @($Package.findings)
    Add-N $achados.Count
    $porSeveridade = @{}
    foreach ($a in $achados) {
        $s = [string]$a.severity
        if (-not $porSeveridade.ContainsKey($s)) { $porSeveridade[$s] = 0 }
        $porSeveridade[$s]++
    }
    foreach ($v in $porSeveridade.Values) { Add-N $v }

    if ($Package.coverage) {
        Add-N @($Package.coverage.evaluated).Count
        foreach ($b in 'unsourced', 'malformed', 'noData', 'noBaseline', 'notApplicable') {
            $bloco = Get-WMNodeChild $Package.coverage $b
            Add-N @(Get-WMNodeKeys $bloco).Count
        }
        # Total de regras: avaliadas + todas as lacunas.
        $total = @($Package.coverage.evaluated).Count
        foreach ($b in 'unsourced', 'malformed', 'noData', 'noBaseline', 'notApplicable') {
            $total += @(Get-WMNodeKeys (Get-WMNodeChild $Package.coverage $b)).Count
        }
        Add-N $total
    }

    # Números que qualquer texto em português usa sem estar citando medida.
    foreach ($n in 0, 1, 2) { [void]$set.Add([double]$n) }

    $set
}

<#
    Confere que todo número do laudo aparece no pacote.

    Tokens que contêm dígito mas NÃO são medida — caminhos de métrica
    (gpu.0.tempCByLoad.b75.p95), identificadores de regra (R-GPU-TEMP-SPEC-3080),
    datas (2026-08-14) — são removidos do texto ANTES da extração. Sem isso,
    citar corretamente o nome de uma regra seria acusado de inventar número.

    Tolerância: o modelo pode arredondar 86,3 para 86 ao escrever. Um número do
    texto é aceito se algum permitido casar dentro da tolerância relativa OU se
    for o arredondamento de um permitido.
#>
<#
    Números escritos por extenso, em português.

    Existe porque a guarda aritmética só via dígito, e "noventa e cinco graus"
    não tem nenhum. Um modelo escreve assim sem esforço — e o número inventado
    passava inteiro por não estar em algarismo.

    Cobre o intervalo que importa para medida de máquina: unidades, dezenas e
    centenas redondas. Não cobre fração por extenso ("meio grau"), nem número em
    outro idioma. Isso está dito aqui e nas limitações do README em vez de ser
    negado no cabeçalho do módulo.
#>
function Get-WMSpelledNumbers {
    param([Parameter(Mandatory)][string]$Text)

    $unid = [ordered]@{
        'zero'=0;'um'=1;'uma'=1;'dois'=2;'duas'=2;'tres'=3;'três'=3;'quatro'=4;'cinco'=5
        'seis'=6;'sete'=7;'oito'=8;'nove'=9;'dez'=10;'onze'=11;'doze'=12;'treze'=13
        'quatorze'=14;'catorze'=14;'quinze'=15;'dezesseis'=16;'dezessete'=17
        'dezoito'=18;'dezenove'=19
    }
    $dez = [ordered]@{
        'vinte'=20;'trinta'=30;'quarenta'=40;'cinquenta'=50;'sessenta'=60
        'setenta'=70;'oitenta'=80;'noventa'=90
    }
    $cem = [ordered]@{
        'cem'=100;'cento'=100;'duzentos'=200;'trezentos'=300;'quatrocentos'=400
        'quinhentos'=500;'seiscentos'=600;'setecentos'=700;'oitocentos'=800;'novecentos'=900
    }

    $todas = @($cem.Keys) + @($dez.Keys) + @($unid.Keys)
    $alt   = ($todas | ForEach-Object { [regex]::Escape($_) }) -join '|'

    <#
        A frase inteira, não a palavra solta: 'noventa e cinco' precisa somar 95,
        e não produzir 90 e 5 separados — o 5 seria aceito por qualquer coisa
        perto de 5 e o 95 inventado escaparia.
    #>
    $padrao = "(?i)\b(?:$alt)(?:\s+e\s+(?:$alt))*\b"

    foreach ($m in [regex]::Matches($Text, $padrao)) {
        $partes = @($m.Value.ToLowerInvariant() -split '\s+e\s+' | ForEach-Object { $_.Trim() })
        $total = 0
        $valeu = $false
        foreach ($p in $partes) {
            if ($cem.Contains($p))       { $total += [int]$cem[$p];  $valeu = $true }
            elseif ($dez.Contains($p))   { $total += [int]$dez[$p];  $valeu = $true }
            elseif ($unid.Contains($p))  { $total += [int]$unid[$p]; $valeu = $true }
        }
        if ($valeu) { [pscustomobject]@{ value = $total; text = $m.Value } }
    }
}

function Test-WMLaudoNumbers {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)]$Package,
        [double]$Tolerance = 0.05
    )

    $permitidos = Get-WMAllowedNumbers -Package $Package

    # --- remove tokens que carregam dígito sem ser medida -------------------
    $limpo = $Text

    $literais = New-Object System.Collections.ArrayList
    foreach ($a in @($Package.findings)) {
        [void]$literais.Add([string]$a.ruleId)
        [void]$literais.Add([string]$a.id)
        foreach ($e in @($a.evidence)) { [void]$literais.Add([string]$e.metric) }
    }
    if ($Package.series)  { foreach ($k in (Get-WMNodeKeys $Package.series)) { [void]$literais.Add([string]$k) } }
    if ($Package.coverage) {
        foreach ($b in 'unsourced', 'malformed', 'noData', 'noBaseline', 'notApplicable') {
            foreach ($k in (Get-WMNodeKeys (Get-WMNodeChild $Package.coverage $b))) { [void]$literais.Add([string]$k) }
        }
        foreach ($k in @($Package.coverage.evaluated)) { [void]$literais.Add([string]$k) }
    }
    [void]$literais.Add([string]$Package.window)
    if ($Package.previous) { [void]$literais.Add([string]$Package.previous.window) }
    # Nomes de peça, como FRASE. Ver Get-WMHardwarePhrases: '3080' sozinho não
    # entra aqui, só acompanhado, e é isso que impede o nome de virar medida.
    foreach ($f in (Get-WMHardwarePhrases -Hardware $Package.hardware)) { [void]$literais.Add($f) }

    # Do mais longo para o mais curto: senão um prefixo come o token maior.
    foreach ($lit in (@($literais | Where-Object { $_ }) | Sort-Object { $_.Length } -Descending)) {
        $limpo = $limpo -replace [regex]::Escape($lit), ' '
    }
    # Datas e horas em qualquer formato ISO.
    $limpo = [regex]::Replace($limpo, '\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2})?)?', ' ')

    # --- extrai e confere ---------------------------------------------------
    $orfaos = New-Object System.Collections.ArrayList

    $confere = {
        param([double]$n, [string]$rotulo)
        foreach ($p in $permitidos) {
            if ($p -eq $n) { return }
            $margem = [math]::Max([math]::Abs($p) * $Tolerance, 0.5)
            if ([math]::Abs($p - $n) -le $margem) { return }
        }
        if (-not $orfaos.Contains($rotulo)) { [void]$orfaos.Add($rotulo) }
    }

    <#
        A extração precisa cobrir três formas que escapavam e que um modelo
        escreve sem esforço nenhum:

          NOTAÇÃO CIENTÍFICA  '3.4e2' virava 3.4 e 2, dois números inofensivos,
                              e os 340 watts inventados passavam.
          MILHAR COM PONTO    '2.048 MB' era lido como 2,048 e aceito pela
                              liberação de 0/1/2.
          POR EXTENSO         'noventa e cinco graus' não tinha dígito nenhum
                              para o regex ver.

        O cabeçalho deste módulo afirmava que "extrai-se todo número do texto".
        Não extraía. Agora extrai estas três também — e continua não sendo
        "todo": fração por extenso, algarismo romano e número em outro idioma
        seguem passando. A fronteira está dita em vez de negada.
    #>

    # Milhar com ponto/vírgula ANTES do resto, senão o separador vira decimal.
    foreach ($m in [regex]::Matches($limpo, '\b\d{1,3}(?:([.,])\d{3})+\b')) {
        $bruto = $m.Value -replace '[.,]', ''
        $n = ConvertTo-WMNumber $bruto
        if ($null -ne $n) { & $confere ([double]$n) $m.Value }
    }
    $limpo = [regex]::Replace($limpo, '\b\d{1,3}(?:[.,]\d{3})+\b', ' ')

    foreach ($m in [regex]::Matches($limpo, '\d+(?:[.,]\d+)?(?:[eE][+-]?\d+)?')) {
        $n = ConvertTo-WMNumber ($m.Value -replace ',', '.')
        if ($null -eq $n) { continue }
        & $confere ([double]$n) $m.Value
    }

    foreach ($e in (Get-WMSpelledNumbers -Text $limpo)) {
        & $confere ([double]$e.value) $e.text
    }

    [pscustomobject]@{
        ok       = ($orfaos.Count -eq 0)
        orphans  = @($orfaos)
        allowed  = @($permitidos | Sort-Object)
    }
}

<#
    Confere que o laudo só discute Achados que existem.

    O parecer pode acrescentar OBSERVAÇÕES — hipóteses explicitamente rotuladas
    como não verificadas, em seção separada. O que ele não pode é apresentar
    hipótese como achado. Esta função procura menções a identificadores de regra
    que não estão no pacote.
#>
function Test-WMLaudoRuleIds {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)]$Package
    )

    <#
        Comparação SEM caixa. Já passou 'r-memoria-vazando' e 'R-Memoria-Vazando'
        enquanto 'R-MEMORIA-VAZANDO' era pego — e modelo pequeno escreve em caixa
        baixa o tempo todo. Uma guarda que só funciona quando o modelo capitaliza
        direito não é guarda.
    #>
    $conhecidos = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($a in @($Package.findings)) { [void]$conhecidos.Add([string]$a.ruleId) }
    if ($Package.coverage) {
        foreach ($b in 'unsourced', 'malformed', 'noData', 'noBaseline', 'notApplicable') {
            foreach ($k in (Get-WMNodeKeys (Get-WMNodeChild $Package.coverage $b))) {
                [void]$conhecidos.Add(([string]$k -split '#')[0])
            }
        }
        foreach ($k in @($Package.coverage.evaluated)) { [void]$conhecidos.Add([string]$k) }
    }

    $inventados = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($Text, '(?i)\bR[-_][A-Z0-9_-]{2,}\b')) {
        $id = $m.Value.TrimEnd('-', '_')
        if (-not $conhecidos.Contains($id) -and -not $inventados.Contains($id)) { [void]$inventados.Add($id) }
    }

    [pscustomobject]@{
        ok       = ($inventados.Count -eq 0)
        invented = @($inventados)
        known    = @($conhecidos | Sort-Object)
    }
}

# ------------------------------------------------------- instrução ---------

<#
    O que o modelo recebe como instrução de sistema.

    Vive aqui, no módulo, e não solto no driver: é texto versionado que decide
    comportamento, e merece o mesmo tratamento de um limiar.
#>
function Get-WMLaudoSystemPrompt {
    @'
Você recebe um pacote fechado com o resultado de uma verificação automática de saúde de uma máquina Windows. Sua tarefa é escrever o laudo para uma pessoa.

O QUE VOCÊ PODE DISCUTIR
Somente os Achados presentes no pacote e as lacunas listadas em coverage. Nada mais. Você não tem acesso à máquina, ao dado bruto nem à tabela de limiares — se não está no pacote, você não sabe.

ACHADO É SÓ O QUE ESTÁ EM findings
O campo findings do seu laudo tem de conter exatamente os achados que vieram em findings no pacote, cada um com o mesmo ruleId. Se o pacote veio com findings vazio, o seu findings vai vazio — não há o que relatar, e isso é uma resposta legítima.

As regras que aparecem em coverage NÃO são achados. Elas são regras que não puderam ser avaliadas, e a única coisa a dizer sobre elas é que ficaram sem verificação, no campo notVerified. Transformar uma delas em achado é afirmar um problema que ninguém mediu. Se você não recebeu o valor, isso não é um achado sem valor: é a ausência de um achado.

Há uma conferência automática que compara o seu findings com o do pacote e rejeita o laudo inteiro nos DOIS sentidos: se você acrescentar um achado que não veio, e se você deixar de relatar um que veio. Apagar é a falha mais grave das duas — achado inventado faz alguém olhar a máquina à toa; achado apagado faz ninguém olhar.

O campo notVerified precisa NOMEAR pelo menos uma das lacunas que o pacote lista em coverage. Escrever "nada" ou "-" preenche o campo sem declarar coisa alguma, e é rejeitado igual a deixá-lo vazio.

NÚMEROS
Todo número que você escrever precisa vir do pacote. Não calcule médias, não estime, não converta unidades, não arredonde para números "redondos" que não estão lá. Um número que não veio do pacote é invenção, e há uma conferência automática que rejeita o laudo por isso.

O VEREDITO NÃO É SEU
Ele já foi calculado por regras determinísticas e vai no laudo de qualquer forma. Não o repita, não o contradiga, não o requalifique.

COBERTURA
Se coverage.complete for falso, o laudo PRECISA dizer o que não foi verificado, no campo próprio. "Nenhum achado" com cobertura incompleta não significa máquina saudável, e o texto não pode sugerir que signifique.

OBSERVAÇÕES
Você pode acrescentar hipóteses — correlações entre achados, causas prováveis — mas apenas no campo observations, e cada uma redigida como o palpite que é. Nunca apresente hipótese como achado.

Uma hipótese é sobre um achado que existe. Se o pacote veio sem achados, observations vai vazio: não há correlação a levantar nem causa a supor. Escrever "a placa parece um pouco quente" sem nenhuma temperatura no pacote não é hipótese, é invenção com verbo no condicional — e é rejeitada igual.

COMO ESCREVER
Português do Brasil, direto, sem jargão desnecessário. Primeiro o significado, depois o número: "a placa está 8 graus mais quente sob a mesma carga" antes de "p95 de 86 °C". Uma pessoa técnica que não acompanhou nada deve entender em uma leitura. Não elogie a máquina, não tranquilize além do que o dado sustenta, e não use exclamação.
'@
}

# Esquema da resposta. Sem 'verdict': ele é determinístico e o driver o anexa.
function Get-WMLaudoSchema {
    @'
{
  "type": "object",
  "properties": {
    "summary":   { "type": "string" },
    "findings":  { "type": "array", "items": { "type": "object",
                   "properties": { "ruleId": {"type":"string"},
                                   "reading": {"type":"string"},
                                   "action": {"type":"string"} },
                   "required": ["ruleId","reading","action"],
                   "additionalProperties": false } },
    "notVerified":      { "type": "string" },
    "changedSinceLast": { "type": "string" },
    "observations":     { "type": "array", "items": { "type": "string" } }
  },
  "required": ["summary","findings","notVerified","changedSinceLast","observations"],
  "additionalProperties": false
}
'@ | ConvertFrom-Json
}

<#
    Terceira conferência: os ACHADOS do laudo têm de ser os achados do pacote.

    POR QUE ELA EXISTE — uma reprovação real, e o que ela quase deixou passar.
    O pacote de 2026-08-15 tinha ZERO achados e veredito 'normal'. O modelo
    devolveu isto:

        ruleId : R-GPU-TEMP-SPEC-3080
        reading: A temperatura da RTX 3080 está acima do especificado.
        action : O valor não foi fornecido no pacote.

    Ele SABIA que não tinha dado, e emitiu o achado assim mesmo. As duas
    guardas anteriores não o pegam:

      - Test-WMLaudoNumbers confere NÚMEROS. Esse achado não tem número. Ele só
        foi rejeitado porque OUTRA frase do laudo trazia um número inventado —
        sorte, não defesa. Com o resto do texto limpo, seria APRESENTADO.
      - Test-WMLaudoRuleIds roda sobre a prosa, e R-GPU-TEMP-SPEC-3080 é uma
        regra legítima de citar: está em coverage como não avaliada. E o ruleId
        estruturado nem chega a entrar no texto que ela examina.

    A distinção que faltava: regra que aparece em coverage é CITÁVEL — o laudo
    precisa poder dizer "esta não pôde ser avaliada" — mas nunca é ACHADO.
    Achado é só o que as regras concluíram, e isso é um conjunto fechado.

    A contagem também é conferida: com duas placas, a mesma regra pode gerar
    dois achados de verdade. O que não pode é o laudo devolver mais achados de
    uma regra do que o pacote trouxe.

    E O OUTRO LADO, QUE FALTAVA — APAGAR
    ------------------------------------
    A guarda conferia só ⊆: acrescentar era barrado, omitir passava. Medido de
    ponta a ponta com um pacote contendo achado de severidade 'agir' (volume de
    sistema com 3 GB livres), o laudo abaixo passou nas quatro guardas e foi
    APRESENTADO:

        Veredito : agir   (calculado pelas regras, não pelo modelo)
        "A máquina está saudável e não há nada a fazer. Nenhum problema foi
         encontrado no período."

    O veredito determinístico dizia 'agir' e o texto dizia que estava tudo bem.
    Das duas falhas possíveis, essa é a pior: inventar problema faz alguém olhar
    a máquina à toa; apagar problema faz ninguém olhar. E a instrução do sistema
    já mandava conter EXATAMENTE os achados do pacote — a guarda é que só
    implementava metade, e quem vale é a guarda.

    Agora a comparação é de igualdade: mesmo conjunto, mesma contagem.
#>
function Test-WMLaudoFindings {
    param(
        [Parameter(Mandatory)]$Laudo,
        [Parameter(Mandatory)]$Package
    )

    $doPacote = @{}
    foreach ($a in @($Package.findings)) {
        $id = [string]$a.ruleId
        if (-not $doPacote.ContainsKey($id)) { $doPacote[$id] = 0 }
        $doPacote[$id]++
    }

    $inventados = New-Object System.Collections.ArrayList
    $omitidos   = New-Object System.Collections.ArrayList
    $vistos     = @{}
    foreach ($a in @($Laudo.findings)) {
        $id = [string]$a.ruleId
        if ([string]::IsNullOrWhiteSpace($id)) { [void]$inventados.Add('(achado sem ruleId)'); continue }
        if (-not $vistos.ContainsKey($id)) { $vistos[$id] = 0 }
        $vistos[$id]++

        if (-not $doPacote.ContainsKey($id)) {
            [void]$inventados.Add($id)
        } elseif ($vistos[$id] -gt $doPacote[$id]) {
            [void]$inventados.Add("$id (x$($vistos[$id]), o pacote trouxe $($doPacote[$id]))")
        }
    }

    # O lado que faltava: tudo que o pacote trouxe tem de aparecer.
    foreach ($id in $doPacote.Keys) {
        $tem = 0
        if ($vistos.ContainsKey($id)) { $tem = [int]$vistos[$id] }
        if ($tem -lt [int]$doPacote[$id]) {
            [void]$omitidos.Add("$id (o pacote trouxe $($doPacote[$id]), o laudo relatou $tem)")
        }
    }

    [pscustomobject]@{
        ok       = ($inventados.Count -eq 0 -and $omitidos.Count -eq 0)
        invented = @($inventados)
        omitted  = @($omitidos)
    }
}

<#
    Quarta conferência: as obrigações de forma que o pacote impõe ao laudo.

    Também nasceu de execução real. O mistral:latest passou nas três guardas
    anteriores e devolveu isto:

      notVerified : ""                          (com coverage.complete = falso)
      observations: ["A temperatura do GPU parece estar um pouco acima da média
                     normal durante o uso pesado..."]

    Duas falhas distintas, e nenhuma das guardas anteriores toca em qualquer uma:

    1. LACUNA CALADA. A cobertura estava incompleta e o campo que existe para
       dizer o que ficou sem verificar veio vazio. É o pior modo de falhar deste
       projeto inteiro: um laudo silencioso sobre a própria ignorância lê-se como
       "está tudo bem". "Lacuna declarada nunca vira 'tudo certo'" só vale se
       alguém CONFERIR que ela foi declarada.

    2. INVENÇÃO REALOCADA. O pacote não tinha nenhum achado — logo nenhuma
       temperatura, nenhuma série. Ainda assim o laudo afirmou que a placa parece
       quente. Sem número, a guarda aritmética dorme; em observations, a guarda
       de achados dorme. O campo que eu abri para hipótese virou a porta da
       invenção.

       A regra que fecha isso vem da definição do próprio campo: observations são
       "correlações entre achados e causas prováveis". Sem achado não há
       correlação entre achados nem causa provável de achado — então não há
       observação legítima a fazer. Pacote sem achados, observations vazio.
#>
<#
    Verdadeiro de verdade.

    Depois de uma volta por JSON, 'complete' pode chegar como a STRING "false" —
    e em PowerShell toda string não vazia é verdadeira, então "false" era lido
    como cobertura completa e a obrigação de declarar a lacuna simplesmente
    desaparecia. O tipo errado desligava a guarda em silêncio.
#>
function Test-WMTrue {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    if ($Value -is [string]) { return ([string]$Value).Trim() -match '^(?i:true|1|sim)$' }
    [bool]$Value
}

function Test-WMLaudoShape {
    param(
        [Parameter(Mandatory)]$Laudo,
        [Parameter(Mandatory)]$Package
    )

    $faltas = New-Object System.Collections.ArrayList

    <#
        Cobertura incompleta: o texto tem de NOMEAR pelo menos uma das lacunas.

        Conferir só que o campo não está em branco era conferir quase nada:
        '.', '-', 'n/a', 'nada' e até "Tudo foi verificado." satisfaziam a
        obrigação de declarar a lacuna. O comentário desta função dizia que o
        lema "lacuna declarada nunca vira tudo certo" só vale se alguém CONFERIR
        que ela foi declarada — e a conferência era de não-branco.

        Quando a cobertura está incompleta existe pelo menos uma chave de
        lacuna. Exigir que o texto cite uma delas é a diferença entre preencher
        o campo e responder à pergunta.
    #>
    <#
        Pacote SEM bloco coverage desligava a guarda inteira: '$Package.coverage
        -and ...' é falso quando o bloco não existe, e a ausência de declaração
        de cobertura virava dispensa de declarar cobertura. Ausência de coverage
        é o caso mais incompleto que existe, não o mais completo.
    #>
    if ($null -eq $Package.coverage) {
        [void]$faltas.Add('o pacote não trouxe bloco coverage: não há como afirmar que algo foi verificado')
    }

    $incompleta = ($null -eq $Package.coverage) -or (-not (Test-WMTrue $Package.coverage.complete))
    if ($incompleta -and $Package.coverage) {
        $lacunas = New-Object System.Collections.ArrayList
        foreach ($b in 'unsourced', 'malformed', 'noData', 'noBaseline', 'notApplicable') {
            foreach ($k in (Get-WMNodeKeys (Get-WMNodeChild $Package.coverage $b))) {
                [void]$lacunas.Add(([string]$k -split '#')[0])
            }
        }
        $texto = [string]$Laudo.notVerified

        if ([string]::IsNullOrWhiteSpace($texto)) {
            [void]$faltas.Add('cobertura incompleta e notVerified vazio: o laudo calou o que não foi verificado')
        } elseif ($lacunas.Count -gt 0) {
            $citou = $false
            foreach ($l in $lacunas) {
                if ($texto.IndexOf($l, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $citou = $true; break }
            }
            if (-not $citou) {
                [void]$faltas.Add("notVerified não nomeia nenhuma das lacunas do pacote ($($lacunas.Count) existem): preencher o campo não é declarar a lacuna")
            }
        }
    }

    if (@($Package.findings).Count -eq 0 -and @($Laudo.observations).Count -gt 0) {
        [void]$faltas.Add('pacote sem achados e observations preenchido: hipótese sobre o que ninguém mediu')
    }

    [pscustomobject]@{
        ok      = ($faltas.Count -eq 0)
        missing = @($faltas)
    }
}

# Junta os campos de texto do laudo num só bloco, para a conferência numérica.
function Get-WMLaudoText {
    param([Parameter(Mandatory)]$Laudo)
    $partes = New-Object System.Collections.ArrayList
    foreach ($c in 'summary', 'notVerified', 'changedSinceLast') {
        if ($Laudo.$c) { [void]$partes.Add([string]$Laudo.$c) }
    }
    foreach ($a in @($Laudo.findings)) {
        foreach ($c in 'reading', 'action') { if ($a.$c) { [void]$partes.Add([string]$a.$c) } }
    }
    foreach ($o in @($Laudo.observations)) { if ($o) { [void]$partes.Add([string]$o) } }
    $partes -join "`n"
}

Export-ModuleMember -Function `
    New-WMLaudoPackage, Get-WMAllowedNumbers, Test-WMLaudoNumbers, Test-WMLaudoRuleIds,
    Test-WMLaudoFindings, Test-WMLaudoShape, Test-WMTrue,
    Get-WMHardwarePhrases, Get-WMSpelledNumbers,
    Get-WMLaudoSystemPrompt, Get-WMLaudoSchema, Get-WMLaudoText
