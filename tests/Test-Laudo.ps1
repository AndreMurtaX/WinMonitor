#requires -Version 5.1
<#
    Testes da camada determinística do parecer.

    O grupo que importa é o da conferência numérica. Ele é a única defesa contra
    fabricação que não depende de um segundo modelo concordar — e por isso
    precisa passar nos dois sentidos: acusar número que não veio do pacote, e
    NÃO acusar citação legítima de caminho de métrica, identificador de regra ou
    data, que contêm dígito e não são medida.

      .\tests\Test-Laudo.ps1
#>
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TestKit.ps1')
Import-Module (Join-Path $root 'src\WinMonitor.psm1')        -Force
Import-Module (Join-Path $root 'src\WinMonitor.Rollup.psm1') -Force
Import-Module (Join-Path $root 'src\WinMonitor.Rules.psm1')  -Force
Import-Module (Join-Path $root 'src\WinMonitor.Laudo.psm1')  -Force

function New-Data { param([string]$Json) $Json | ConvertFrom-Json }

# Achados de referência: uma deriva térmica de 78 para 86 (limiar 84) e um
# volume com 12,4 GB livres (limiar 20).
$ACHADOS = New-Data @'
{ "v":1, "window":"2026-08-14", "host":"TESTE", "verdict":"agir",
  "findings":[
    { "id":"R-GPU-TEMP-DRIFT#gpu.0.tempCByLoad.b75.p95", "ruleId":"R-GPU-TEMP-DRIFT",
      "severity":"observar", "subsystem":"gpu", "claim":"A GPU esta mais quente que a linha-base",
      "evidence":[ {"metric":"gpu.0.tempCByLoad.b75.p95","value":86,"from":"agregado"},
                   {"metric":"gpu.0.tempCByLoad.b75.p95","value":78,"from":"linha-base"} ],
      "rule":{"kind":"relative","operator":"gt","threshold":84,
              "source":{"kind":"policy","text":"sensibilidade escolhida"}} },
    { "id":"R-DISK-SPACE-LOW#sto.volFreeGB.C:.min", "ruleId":"R-DISK-SPACE-LOW",
      "severity":"agir", "subsystem":"sto", "claim":"O volume ficou com pouco espaco livre",
      "evidence":[ {"metric":"sto.volFreeGB.C:.min","value":12.4,"from":"agregado"} ],
      "rule":{"kind":"absolute","operator":"lt","threshold":20,
              "source":{"kind":"policy","text":"folga de operacao"}} }
  ],
  "coverage":{ "complete":false, "evaluated":["R-GPU-TEMP-DRIFT","R-DISK-SPACE-LOW"],
    "unsourced":{"R-CPU-TEMP-SPEC":"fonte pendente"},
    "malformed":{}, "noData":{}, "noBaseline":{}, "notApplicable":{} } }
'@

$HW = New-Data '{"os":"Windows 11 Pro","cpuName":"11th Gen Intel Core i9-11900K","cpuCores":8,"memTotalMB":130879,"gpuNames":["NVIDIA GeForce RTX 3080"]}'

