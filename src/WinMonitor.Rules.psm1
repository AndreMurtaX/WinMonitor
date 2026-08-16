#requires -Version 5.1
<#
    WinMonitor — motor de regras.

    Função pura de dado para dado: entram o agregado, a linha-base e a tabela de
    limiares; saem Achados. Nenhuma leitura de disco, nenhuma chamada de
    sistema, nenhum modelo de linguagem. É a última camada determinística antes
    da fronteira, e é o que impede o parecer de inventar um número.

    AS QUATRO MANEIRAS DE UMA REGRA NÃO DISPARAR
    -------------------------------------------
    Elas NÃO são a mesma coisa, e confundi-las é o modo de falha que este
    projeto inteiro existe para evitar:

      passou          a métrica existe, foi comparada, está dentro do limiar.
      semDado         a métrica não existe no agregado. Nada foi verificado.
      semFonte        a regra não tem procedência declarada. Recusada de
                      propósito: limiar sem origem é palpite com aparência de
                      dado, e é pior que limiar nenhum.
      semLinhaBase    regra relativa sem referência congelada para comparar.
      naoSeAplica     o limiar é de um hardware que esta máquina não tem.
      malformada      a regra em si está errada (sem limiar, operador
                      desconhecido). Defeito de configuração, não da máquina —
                      e por isso não pode se disfarçar de problema de fonte.

    Só a primeira é uma afirmação sobre a saúde da máquina. As outras são
    afirmações sobre o que NÃO foi possível afirmar, e vão para o bloco de
    cobertura para que o parecer não possa escrever "nenhum problema
    encontrado" quando a verdade é "não olhei".

    DEPENDÊNCIA: usa ConvertTo-WMNumber de WinMonitor.Rollup.psm1, para que
    número aqui seja lido com o mesmo critério do armazém — cultura invariante,
    NaN e Infinity recusados. Quem importar este módulo precisa importar aquele.
#>

# ------------------------------------------------- navegação em objeto ------

# Chaves de um nó, seja ele PSCustomObject (vindo de JSON) ou dicionário.
function Get-WMNodeKeys {
    param($Node)
    if ($null -eq $Node) { return @() }
    if ($Node -is [System.Collections.IDictionary]) { return @($Node.Keys) }
    if ($Node -is [psobject] -and $Node.PSObject.Properties) {
        return @($Node.PSObject.Properties | ForEach-Object { $_.Name })
    }
    @()
}

function Get-WMNodeChild {
    param($Node, [string]$Key)
    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.Contains($Key)) { return $Node[$Key] }
        return $null
    }
    $p = $Node.PSObject.Properties[$Key]
    if ($null -eq $p) { return $null }
    $p.Value
}

<#
    Resolve um caminho de métrica, expandindo '*' em todas as chaves daquele
    nível. 'gpu.*.tempCByLoad.b75.p95' numa máquina de duas placas devolve duas
    entradas, cada uma com o caminho concreto — para o Achado poder dizer QUAL
    placa, em vez de "alguma".

    Devolve lista de @{ path; value }. Lista vazia significa métrica ausente,
    que quem chama trata como semDado — nunca como zero.
#>
function Resolve-WMMetric {
    param($Root, [Parameter(Mandatory)][string]$Path)

    $atual = @([pscustomobject]@{ path = @(); node = $Root })

    foreach ($seg in ($Path -split '\.')) {
        $prox = @()
        foreach ($c in $atual) {
            if ($null -eq $c.node) { continue }
            if ($seg -eq '*') {
                foreach ($k in (Get-WMNodeKeys $c.node)) {
                    $filho = Get-WMNodeChild $c.node $k
                    if ($null -ne $filho) {
                        $prox += [pscustomobject]@{ path = ($c.path + $k); node = $filho }
                    }
                }
            } else {
                $filho = Get-WMNodeChild $c.node $seg
                if ($null -ne $filho) {
                    $prox += [pscustomobject]@{ path = ($c.path + $seg); node = $filho }
                }
            }
        }
        $atual = $prox
    }

    $atual | ForEach-Object {
        [pscustomobject]@{ path = ($_.path -join '.'); value = $_.node }
    }
}

