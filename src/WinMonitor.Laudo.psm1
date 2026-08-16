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
<#
    Um pedaço de texto que é IDENTIFICADOR e não pode ser medida.

    O critério é ter letra e dígito juntos: 'i9-11900K', 'MP600',
    'ST10000NM001G-2MW103'. Nenhuma temperatura, percentual ou contagem se
    escreve assim, então remover isso do texto não abre porta nenhuma.

    Só dígito NÃO é identificador, por mais que venha do hardware: '98', '103'
    e '3080' são exatamente o que um modelo escreveria como medida inventada.
#>
function Test-WMIdentifierToken {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
    ($Token -match '\d') -and ($Token -match '\p{L}')
}

function Get-WMHardwarePhrases {
    param($Hardware)

    $frases = New-Object System.Collections.ArrayList
    if ($null -eq $Hardware) { return @() }

    foreach ($texto in (Get-WMStringsDeep -Node $Hardware)) {
        if ([string]::IsNullOrWhiteSpace($texto)) { continue }

        $tokens = @($texto -split '\s+' | Where-Object { $_ })

        <#
            A string INTEIRA só entra se ela própria obedecer ao critério. Antes
            entrava incondicionalmente, e isso reabria o buraco que a função
            existe para fechar: um campo de hardware cujo valor é só dígito —
            'disks[].id' vale "98" numa máquina com dez discos — virava frase
            sozinho e liberava 98 como temperatura. Medido.
        #>
        if ($tokens.Count -ge 2 -or (Test-WMIdentifierToken $texto)) { [void]$frases.Add($texto) }

        foreach ($t in $tokens) {
            # Misto letra+dígito: identificador, não medida. Sai sozinho.
            if (Test-WMIdentifierToken $t) { [void]$frases.Add($t) }
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

    $todas = @('mil') + @($cem.Keys) + @($dez.Keys) + @($unid.Keys)
    $alt   = ($todas | ForEach-Object { [regex]::Escape($_) }) -join '|'

    <#
        A frase inteira, não a palavra solta: 'noventa e cinco' precisa somar 95,
        e não produzir 90 e 5 separados — o 5 seria aceito por qualquer coisa
        perto de 5 e o 95 inventado escaparia.
    #>
    $padrao = "(?i)\b(?:$alt)(?:\s+e\s+(?:$alt))*\b"

    <#
        'por cento' NÃO é o número cem. É a unidade percentual, e a leitura
        ingênua injetava um 100 fantasma em qualquer laudo que escrevesse
        "2 por cento de uso" — recusando texto honesto. Percentual é a unidade
        mais natural de um relatório de espaço em disco, então isso não é caso
        de borda.
    #>
    $semPorCento = [regex]::Replace($Text, '(?i)\bpor\s+cento\b', ' ')

    foreach ($m in [regex]::Matches($semPorCento, $padrao)) {
        $partes = @($m.Value.ToLowerInvariant() -split '\s+e\s+' | ForEach-Object { $_.Trim() })

        <#
            A soma só vale para numeral COMPOSTO de verdade: centena, depois
            dezena, depois unidade, sempre em magnitude decrescente. 'noventa e
            cinco' é 95; 'entre dois e três dias' NÃO é 5 — são dois numerais
            distintos ligados por uma conjunção comum, e somá-los inventava um
            órfão em prosa honesta.
        #>
        <#
            'mil' entra como a classe mais alta. 'dois mil MB' é medida
            perfeitamente plausível, e sem isto o número passava por não ter
            dígito — a mesma porta que 'noventa e cinco' usava.

            A multiplicação ('dois mil') fica de fora de propósito: exigiria um
            analisador de numeral de verdade, e o ganho não paga a chance de
            errar. 'mil' sozinho vale 1000, e 'dois' é contado à parte — o que
            pode gerar órfão a mais, nunca a menos.
        #>
        $classe = { param($p)
            if ($p -eq 'mil')       { return 4 }
            if ($cem.Contains($p))  { return 3 }
            if ($dez.Contains($p))  { return 2 }
            if ($unid.Contains($p)) { return 1 }
            0
        }
        $valor = { param($p)
            if ($p -eq 'mil')       { return 1000 }
            if ($cem.Contains($p))  { return [int]$cem[$p] }
            if ($dez.Contains($p))  { return [int]$dez[$p] }
            if ($unid.Contains($p)) { return [int]$unid[$p] }
            0
        }

        $total    = 0
        $anterior = 99
        $valeu    = $false
        foreach ($p in $partes) {
            $c = & $classe $p
            if ($c -eq 0) { continue }
            if ($c -ge $anterior) {
                # Magnitude não decresceu: acabou o numeral composto.
                if ($valeu) { [pscustomobject]@{ value = $total; text = $m.Value } }
                $total = 0; $valeu = $false; $anterior = 99
            }
            $total += (& $valor $p)
            $anterior = $c
            $valeu = $true
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
    <#
        A chave de cobertura entra INTEIRA e também sem o sufixo '#métrica'.

        Regra relativa gera chave como 'R-GPU-TEMP-DRIFT#gpu.0.tempCByLoad...',
        e o identificador da regra é só o pedaço antes do '#'. Test-WMLaudoRuleIds
        já fazia o split; esta função não fazia. Sobre o MESMO dado, uma guarda
        aceitava o id e a outra o via como texto desconhecido — e num id com
        dígito, como R-GPU-TEMP-SPEC-3080, o 3080 virava número inventado num
        laudo honesto.

        Pior: a forma MAIS correta era a que reprovava. Declarar o id puro (que é
        o certo) falhava; declarar a chave com o caminho colado passava.
    #>
    if ($Package.coverage) {
        foreach ($b in 'unsourced', 'malformed', 'noData', 'noBaseline', 'notApplicable') {
            foreach ($k in (Get-WMNodeKeys (Get-WMNodeChild $Package.coverage $b))) {
                [void]$literais.Add([string]$k)
                [void]$literais.Add(([string]$k -split '#')[0])
            }
        }
        # 'evaluated' guarda o id puro (WinMonitor.Rules.psm1) — só os baldes de
        # lacuna geram chave com '#'. Separar aqui seria no-op com cara de defesa.
        foreach ($k in @($Package.coverage.evaluated)) { [void]$literais.Add([string]$k) }
    }
    [void]$literais.Add([string]$Package.window)
    if ($Package.previous) { [void]$literais.Add([string]$Package.previous.window) }
    # Nomes de peça, como FRASE. Ver Get-WMHardwarePhrases: '3080' sozinho não
    # entra aqui, só acompanhado, e é isso que impede o nome de virar medida.
    foreach ($f in (Get-WMHardwarePhrases -Hardware $Package.hardware)) { [void]$literais.Add($f) }

    <#
        Do mais longo para o mais curto: senão um prefixo come o token maior.

        E ANCORADO EM FRONTEIRA DE PALAVRA, que foi um vazamento medido: a frase
        "11 Pro" sai de "Microsoft Windows 11 Pro" no host.json real, e sem
        âncora ela casava o começo de "11 processos" — apagando um 11 que o
        modelo inventou. Ponta a ponta, "havia 11 processos travados" era
        APROVADO e "havia 11 travamentos" era reprovado; a diferença era só a
        palavra depois do dígito.

        Lookaround em vez de \b porque muitos literais começam ou terminam em
        caractere não-alfanumérico — 'sto.volFreeGB.C:.min', 'Intel(R)' — e \b
        não se comporta na borda desses.
    #>
    foreach ($lit in (@($literais | Where-Object { $_ }) | Sort-Object { $_.Length } -Descending)) {
        $padrao = '(?<![\w])' + [regex]::Escape($lit) + '(?![\w])'
        $limpo = [regex]::Replace($limpo, $padrao, ' ', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
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
        <#
            Token que o regex casou e o conversor recusou vira ÓRFÃO, não é
            descartado. O '\d' do .NET casa dígito Unicode — largura inteira,
            indo-arábico — e ConvertTo-WMNumber, que é invariante, recusa.
            O 'continue' que havia aqui jogava fora em silêncio exatamente o
            token mais suspeito do texto: um número escrito de forma que a
            conferência não sabe ler.
        #>
        if ($null -eq $n) {
            if (-not $orfaos.Contains($m.Value)) { [void]$orfaos.Add($m.Value) }
            continue
        }
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
    <#
        Letra COM acento no conjunto: 'R-MEMÓRIA-VAZANDO' escapava inteira,
        porque \b não fecha fronteira entre 'M' e 'Ó' e o padrão não casava
        nada. Num laudo em português essa é a grafia provável — a guarda só
        funcionava enquanto o modelo não acentuasse.

        \p{L} em vez de A-Z pela mesma razão, e as âncoras viram lookaround
        porque \b é definido em cima de \w e volta a falhar na borda acentuada.
    #>
    <#
        DOIS SEGMENTOS, no mínimo. Identificador de regra deste projeto sempre
        tem a forma R-ALGO-ALGO: R-GPU-TEMP-DRIFT, R-DISK-SPACE-LOW. Exigir o
        segundo hífen elimina os falsos positivos que a versão anterior criava
        em prosa portuguesa — 'r-quadrado', 'R-123' e afins eram acusados de
        regra inventada, e guarda que reprova texto honesto acaba desligada por
        quem a mantém.
    #>
    foreach ($m in [regex]::Matches($Text, '(?i)(?<![\p{L}\d])R[-_][\p{L}\d]+[-_][\p{L}\d_-]+(?![\p{L}\d])')) {
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

Cada achado do seu findings precisa de TRÊS campos preenchidos: ruleId, reading e action. reading é o que foi medido, dito em português para uma pessoa. action é o que fazer a respeito — e quando não há ação necessária, escreva isso ("acompanhar na próxima ronda; nada a fazer agora"), porque campo vazio é rejeitado. Nenhum dos três aceita string em branco, ponto, traço ou "n/a".

Há uma conferência automática que compara o seu findings com o do pacote e rejeita o laudo inteiro nos DOIS sentidos: se você acrescentar um achado que não veio, e se você deixar de relatar um que veio. Apagar é a falha mais grave das duas — achado inventado faz alguém olhar a máquina à toa; achado apagado faz ninguém olhar. Se a rejeição disser que faltou preencher um campo, PREENCHA o campo: não remova o achado.

O campo notVerified é uma LISTA, e ela tem de conter TODAS as lacunas que o pacote lista em coverage — uma entrada por regra, com o ruleId exato. Não é você que escolhe quais menciona.

Em note, ao lado de cada id, escreva o que a falta daquela verificação significa na prática para quem lê. O que não cabe em note é dizer que a regra foi verificada, ou que está normal, ou que nada indica problema: ela está nessa lista precisamente porque NINGUÉM olhou. Afirmar o contrário ali é a pior frase que este laudo pode conter.

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
    "notVerified":  { "type": "array", "items": { "type": "object",
                       "properties": { "ruleId": {"type":"string"},
                                       "note": {"type":"string"} },
                       "required": ["ruleId","note"],
                       "additionalProperties": false } },
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

    $inventados  = New-Object System.Collections.ArrayList
    $omitidos    = New-Object System.Collections.ArrayList
    $incompletos = New-Object System.Collections.ArrayList
    $vistos      = @{}
    foreach ($a in @($Laudo.findings)) {
        <#
            Item NULO é campo ausente, não achado sem identificador.

            @($null) rende UM elemento nulo, e sem esta linha um laudo que
            simplesmente omitia a chave 'findings' era acusado de relatar
            '(achado sem ruleId)'. Medido de ponta a ponta: pacote sem nenhum
            achado, laudo dizendo "nada mereceu atenção no período" — REPROVADO
            nas duas tentativas, com a guarda afirmando que ele relatou um
            achado inventado.

            É o caso mais comum que este sistema vai encontrar: máquina
            saudável. E a reapresentação não tinha como ajudar, porque mandava o
            modelo remover um achado que ele nunca escreveu.

            Toda fixture do projeto trazia "findings":[] — presente e vazio,
            nunca ausente. O teste cobria a forma que não quebrava.
        #>
        if ($null -eq $a) { continue }

        $id = [string]$a.ruleId
        if ([string]::IsNullOrWhiteSpace($id)) { [void]$inventados.Add('(achado sem ruleId)'); continue }

        <#
            ACHADO INCOMPLETO É CATEGORIA PRÓPRIA, e a distinção custou uma
            reprovação inteira.

            Achado com ruleId legítimo mas sem leitura ou sem ação era jogado em
            'inventados' e o 'continue' pulava a contagem. Consequência medida:
            o MESMO achado era acusado de inventado E de apagado na mesma
            execução — duas mensagens que se contradizem, ambas falsas, sobre um
            achado que o pacote trouxe e o laudo relatou.

            E o beco sem saída: o modelo que OBEDECIA a primeira rejeição
            removia o achado, e a segunda tentativa era reprovada por APAGOU.
            Laudo honesto na lixeira em duas tentativas, com a guarda mentindo
            nas duas.

            Agora ele CONTA (não é omissão) e vai para uma lista própria, cuja
            mensagem pede o que falta em vez de acusar invenção.
        #>
        if (-not $vistos.ContainsKey($id)) { $vistos[$id] = 0 }
        $vistos[$id]++

<#
            NÃO-BRANCO NÃO BASTA, e o projeto já sabia disso.

            O prompt escrito neste mesmo commit promete que ponto, traço e 'n/a'
            são recusados. A guarda usava só IsNullOrWhiteSpace e aceitava os
            três — medido. É exatamente a lição que a camada aprendeu ao abolir
            a prosa em notVerified ("conferir só que o campo não está em branco
            era conferir quase nada"), reintroduzida no campo novo, agora com o
            prompt afirmando a regra forte.

            E vale a doutrina que este arquivo já registra: entre o prompt e a
            guarda, quem vale é a guarda. Então a guarda passa a fazer o que o
            prompt promete.
        #>
        $faltantes = @()
        if (-not (Test-WMTextoSubstantivo $a.reading)) { $faltantes += 'reading' }
        if (-not (Test-WMTextoSubstantivo $a.action))  { $faltantes += 'action' }
        if ($faltantes.Count -gt 0) {
            [void]$incompletos.Add("$id (falta preencher: $($faltantes -join ', '))")
        }

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
        ok         = ($inventados.Count -eq 0 -and $omitidos.Count -eq 0 -and $incompletos.Count -eq 0)
        invented   = @($inventados)
        omitted    = @($omitidos)
        incomplete = @($incompletos)
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
<#
    Texto que diz alguma coisa.

    Recusa o vazio e também os preenchimentos de fachada — '.', '-', 'n/a',
    '...', '?', 'null' — que satisfazem qualquer conferência de não-branco. O
    piso de dois caracteres alfanuméricos é grosseiro de propósito: não julga
    conteúdo, só exige que exista conteúdo.
#>
function Test-WMTextoSubstantivo {
    param($Value)
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    $s = $s.Trim()
    if ($s -match '^(?i:n/?a|nulo|null|nenhum|nada|sem|-+|\.+|\?+|_+)$') { return $false }
    (@([regex]::Matches($s, '[\p{L}\d]')).Count -ge 2)
}

function Test-WMTrue {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    if ($Value -is [string]) { return ([string]$Value).Trim() -match '^(?i:true|1|sim)$' }
    [bool]$Value
}

<#
    Conta itens de verdade num campo que pode vir como lista, nulo, vazio ou
    escalar.

    Existe porque @($null).Count é UM em PowerShell, não zero — e @('') também.
    A armadilha já mordeu este projeto na escala de severidade, está registrada,
    e mesmo assim voltou: o ramo que confere 'cobertura completa e notVerified
    preenchido' reprovava laudo honesto cujo notVerified era ausente ou nulo,
    afirmando que o campo estava PREENCHIDO. A guarda dizia o contrário do que
    tinha acontecido, que é a pior coisa que uma mensagem de erro pode fazer.
#>
function Get-WMRealCount {
    param($Value)
    @($Value | Where-Object {
        $null -ne $_ -and -not ($_ -is [string] -and [string]::IsNullOrWhiteSpace($_))
    }).Count
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
                $id = ([string]$k -split '#')[0]
                if (-not $lacunas.Contains($id)) { [void]$lacunas.Add($id) }
            }
        }

        <#
            AQUI A PROSA FOI ABOLIDA, e a razão é uma derrota medida.

            A versão anterior exigia que o texto NOMEASSE uma lacuna. O
            verificador respondeu com:

              "R-CPU-TEMP-SPEC foi verificada e está normal. R-GPU-TEMP-DRIFT
               também foi conferida e nada indica problema. Tudo foi verificado."

            Aprovado e apresentado. Nomeava as lacunas — e negava cada uma. A
            mesma frase "Tudo foi verificado." sozinha era rejeitada; colada
            atrás de um identificador, passava.

            Não existe conferência aritmética de negação em prosa livre, e
            tentar denylist de "foi verificada", "está normal", "nada indica" é
            perder a corrida contra um gerador de frases. Então o campo deixa de
            ser prosa: notVerified passa a ser LISTA DE IDENTIFICADORES, e a
            lista tem de cobrir TODAS as lacunas do pacote.

            O modelo continua podendo comentar cada uma — em 'note', ao lado do
            id. O que ele não pode mais é escolher quais lacunas menciona, nem
            fazer a estrutura dizer o contrário do que a prosa diz: quem
            renderiza o laudo imprime a lista sob o título NÃO VERIFICADO, e
            essa é a afirmação que fica.

            É a mesma lição dos achados, aplicada de novo: o que precisa ser
            conferido não pode morar em texto corrido.
        #>
        $declaradas = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($n in @($Laudo.notVerified)) {
            if ($null -eq $n) { continue }
            $id = if ($n -is [string]) { [string]$n } else { [string]$n.ruleId }
            # Trim: sem ele, ' R-CPU-TEMP-SPEC' reprovava com DUAS mensagens
            # visualmente idênticas ao id correto — diagnóstico ilegível.
            if (-not [string]::IsNullOrWhiteSpace($id)) { [void]$declaradas.Add((($id -split '#')[0]).Trim()) }
        }

        $faltando = @($lacunas | Where-Object { -not $declaradas.Contains($_) })
        if ($faltando.Count -gt 0) {
            [void]$faltas.Add("notVerified não declara $($faltando.Count) de $($lacunas.Count) lacunas do pacote: $($faltando -join ', ')")
        }

        <#
            E O SENTIDO INVERSO, que faltava e custou a terceira reprovação.

            Conferir só COBERTURA deixava o campo aceitar qualquer identificador
            inventado. Medido pelo driver, contra os achados reais:

              - R-SMART-DISK-FAILING e R-PSU-VOLTAGE-SAG, regras que não existem
                em thresholds.json: aprovadas e impressas sob "Não verificado".
              - R-CPU-TEMP-100C-ATINGIDA: o 100 viajou dentro do identificador,
                onde a guarda aritmética não olha. É exatamente o número que a
                tabela de limiares se recusa a escrever por falta de procedência.
              - R-DISK-SPACE-LOW declarada não verificada NO MESMO laudo que
                imprime o achado 'agir' dela três linhas acima.

            A causa é a de sempre neste projeto, e é a terceira vez: campo
            estruturado que nenhuma guarda inspeciona. Quando o mesmo id era
            escrito na PROSA, Test-WMLaudoRuleIds o acusava; dentro do objeto,
            passava — porque Get-WMLaudoText só repassava 'note'.

            Duas travas agora. Aqui: todo id declarado tem de ser uma lacuna DO
            PACOTE — nem regra inexistente, nem regra que foi avaliada. E em
            Get-WMLaudoText: o ruleId passa a entrar no texto conferido, para
            que número embutido em identificador inventado caia na guarda
            aritmética como qualquer outro.
        #>
        $intrusos = @($declaradas | Where-Object { $lacunas -notcontains $_ })
        if ($intrusos.Count -gt 0) {
            [void]$faltas.Add("notVerified declara o que não é lacuna do pacote: $($intrusos -join ', ')")
        }
    }
    elseif ($Package.coverage -and (Get-WMRealCount $Laudo.notVerified) -gt 0) {
        <#
            Cobertura COMPLETA e notVerified preenchido: não há lacuna nenhuma
            para declarar, então tudo que estiver ali é invenção. Sem este ramo,
            o bloco acima nem roda e o campo fica livre.

            A condição exige coverage EXISTINDO: sem bloco de cobertura, a falta
            já foi registrada acima, e dizer "cobertura completa" sobre um pacote
            que não trouxe cobertura nenhuma seria mais uma mensagem falsa.
        #>
        [void]$faltas.Add('cobertura completa e notVerified preenchido: não há lacuna a declarar')
    }

    <#
        Get-WMRealCount nos DOIS lados, pelo mesmo motivo de sempre: com
        observations ausente, @($null).Count é UM e esta linha acusava hipótese
        num laudo que não tinha hipótese nenhuma.

        Encontrado por execução, depois de eu ter consertado a linha vizinha e
        não olhado esta. É literalmente o padrão que quatro verificações
        seguidas apontaram — conserto o ponto exato e paro de olhar em volta.
    #>
    if ((Get-WMRealCount $Package.findings) -eq 0 -and (Get-WMRealCount $Laudo.observations) -gt 0) {
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
    foreach ($c in 'summary', 'changedSinceLast') {
        if ($Laudo.$c) { [void]$partes.Add([string]$Laudo.$c) }
    }
    <#
        O ruleId ENTRA no texto conferido, não só a nota.

        Enquanto só a nota entrava, um identificador inventado passeava com
        número dentro: 'R-CPU-TEMP-100C-ATINGIDA' era aprovado e o 100 nunca
        chegava à guarda aritmética. Identificador legítimo é removido pela
        lista de literais — ele está em coverage —, então incluí-lo aqui não
        acusa laudo honesto; o inventado, que não é literal de nada, fica
        exposto com todos os dígitos que carrega.
    #>
    foreach ($n in @($Laudo.notVerified)) {
        if ($null -eq $n) { continue }
        if ($n -is [string]) { [void]$partes.Add([string]$n) }
        else {
            if ($n.ruleId) { [void]$partes.Add([string]$n.ruleId) }
            if ($n.note)   { [void]$partes.Add([string]$n.note) }
        }
    }
    foreach ($a in @($Laudo.findings)) {
        foreach ($c in 'reading', 'action') { if ($a.$c) { [void]$partes.Add([string]$a.$c) } }
    }
    foreach ($o in @($Laudo.observations)) { if ($o) { [void]$partes.Add([string]$o) } }
    $partes -join "`n"
}

Export-ModuleMember -Function `
    New-WMLaudoPackage, Get-WMAllowedNumbers, Test-WMLaudoNumbers, Test-WMLaudoRuleIds,
    Test-WMLaudoFindings, Test-WMLaudoShape, Test-WMTrue, Get-WMRealCount, Test-WMTextoSubstantivo,
    Get-WMHardwarePhrases, Get-WMSpelledNumbers,
    Get-WMLaudoSystemPrompt, Get-WMLaudoSchema, Get-WMLaudoText
