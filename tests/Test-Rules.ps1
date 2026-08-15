#requires -Version 5.1
<#
    Testes do motor de regras.

    As regras são construídas a partir de JSON, e não de hashtables, de
    propósito: em produção elas chegam como PSCustomObject vindo de
    ConvertFrom-Json, e testar com dicionário testaria um caminho de código
    diferente do que roda de verdade.

    O grupo que mais importa é "silêncio não é aprovação". Ele existe porque o
    modo de falha mais grave desta camada não é errar um limiar — é uma regra
    deixar de rodar e o relatório sair limpo, com o parecer lendo ausência de
    achado como ausência de problema.

      .\tests\Test-Rules.ps1
#>
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TestKit.ps1')
Import-Module (Join-Path $root 'src\WinMonitor.psm1')        -Force
Import-Module (Join-Path $root 'src\WinMonitor.Rollup.psm1') -Force
Import-Module (Join-Path $root 'src\WinMonitor.Rules.psm1')  -Force

function New-Rules { param([string]$Json) $Json | ConvertFrom-Json }
function New-Data  { param([string]$Json) $Json | ConvertFrom-Json }

$FONTE_OK = '"source":{"kind":"policy","text":"motivo declarado","url":"","verifiedAt":"2026-08-15"}'

# Agregado de referência: GPU 0 quente e contida, GPU 1 fria.
$ROLLUP = New-Data @'
{ "day":"2026-08-14","host":"TESTE","reboots":2,
  "cpu":{"util":{"p50":30},"mhzByLoad":{"b75":{"p50":4200}}},
  "mem":{"poolNonpagedMB":{"p50":3900}},
  "sto":{"volFreeGB":{"C:":{"min":12.4},"D:":{"min":900}}},
  "gpu":{"0":{"name":"NVIDIA GeForce RTX 3080",
              "throttle":{"thermal":12,"thermalMeasured":1440},
              "tempCAllDay":{"max":94},
              "tempCByLoad":{"b75":{"p95":86,"n":300}}},
         "1":{"name":"Intel UHD Graphics",
              "throttle":{"thermal":0,"thermalMeasured":1440},
              "tempCAllDay":{"max":45},
              "tempCByLoad":{"b00":{"p95":44,"n":1400}}}} }
'@

$BASELINE = New-Data @'
{ "profile":{ "cpu":{"mhzByLoad":{"b75":{"p50":4900}}},
              "mem":{"poolNonpagedMB":{"p50":2600}},
              "gpu":{"0":{"tempCByLoad":{"b75":{"p95":78,"n":400}}}} } }
'@

$HW = New-Data '{"cpuName":"11th Gen Intel Core i9-11900K","os":"Windows 11 Pro","gpus":["NVIDIA GeForce RTX 3080","Intel UHD Graphics"]}'