# Substitui os '*' de um caminho de regra pelos valores concretos de um caminho
# já resolvido, para achar a métrica equivalente na linha-base.
function ConvertTo-WMConcretePath {
    param([string]$Template, [string]$Resolved)
    $t = $Template -split '\.'
    $r = $Resolved -split '\.'
    if ($t.Count -ne $r.Count) { return $Resolved }
    $out = @()
    for ($i = 0; $i -lt $t.Count; $i++) {
        if ($t[$i] -eq '*') { $out += $r[$i] } else { $out += $t[$i] }
    }
    $out -join '.'
}

# ------------------------------------------------------ comparação ----------

$script:WM_OPERADORES = @('gt', 'gte', 'lt', 'lte')

# Usada só quando a tabela não declara severityScale. A escala real vem do
# arquivo: manter duas listas independentes que "coincidem por sorte" foi
# exatamente como uma severidade desconhecida passou despercebida.
$script:WM_ESCALA_PADRAO = @('normal', 'observar', 'agir', 'parar')

function Test-WMOperator {
    param([Parameter(Mandatory)][string]$Operator, [double]$Left, [double]$Right)
    switch ($Operator) {
        'gt'  { return $Left -gt  $Right }
        'gte' { return $Left -ge  $Right }
        'lt'  { return $Left -lt  $Right }
        'lte' { return $Left -le  $Right }
        default { throw "operador desconhecido: $Operator" }
    }
}

<#
    Confere que a regra é utilizável ANTES de tentar avaliá-la.

    Separado de Test-WMRuleSourced de propósito: regra malformada é defeito de
    configuração, não ausência de procedência, e misturar as duas faria o
    relatório dizer "sem fonte" sobre uma regra que tem fonte e está só
    escrita errada.
#>
function Test-WMRuleWellFormed {
    param($Rule, [string[]]$Scale = $script:WM_ESCALA_PADRAO)

    if ([string]::IsNullOrWhiteSpace([string]$Rule.id))     { return @{ ok = $false; reason = 'regra sem id' } }
    if ([string]::IsNullOrWhiteSpace([string]$Rule.metric)) { return @{ ok = $false; reason = 'regra sem metric' } }
    if ($Rule.operator -notin $script:WM_OPERADORES) {
        return @{ ok = $false; reason = "operador desconhecido: '$($Rule.operator)' (esperado: $($script:WM_OPERADORES -join ', '))" }
    }

    <#
        O LIMIAR passa pelo mesmo crivo da métrica.

        Antes, a métrica era lida por ConvertTo-WMNumber (cultura invariante,
        NaN e Infinity recusados) e o limiar por cast cru. A assimetria era o
        defeito: valor ilegível vindo da máquina virava lacuna declarada; valor
        ilegível vindo do arquivo que o humano edita virava número errado ou
        pane. Medido num Windows pt-BR, "9,3" no limiar virava 93 — dez vezes
        errado, calado —, "NaN" fazia a regra nunca disparar e ainda contar como
        avaliada, e "N/A" derrubava a avaliação inteira.
    #>
    if ($Rule.kind -eq 'relative') {
        if ($null -eq $Rule.delta -and $null -eq $Rule.deltaPct) {
            return @{ ok = $false; reason = 'regra relativa sem delta nem deltaPct' }
        }
        foreach ($campo in 'delta', 'deltaPct') {
            $bruto = $Rule.$campo
            if ($null -eq $bruto) { continue }
            if ($null -eq (ConvertTo-WMNumber $bruto)) {
                return @{ ok = $false; reason = "$campo não é um número utilizável: '$bruto'" }
            }
        }
    } elseif ($Rule.kind -eq 'absolute') {
        if ($null -eq $Rule.value) { return @{ ok = $false; reason = 'regra absoluta sem valor de limiar' } }
        if ($null -eq (ConvertTo-WMNumber $Rule.value)) {
            return @{ ok = $false; reason = "value não é um número utilizável: '$($Rule.value)'" }
        }
    } else {
        return @{ ok = $false; reason = "kind desconhecido: '$($Rule.kind)' (esperado: absolute, relative)" }
    }

    <#
        Severidade tem de PERTENCER à escala, não apenas ser não-vazia.

        Uma severidade desconhecida produzia achado com veredito 'normal' e
        cobertura completa: a ordenação usa índice na escala, e chave ausente
        devolve $null, que nunca é maior que nada. O achado entrava na lista e
        as duas informações que deveriam se qualificar mutuamente concordavam em
        dizer que estava tudo bem.
    #>
    if ([string]::IsNullOrWhiteSpace([string]$Rule.severity)) { return @{ ok = $false; reason = 'regra sem severity' } }
    if ($Rule.severity -cnotin $Scale) {
        return @{ ok = $false; reason = "severity '$($Rule.severity)' fora da escala declarada ($($Scale -join ', '))" }
    }

    @{ ok = $true; reason = $null }
}

