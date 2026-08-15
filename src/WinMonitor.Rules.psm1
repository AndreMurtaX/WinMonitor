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
      naoSeAplica     o limiar é de um hardware que esta máquina não tem.

    Só a primeira é uma afirmação sobre a saúde da máquina. As outras três são
    afirmações sobre o que NÃO foi possível afirmar, e vão para o bloco de
    cobertura para que o parecer não possa escrever "nenhum problema
    encontrado" quando a verdade é "não olhei".
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
    $semDado      = [ordered]@{}
    $naoSeAplica  = [ordered]@{}
    $semLinhaBase = [ordered]@{}

    $textoHardware = ''
    if ($Hardware) {
        $textoHardware = (@($Hardware.cpuName, $Hardware.os) + @($Hardware.disks | ForEach-Object { $_.name })) -join ' | '
        if ($Hardware.gpus) { $textoHardware += ' | ' + (@($Hardware.gpus) -join ' ') }
    }

    foreach ($rule in $Rules.rules) {

        # --- procedência antes de qualquer coisa ----------------------------
        $fonte = Test-WMRuleSourced -Rule $rule
        if (-not $fonte.ok) {
            $semFonte[$rule.id] = $fonte.reason
            continue
        }

        # --- hardware -------------------------------------------------------
        if (-not [string]::IsNullOrWhiteSpace([string]$rule.appliesTo)) {
            if ([string]::IsNullOrWhiteSpace($textoHardware)) {
                $naoSeAplica[$rule.id] = "regra restrita a '$($rule.appliesTo)' e não há descrição de hardware para conferir"
                continue
            }
            if ($textoHardware -notlike "*$($rule.appliesTo)*") {
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
                if ($base.Count -eq 0) {
                    $semLinhaBase[$rule.id] = "sem referência na linha-base para $caminhoBase"
                    continue
                }
                $refBase = ConvertTo-WMNumber $base[0].value
                if ($null -eq $refBase) {
                    $semLinhaBase[$rule.id] = "referência da linha-base sem medida em $caminhoBase"
                    continue
                }

                if ($null -ne $rule.deltaPct) {
                    $limiar = $refBase * (1.0 + ([double]$rule.deltaPct / 100.0))
                } elseif ($null -ne $rule.delta) {
                    $limiar = $refBase + [double]$rule.delta
                } else {
                    $semFonte[$rule.id] = 'regra relativa sem delta nem deltaPct'
                    break
                }
            } else {
                if ($null -eq $rule.value) {
                    $semFonte[$rule.id] = 'regra absoluta sem valor de limiar'
                    break
                }
                $limiar = [double]$rule.value
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

    # --- veredito ------------------------------------------------------------
    $ordem = @{ 'normal' = 0; 'observar' = 1; 'agir' = 2; 'parar' = 3 }
    $veredito = 'normal'
    foreach ($a in $achados) {
        if ($ordem[$a.severity] -gt $ordem[$veredito]) { $veredito = $a.severity }
    }

    $lacunas = $semFonte.Count + $semDado.Count + $naoSeAplica.Count + $semLinhaBase.Count

    [pscustomobject][ordered]@{
        v        = 1
        window   = $Rollup.day
        host     = $Rollup.host
        verdict  = $veredito
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
            noData          = $semDado
            noBaseline      = $semLinhaBase
            notApplicable   = $naoSeAplica
        }
    }
}

Export-ModuleMember -Function `
    Get-WMNodeKeys, Get-WMNodeChild, Resolve-WMMetric, ConvertTo-WMConcretePath,
    Test-WMOperator, Test-WMRuleSourced, Invoke-WMRules