try {

    # =====================================================================
    Start-TestGroup 'Resolução de caminho de métrica'

    Assert-Equal 4200 (Resolve-WMMetric -Root $ROLLUP -Path 'cpu.mhzByLoad.b75.p50')[0].value 'caminho direto'
    Assert-Equal 0    (@(Resolve-WMMetric -Root $ROLLUP -Path 'cpu.naoExiste.p50')).Count      'caminho ausente devolve lista vazia'

    $curinga = @(Resolve-WMMetric -Root $ROLLUP -Path 'gpu.*.tempCAllDay.max')
    Assert-Equal 2 $curinga.Count 'o curinga expande nas duas GPUs'
    Assert-Equal 'gpu.0.tempCAllDay.max' $curinga[0].path 'e devolve o caminho concreto, dizendo QUAL placa'
    Assert-Equal 94 $curinga[0].value 'com o valor da placa certa'
    Assert-Equal 45 $curinga[1].value 'e da outra'

    # Curinga onde só uma das instâncias tem a métrica: a que não tem some.
    $parcial = @(Resolve-WMMetric -Root $ROLLUP -Path 'gpu.*.tempCByLoad.b75.p95')
    Assert-Equal 1 $parcial.Count 'só a GPU que tem faixa alta responde'
    Assert-Equal 'gpu.0.tempCByLoad.b75.p95' $parcial[0].path 'e é a GPU 0'

    Assert-Equal 'gpu.0.tempCByLoad.b75.p95' (ConvertTo-WMConcretePath -Template 'gpu.*.tempCByLoad.b75.p95' -Resolved 'gpu.0.tempCByLoad.b75.p95') 'caminho concreto para buscar na linha-base'

    # =====================================================================
    Start-TestGroup 'Operadores nas fronteiras'

    Assert-True  (Test-WMOperator -Operator 'gte' -Left 93 -Right 93) 'gte inclui a igualdade'
    Assert-True  (-not (Test-WMOperator -Operator 'gt' -Left 93 -Right 93)) 'gt exclui'
    Assert-True  (Test-WMOperator -Operator 'lt'  -Left 12 -Right 20) 'lt'
    Assert-True  (Test-WMOperator -Operator 'lte' -Left 20 -Right 20) 'lte inclui a igualdade'

    # =====================================================================
    Start-TestGroup 'Procedência: o que é recusado  [MUTAÇÃO]'

    Assert-True (Test-WMRuleSourced -Rule (New-Data ('{' + $FONTE_OK + '}'))).ok 'policy com texto passa'
    Assert-True (Test-WMRuleSourced -Rule (New-Data '{"source":{"kind":"spec","text":"t","url":"https://x"}}')).ok 'spec com url passa'

    Assert-True (-not (Test-WMRuleSourced -Rule (New-Data '{}')).ok) 'sem bloco source é recusada'
    Assert-True (-not (Test-WMRuleSourced -Rule (New-Data '{"source":{"kind":"pending","text":"aguardando"}}')).ok) 'pending é recusada'
    Assert-True (-not (Test-WMRuleSourced -Rule (New-Data '{"source":{"kind":"","text":"t"}}')).ok) 'kind vazio é recusado'
    Assert-True (-not (Test-WMRuleSourced -Rule (New-Data '{"source":{"kind":"chute","text":"t"}}')).ok) 'kind desconhecido é recusado'
    Assert-True (-not (Test-WMRuleSourced -Rule (New-Data '{"source":{"kind":"policy","text":""}}')).ok) 'policy sem justificativa é recusada'
    # Fato de hardware sem onde conferir não é fato, é lembrança.
    Assert-True (-not (Test-WMRuleSourced -Rule (New-Data '{"source":{"kind":"spec","text":"t","url":""}}')).ok) 'spec sem url é recusada'

    # =====================================================================
    Start-TestGroup 'Forma da regra: defeito de configuração não é falta de fonte'

    $bem = New-Data ('{"id":"R1","metric":"a.b","operator":"gt","kind":"absolute","value":1,"severity":"agir",' + $FONTE_OK + '}')
    Assert-True (Test-WMRuleWellFormed -Rule $bem).ok 'regra completa passa'

    Assert-True (-not (Test-WMRuleWellFormed -Rule (New-Data '{"id":"R","metric":"a","operator":"xx","kind":"absolute","value":1,"severity":"agir"}')).ok) 'operador desconhecido'
    Assert-True (-not (Test-WMRuleWellFormed -Rule (New-Data '{"id":"R","metric":"a","operator":"gt","kind":"absolute","severity":"agir"}')).ok) 'absoluta sem valor'
    Assert-True (-not (Test-WMRuleWellFormed -Rule (New-Data '{"id":"R","metric":"a","operator":"gt","kind":"relative","severity":"agir"}')).ok) 'relativa sem delta'
    Assert-True (-not (Test-WMRuleWellFormed -Rule (New-Data '{"id":"R","metric":"a","operator":"gt","kind":"outro","value":1,"severity":"agir"}')).ok) 'kind desconhecido'
    Assert-True (-not (Test-WMRuleWellFormed -Rule (New-Data '{"id":"R","operator":"gt","kind":"absolute","value":1,"severity":"agir"}')).ok) 'sem metric'

    # =====================================================================
    Start-TestGroup 'SILÊNCIO NÃO É APROVAÇÃO  [MUTAÇÃO]'

    <#
        O modo de falha mais grave desta camada não é errar um limiar: é uma
        regra deixar de rodar e o relatório sair limpo. Aqui a MESMA regra, com
        o MESMO dado que a faria disparar, é apresentada com fonte pendente.
        Ela não pode virar silêncio.
    #>
    $regraQueDispararia = '{"id":"R-QUENTE","kind":"absolute","subsystem":"gpu","severity":"parar","claim":"placa quente",' +
                          '"metric":"gpu.0.tempCAllDay.max","operator":"gt","value":50,'

    $comFonte = New-Rules ('{"rules":[' + $regraQueDispararia + $FONTE_OK + '}]}')
    $r1 = Invoke-WMRules -Rollup $ROLLUP -Rules $comFonte -Hardware $HW
    Assert-Equal 1 $r1.findings.Count 'com fonte, a regra dispara'
    Assert-Equal 'parar' $r1.verdict  'e o veredito sobe'
    Assert-True  $r1.coverage.complete 'cobertura completa'

    $semFonte = New-Rules ('{"rules":[' + $regraQueDispararia + '"source":{"kind":"pending","text":"sem citacao"}}]}')
    $r2 = Invoke-WMRules -Rollup $ROLLUP -Rules $semFonte -Hardware $HW
    Assert-Equal 0 $r2.findings.Count 'sem fonte, não há achado'
    Assert-Equal 'normal' $r2.verdict 'e o veredito volta a normal...'
    Assert-True (-not $r2.coverage.complete) '...MAS a cobertura fica incompleta'
    Assert-Equal 1 @(Get-WMNodeKeys $r2.coverage.unsourced).Count 'e a regra aparece nominalmente como não-verificada'
    Assert-True ((Get-WMNodeChild $r2.coverage.unsourced 'R-QUENTE') -match 'pendente') 'com o motivo'

    # =====================================================================
    Start-TestGroup 'Métrica ausente e linha-base ausente não são aprovação'

    $semMetrica = New-Rules ('{"rules":[{"id":"R-X","kind":"absolute","subsystem":"cpu","severity":"agir","claim":"c",' +
                             '"metric":"cpu.tempC.max","operator":"gt","value":90,' + $FONTE_OK + '}]}')
    $r3 = Invoke-WMRules -Rollup $ROLLUP -Rules $semMetrica -Hardware $HW
    Assert-Equal 0 $r3.findings.Count 'métrica ausente não gera achado'
    Assert-True (-not $r3.coverage.complete) 'nem aprovação'
    Assert-Equal 1 @(Get-WMNodeKeys $r3.coverage.noData).Count 'aparece como métrica ausente'

    $relativa = '{"id":"R-DRIFT","kind":"relative","subsystem":"gpu","severity":"observar","claim":"deriva",' +
                '"metric":"gpu.*.tempCByLoad.b75.p95","operator":"gt","delta":6,' + $FONTE_OK + '}'

    $r4 = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules ('{"rules":[' + $relativa + ']}')) -Hardware $HW
    Assert-Equal 0 $r4.findings.Count 'sem linha-base, regra relativa não dispara'
    Assert-True (-not $r4.coverage.complete) 'e não conta como aprovação'
    Assert-Equal 1 @(Get-WMNodeKeys $r4.coverage.noBaseline).Count 'aparece como sem linha-base'

    # =====================================================================
    Start-TestGroup 'Regras relativas contra a linha-base'

    $r5 = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules ('{"rules":[' + $relativa + ']}')) -Baseline $BASELINE -Hardware $HW
    Assert-Equal 1 $r5.findings.Count 'com linha-base, a deriva de 78 para 86 dispara (limiar 84)'
    Assert-Equal 'gpu.0.tempCByLoad.b75.p95' $r5.findings[0].evidence[0].metric 'a evidência nomeia a GPU'
    Assert-Equal 86 $r5.findings[0].evidence[0].value    'com o valor de hoje'
    Assert-Equal 78 $r5.findings[0].evidence[1].value    'e o da linha-base ao lado'
    Assert-Equal 84 $r5.findings[0].rule.threshold       'e o limiar calculado'
    Assert-True  $r5.coverage.complete 'cobertura completa'

    # deltaPct NEGATIVO com operador lt: clock que caiu abaixo de 92% da base.
    $queda = '{"id":"R-CLOCK","kind":"relative","subsystem":"cpu","severity":"observar","claim":"clock caiu",' +
             '"metric":"cpu.mhzByLoad.b75.p50","operator":"lt","deltaPct":-8,' + $FONTE_OK + '}'
    $r6 = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules ('{"rules":[' + $queda + ']}')) -Baseline $BASELINE -Hardware $HW
    Assert-Equal 1 $r6.findings.Count '4200 está abaixo de 92% de 4900 (4508)'
    Assert-Equal 4508 $r6.findings[0].rule.threshold 'o limiar percentual foi calculado sobre a base'

    <#
        deltaPct POSITIVO com gt, exatamente na fronteira.

        A base é 2600 e o delta é +50%, então o limiar é 3900 — e o agregado
        tem 3900 cravados. Com operador gt estrito, isso NÃO dispara. O teste
        existe para fixar essa semântica: quem lê o relatório precisa saber que
        "acima de 50%" significa estritamente acima, e não "atingiu".
    #>
    $vaza = '{"id":"R-POOL","kind":"relative","subsystem":"mem","severity":"observar","claim":"pool cresceu",' +
            '"metric":"mem.poolNonpagedMB.p50","operator":"gt","deltaPct":50,' + $FONTE_OK + '}'
    $r7 = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules ('{"rules":[' + $vaza + ']}')) -Baseline $BASELINE -Hardware $HW
    Assert-Equal 0 $r7.findings.Count 'valor exatamente no limiar não dispara com gt'
    Assert-True  $r7.coverage.complete 'e isso é uma avaliação de verdade, não uma lacuna'
    Assert-Equal 1 @($r7.coverage.evaluated).Count 'a regra consta como avaliada'

    # Um megabyte acima da fronteira já dispara.
    $ROLLUP_MAIS = New-Data '{"day":"d","host":"T","mem":{"poolNonpagedMB":{"p50":3901}}}'
    $r7b = Invoke-WMRules -Rollup $ROLLUP_MAIS -Rules (New-Rules ('{"rules":[' + $vaza + ']}')) -Baseline $BASELINE -Hardware $HW
    Assert-Equal 1 $r7b.findings.Count 'um acima da fronteira dispara'
    Assert-Equal 3900 $r7b.findings[0].rule.threshold 'e o limiar registrado é o calculado sobre a base'

    # =====================================================================
    Start-TestGroup 'Filtro de hardware'

    $so3080 = '{"id":"R-3080","kind":"absolute","subsystem":"gpu","severity":"agir","claim":"c",' +
              '"metric":"gpu.*.tempCAllDay.max","operator":"gte","value":93,"appliesTo":"GeForce RTX 3080",' + $FONTE_OK + '}'

    $r8 = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules ('{"rules":[' + $so3080 + ']}')) -Hardware $HW
    Assert-Equal 1 $r8.findings.Count 'a máquina tem a placa, a regra roda'

    $outroHw = New-Data '{"cpuName":"AMD Ryzen","os":"Windows","gpus":["Radeon RX 7900"]}'
    $r9 = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules ('{"rules":[' + $so3080 + ']}')) -Hardware $outroHw
    Assert-Equal 0 $r9.findings.Count 'noutra máquina não roda'
    Assert-Equal 1 @(Get-WMNodeKeys $r9.coverage.notApplicable).Count 'e fica declarada como não aplicável'

    # Sem descrição de hardware não se aplica a regra às cegas.
    $r10 = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules ('{"rules":[' + $so3080 + ']}'))
    Assert-Equal 0 $r10.findings.Count 'sem saber o hardware, a regra restrita não roda'
    Assert-True (-not $r10.coverage.complete) 'e isso é lacuna, não aprovação'

    # =====================================================================
    Start-TestGroup 'Veredito é a maior severidade, e regra malformada não vira "sem fonte"'

    $tres = '{"rules":[' +
      '{"id":"A","kind":"absolute","subsystem":"os","severity":"observar","claim":"a","metric":"reboots","operator":"gt","value":0,' + $FONTE_OK + '},' +
      '{"id":"B","kind":"absolute","subsystem":"sto","severity":"agir","claim":"b","metric":"sto.volFreeGB.*.min","operator":"lt","value":20,' + $FONTE_OK + '},' +
      '{"id":"C","kind":"absolute","subsystem":"gpu","severity":"parar","claim":"c","metric":"gpu.0.throttle.thermal","operator":"gt","value":0,' + $FONTE_OK + '}]}'
    $r11 = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules $tres) -Hardware $HW
    Assert-Equal 3 $r11.findings.Count 'três regras disparam (uma só no volume C:)'
    Assert-Equal 'parar' $r11.verdict 'o veredito é a maior severidade entre elas'

    $torta = New-Rules ('{"rules":[{"id":"R-TORTA","kind":"absolute","subsystem":"cpu","severity":"agir","claim":"c",' +
                        '"metric":"cpu.util.p50","operator":"maior","value":1,' + $FONTE_OK + '}]}')
    $r12 = Invoke-WMRules -Rollup $ROLLUP -Rules $torta -Hardware $HW
    Assert-Equal 0 @(Get-WMNodeKeys $r12.coverage.unsourced).Count 'regra com fonte e operador inválido NÃO é "sem fonte"'
    Assert-Equal 1 @(Get-WMNodeKeys $r12.coverage.malformed).Count 'é malformada, que é defeito de configuração'
    Assert-True (-not $r12.coverage.complete) 'e continua sendo lacuna'

    # =====================================================================
    Start-TestGroup 'A tabela de limiares que vai no repositório'

    <#
        Guarda sobre o arquivo REAL: toda regra publicada precisa ou estar bem
        formada, ou estar declarada como pendente com justificativa. Sem isto,
        uma regra quebrada entraria no repositório e só apareceria como uma
        lacuna silenciosa no relatório de alguém.
    #>
    $real = Get-Content (Join-Path $root 'config\thresholds.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-GreaterThan @($real.rules).Count 0 'a tabela tem regras'

    $ruins = @()
    $pendentesSemTexto = @()
    foreach ($rr in $real.rules) {
        $f = Test-WMRuleSourced -Rule $rr
        if ($f.ok) {
            $w = Test-WMRuleWellFormed -Rule $rr
            if (-not $w.ok) { $ruins += ("{0}: {1}" -f $rr.id, $w.reason) }
        } elseif ($rr.source.kind -eq 'pending') {
            if ([string]::IsNullOrWhiteSpace([string]$rr.source.text)) { $pendentesSemTexto += $rr.id }
        } else {
            $ruins += ("{0}: {1}" -f $rr.id, $f.reason)
        }
    }
    Assert-Equal 0 $ruins.Count ("toda regra com fonte está bem formada — problemas: " + ($ruins -join '; '))
    Assert-Equal 0 $pendentesSemTexto.Count ("toda regra pendente explica por quê — sem texto: " + ($pendentesSemTexto -join '; '))

    # Nenhuma regra 'spec' pode ir para o repositório sem url de verificação.
    $specSemUrl = @($real.rules | Where-Object { $_.source.kind -eq 'spec' -and [string]::IsNullOrWhiteSpace([string]$_.source.url) })
    Assert-Equal 0 $specSemUrl.Count 'nenhuma regra spec sem url para conferir'

    # =====================================================================
    Start-TestGroup 'Severidade fora da escala não pode virar silêncio  [MUTAÇÃO]'

    <#
        Uma severidade desconhecida DISPARAVA o achado e deixava o veredito em
        'normal' com cobertura completa: a ordenação usa índice na escala, e
        chave ausente devolve $null, que nunca é maior que nada. O parecer leria
        "veredito normal, cobertura completa" com um achado grave na lista.
    #>
    $molde = '{"severityScale":["normal","observar","agir","parar"],"rules":[' +
             '{"id":"R-S","kind":"absolute","subsystem":"gpu","claim":"c",' +
             '"metric":"gpu.0.tempCAllDay.max","operator":"gt","value":50,"severity":"%SEV%",' + $FONTE_OK + '}]}'

    $ok = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules ($molde -replace '%SEV%','parar')) -Hardware $HW
    Assert-Equal 1 $ok.findings.Count 'severidade válida dispara'
    Assert-Equal 'parar' $ok.verdict  'e levanta o veredito'

    $fora = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules ($molde -replace '%SEV%','critico')) -Hardware $HW
    Assert-Equal 0 $fora.findings.Count 'severidade fora da escala NÃO produz achado'
    Assert-True (-not $fora.coverage.complete) 'e a cobertura fica incompleta'
    Assert-Equal 1 @(Get-WMNodeKeys $fora.coverage.malformed).Count 'a regra é malformada'
    Assert-True ((Get-WMNodeChild $fora.coverage.malformed 'R-S') -match 'fora da escala') 'com o motivo nomeando a escala'

    # Caixa importa: 'PARAR' não é 'parar'.
    $caixa = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules ($molde -replace '%SEV%','PARAR')) -Hardware $HW
    Assert-Equal 0 $caixa.findings.Count 'severidade com caixa diferente também é recusada'
    Assert-Equal 'normal' $caixa.verdict 'e não vaza para o veredito'

    # A escala vem do ARQUIVO, não de uma cópia embutida.
    $outraEscala = '{"severityScale":["calmo","urgente"],"rules":[' +
                   '{"id":"R-E","kind":"absolute","subsystem":"gpu","claim":"c",' +
                   '"metric":"gpu.0.tempCAllDay.max","operator":"gt","value":50,"severity":"urgente",' + $FONTE_OK + '}]}'
    $re = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules $outraEscala) -Hardware $HW
    Assert-Equal 1 $re.findings.Count 'escala personalizada é respeitada'
    Assert-Equal 'urgente' $re.verdict 'e o veredito sai na escala do arquivo'

    # =====================================================================
    Start-TestGroup 'O LIMIAR passa pelo mesmo crivo da métrica  [MUTAÇÃO]'

    <#
        A métrica era lida com cultura invariante e NaN recusado; o limiar
        usava cast cru. Num Windows pt-BR, "9,3" no limiar virava 93 — dez
        vezes errado e calado. thresholds.json é, por desenho, o arquivo que
        humanos editam.
    #>
    $comLimiar = '{"rules":[{"id":"R-L","kind":"absolute","subsystem":"gpu","severity":"agir","claim":"c",' +
                 '"metric":"gpu.0.tempCAllDay.max","operator":"gt","value":%V%,' + $FONTE_OK + '}]}'

    $lNum = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules ($comLimiar -replace '%V%','50')) -Hardware $HW
    Assert-Equal 1 $lNum.findings.Count 'limiar numérico funciona (94 > 50)'

    foreach ($lixo in '"9,3"', '"NaN"', '"Infinity"', '"N/A"', 'true') {
        $r = $null
        $erro = $null
        try { $r = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules ($comLimiar -replace '%V%', $lixo)) -Hardware $HW }
        catch { $erro = $_.Exception.Message }
        Assert-Null $erro "limiar $lixo não derruba a avaliação"
        Assert-Equal 0 $r.findings.Count "limiar $lixo não produz achado"
        Assert-Equal 1 @(Get-WMNodeKeys $r.coverage.malformed).Count "limiar $lixo é recusado como malformado"
        Assert-True (-not $r.coverage.complete) "limiar $lixo deixa a cobertura incompleta"
    }

    # E o mesmo do lado do delta.
    $comDelta = '{"rules":[{"id":"R-D","kind":"relative","subsystem":"cpu","severity":"agir","claim":"c",' +
                '"metric":"cpu.mhzByLoad.b75.p50","operator":"lt","delta":%V%,' + $FONTE_OK + '}]}'
    $dLixo = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules ($comDelta -replace '%V%','"6,5"')) -Baseline $BASELINE -Hardware $HW
    Assert-Equal 1 @(Get-WMNodeKeys $dLixo.coverage.malformed).Count 'delta com vírgula decimal é recusado'

    # delta NEGATIVO: o sinal precisa ser respeitado, não absorvido.
    $dNeg = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules ($comDelta -replace '%V%','-300')) -Baseline $BASELINE -Hardware $HW
    Assert-Equal 1 $dNeg.findings.Count 'delta negativo: 4200 está abaixo de 4900-300'
    Assert-Equal 4600 $dNeg.findings[0].rule.threshold 'e o limiar é base menos 300, não base mais 300'

    # =====================================================================
    Start-TestGroup 'A métrica ilegível continua virando lacuna  [MUTAÇÃO]'

    # Herança das defesas do armazém: documentada e, até aqui, sem teste.
    foreach ($par in @(@('"NaN"', 'NaN'), @('"Infinity"', 'Infinity'), @('"9,3"', 'virgula'))) {
        $rr = New-Data ('{"day":"d","host":"T","gpu":{"0":{"tempCAllDay":{"max":' + $par[0] + '}}}}')
        $x = Invoke-WMRules -Rollup $rr -Rules (New-Rules ($comLimiar -replace '%V%','50')) -Hardware $HW
        Assert-Equal 0 $x.findings.Count "métrica $($par[1]) não produz achado"
        Assert-Equal 1 @(Get-WMNodeKeys $x.coverage.noData).Count "métrica $($par[1]) vira lacuna declarada"
    }
    $bom = New-Data '{"day":"d","host":"T","gpu":{"0":{"tempCAllDay":{"max":"93.5"}}}}'
    $xb = Invoke-WMRules -Rollup $bom -Rules (New-Rules ($comLimiar -replace '%V%','50')) -Hardware $HW
    Assert-Equal 1 $xb.findings.Count 'número em texto com ponto decimal é aceito'

    # =====================================================================
    Start-TestGroup 'Procedência é conferida ANTES da forma  [MUTAÇÃO]'

    <#
        A ordem existe porque regra pendente legitimamente ainda não tem limiar
        preenchido. Invertida, R-CPU-TEMP-SPEC sairia de "aguardando citação"
        para "erro de escrita" — o relatório acusaria a coisa errada.
    #>
    $pendenteEsemValor = New-Rules ('{"rules":[{"id":"R-P","kind":"absolute","subsystem":"cpu","severity":"agir","claim":"c",' +
                                    '"metric":"cpu.util.p50","operator":"gt","value":null,' +
                                    '"source":{"kind":"pending","text":"aguardando fonte primaria"}}]}')
    $rp = Invoke-WMRules -Rollup $ROLLUP -Rules $pendenteEsemValor -Hardware $HW
    Assert-Equal 1 @(Get-WMNodeKeys $rp.coverage.unsourced).Count 'regra pendente E sem limiar é reportada como SEM FONTE'
    Assert-Equal 0 @(Get-WMNodeKeys $rp.coverage.malformed).Count 'e não como malformada'

    # =====================================================================
    Start-TestGroup 'Sem descrição de hardware, o desfecho é nomeado'

    $so3080b = '{"rules":[{"id":"R-H","kind":"absolute","subsystem":"gpu","severity":"agir","claim":"c",' +
               '"metric":"gpu.*.tempCAllDay.max","operator":"gte","value":93,"appliesTo":"GeForce RTX 3080",' + $FONTE_OK + '}]}'
    $rsh = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules $so3080b)
    Assert-Equal 1 @(Get-WMNodeKeys $rsh.coverage.notApplicable).Count 'sem hardware conhecido cai em "não se aplica"'
    Assert-Equal 0 @(Get-WMNodeKeys $rsh.coverage.noData).Count       'e não em "métrica ausente"'

    # appliesTo compara literal: metacaractere não pode virar curinga.
    $curingaHw = New-Data '{"gpus":["NVIDIA GeForce RTX 9080"]}'
    # Colchete literal no JSON (não precisa de escape em JSON, e escapá-lo com
    # contrabarra produz sequência inválida).
    $rcw = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules ($so3080b -replace 'GeForce RTX 3080','RTX [39]080')) -Hardware $curingaHw
    Assert-Equal 0 $rcw.findings.Count 'colchete no modelo não vira classe de caracteres'

    # =====================================================================
    Start-TestGroup 'A escala do arquivo governa também o caso sem achado  [MUTAÇÃO]'

    # Máquina sã numa escala personalizada: o veredito base é o PRIMEIRO item
    # da escala declarada, não a palavra 'normal' embutida no código.
    $escalaPropriaFria = '{"severityScale":["calmo","urgente"],"rules":[' +
                         '{"id":"R-F","kind":"absolute","subsystem":"gpu","claim":"c",' +
                         '"metric":"gpu.0.tempCAllDay.max","operator":"gt","value":500,"severity":"urgente",' + $FONTE_OK + '}]}'
    $rf = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules $escalaPropriaFria) -Hardware $HW
    Assert-Equal 0 $rf.findings.Count 'nenhum achado (94 não passa de 500)'
    Assert-Equal 'calmo' $rf.verdict  'e o veredito é o primeiro item da escala DECLARADA'
    Assert-True  $rf.coverage.complete 'com cobertura completa'

    <#
        Escala inválida não pode derrubar a avaliação nem passar calada: cai
        para a padrão e o problema fica declarado, pelo mesmo princípio que
        vale para as regras.
    #>
    $escalaRepetida = '{"severityScale":["normal","agir","agir"],"rules":[' +
                      '{"id":"R-R","kind":"absolute","subsystem":"gpu","claim":"c",' +
                      '"metric":"gpu.0.tempCAllDay.max","operator":"gt","value":50,"severity":"agir",' + $FONTE_OK + '}]}'
    $rr = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules $escalaRepetida) -Hardware $HW
    Assert-Equal 1 @($rr.configProblems).Count 'escala com item repetido é reportada como problema de configuração'
    Assert-True (@($rr.configProblems)[0] -match 'repetidos') 'dizendo o quê'
    Assert-Equal 'normal' $rr.severityScale[0] 'e a escala usada volta a ser a padrão'
    Assert-Equal 1 $rr.findings.Count 'sem derrubar a avaliação'

    $rSemProblema = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules ($molde -replace '%SEV%','parar')) -Hardware $HW
    Assert-Equal 0 @($rSemProblema.configProblems).Count 'tabela sã não reporta problema de configuração'

    # =====================================================================
    Start-TestGroup 'Detalhes que estavam corretos e indefesos  [MUTAÇÃO]'

    # appliesTo é insensível a caixa: o nome vem do driver e a grafia varia.
    foreach ($grafia in 'NVIDIA GeForce RTX 3080', 'nvidia geforce rtx 3080', 'NVIDIA GEFORCE RTX 3080') {
        $hwG = New-Data ('{"gpus":["' + $grafia + '"]}')
        $rg = Invoke-WMRules -Rollup $ROLLUP -Rules (New-Rules $so3080b) -Hardware $hwG
        Assert-Equal 1 $rg.findings.Count "appliesTo casa com a grafia '$grafia'"
    }

    <#
        Com curinga, a lacuna de linha-base precisa dizer QUAL instância ficou
        sem referência. Indexada só pela regra, a segunda GPU sobrescreveria a
        primeira e a informação de qual placa se perderia.
    #>
    $baseSoGpu0 = New-Data '{"profile":{"gpu":{"0":{"tempCByLoad":{"b75":{"p95":78}}}}}}'
    $duasFaixas = New-Data ('{"day":"d","host":"T","gpu":{' +
                            '"0":{"tempCByLoad":{"b75":{"p95":86}}},' +
                            '"1":{"tempCByLoad":{"b75":{"p95":70}}}}}')
    $rnb = Invoke-WMRules -Rollup $duasFaixas -Rules (New-Rules ('{"rules":[' + $relativa + ']}')) -Baseline $baseSoGpu0 -Hardware $HW
    Assert-Equal 1 $rnb.findings.Count 'a GPU 0, que tem referência, é avaliada e dispara'
    $chavesNb = @(Get-WMNodeKeys $rnb.coverage.noBaseline)
    Assert-Equal 1 $chavesNb.Count 'e a GPU 1 aparece como sem referência'
    Assert-True ($chavesNb[0] -match 'gpu\.1\.') 'com a chave nomeando QUAL placa ficou sem linha-base'

    # =====================================================================
    Start-TestGroup 'Os valores da tabela publicada'

    <#
        Guarda sobre o NÚMERO, não só sobre a estrutura: trocar o 93 por 200
        passava verde, porque nenhum teste fixava valor nenhum.
    #>
    $r3080 = @($real.rules | Where-Object { $_.id -eq 'R-GPU-TEMP-SPEC-3080' })[0]
    Assert-NotNull $r3080 'a regra da RTX 3080 existe'
    Assert-Equal 93 $r3080.value 'o limiar é 93 C, o maximo de projeto publicado pela NVIDIA'
    Assert-Equal 'gte' $r3080.operator 'com gte: atingir o limite ja conta'
    Assert-True ($r3080.source.url -match 'nvidia\.com') 'e a url aponta para a NVIDIA'

    $rdrift = @($real.rules | Where-Object { $_.id -eq 'R-GPU-TEMP-DRIFT' })[0]
    Assert-Equal 6 $rdrift.delta 'a deriva termica dispara com 6 C acima da linha-base'

    $rdisk = @($real.rules | Where-Object { $_.id -eq 'R-DISK-SPACE-LOW' })[0]
    Assert-Equal 20 $rdisk.value 'o piso de espaco livre e 20 GB'

    # A escala declarada no arquivo tem de conter toda severidade usada.
    $foraEscala = @($real.rules | Where-Object { $_.severity -cnotin @($real.severityScale) })
    Assert-Equal 0 $foraEscala.Count ('nenhuma regra usa severidade fora da escala: ' + (($foraEscala | ForEach-Object { $_.id }) -join ', '))

} finally { }

Show-TestSummary
exit (Get-TestExitCode)
