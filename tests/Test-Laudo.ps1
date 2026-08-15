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
    $VAZIO_OU_ACHADOS = New-Data '{"v":1,"window":"2026-08-15","host":"TESTE","verdict":"normal","findings":[],"coverage":{"complete":false,"evaluated":[],"unsourced":{"R-CPU-TEMP-SPEC":"fonte pendente"},"malformed":{},"noData":{},"noBaseline":{},"notApplicable":{}}}'
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

    <#
        O BURACO QUE A LIBERAÇÃO DE NÚMERO DE HARDWARE ABRIU, e que a verificação
        adversarial mediu no host.json REAL desta máquina.

        O disco chama-se ST10000NM001G-2MW103. Da versão antiga saía o número
        103, e com a tolerância de 5% isso liberava a faixa CONTÍNUA de 98 a 108
        — exatamente onde mora uma temperatura de CPU plausível. Um laudo
        afirmando "a CPU chegou a 100 graus" passava nas quatro guardas contra um
        pacote com zero achados e nenhuma temperatura.

        A ironia mede o tamanho do erro: R-CPU-TEMP-SPEC está desligada porque a
        procedência dos 100 °C era post de comunidade, e escrevê-lo na tabela
        seria inventar fonte. A guarda então aceitava o modelo escrevendo 100 no
        laudo.
    #>
    $HW3 = New-Data '{"os":"Windows 11 Pro","cpuName":"11th Gen Intel Core i9-11900K","cpuCores":8,"memTotalMB":130879,"gpuNames":["NVIDIA GeForce RTX 3080"],"disks":[{"name":"ST10000NM001G-2MW103","sizeGB":9314}]}'
    $pacDisco = New-WMLaudoPackage -Findings $VAZIO_OU_ACHADOS -Hardware $HW3

    foreach ($grau in 98, 99, 100, 104, 108) {
        $rr = Test-WMLaudoNumbers -Text "A CPU chegou a $grau graus no pico." -Package $pacDisco
        Assert-True (-not $rr.ok) "$grau graus NAO pode passar por causa do 103 no nome do disco"
    }

    # E o que motivou tudo continua funcionando: nome de peça em forma curta.
    $rr = Test-WMLaudoNumbers -Package $pacDisco -Text 'A RTX 3080 sustenta a carga e o disco ST10000NM001G-2MW103 tem folga.'
    Assert-True $rr.ok ('nome de peça, curto e longo, continua passando (órfãos: ' + ($rr.orphans -join ', ') + ')')

    # O número do nome, sozinho e como medida, agora é órfão.
    $rr = Test-WMLaudoNumbers -Text 'A GPU registrou 3080 graus.' -Package $pacDisco
    Assert-True (-not $rr.ok) '3080 como MEDIDA agora é recusado (antes passava, e estava registrado como limitação)'

    # =====================================================================
    Start-TestGroup 'CONFERÊNCIA: as formas de número que escapavam  [MUTAÇÃO]'

    $rr = Test-WMLaudoNumbers -Text 'O consumo chegou a 3.4e2 watts.' -Package $pac
    Assert-True (-not $rr.ok) 'notação científica não escapa mais (3.4e2 = 340)'

    $rr = Test-WMLaudoNumbers -Text 'A memória usou 2.048 MB no pico.' -Package $pac
    Assert-True (-not $rr.ok) 'milhar com ponto não vira 2,048 e passa'

    $rr = Test-WMLaudoNumbers -Text 'A placa passou de noventa e cinco graus.' -Package $pac
    Assert-True (-not $rr.ok) 'número por extenso não escapa por não ter dígito'

    $rr = Test-WMLaudoNumbers -Text 'Foram dois achados no período.' -Package $pac
    Assert-True $rr.ok 'mas "dois" continua passando: 2 está no pacote'

    <#
        FALSOS POSITIVOS QUE A PRÓPRIA CORREÇÃO DO EXTRATOR CRIOU, e que
        recusavam laudo honesto. Guarda que reprova texto correto acaba sendo
        desligada por quem a mantém, e aí não guarda mais nada.
    #>
    $rr = Test-WMLaudoNumbers -Text 'O volume está a 2 por cento de uso.' -Package $pac
    Assert-True $rr.ok '"por cento" é unidade, não o número cem'

    $rr = Test-WMLaudoNumbers -Text 'O problema apareceu entre dois e três dias atrás.' -Package $pac
    Assert-True $rr.ok '"entre dois e três" são dois numerais, não a soma 5'

    Assert-Equal 95 (@(Get-WMSpelledNumbers -Text 'noventa e cinco')[0].value) 'mas o composto de verdade ainda soma: 95'
    Assert-Equal 105 (@(Get-WMSpelledNumbers -Text 'cento e cinco')[0].value) 'e cento e cinco é 105'

    # 'mil' escapava por não ter dígito, e 2000 MB é medida plausível.
    $rr = Test-WMLaudoNumbers -Text 'A memoria livre caiu para mil MB.' -Package $pac
    Assert-True (-not $rr.ok) '"mil" não escapa por não ter dígito'
    Assert-Equal 1000 (@(Get-WMSpelledNumbers -Text 'mil')[0].value) 'mil é 1000'

    <#
        DÍGITO QUE O CONVERSOR NÃO SABE LER É ÓRFÃO, não é descartado. O '\d' do
        .NET casa dígito Unicode de largura inteira; ConvertTo-WMNumber, que é
        invariante, recusa. O 'continue' que havia aqui jogava fora em silêncio
        justamente o token mais suspeito do texto.
    #>
    $rr = Test-WMLaudoNumbers -Text ("A CPU chegou a " + [char]0xFF19 + [char]0xFF15 + " graus.") -Package $pac
    Assert-True (-not $rr.ok) 'dígito unicode que o conversor recusa vira órfão, não silêncio'

    # =====================================================================
    Start-TestGroup 'CONFERÊNCIA: as duas reaberturas do BL-1  [MUTAÇÃO]'

    <#
        N-2. Get-WMHardwarePhrases adicionava a string INTEIRA sem critério, e
        um campo de hardware cujo valor é só dígito — disks[].id vale "98" numa
        máquina com dez discos — virava frase sozinho. Aí 98 sumia do texto e
        "a CPU chegou a 98 graus" passava. É um dos números do laudo atacante.
    #>
    Assert-Equal 0 (@(Get-WMHardwarePhrases -Hardware '3080').Count) 'string de hardware só com dígito NÃO vira frase'
    Assert-Equal 1 (@(Get-WMHardwarePhrases -Hardware 'MP600').Count) 'mas token misto letra+dígito vira'
    Assert-True  (@(Get-WMHardwarePhrases -Hardware 'RTX 3080') -contains 'RTX 3080') 'e a frase de dois tokens também'
    Assert-Equal 0 (@(Get-WMHardwarePhrases -Hardware $null).Count) 'hardware nulo não produz frase'

    $HWNUM = New-Data '{"os":"Windows 11 Pro","cpuCores":8,"disks":[{"id":"98","name":"Disco","sizeGB":1863}]}'
    $pacNum = New-WMLaudoPackage -Findings $VAZIO_OU_ACHADOS -Hardware $HWNUM
    $rr = Test-WMLaudoNumbers -Text 'A CPU chegou a 98 graus no pico.' -Package $pacNum
    Assert-True (-not $rr.ok) 'campo de hardware puramente numérico não libera 98 como medida'

    <#
        N-3. A remoção de frase usava -replace sem âncora. Do host.json real sai
        a frase "11 Pro" (de "Microsoft Windows 11 Pro"), que casava o começo de
        "11 processos" e apagava um 11 inventado. Medido ponta a ponta: "havia 11
        processos travados" era APROVADO e "havia 11 travamentos" reprovado — a
        diferença era só a palavra depois do dígito.
    #>
    $pacOs = New-WMLaudoPackage -Findings $VAZIO_OU_ACHADOS -Hardware (New-Data '{"os":"Microsoft Windows 11 Pro","cpuCores":8}')
    $rr = Test-WMLaudoNumbers -Text 'Havia 11 processos travados no periodo.' -Package $pacOs
    Assert-True (-not $rr.ok) 'a frase "11 Pro" não come o 11 de "11 processos"'
    $rr = Test-WMLaudoNumbers -Text 'O sistema e o Microsoft Windows 11 Pro.' -Package $pacOs
    Assert-True $rr.ok 'e citar o nome do sistema inteiro continua passando'

    <#
        A REMOÇÃO DE LITERAIS IGNORA CAIXA, e isso não tinha teste — medido: dava
        para reverter ao String.Replace sensível a caixa e a suíte continuava
        verde. Com a mutação aplicada, "a placa e uma rtx 3080" virava órfão
        3080, e "i9-11900k" virava órfãos 9 e 11900.

        Reprovar laudo honesto é o modo de falha que faz alguém desligar a
        guarda, e aí ela não guarda mais nada. Todos os outros testes de literal
        usam a caixa exata do host.json, então nenhum exercitava a diferença.
    #>
    $rr = Test-WMLaudoNumbers -Package $pacHW -Text 'A placa e uma rtx 3080 e o processador um i9-11900k.'
    Assert-True $rr.ok ('nome de peça em CAIXA BAIXA não é fabricação (órfãos: ' + ($rr.orphans -join ', ') + ')')
    $rr = Test-WMLaudoNumbers -Package $pacHW -Text 'A placa e uma RTX 3080 E O PROCESSADOR UM I9-11900K.'
    Assert-True $rr.ok 'nem em CAIXA ALTA'

    Assert-Equal 95 (@(Get-WMSpelledNumbers -Text 'noventa e cinco')[0].value) 'a soma por extenso é 95, não 90 e 5 soltos'
    Assert-Equal 100 (@(Get-WMSpelledNumbers -Text 'cem')[0].value) 'cem é 100'

    # =====================================================================
    Start-TestGroup 'CONFERÊNCIA: identificador de regra em qualquer caixa  [MUTAÇÃO]'

    foreach ($id in 'R-MEMORIA-VAZANDO', 'r-memoria-vazando', 'R-Memoria-Vazando', 'R_MEMORIA_VAZANDO') {
        $rr = Test-WMLaudoRuleIds -Text "O achado $id sugere um problema." -Package $pac
        Assert-True (-not $rr.ok) "regra inventada escrita como '$id' é pega"
    }
    $rr = Test-WMLaudoRuleIds -Text 'a regra r-gpu-temp-drift disparou' -Package $pac
    Assert-True $rr.ok 'e uma regra que EXISTE passa mesmo em caixa baixa'

    <#
        Com acento. 'R-MEMÓRIA-VAZANDO' escapava inteira porque \b não fecha
        fronteira entre 'M' e 'Ó' — num laudo em português essa é a grafia
        provável, e a guarda só funcionava enquanto o modelo não acentuasse.
    #>
    $rr = Test-WMLaudoRuleIds -Text 'O achado R-MEMÓRIA-VAZANDO sugere um problema.' -Package $pac
    Assert-True (-not $rr.ok) 'regra inventada COM ACENTO é pega'

    <#
        E o outro sentido: prosa portuguesa comum não pode ser acusada de citar
        regra que não existe. Identificador deste projeto sempre tem dois
        segmentos depois do R; exigir isso elimina os falsos positivos sem
        afrouxar nada, porque nenhuma regra real tem um segmento só.
    #>
    foreach ($prosa in 'o r-quadrado do ajuste ficou baixo', 'o eixo r-y do grafico', 'a norma R-123 nao se aplica') {
        $rr = Test-WMLaudoRuleIds -Text $prosa -Package $pac
        Assert-True $rr.ok "prosa comum não é acusada de citar regra: '$prosa'"
    }

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

    $inventado = New-Data '{"summary":"x","notVerified":[{"ruleId":"R-CPU-TEMP-SPEC","note":"n"}],"changedSinceLast":"","observations":[],"findings":[{"ruleId":"R-GPU-TEMP-SPEC-3080","reading":"A temperatura da placa está acima do especificado.","action":"O valor não foi fornecido no pacote."}]}'
    $f1 = Test-WMLaudoFindings -Laudo $inventado -Package $pacV
    Assert-True (-not $f1.ok) 'regra de coverage virando ACHADO é rejeitada'
    Assert-True (@($f1.invented) -contains 'R-GPU-TEMP-SPEC-3080') 'e é nominada'

    # A prova de que as outras duas guardas realmente não pegavam este caso —
    # se um dia pegarem, ótimo, mas a defesa não pode depender disso.
    $textoInv = Get-WMLaudoText -Laudo $inventado
    Assert-True (Test-WMLaudoNumbers -Text $textoInv -Package $pacV).ok 'a guarda de números deixa passar (não há número)'
    Assert-True (Test-WMLaudoRuleIds -Text $textoInv -Package $pacV).ok 'a guarda de regras deixa passar (ruleId não está na prosa)'

    # Pacote vazio, laudo vazio: é a resposta certa, não uma falha.
    $limpo = New-Data '{"summary":"Nada mereceu atenção.","notVerified":[{"ruleId":"R-CPU-TEMP-SPEC","note":"n"}],"changedSinceLast":"","observations":[],"findings":[]}'
    Assert-True (Test-WMLaudoFindings -Laudo $limpo -Package $pacV).ok 'pacote sem achados, laudo sem achados: passa'

    # Relatar os achados que existem, passa.
    $fiel = New-Data '{"summary":"x","notVerified":[{"ruleId":"R-CPU-TEMP-SPEC","note":"n"}],"changedSinceLast":"","observations":[],"findings":[{"ruleId":"R-GPU-TEMP-DRIFT","reading":"a","action":"b"},{"ruleId":"R-DISK-SPACE-LOW","reading":"c","action":"d"}]}'
    Assert-True (Test-WMLaudoFindings -Laudo $fiel -Package $pac).ok 'relatar os achados do pacote passa'

    <#
        APAGAR ACHADO. A guarda conferia só ⊆, então omitir passava — e a
        verificação adversarial mediu o caso completo pelo driver: pacote com
        achado de severidade 'agir' (volume de sistema com 3 GB livres) e um
        laudo dizendo "a máquina está saudável e não há nada a fazer" passou nas
        quatro guardas e foi APRESENTADO, com o veredito determinístico 'agir'
        impresso duas linhas acima do texto que o contradizia.

        Das duas falhas possíveis esta é a pior. Achado inventado faz alguém
        olhar a máquina à toa; achado apagado faz ninguém olhar.
    #>
    $menos = New-Data '{"summary":"x","notVerified":[{"ruleId":"R-CPU-TEMP-SPEC","note":"n"}],"changedSinceLast":"","observations":[],"findings":[{"ruleId":"R-GPU-TEMP-DRIFT","reading":"a","action":"b"}]}'
    $fm = Test-WMLaudoFindings -Laudo $menos -Package $pac
    Assert-True (-not $fm.ok) 'omitir um achado do pacote é rejeitado'
    Assert-True ((@($fm.omitted) -join ' ') -match 'R-DISK-SPACE-LOW') 'e o achado apagado é nominado'

    $nenhum = New-Data '{"summary":"A maquina esta saudavel e nao ha nada a fazer.","notVerified":[{"ruleId":"R-CPU-TEMP-SPEC","note":"n"}],"changedSinceLast":"","observations":[],"findings":[]}'
    $fz = Test-WMLaudoFindings -Laudo $nenhum -Package $pac
    Assert-True (-not $fz.ok) 'apagar TODOS os achados é rejeitado'
    Assert-Equal 2 (@($fz.omitted).Count) 'e os dois são nominados'

    <#
        Duplicata: com duas placas a MESMA regra gera dois achados de verdade,
        então repetir não é erro por si. O que não pode é o laudo devolver mais
        ocorrências de uma regra do que o pacote trouxe — é inflar achado com
        um ruleId que passa no teste de pertinência.
    #>
    $inflado = New-Data '{"summary":"x","notVerified":[{"ruleId":"R-CPU-TEMP-SPEC","note":"n"}],"changedSinceLast":"","observations":[],"findings":[{"ruleId":"R-GPU-TEMP-DRIFT","reading":"a","action":"b"},{"ruleId":"R-GPU-TEMP-DRIFT","reading":"c","action":"d"}]}'
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
    $semId = New-Data '{"summary":"x","notVerified":[{"ruleId":"R-CPU-TEMP-SPEC","note":"n"}],"changedSinceLast":"","observations":[],"findings":[{"ruleId":"","reading":"a","action":"b"}]}'
    Assert-True (-not (Test-WMLaudoFindings -Laudo $semId -Package $pac).ok) 'achado sem ruleId é rejeitado'

    <#
        MÁQUINA SAUDÁVEL, O CASO MAIS COMUM QUE ESTE SISTEMA VAI VER.

        Pacote sem nenhum achado e laudo que simplesmente OMITE a chave
        'findings' era REPROVADO, acusado de relatar '(achado sem ruleId)' —
        porque @($null) rende um elemento nulo. Medido de ponta a ponta: as duas
        tentativas reprovavam, e a reapresentação mandava o modelo remover um
        achado que ele nunca escreveu.

        Toda fixture do projeto trazia "findings":[]. O campo presente e vazio
        nunca quebrou; o ausente quebrava, e nenhum teste o exercitava.
    #>
    $VAZIO2 = New-Data '{"v":1,"window":"2026-08-15","host":"T","verdict":"normal","findings":[],"coverage":{"complete":true,"evaluated":["R-DISK-SPACE-LOW"],"unsourced":{},"malformed":{},"noData":{},"noBaseline":{},"notApplicable":{}}}'
    $pacSao = New-WMLaudoPackage -Findings $VAZIO2

    foreach ($j in '{"summary":"Nada mereceu atencao no periodo."}',
                   '{"summary":"x","findings":null}',
                   '{"summary":"x","findings":null,"observations":null,"notVerified":null}') {
        $l = New-Data $j
        $fa = Test-WMLaudoFindings -Laudo $l -Package $pacSao
        $sh = Test-WMLaudoShape    -Laudo $l -Package $pacSao
        Assert-True ($fa.ok -and $sh.ok) ("laudo de máquina saudável com campos AUSENTES passa: $j (inventados: " + ($fa.invented -join ', ') + ')')
    }

    # E o achado genuinamente sem id continua sendo pego, com o pacote que o tem.
    Assert-True (-not (Test-WMLaudoFindings -Laudo $semId -Package $pac).ok) 'e achado com ruleId em branco continua rejeitado'

    # =====================================================================
    Start-TestGroup 'CONFERÊNCIA: obrigações de forma  [MUTAÇÃO]'

    <#
        O laudo que o mistral:latest devolveu de verdade, e que passou nas três
        guardas anteriores: lacuna calada e hipótese sobre o que ninguém mediu.
    #>
    $mistral = New-Data '{"summary":"Avaliado como normal.","notVerified":[],"changedSinceLast":"Nenhum","findings":[],"observations":["A temperatura do GPU parece estar um pouco acima da média normal durante o uso pesado."]}'

    $s1 = Test-WMLaudoShape -Laudo $mistral -Package $pacV
    Assert-True (-not $s1.ok) 'o laudo real do mistral é rejeitado'
    Assert-Equal 2 (@($s1.missing).Count) 'pelas duas razões, não por uma'

    # E a prova de que as outras três dormiam neste caso.
    $tm = Get-WMLaudoText -Laudo $mistral
    Assert-True (Test-WMLaudoNumbers  -Text $tm -Package $pacV).ok        'a guarda de números deixava passar'
    Assert-True (Test-WMLaudoRuleIds  -Text $tm -Package $pacV).ok        'a de regras deixava passar'
    Assert-True (Test-WMLaudoFindings -Laudo $mistral -Package $pacV).ok  'a de achados deixava passar'

    # Cada obrigação isolada, para que uma não mascare a outra.
    $soLacuna = New-Data '{"summary":"x","notVerified":[],"changedSinceLast":"","findings":[],"observations":[]}'
    $s2 = Test-WMLaudoShape -Laudo $soLacuna -Package $pacV
    Assert-True (-not $s2.ok) 'cobertura incompleta com notVerified vazio é rejeitada'
    Assert-True ((@($s2.missing) -join ' ') -match 'notVerified') 'e a razão nomeia o campo'

    # Entrada sem ruleId não declara lacuna nenhuma.
    $branco = New-Data '{"summary":"x","notVerified":[{"ruleId":"","note":"algo"}],"changedSinceLast":"","findings":[],"observations":[]}'
    Assert-True (-not (Test-WMLaudoShape -Laudo $branco -Package $pacV).ok) 'entrada sem ruleId não declara nada'

    # notVerified nomeia a lacuna: assim a única falha que resta é a hipótese.
    $soHipotese = New-Data '{"summary":"x","notVerified":[{"ruleId":"R-CPU-TEMP-SPEC","note":"n"},{"ruleId":"R-GPU-TEMP-SPEC-3080","note":"n"}],"changedSinceLast":"","findings":[],"observations":["a placa talvez esteja quente"]}'
    $s3 = Test-WMLaudoShape -Laudo $soHipotese -Package $pacV
    Assert-True (-not $s3.ok) 'hipótese sem nenhum achado no pacote é rejeitada'
    Assert-Equal 1 (@($s3.missing).Count) 'e só por essa razão'

    # O laudo correto para um pacote sem achados e cobertura incompleta.
    $certo = New-Data '{"summary":"Nada mereceu atenção.","notVerified":[{"ruleId":"R-CPU-TEMP-SPEC","note":"n"},{"ruleId":"R-GPU-TEMP-SPEC-3080","note":"n"}],"changedSinceLast":"","findings":[],"observations":[]}'
    Assert-True (Test-WMLaudoShape -Laudo $certo -Package $pacV).ok 'declarar a lacuna e não supor nada passa'

    # Com achados no pacote, hipótese é legítima — o campo não vira letra morta.
    $comAchado = New-Data '{"summary":"x","notVerified":[{"ruleId":"R-CPU-TEMP-SPEC","note":"n"}],"changedSinceLast":"","findings":[{"ruleId":"R-GPU-TEMP-DRIFT","reading":"a","action":"b"}],"observations":["o calor pode vir do ambiente"]}'
    Assert-True (Test-WMLaudoShape -Laudo $comAchado -Package $pac).ok 'com achado, a hipótese continua permitida'

    # Cobertura COMPLETA não exige notVerified.
    $pacC = New-WMLaudoPackage -Findings $DOISGPU
    $semLacuna = New-Data '{"summary":"x","notVerified":[],"changedSinceLast":"","findings":[],"observations":[]}'
    Assert-True (Test-WMLaudoShape -Laudo $semLacuna -Package $pacC).ok 'cobertura completa não obriga a declarar lacuna'

    <#
        A DERROTA QUE ACABOU COM A PROSA NESTE CAMPO.

        A guarda passou a exigir que o texto NOMEASSE uma lacuna. O verificador
        adversarial respondeu nomeando e NEGANDO na mesma frase:

          "R-CPU-TEMP-SPEC foi verificada e está normal. R-GPU-TEMP-DRIFT também
           foi conferida e nada indica problema. Tudo foi verificado."

        Aprovado e apresentado. A frase "Tudo foi verificado." sozinha era
        rejeitada; colada atrás de um identificador, passava. Não existe
        conferência aritmética de negação em prosa, e denylist de "foi
        verificada" / "está normal" / "nada indica" é corrida perdida contra um
        gerador de frases.

        Por isso o campo deixou de ser prosa. Estes testes fixam a nova regra:
        é lista de identificadores, e tem de COBRIR TODAS as lacunas do pacote.
    #>
    $negando = New-Data '{"summary":"x","notVerified":"R-CPU-TEMP-SPEC foi verificada e esta normal. Tudo foi verificado.","changedSinceLast":"","findings":[],"observations":[]}'
    Assert-True (-not (Test-WMLaudoShape -Laudo $negando -Package $pacV).ok) 'prosa que nomeia a lacuna e a nega não declara nada'

    $l = New-Data '{"summary":"x","notVerified":[{"ruleId":"R-CPU-TEMP-SPEC","note":"n"},{"ruleId":"R-GPU-TEMP-SPEC-3080","note":"n"}],"changedSinceLast":"","findings":[],"observations":[]}'
    Assert-True (Test-WMLaudoShape -Laudo $l -Package $pacV).ok 'declarar a lacuna como identificador passa'

    <#
        E COBRIR TODAS: o pacote $pacV tem duas lacunas (R-CPU-TEMP-SPEC em
        unsourced e R-GPU-TEMP-SPEC-3080 em noData). Declarar só uma deixava o
        modelo escolher qual lacuna existe.
    #>
    $meia = New-Data '{"summary":"x","notVerified":[{"ruleId":"R-CPU-TEMP-SPEC","note":"n"}],"changedSinceLast":"","findings":[],"observations":[]}'
    $pacDuas = New-WMLaudoPackage -Findings (New-Data '{"v":1,"window":"2026-08-15","host":"T","verdict":"normal","findings":[],"coverage":{"complete":false,"evaluated":[],"unsourced":{"R-CPU-TEMP-SPEC":"x"},"malformed":{},"noData":{"R-GPU-TEMP-SPEC-3080":"y"},"noBaseline":{},"notApplicable":{}}}')
    $sm = Test-WMLaudoShape -Laudo $meia -Package $pacDuas
    Assert-True (-not $sm.ok) 'declarar só uma de duas lacunas é rejeitado'
    Assert-True ((@($sm.missing) -join ' ') -match 'R-GPU-TEMP-SPEC-3080') 'e a lacuna calada é nominada'

    $ambas = New-Data '{"summary":"x","notVerified":[{"ruleId":"R-CPU-TEMP-SPEC","note":"n"},{"ruleId":"R-GPU-TEMP-SPEC-3080","note":"n"}],"changedSinceLast":"","findings":[],"observations":[]}'
    Assert-True (Test-WMLaudoShape -Laudo $ambas -Package $pacDuas).ok 'declarar as duas passa'

    <#
        O SENTIDO INVERSO, que custou a TERCEIRA reprovação.

        Transformar notVerified em lista estruturada fechou um buraco e abriu
        outro: o ruleId declarado não era conferido contra nada, e não entrava
        no texto que as guardas examinam. Medido pelo driver, com os achados
        reais — todos APROVADOS e impressos sob "Não verificado":

          R-SMART-DISK-FAILING, R-PSU-VOLTAGE-SAG   regras que não existem
          R-CPU-TEMP-100C-ATINGIDA                  o 100 viajando no id
          R-DISK-SPACE-LOW                          regra AVALIADA, com achado
                                                    'agir' impresso acima

        É a terceira vez que a mesma classe de defeito aparece neste projeto:
        campo estruturado que nenhuma guarda inspeciona. O mesmo id escrito na
        PROSA era acusado; dentro do objeto, passava.
    #>
    $inexistente = New-Data '{"summary":"x","notVerified":[{"ruleId":"R-CPU-TEMP-SPEC","note":"n"},{"ruleId":"R-GPU-TEMP-SPEC-3080","note":"n"},{"ruleId":"R-SMART-DISK-FAILING","note":"n"}],"changedSinceLast":"","findings":[],"observations":[]}'
    $si = Test-WMLaudoShape -Laudo $inexistente -Package $pacDuas
    Assert-True (-not $si.ok) 'declarar lacuna que não existe no pacote é rejeitado'
    Assert-True ((@($si.missing) -join ' ') -match 'R-SMART-DISK-FAILING') 'e a regra inventada é nominada'

    # Regra AVALIADA declarada como não verificada: contradição dentro do laudo.
    $contradiz = New-Data '{"summary":"x","notVerified":[{"ruleId":"R-CPU-TEMP-SPEC","note":"n"},{"ruleId":"R-GPU-TEMP-DRIFT","note":"n"}],"changedSinceLast":"","findings":[{"ruleId":"R-GPU-TEMP-DRIFT","reading":"a","action":"b"},{"ruleId":"R-DISK-SPACE-LOW","reading":"c","action":"d"}],"observations":[]}'
    Assert-True (-not (Test-WMLaudoShape -Laudo $contradiz -Package $pac).ok) 'regra que FOI avaliada não pode ser declarada não verificada'

    <#
        E o número contrabandeado no identificador. Agora o ruleId entra no
        texto conferido, então a guarda aritmética o vê como veria qualquer
        outro dígito — o identificador legítimo é removido pela lista de
        literais, o inventado não é.
    #>
    $comNumero = New-Data '{"summary":"x","notVerified":[{"ruleId":"R-CPU-TEMP-100C-ATINGIDA","note":"sem leitura"}],"changedSinceLast":"","findings":[],"observations":[]}'
    $txtN = Get-WMLaudoText -Laudo $comNumero
    Assert-True (-not (Test-WMLaudoNumbers -Text $txtN -Package $pacV).ok) 'número escondido dentro do ruleId cai na guarda aritmética'

    # Cobertura completa: não há lacuna, então declarar qualquer uma é invenção.
    $comLacuna = New-Data '{"summary":"x","notVerified":[{"ruleId":"R-GPU-TEMP-DRIFT","note":"n"}],"changedSinceLast":"","findings":[],"observations":[]}'
    Assert-True (-not (Test-WMLaudoShape -Laudo $comLacuna -Package $pacC).ok) 'cobertura completa com notVerified preenchido é rejeitada'

    <#
        @($null).Count É UM. A armadilha já está registrada neste projeto — ela
        matou a escala de severidade uma vez — e voltou aqui: com cobertura
        completa, um laudo cujo notVerified era AUSENTE, nulo ou string vazia era
        REPROVADO com a mensagem "notVerified preenchido". A guarda afirmava o
        oposto do que tinha acontecido, sobre um laudo honesto.
    #>
    <#
        Os campos AUSENTES de verdade entram nesta lista, não só os presentes e
        vazios. A primeira versão deste teste trazia sempre "observations":[] nas
        fixtures — e por isso não pegou que a MESMA armadilha estava na linha
        vizinha: com observations ausente, @($null).Count valia 1 e a guarda
        acusava hipótese num laudo que não tinha nenhuma. Achado rodando, depois
        do teste passar.
    #>
    foreach ($j in '{"summary":"x","changedSinceLast":"","findings":[],"observations":[]}',
                   '{"summary":"x","notVerified":null,"changedSinceLast":"","findings":[],"observations":[]}',
                   '{"summary":"x","notVerified":"","changedSinceLast":"","findings":[],"observations":[]}',
                   '{"summary":"x","notVerified":[],"changedSinceLast":"","findings":[],"observations":[]}',
                   '{"summary":"x"}',
                   '{"summary":"x","notVerified":null,"observations":null}') {
        $l = New-Data $j
        Assert-True (Test-WMLaudoShape -Laudo $l -Package $pacC).ok "campo vazio ou ausente não conta como preenchido: $j"
    }
    Assert-Equal 0 (Get-WMRealCount $null) 'Get-WMRealCount de nulo é ZERO, não um'
    Assert-Equal 0 (Get-WMRealCount '')    'de string vazia também'
    Assert-Equal 2 (Get-WMRealCount @('a', 'b')) 'e conta certo o que existe'

    <#
        A chave de cobertura com sufixo '#métrica'. Regra relativa gera
        'R-X#caminho.da.metrica', e o identificador é só o pedaço antes do '#'.
        Test-WMLaudoRuleIds já separava; Test-WMLaudoNumbers não — então num id
        com dígito o número virava órfão em laudo HONESTO. E a forma mais
        correta, declarar o id puro, era exatamente a que reprovava.
    #>
    $SUFIXO = New-Data '{"v":1,"window":"2026-08-15","host":"T","verdict":"normal","findings":[],"coverage":{"complete":false,"evaluated":[],"unsourced":{},"malformed":{},"noData":{},"noBaseline":{"R-GPU-TEMP-SPEC-3080#gpu.0.tempCAllDay.max":"sem linha-base"},"notApplicable":{}}}'
    $pacSfx = New-WMLaudoPackage -Findings $SUFIXO -Hardware $HW

    foreach ($decl in 'R-GPU-TEMP-SPEC-3080', 'R-GPU-TEMP-SPEC-3080#gpu.0.tempCAllDay.max') {
        $l = New-Data ('{"summary":"Nada a relatar.","changedSinceLast":"","findings":[],"observations":[],"notVerified":[{"ruleId":"' + $decl + '","note":"sem linha-base"}]}')
        $sh = Test-WMLaudoShape   -Laudo $l -Package $pacSfx
        $nu = Test-WMLaudoNumbers -Text (Get-WMLaudoText -Laudo $l) -Package $pacSfx
        Assert-True ($sh.ok -and $nu.ok) ("declarar a lacuna como '$decl' passa nas duas guardas (órfãos: " + ($nu.orphans -join ', ') + ')')
    }

    # Espaço sobrando no ruleId não pode virar duas mensagens ilegíveis.
    $comEspaco = New-Data '{"summary":"x","changedSinceLast":"","findings":[],"observations":[],"notVerified":[{"ruleId":" R-GPU-TEMP-SPEC-3080 ","note":"n"}]}'
    Assert-True (Test-WMLaudoShape -Laudo $comEspaco -Package $pacSfx).ok 'ruleId com espaço sobrando é aparado, não rejeitado'

    # coverage.complete como STRING "false" desligava a guarda inteira.
    $pacStr = $pacV | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $pacStr.coverage.complete = 'false'
    Assert-True (-not (Test-WMLaudoShape -Laudo $semLacuna -Package $pacStr).ok) 'complete:"false" (string) não é lido como cobertura completa'
    Assert-True (-not (Test-WMTrue 'false')) 'a string "false" é falsa'
    Assert-True (Test-WMTrue $true) 'e o booleano verdadeiro continua verdadeiro'

    # Pacote SEM bloco coverage desligava a guarda 4 por inteiro.
    $semCob = $pacV | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $semCob.PSObject.Properties.Remove('coverage')
    Assert-True (-not (Test-WMLaudoShape -Laudo $semLacuna -Package $semCob).ok) 'pacote sem coverage é o caso MAIS incompleto, não o mais completo'

} finally { }

Show-TestSummary
exit (Get-TestExitCode)
