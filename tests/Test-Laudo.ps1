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

} finally { }

Show-TestSummary
exit (Get-TestExitCode)