try {

    # =====================================================================
    Start-TestGroup 'O pacote é fechado'

    $pac = New-WMLaudoPackage -Findings $ACHADOS -Hardware $HW
    Assert-Equal 2 @($pac.findings).Count 'os dois achados entram'
    Assert-Equal 'agir' $pac.verdict      'o veredito entra'
    Assert-NotNull $pac.coverage          'a cobertura entra'
    Assert-Equal 2 @(Get-WMNodeKeys $pac.series).Count 'só as duas métricas CITADAS viram série'
    Assert-NotNull (Get-WMNodeChild $pac.series 'gpu.0.tempCByLoad.b75.p95') 'a métrica da GPU está lá'
    Assert-Null (Get-WMNodeChild $pac.series 'mem.poolNonpagedMB.p50') 'métrica não citada por nenhum achado NÃO entra'

    # Continuidade: o laudo anterior entra resumido, não inteiro.
    $ant = New-Data '{"window":"2026-08-13","verdict":"observar","summary":"tudo calmo","findings":[{"ruleId":"R-GPU-TEMP-DRIFT"}]}'
    $pac2 = New-WMLaudoPackage -Findings $ACHADOS -Previous $ant -Hardware $HW
    Assert-Equal 'observar' $pac2.previous.verdict 'o veredito anterior entra'
    Assert-True (@($pac2.previous.ruleIds) -contains 'R-GPU-TEMP-DRIFT') 'e as regras que dispararam antes'

    # =====================================================================
    Start-TestGroup 'Números permitidos'

    $perm = Get-WMAllowedNumbers -Package $pac
    foreach ($n in 86, 78, 84, 12.4, 20) {
        Assert-True $perm.Contains([double]$n) "$n (valor ou limiar) é permitido"
    }
    Assert-True $perm.Contains([double]2) 'a contagem de achados é permitida'
    Assert-True $perm.Contains([double]130879) 'fato de hardware é permitido'

    # =====================================================================
    Start-TestGroup 'CONFERÊNCIA: número órfão é fabricação  [MUTAÇÃO]'

    $bom = @'
A GPU subiu de 78 para 86 graus na mesma faixa de carga, acima do limiar de 84.
O volume C: ficou com 12,4 GB livres, abaixo dos 20 GB de folga.
São 2 achados; 1 regra ficou sem fonte declarada.
'@
    $r = Test-WMLaudoNumbers -Text $bom -Package $pac
    Assert-True $r.ok ('laudo honesto passa (órfãos: ' + ($r.orphans -join ', ') + ')')

    # O número que ninguém mediu.
    $ruim = 'A GPU subiu de 78 para 86 graus, e o consumo chegou a 340 watts.'
    $r2 = Test-WMLaudoNumbers -Text $ruim -Package $pac
    Assert-True (-not $r2.ok) 'número inventado é acusado'
    Assert-True (@($r2.orphans) -contains '340') 'e é nominado'

    # Arredondamento é tolerado: o modelo escreve 86 onde o dado diz 86,3.
    $pacR = New-WMLaudoPackage -Findings (New-Data ($ACHADOS | ConvertTo-Json -Depth 12 -Compress).Replace('"value":86,', '"value":86.3,'))
    $r3 = Test-WMLaudoNumbers -Text 'A faixa alta marcou 86 graus.' -Package $pacR
    Assert-True $r3.ok 'arredondar 86,3 para 86 não é fabricação'

    <#
        O outro sentido, que é onde uma guarda ingênua se destrói: caminhos de
        métrica, identificadores de regra e datas contêm dígito e não são
        medida. Acusá-los tornaria a guarda inútil na primeira execução real.
    #>
    $citando = @'
O achado R-GPU-TEMP-DRIFT compara gpu.0.tempCByLoad.b75.p95 entre 2026-08-13 e
2026-08-14. A regra R-DISK-SPACE-LOW olhou sto.volFreeGB.C:.min.
A placa é uma NVIDIA GeForce RTX 3080 e o processador um 11th Gen Intel Core i9-11900K.
'@
    $r4 = Test-WMLaudoNumbers -Text $citando -Package $pac2
    Assert-True $r4.ok ('citar caminho, regra, data e hardware não é fabricação (órfãos: ' + ($r4.orphans -join ', ') + ')')

    <#
        REGRESSÃO DA PRIMEIRA EXECUÇÃO REAL. O modelo escreveu "RTX 3080" e
        "UHD Graphics 750" — formas CURTAS — e a conferência acusou 3080 e 750
        como inventados. Estavam no pacote; a remoção de literais só casa a
        string inteira, e ninguém escreve o nome completo quando o curto basta.

        O teste anterior não pegava isso porque escrevia o nome completo, que é
        justamente o caso que a remoção de literais já cobria.
    #>
    $HW2 = New-Data '{"os":"Windows 11 Pro","cpuName":"11th Gen Intel Core i9-11900K","cpuCores":8,"memTotalMB":130879,"gpuNames":["NVIDIA GeForce RTX 3080","Intel(R) UHD Graphics 750"],"disks":[{"name":"Corsair MP600","sizeGB":1863}]}'
    $pacHW = New-WMLaudoPackage -Findings $ACHADOS -Hardware $HW2

    $r4b = Test-WMLaudoNumbers -Package $pacHW -Text @'
A RTX 3080 é a placa que sustenta a carga; a UHD Graphics 750 é integrada.
O disco MP600 de 1863 GB tem folga, e o i9-11900K opera com 8 núcleos.
'@
    Assert-True $r4b.ok ('nome de peça em forma curta não é fabricação (órfãos: ' + ($r4b.orphans -join ', ') + ')')

    <#
        E o outro lado da MESMA mudança, que é o que a torna segura: liberar os
        números do hardware NÃO pode liberar os números dos caminhos de métrica.
        Se b75/p95 virassem medida permitida, a guarda aceitaria justamente o
        tipo de invenção que ela existe para pegar — 95 foi um dos números que o
        modelo inventou naquela execução.
    #>
    $r4c = Test-WMLaudoNumbers -Text 'A placa passou de 95 graus na faixa alta e a CPU chegou a 74.' -Package $pacHW
    Assert-True (-not $r4c.ok) 'liberar hardware não liberou 95 e 74'
    Assert-True ((@($r4c.orphans) -contains '95') -and (@($r4c.orphans) -contains '74')) 'os dois são nominados'

    # E o nome do modelo não pode virar salvo-conduto para a medida homônima.
    $r4d = Test-WMLaudoNumbers -Text 'A GPU registrou 3080 graus.' -Package $pacHW
    Assert-True $r4d.ok 'limitação aceita e registrada: 3080 como medida passa (vem do nome da peça)'

    # =====================================================================
    Start-TestGroup 'CONFERÊNCIA: achado inventado  [MUTAÇÃO]'

    $r5 = Test-WMLaudoRuleIds -Text 'Os achados R-GPU-TEMP-DRIFT e R-DISK-SPACE-LOW indicam...' -Package $pac
    Assert-True $r5.ok 'citar regras que existem passa'

    $r6 = Test-WMLaudoRuleIds -Text 'O achado R-MEMORIA-VAZANDO sugere um problema.' -Package $pac
    Assert-True (-not $r6.ok) 'regra que não existe no pacote é acusada'
    Assert-True (@($r6.invented) -contains 'R-MEMORIA-VAZANDO') 'e é nominada'

    # Regra que existe mas ficou SEM AVALIAR também pode ser citada — é dela
    # que o laudo fala ao dizer o que não foi verificado.
    $r7 = Test-WMLaudoRuleIds -Text 'R-CPU-TEMP-SPEC não pôde ser avaliada.' -Package $pac
    Assert-True $r7.ok 'regra não avaliada é citável'

    # =====================================================================
    Start-TestGroup 'CONFERÊNCIA: achado que o pacote não trouxe  [MUTAÇÃO]'

    <#
        O caso REAL que abriu esta guarda. Pacote de 2026-08-15: zero achados,
        veredito 'normal'. O gemma3:4b devolveu um achado com ruleId legítimo
        (a regra existe, e está em coverage como não avaliada) e action "O valor
        não foi fornecido no pacote" — sabia que não tinha dado e afirmou mesmo
        assim.

        As duas guardas anteriores NÃO o pegam: o achado não tem número, e o
        ruleId estruturado nunca entra no texto que a guarda de regras examina.
        Ele só foi rejeitado porque outra frase trazia número inventado. Sorte.
    #>
    $VAZIO = New-Data '{"v":1,"window":"2026-08-15","host":"TESTE","verdict":"normal","findings":[],"coverage":{"complete":false,"evaluated":[],"unsourced":{"R-CPU-TEMP-SPEC":"fonte pendente"},"malformed":{},"noData":{"R-GPU-TEMP-SPEC-3080":"sem amostra"},"noBaseline":{},"notApplicable":{}}}'
    $pacV = New-WMLaudoPackage -Findings $VAZIO -Hardware $HW

    $inventado = New-Data '{"summary":"x","notVerified":"y","changedSinceLast":"","observations":[],"findings":[{"ruleId":"R-GPU-TEMP-SPEC-3080","reading":"A temperatura da placa está acima do especificado.","action":"O valor não foi fornecido no pacote."}]}'
    $f1 = Test-WMLaudoFindings -Laudo $inventado -Package $pacV
    Assert-True (-not $f1.ok) 'regra de coverage virando ACHADO é rejeitada'
    Assert-True (@($f1.invented) -contains 'R-GPU-TEMP-SPEC-3080') 'e é nominada'

    # A prova de que as outras duas guardas realmente não pegavam este caso —
    # se um dia pegarem, ótimo, mas a defesa não pode depender disso.
    $textoInv = Get-WMLaudoText -Laudo $inventado
    Assert-True (Test-WMLaudoNumbers -Text $textoInv -Package $pacV).ok 'a guarda de números deixa passar (não há número)'
    Assert-True (Test-WMLaudoRuleIds -Text $textoInv -Package $pacV).ok 'a guarda de regras deixa passar (ruleId não está na prosa)'

    # Pacote vazio, laudo vazio: é a resposta certa, não uma falha.
    $limpo = New-Data '{"summary":"Nada mereceu atenção.","notVerified":"y","changedSinceLast":"","observations":[],"findings":[]}'
    Assert-True (Test-WMLaudoFindings -Laudo $limpo -Package $pacV).ok 'pacote sem achados, laudo sem achados: passa'

    # Relatar os achados que existem, passa.
    $fiel = New-Data '{"summary":"x","notVerified":"y","changedSinceLast":"","observations":[],"findings":[{"ruleId":"R-GPU-TEMP-DRIFT","reading":"a","action":"b"},{"ruleId":"R-DISK-SPACE-LOW","reading":"c","action":"d"}]}'
    Assert-True (Test-WMLaudoFindings -Laudo $fiel -Package $pac).ok 'relatar os achados do pacote passa'

    # Relatar MENOS que o pacote passa: o laudo pode agrupar. Relatar a MAIS não.
    $menos = New-Data '{"summary":"x","notVerified":"y","changedSinceLast":"","observations":[],"findings":[{"ruleId":"R-GPU-TEMP-DRIFT","reading":"a","action":"b"}]}'
    Assert-True (Test-WMLaudoFindings -Laudo $menos -Package $pac).ok 'relatar um subconjunto passa'

    <#
        Duplicata: com duas placas a MESMA regra gera dois achados de verdade,
        então repetir não é erro por si. O que não pode é o laudo devolver mais
        ocorrências de uma regra do que o pacote trouxe — é inflar achado com
        um ruleId que passa no teste de pertinência.
    #>
    $inflado = New-Data '{"summary":"x","notVerified":"y","changedSinceLast":"","observations":[],"findings":[{"ruleId":"R-GPU-TEMP-DRIFT","reading":"a","action":"b"},{"ruleId":"R-GPU-TEMP-DRIFT","reading":"c","action":"d"}]}'
    $f2 = Test-WMLaudoFindings -Laudo $inflado -Package $pac
    Assert-True (-not $f2.ok) 'duplicar um achado que o pacote trouxe uma vez é rejeitado'

    $DOISGPU = New-Data @'
{ "v":1, "window":"2026-08-14", "host":"TESTE", "verdict":"observar",
  "findings":[
    { "id":"R-GPU-TEMP-DRIFT#gpu.0.tempCByLoad.b75.p95", "ruleId":"R-GPU-TEMP-DRIFT",
      "severity":"observar", "subsystem":"gpu", "claim":"a placa 0 esta mais quente",
      "evidence":[ {"metric":"gpu.0.tempCByLoad.b75.p95","value":86,"from":"agregado"} ],
      "rule":{"kind":"relative","operator":"gt","threshold":84,
              "source":{"kind":"policy","text":"sensibilidade escolhida"}} },
    { "id":"R-GPU-TEMP-DRIFT#gpu.1.tempCByLoad.b75.p95", "ruleId":"R-GPU-TEMP-DRIFT",
      "severity":"observar", "subsystem":"gpu", "claim":"a placa 1 esta mais quente",
      "evidence":[ {"metric":"gpu.1.tempCByLoad.b75.p95","value":88,"from":"agregado"} ],
      "rule":{"kind":"relative","operator":"gt","threshold":84,
              "source":{"kind":"policy","text":"sensibilidade escolhida"}} }
  ],
  "coverage":{ "complete":true, "evaluated":["R-GPU-TEMP-DRIFT"],
    "unsourced":{}, "malformed":{}, "noData":{}, "noBaseline":{}, "notApplicable":{} } }
'@
    $pacD = New-WMLaudoPackage -Findings $DOISGPU
    Assert-True (Test-WMLaudoFindings -Laudo $inflado -Package $pacD).ok 'duas placas, mesma regra duas vezes: passa'

    # Achado sem ruleId nenhum não escapa por omissão.
    $semId = New-Data '{"summary":"x","notVerified":"y","changedSinceLast":"","observations":[],"findings":[{"ruleId":"","reading":"a","action":"b"}]}'
    Assert-True (-not (Test-WMLaudoFindings -Laudo $semId -Package $pac).ok) 'achado sem ruleId é rejeitado'

    # =====================================================================
    Start-TestGroup 'CONFERÊNCIA: obrigações de forma  [MUTAÇÃO]'

    <#
        O laudo que o mistral:latest devolveu de verdade, e que passou nas três
        guardas anteriores: lacuna calada e hipótese sobre o que ninguém mediu.
    #>
    $mistral = New-Data '{"summary":"Avaliado como normal.","notVerified":"","changedSinceLast":"Nenhum","findings":[],"observations":["A temperatura do GPU parece estar um pouco acima da média normal durante o uso pesado."]}'

    $s1 = Test-WMLaudoShape -Laudo $mistral -Package $pacV
    Assert-True (-not $s1.ok) 'o laudo real do mistral é rejeitado'
    Assert-Equal 2 (@($s1.missing).Count) 'pelas duas razões, não por uma'

    # E a prova de que as outras três dormiam neste caso.
    $tm = Get-WMLaudoText -Laudo $mistral
    Assert-True (Test-WMLaudoNumbers  -Text $tm -Package $pacV).ok        'a guarda de números deixava passar'
    Assert-True (Test-WMLaudoRuleIds  -Text $tm -Package $pacV).ok        'a de regras deixava passar'
    Assert-True (Test-WMLaudoFindings -Laudo $mistral -Package $pacV).ok  'a de achados deixava passar'

    # Cada obrigação isolada, para que uma não mascare a outra.
    $soLacuna = New-Data '{"summary":"x","notVerified":"","changedSinceLast":"","findings":[],"observations":[]}'
    $s2 = Test-WMLaudoShape -Laudo $soLacuna -Package $pacV
    Assert-True (-not $s2.ok) 'cobertura incompleta com notVerified vazio é rejeitada'
    Assert-True ((@($s2.missing) -join ' ') -match 'notVerified') 'e a razão nomeia o campo'

    # Espaço em branco não conta como declaração.
    $branco = New-Data '{"summary":"x","notVerified":"   ","changedSinceLast":"","findings":[],"observations":[]}'
    Assert-True (-not (Test-WMLaudoShape -Laudo $branco -Package $pacV).ok) 'notVerified só com espaço não declara nada'

    $soHipotese = New-Data '{"summary":"x","notVerified":"faltou o sensor","changedSinceLast":"","findings":[],"observations":["a placa talvez esteja quente"]}'
    $s3 = Test-WMLaudoShape -Laudo $soHipotese -Package $pacV
    Assert-True (-not $s3.ok) 'hipótese sem nenhum achado no pacote é rejeitada'
    Assert-Equal 1 (@($s3.missing).Count) 'e só por essa razão'

    # O laudo correto para um pacote sem achados e cobertura incompleta.
    $certo = New-Data '{"summary":"Nada mereceu atenção.","notVerified":"R-CPU-TEMP-SPEC ficou sem fonte.","changedSinceLast":"","findings":[],"observations":[]}'
    Assert-True (Test-WMLaudoShape -Laudo $certo -Package $pacV).ok 'declarar a lacuna e não supor nada passa'

    # Com achados no pacote, hipótese é legítima — o campo não vira letra morta.
    $comAchado = New-Data '{"summary":"x","notVerified":"R-CPU-TEMP-SPEC sem fonte","changedSinceLast":"","findings":[{"ruleId":"R-GPU-TEMP-DRIFT","reading":"a","action":"b"}],"observations":["o calor pode vir do ambiente"]}'
    Assert-True (Test-WMLaudoShape -Laudo $comAchado -Package $pac).ok 'com achado, a hipótese continua permitida'

    # Cobertura COMPLETA não exige notVerified.
    $pacC = New-WMLaudoPackage -Findings $DOISGPU
    $semLacuna = New-Data '{"summary":"x","notVerified":"","changedSinceLast":"","findings":[],"observations":[]}'
    Assert-True (Test-WMLaudoShape -Laudo $semLacuna -Package $pacC).ok 'cobertura completa não obriga a declarar lacuna'

} finally { }

Show-TestSummary
exit (Get-TestExitCode)