<#
    Uma regra tem fonte utilizável?

    Recusa fonte ausente, kind vazio, kind 'pending', e texto vazio. Um kind
    'spec' sem url também é recusado: fato de hardware sem onde conferir não é
    fato, é lembrança.
#>
function Test-WMRuleSourced {
    param($Rule)
    $s = $Rule.source
    if ($null -eq $s) { return @{ ok = $false; reason = 'regra sem bloco source' } }
    if ([string]::IsNullOrWhiteSpace([string]$s.kind)) { return @{ ok = $false; reason = 'source.kind vazio' } }
    if ($s.kind -eq 'pending') {
        $t = [string]$s.text
        if ([string]::IsNullOrWhiteSpace($t)) { $t = 'sem justificativa' }
        return @{ ok = $false; reason = "fonte pendente: $t" }
    }
    if ($s.kind -notin @('spec', 'policy')) { return @{ ok = $false; reason = "source.kind desconhecido: $($s.kind)" } }
    if ([string]::IsNullOrWhiteSpace([string]$s.text)) { return @{ ok = $false; reason = 'source.text vazio' } }
    if ($s.kind -eq 'spec' -and [string]::IsNullOrWhiteSpace([string]$s.url)) {
        return @{ ok = $false; reason = 'fonte declarada como spec sem url para conferir' }
    }
    @{ ok = $true; reason = $null }
}

# ------------------------------------------------------- avaliação ----------

<#
    Avalia a tabela de regras contra um agregado e (opcionalmente) uma
    linha-base.

    -Hardware recebe os fatos da máquina (data\host.json) para o filtro
    appliesTo. Sem ele, regras com appliesTo são reportadas como naoSeAplica em
    vez de aplicadas às cegas.
#>
function Invoke-WMRules {
    param(
        [Parameter(Mandatory)]$Rollup,
        [Parameter(Mandatory)]$Rules,
        $Baseline,
        $Hardware
    )

    $achados = New-Object System.Collections.ArrayList
    $avaliadas    = New-Object System.Collections.ArrayList
    $semFonte     = [ordered]@{}
    $malformadas  = [ordered]@{}
    $semDado      = [ordered]@{}
    $naoSeAplica  = [ordered]@{}
    $semLinhaBase = [ordered]@{}

    <#
        A escala vem do ARQUIVO, não de uma cópia embutida no código. Duas
        listas independentes que coincidem por sorte foi como uma severidade
        desconhecida atravessou o motor inteiro sem ser notada.
    #>
    # Where-Object obrigatório: @($null).Count é 1, não 0, então sem o filtro
    # uma tabela sem severityScale produziria uma escala de um item nulo e o
    # fallback nunca dispararia.
    $escala = @($Rules.severityScale | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $problemasConfig = New-Object System.Collections.ArrayList

    <#
        A escala é a ordem do veredito, e o motor confia nela inteiramente.
        Uma escala invertida faria máquina sã reportar a severidade máxima com
        zero achados, e uma com duplicatas tornaria a ordenação ambígua. É
        falha ruidosa e não silenciosa — mas ruidosa e errada continua errada.

        Escala inválida NÃO derruba a avaliação: cai para a padrão e o
        problema fica declarado na saída, pelo mesmo princípio que vale para as
        regras — o que não pôde ser usado precisa aparecer.
    #>
    if ($escala.Count -eq 0) {
        if (@($Rules.severityScale).Count -gt 0) {
            [void]$problemasConfig.Add('severityScale só continha itens vazios; usando a escala padrão')
        }
        $escala = $script:WM_ESCALA_PADRAO
    } elseif (@($escala | Sort-Object -Unique).Count -ne $escala.Count) {
        [void]$problemasConfig.Add("severityScale tem itens repetidos ($($escala -join ', ')); a ordenação seria ambígua. Usando a escala padrão.")
        $escala = $script:WM_ESCALA_PADRAO
    }

    $textoHardware = ''
    if ($Hardware) {
        $textoHardware = (@($Hardware.cpuName, $Hardware.os) + @($Hardware.disks | ForEach-Object { $_.name })) -join ' | '
        if ($Hardware.gpus) { $textoHardware += ' | ' + (@($Hardware.gpus) -join ' ') }
    }

    $indice = 0
    foreach ($rule in $Rules.rules) {
        $indice++

        <#
            REGRA SEM id MATAVA O MOTOR INTEIRO, e com ele o monitor.

            Toda lacuna é registrada indexando por $rule.id. Com id nulo, o
            índice de matriz é avaliado como nulo e Invoke-WMRules lança — não
            há arquivo de achados, Invoke-Report diz "nenhum arquivo de achados",
            e o sistema emudece. A guarda 'regra sem id' EXISTIA em
            Test-WMRuleWellFormed; o que morria era justamente a linha que
            registrava o veredito dela.

            thresholds.json é, por desenho declarado, o arquivo que humanos
            editam. Uma vírgula fora do lugar não pode calar o monitor: a regra
            sem identificação vira lacuna com nome sintético, e o dia continua.
        #>
        $rid = [string]$rule.id
        if ([string]::IsNullOrWhiteSpace($rid)) {
            $malformadas["(regra #$indice sem id)"] = 'regra sem id na tabela de limiares: impossível identificá-la, avaliá-la ou citá-la num laudo'
            continue
        }

        <#
            Procedência ANTES de forma. A ordem importa: uma regra pendente
            legitimamente ainda não tem limiar preenchido, e checar a forma
            primeiro a reportaria como malformada quando a verdade é que ela
            está esperando alguém citar a fonte.
        #>
        $fonte = Test-WMRuleSourced -Rule $rule
        if (-not $fonte.ok) {
            $semFonte[$rule.id] = $fonte.reason
            continue
        }

        $forma = Test-WMRuleWellFormed -Rule $rule -Scale $escala
        if (-not $forma.ok) {
            $malformadas[$rule.id] = $forma.reason
            continue
        }

        # --- hardware -------------------------------------------------------
        if (-not [string]::IsNullOrWhiteSpace([string]$rule.appliesTo)) {
            if ([string]::IsNullOrWhiteSpace($textoHardware)) {
                $naoSeAplica[$rule.id] = "regra restrita a '$($rule.appliesTo)' e não há descrição de hardware para conferir"
                continue
            }
            <#
                Comparação literal, não curinga. Com -like, um colchete ou uma
                interrogação no nome do modelo mudaria o significado do filtro:
                'RTX [39]080' casaria com 3080 E 9080, e 'GeForce?RTX' casaria
                com qualquer caractere no lugar do espaço.
            #>
            if ($textoHardware.IndexOf([string]$rule.appliesTo, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                $naoSeAplica[$rule.id] = "regra restrita a '$($rule.appliesTo)'; esta máquina não corresponde"
                continue
            }
        }

        # --- métrica --------------------------------------------------------
        $alvos = @(Resolve-WMMetric -Root $Rollup -Path $rule.metric)
        $alvos = @($alvos | Where-Object { $null -ne (ConvertTo-WMNumber $_.value) })

        if ($alvos.Count -eq 0) {
            $semDado[$rule.id] = "métrica ausente ou sem medida: $($rule.metric)"
            continue
        }

        $rodou = $false

        foreach ($alvo in $alvos) {
            $valor = ConvertTo-WMNumber $alvo.value

            $limiar   = $null
            $refBase  = $null

            if ($rule.kind -eq 'relative') {
                if ($null -eq $Baseline) {
                    $semLinhaBase[$rule.id] = 'regra relativa sem linha-base congelada'
                    break
                }
                $caminhoBase = ConvertTo-WMConcretePath -Template $rule.metric -Resolved $alvo.path
                $base = @(Resolve-WMMetric -Root $Baseline.profile -Path $caminhoBase)

                # Indexado pelo CAMINHO e não pela regra: com curinga, uma
                # entrada por regra perderia qual GPU ficou sem referência —
                # só a última mensagem sobreviveria.
                if ($base.Count -eq 0) {
                    $semLinhaBase["$($rule.id)#$caminhoBase"] = "sem referência na linha-base para $caminhoBase"
                    continue
                }
                $refBase = ConvertTo-WMNumber $base[0].value
                if ($null -eq $refBase) {
                    $semLinhaBase["$($rule.id)#$caminhoBase"] = "referência da linha-base sem medida em $caminhoBase"
                    continue
                }

                # Forma já validada: existe delta ou deltaPct, e converte.
                if ($null -ne $rule.deltaPct) {
                    $limiar = $refBase * (1.0 + ((ConvertTo-WMNumber $rule.deltaPct) / 100.0))
                } else {
                    $limiar = $refBase + (ConvertTo-WMNumber $rule.delta)
                }
            } else {
                $limiar = ConvertTo-WMNumber $rule.value
            }

            $rodou = $true
            if (-not (Test-WMOperator -Operator $rule.operator -Left $valor -Right $limiar)) { continue }

            $evidencia = New-Object System.Collections.ArrayList
            [void]$evidencia.Add([ordered]@{ metric = $alvo.path; value = $valor; from = 'agregado' })
            if ($null -ne $refBase) {
                [void]$evidencia.Add([ordered]@{ metric = (ConvertTo-WMConcretePath -Template $rule.metric -Resolved $alvo.path); value = $refBase; from = 'linha-base' })
            }

            [void]$achados.Add([pscustomobject][ordered]@{
                id        = ('{0}#{1}' -f $rule.id, $alvo.path)
                ruleId    = $rule.id
                severity  = $rule.severity
                subsystem = $rule.subsystem
                claim     = $rule.claim
                evidence  = @($evidencia)
                rule      = [ordered]@{
                    kind      = $rule.kind
                    operator  = $rule.operator
                    threshold = $limiar
                    source    = $rule.source
                }
            })
        }

        if ($rodou) { [void]$avaliadas.Add($rule.id) }
    }

    <#
        Veredito pela posição na escala DECLARADA.

        A forma da regra já garantiu que toda severidade que chega aqui
        pertence à escala, então não há mais o caso de chave ausente devolver
        $null e nunca ser maior que nada — que era como um achado grave
        conviveu com veredito 'normal'.
    #>
    $ordem = @{}
    for ($i = 0; $i -lt $escala.Count; $i++) { $ordem[$escala[$i]] = $i }

    $veredito = $escala[0]
    foreach ($a in $achados) {
        if ($ordem[$a.severity] -gt $ordem[$veredito]) { $veredito = $a.severity }
    }

    $lacunas = $semFonte.Count + $malformadas.Count + $semDado.Count + $naoSeAplica.Count + $semLinhaBase.Count

    <#
        ZERO REGRA AVALIADA NÃO É COBERTURA COMPLETA.

        Medido: tabela sem a chave 'rules', ou com 'rules': [], devolvia
        verdict=normal, findings=0 e complete=TRUE — que vira "Veredito: normal,
        Cobertura: completa" no relatório entregue. Nada foi medido e a saída
        afirmava que tudo foi verificado.

        O lema desta camada é que silêncio não é aprovação. Sem esta linha, ele
        era satisfeito vacuamente: zero lacunas porque zero perguntas.
    #>
    if (@($avaliadas).Count -eq 0) {
        [void]$problemasConfig.Add('nenhuma regra foi avaliada: a tabela de limiares está vazia, ilegível ou inteiramente descartada. Cobertura declarada INCOMPLETA — nada foi medido.')
        $lacunas++
    }

    [pscustomobject][ordered]@{
        v        = 1
        window   = $Rollup.day
        host     = $Rollup.host
        verdict  = $veredito
        severityScale  = @($escala)
        configProblems = @($problemasConfig)
        findings = @($achados)
        coverage = [ordered]@{
            <#
                coverageComplete existe para o parecer não poder tratar
                "veredito normal" como "máquina saudável" quando metade das
                regras não pôde ser avaliada. Veredito e cobertura são duas
                informações, e a segunda qualifica a primeira.
            #>
            complete        = ($lacunas -eq 0)
            evaluated       = @($avaliadas)
            unsourced       = $semFonte
            malformed       = $malformadas
            noData          = $semDado
            noBaseline      = $semLinhaBase
            notApplicable   = $naoSeAplica
        }
    }
}

Export-ModuleMember -Function `
    Get-WMNodeKeys, Get-WMNodeChild, Resolve-WMMetric, ConvertTo-WMConcretePath,
    Test-WMOperator, Test-WMRuleSourced, Test-WMRuleWellFormed, Invoke-WMRules
