#requires -Version 5.1
<#
    Bateria de mutação: prova que uma trava é defendida por teste.

    POR QUE ESTA FERRAMENTA EXISTE
    ------------------------------
    Sete verificações adversariais seguidas reprovaram este projeto, e a sétima
    nomeou a causa raiz — que não era o código:

        "Não é o código que não converge — é o método de aceitação."

    O método era: medir à mão, escrever o comentário com a medição, comitar. Ele
    produz código majoritariamente CERTO e defesa sistematicamente AUSENTE. Por
    isso a contagem de bloqueadores não caía — 6, 6, 4, 4, 5, 6, 6 — e por isso
    a mesma correção era refeita três vezes: ninguém segurava a anterior.

    A REGRA NOVA, e esta ferramenta é ela
    -------------------------------------
    Nenhuma correção entra sem um MUTANTE MORTO. Reverter a correção tem de
    deixar a suíte vermelha, e isso tem de ser DEMONSTRADO, não afirmado.

    Na primeira aplicação, contra dez correções que eu daria por prontas:
    CINCO mutantes sobreviveram. Metade do trabalho daquela sessão estava
    indefeso, e eu não saberia sem rodar isto.

    COMO USAR
    ---------
    Cada entrada reverte UMA correção numa cópia do projeto e roda a suíte que
    deveria defendê-la. Verde depois da reversão = trava indefesa.

        .\tools\Test-Mutantes.ps1
        .\tools\Test-Mutantes.ps1 -Somente 'BL-1'

    Ao acrescentar uma trava, acrescente aqui a mutação que a reverte. Se você
    não consegue escrever a mutação, provavelmente não sabe o que a trava
    defende.

    O QUE ISTO NÃO PEGA: teste que virou vácuo. Um 'Assert-True $true' não é
    revertido por mutação nenhuma. Só leitura humana e verificação adversarial
    pegam aquilo — está dito aqui em vez de negado.
#>
[CmdletBinding()]
param([string]$Somente)

$raiz = Split-Path -Parent $PSScriptRoot
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

<#
    ÂNCORAS SEM ALTERNATIVA. Uma asserção 'A|B' sobrevive à mutação de A porque
    B ainda satisfaz — medido, aconteceu na primeira versão de uma destas.
    Uma obrigação, uma âncora.
#>
$mutantes = @(
    @{ id='BL-1a'; nome='achado incompleto é categoria própria';  arq='src\WinMonitor.Laudo.psm1'
       de='ok         = ($inventados.Count -eq 0 -and $omitidos.Count -eq 0 -and $incompletos.Count -eq 0)'
       para='ok         = ($inventados.Count -eq 0 -and $omitidos.Count -eq 0)'; suite='Test-Laudo.ps1' }

    @{ id='BL-1b'; nome='o prompt nomeia os três campos';         arq='src\WinMonitor.Laudo.psm1'
       de='ruleId, reading e action'; para='os campos'; suite='Test-Laudo.ps1' }

    @{ id='BL-1c'; nome='o prompt diz que campo vazio é rejeitado'; arq='src\WinMonitor.Laudo.psm1'
       de='campo vazio é rejeitado'; para='campo livre'; suite='Test-Laudo.ps1' }

    @{ id='BL-1d'; nome='o prompt manda preencher, não remover';  arq='src\WinMonitor.Laudo.psm1'
       de='PREENCHA o campo: não remova o achado'; para='faça como preferir'; suite='Test-Laudo.ps1' }

    @{ id='BL-1e'; nome='o prompt ensina o que escrever sem ação'; arq='src\WinMonitor.Laudo.psm1'
       de='quando não há ação necessária, escreva isso'; para='algo'; suite='Test-Laudo.ps1' }

    @{ id='BL-5';  nome='regra sem id não mata o motor';          arq='src\WinMonitor.Rules.psm1'
       de='if ([string]::IsNullOrWhiteSpace($rid)) {'; para='if ($false) {'; suite='Test-Rules.ps1' }

    <#
        PROCEDÊNCIA DE MUTANTE: este assevera no módulo MAIS DISTANTE que
        consome o resultado, e não na linha do diff.

        O mutante acima prova que o motor não morre. Ele parava na fronteira do
        módulo — e o defeito estava um módulo adiante: o nome sintético que eu
        escolhi continha '#', o separador de campo do protocolo, e o laudo
        ficava ESTRUTURALMENTE INAPROVÁVEL. "Não mata o motor" era verdade e
        insuficiente; a consequência escrita no comentário era "e o dia
        continua", e é ELA que precisa de mutante.
    #>
    @{ id='BL-5b'; nome='o nome sintético não quebra o laudo';    arq='src\WinMonitor.Rules.psm1'
       de='"(regra sem id na posicao $indice)"'; para='"(regra #$indice sem id)"'; suite='Test-Laudo.ps1' }

    @{ id='BL-5c'; nome='duas regras sem id não colapsam';        arq='src\WinMonitor.Rules.psm1'
       de='"(regra sem id na posicao $indice)"'; para='"(regra sem id)"'; suite='Test-Rules.ps1' }

    @{ id='BL-Ea'; nome='campo de fachada é recusado';            arq='src\WinMonitor.Laudo.psm1'
       de='if (-not (Test-WMTextoSubstantivo $a.reading)) { $faltantes += ''reading'' }'
       para='if ([string]::IsNullOrWhiteSpace([string]$a.reading)) { $faltantes += ''reading'' }'; suite='Test-Laudo.ps1' }

    @{ id='BL-Eb'; nome='action de fachada é recusado';           arq='src\WinMonitor.Laudo.psm1'
       de='if (-not (Test-WMTextoSubstantivo $a.action))  { $faltantes += ''action'' }'
       para='if ([string]::IsNullOrWhiteSpace([string]$a.action))  { $faltantes += ''action'' }'; suite='Test-Laudo.ps1' }

    @{ id='BL-B';  nome='o dia decorrido é o dia LOCAL';          arq='src\WinMonitor.Report.psm1'
       de='$agoraLocal = $NowUtc.ToLocalTime()'; para='$agoraLocal = $NowUtc'; suite='Test-Report.ps1' }

    @{ id='BL-Cb'; nome='o frescor usa o MAIOR carimbo do passado'; arq='src\WinMonitor.Report.psm1'
       de='$ultimoReal = ($passado | Sort-Object)[-1]'; para='$ultimoReal = $passado[0]'; suite='Test-Report.ps1' }

    @{ id='BL-6';  nome='zero regra avaliada = cobertura incompleta'; arq='src\WinMonitor.Rules.psm1'
       de='if (@($avaliadas).Count -eq 0) {'; para='if ($false) {'; suite='Test-Rules.ps1' }

    @{ id='BL-3';  nome='carimbo no futuro não prova frescor';    arq='src\WinMonitor.Report.psm1'
       de='if ($atraso -lt 0) {'; para='if ($false) {'; suite='Test-Report.ps1' }

    @{ id='BL-2a'; nome='a razão da coleta sai com ok=true';      arq='src\WinMonitor.Report.psm1'
       de='} elseif (-not [string]::IsNullOrWhiteSpace([string]$Report.health.reason)) {'
       para='} elseif ($false) {'; suite='Test-Report.ps1' }

    @{ id='BL-2b'; nome='cobertura contra o dia DECORRIDO';       arq='src\WinMonitor.Report.psm1'
       de='$esperadasAteAgora = [Math]::Max(1.0, $minutosDoDia / [Math]::Max(1, $IntervalMinutes))'
       para='$esperadasAteAgora = [double]$saude.expectedPerDay'; suite='Test-Report.ps1' }

    @{ id='BL-4a'; nome='o portão lê o stdout com OEM';           arq='tests\Run-All.ps1'
       de='(Get-Content -LiteralPath $tmpOut -Raw -Encoding OEM -ErrorAction SilentlyContinue)'
       para='(Get-Content -LiteralPath $tmpOut -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)'; suite='Test-Gate.ps1' }

    @{ id='BL-4a2'; nome='o portão lê o stderr com OEM';          arq='tests\Run-All.ps1'
       de='(Get-Content -LiteralPath ($tmpOut + ''.err'') -Raw -Encoding OEM -ErrorAction SilentlyContinue)'
       para='(Get-Content -LiteralPath ($tmpOut + ''.err'') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)'; suite='Test-Gate.ps1' }

    <#
        O canal local monta XML. Sem escapar, um '&' vindo de nome de disco
        quebra o documento e a notificacao some SEM ERRO - o pior desfecho para
        um canal de aviso. A mutacao remove o escape.
    #>
    @{ id='BL-T';  nome='o canal local escapa XML';               arq='src\notifiers\Notify-Toast.ps1'
       de='function Protege { param([string]$s) [System.Security.SecurityElement]::Escape($s) }'
       para='function Protege { param([string]$s) $s }'; suite='Test-Report.ps1' }

    <#
        As quatro travas que nasceram da comparacao de modelos: o pacote passou
        a DAR a resposta em vez de pedir deducao, e a remocao de literais passou
        a conhecer o nome da maquina e os caminhos dentro das razoes.
    #>
    @{ id='BL-G';  nome='o pacote traz a lista pronta de lacunas'; arq='src\WinMonitor.Laudo.psm1'
       de='$pacote.gapsToDeclare = @($lacunas)'; para='$pacote.gapsToDeclare = @()'; suite='Test-Laudo.ps1' }

    @{ id='BL-O';  nome='o pacote diz se hipotese e permitida';    arq='src\WinMonitor.Laudo.psm1'
       de='$pacote.observationsAllowed = (@($Findings.findings).Count -gt 0)'
       para='$pacote.observationsAllowed = $true'; suite='Test-Laudo.ps1' }

    @{ id='BL-H';  nome='o nome da maquina nao vira numero inventado'; arq='src\WinMonitor.Laudo.psm1'
       de='[void]$literais.Add([string]$Package.host)'; para='$null = $Package'; suite='Test-Laudo.ps1' }

    <#
        A substituição não pode quebrar a sintaxe do arquivo mutado: '# removido'
        numa linha dentro de bloco engole a chave de fechamento que vem depois,
        a suíte morre no parse e a bateria classifica como INCONCLUSIVO. Foi o
        que aconteceu aqui — e a classificação nova estava certa: ela recusou-se
        a chamar de morto o que não tinha rodado.
    #>
    @{ id='BL-R';  nome='o caminho dentro da razao da lacuna some'; arq='src\WinMonitor.Laudo.psm1'
       de='[void]$literais.Add($m.Value)'
       para='$null = $m'; suite='Test-Laudo.ps1' }

    <#
        AS TRAVAS DA PRÓPRIA AFERIÇÃO — impossíveis de mutar até o sandbox
        passar a copiar 'tools'. A ferramenta que decide o portão era a única
        peça do repositório que ninguém podia sabotar.
    #>
    @{ id='BL-91a'; nome='o portao reprova bateria com codigo != 0'; arq='tests\Run-All.ps1'
       de='if ($codBat -ne 0) {'; para='if ($false) {'; suite='Test-Gate.ps1' }

    @{ id='BL-91b'; nome='bateria muda nao prova nada';            arq='tests\Run-All.ps1'
       de="[void]`$falhas.Add('bateria de mutação: saiu com zero mas não declarou quantos mutantes morreram')"
       para='$null = $codBat'; suite='Test-Gate.ps1' }

    @{ id='BL-91c'; nome='bateria com ZERO mutantes nao prova nada'; arq='tests\Run-All.ps1'
       de='if ($qtd -lt 1) {'; para='if ($false) {'; suite='Test-Gate.ps1' }

    @{ id='BL-91d'; nome='a contagem da bateria e conferida';       arq='tests\Run-All.ps1'
       de='if ($mortos -ne $qtd) {'; para='if ($false) {'; suite='Test-Gate.ps1' }

    @{ id='BL-92';  nome='a bateria tem prazo';                     arq='tests\Run-All.ps1'
       de='if (-not $pb.WaitForExit($BateriaTimeoutSec * 1000)) {'
       para='if ($false) { $pb.WaitForExit()'; suite='Test-Gate.ps1' }

    @{ id='BL-93';  nome='o sandbox da bateria copia tools';        arq='tools\Test-Mutantes.ps1'
       de="foreach (`$d in 'src', 'config', 'tests', 'tools') {"
       para="foreach (`$d in 'src', 'config', 'tests') {"; suite='Test-Gate.ps1' }

    <#
        As tres travas que b5543bf introduziu sem mutante - medidas vivas pela
        nona verificacao.
    #>
    @{ id='BL-95a'; nome='piso de dois alfanumericos';            arq='src\WinMonitor.Laudo.psm1'
       de='(@([regex]::Matches($s, ''[\p{L}\d]'')).Count -ge 2)'
       para='(@([regex]::Matches($s, ''[\p{L}\d]'')).Count -ge 1)'; suite='Test-Laudo.ps1' }

    @{ id='BL-95b'; nome='Trim antes da denylist de fachada';     arq='src\WinMonitor.Laudo.psm1'
       de='$s = $s.Trim()'; para='$s = $s'; suite='Test-Laudo.ps1' }

    @{ id='BL-95c'; nome='ramo do dia FECHADO na cobertura';      arq='src\WinMonitor.Report.psm1'
       de='if ($ehHoje) {'; para='if ($true) {'; suite='Test-Report.ps1' }

    <#
        Saude de disco: so 'Healthy' conta como saudavel. A mutacao troca a
        comparacao por "nao e Unhealthy", que aceita Warning como sao - o
        degrau que o Windows usa justamente para avisar antes de desistir.
    #>
    @{ id='BL-D1';  nome='so Healthy conta como saudavel';        arq='src\probes\Probe-DiskHealth.ps1'
       de='$ok = ($saude -ceq ''Healthy'')'; para='$ok = ($saude -cne ''Unhealthy'')'; suite='Test-Exam.ps1' }

    @{ id='BL-D2';  nome='sonda de disco que falha devolve NULO'; arq='src\probes\Probe-DiskHealth.ps1'
       de='disks    = $null'; para='disks    = @()'; suite='Test-Exam.ps1' }

    <#
        -ceq E NAO -eq: '-eq' e insensivel a caixa, entao 'healthy' minusculo
        passava por saudavel. Nao e preciosismo - HealthStatus chega como texto
        de fonte externa, e "aceito qualquer caixa" e como um valor que eu nao
        reconheco vira aprovacao silenciosa.
    #>
    @{ id='BL-D3';  nome='saude de disco compara com caixa';      arq='src\probes\Probe-DiskHealth.ps1'
       de='$ok = ($saude -ceq ''Healthy'')'; para='$ok = ($saude -eq ''Healthy'')'; suite='Test-Exam.ps1' }

    <#
        ZERO DISCO NAO E ZERO DOENTE. Sem este ramo, a maquina que nao devolve
        disco nenhum sai com unhealthy=0 - a leitura mais tranquilizadora
        possivel para a situacao em que nada foi lido.
    #>
    @{ id='BL-D4';  nome='zero disco lido nao vira zero doente';  arq='src\probes\Probe-DiskHealth.ps1'
       de='if ($lidos.Count -eq 0) {'; para='if ($false) {'; suite='Test-Exam.ps1' }

    <#
        A CADEIA DA REGRA, ponta a ponta: sonda registrada no exame, regra
        apontando para a chave que a sonda escreve, motor avaliando. Cada elo
        sozinho passa com o vizinho quebrado - foi assim que a regra de disco
        ficou tres fases declarada e nunca avaliada.
    #>
    @{ id='BL-X1';  nome='a sonda de disco esta no exame';        arq='config\config.json'
       de='"name":  "DiskHealth",'; para='"name":  "DiskHealthX",'; suite='Test-Exam.ps1' }

    @{ id='BL-X3';  nome='a regra le a chave que a sonda escreve'; arq='config\thresholds.json'
       de='"metric":  "dsk.unhealthy",'; para='"metric":  "dsk.doentes",'; suite='Test-Exam.ps1' }

    @{ id='A5';    nome='regra malformada conta como lacuna';     arq='src\WinMonitor.Rules.psm1'
       de='$lacunas = $semFonte.Count + $malformadas.Count + $semDado.Count'
       para='$lacunas = $semFonte.Count + $semDado.Count'; suite='Test-Rules.ps1' }

    <#
        AS TRAVAS DA DECIMA RODADA. Todas nasceram de defeitos que o portao
        deixava passar VERDE, e por isso todas apontam para o portao ou para a
        propria bateria: o instrumento de medida errando e a categoria de erro
        que nenhuma outra trava pega.
    #>
    @{ id='BL-94a'; nome='dois resumos de bateria nao sao um';    arq='tests\Run-All.ps1'
       de='if ($mbs.Count -gt 1) {'; para='if ($false) {'; suite='Test-Gate.ps1' }

    @{ id='BL-94b'; nome='o piso de mutantes vale';               arq='tests\Run-All.ps1'
       de='} elseif ($qtd -lt $MutantesMin) {'; para='} elseif ($false) {'; suite='Test-Gate.ps1' }

    <#
        A propria bateria: silencio nao e morte. Este mutante roda dentro do
        sandbox que copia 'tools', e Test-Gate executa a bateria MUTADA contra
        um mutante cuja suite nao existe. Sem o ramo, ela anuncia sucesso sobre
        o que nao rodou.
    #>
    @{ id='BL-96a'; nome='suite que nao roda e INCONCLUSIVO';     arq='tools\Test-Mutantes.ps1'
       de='if ([string]::IsNullOrWhiteSpace($linha)) {'; para='if ($false) {'; suite='Test-Gate.ps1' }

    @{ id='BL-96b'; nome='inconclusivo conta no veredito final';  arq='tools\Test-Mutantes.ps1'
       de='if ($vivos.Count -eq 0 -and $naoAplic.Count -eq 0 -and $inconclusivos.Count -eq 0) {'
       para='if ($vivos.Count -eq 0 -and $naoAplic.Count -eq 0) {'; suite='Test-Gate.ps1' }

    <#
        A VARREDURA DE SOMBRA DE PARAMETRO, e ela entra COM os mutantes que a
        atacam - a primeira versao dela nasceu morta por usar '-eq', que e
        insensivel a caixa e descartava exatamente o que ela procurava.

        BL-97a reverte para '-eq': a varredura deixa de acusar qualquer coisa.
        BL-97b apaga o descarte legitimo: ela acusa reatribuicao normal e vira
        ruido, que e o outro jeito de uma varredura morrer.
    #>
    @{ id='BL-97a'; nome='a varredura compara com caixa';         arq='tools\Find-ParamShadow.ps1'
       de='if (($nomeV -ceq $nomeP)) { continue }'; para='if (($nomeV -eq $nomeP)) { continue }'; suite='Test-Gate.ps1' }

    @{ id='BL-97b'; nome='mesma grafia nao e colisao';            arq='tools\Find-ParamShadow.ps1'
       de='if (($nomeV -ceq $nomeP)) { continue }'; para='if ($false) { continue }'; suite='Test-Gate.ps1' }

    <#
        O terceiro jeito de a varredura morrer: acusar o que e legitimo. Sem o
        recuo, o escopo do script engole os corpos das funcoes e '$discos = 1'
        DENTRO de uma funcao vira colisao - e nao e: ali nasce variavel nova.
    #>
    @{ id='BL-97d'; nome='o escopo do script para na funcao';     arq='tools\Find-ParamShadow.ps1'
       de='if ($dentroDeFuncao) { continue }'; para='if ($false) { continue }'; suite='Test-Gate.ps1' }

    @{ id='BL-97c'; nome='o portao reprova por sombra';           arq='tests\Run-All.ps1'
       de='if ($psom.ExitCode -ne 0) {'; para='if ($false) {'; suite='Test-Gate.ps1' }

    <#
        Os bytes executados sao os publicados. O .gitattributes declara CRLF e a
        arvore estava em LF: o verde valia para uma versao que so existia nesta
        maquina. O mutante desliga a conferencia; o cenario copia o projeto,
        reescreve um arquivo em LF e exige vermelho.
    #>
    @{ id='BL-99';  nome='LF solto num script reprova';           arq='tests\Run-All.ps1'
       de='if ($lfSoltos.Count -gt 0) {'; para='if ($false) {'; suite='Test-Gate.ps1' }

    @{ id='BL-98';  nome='-BateriaPath confinado a afericao';     arq='tests\Run-All.ps1'
       de='if ($BateriaPath -and -not $SuiteDir) {'; para='if ($false) {'; suite='Test-Gate.ps1' }

    @{ id='BL-4b'; nome='recuo de exam.probes ausente';           arq='src\Invoke-Exam.ps1'
       de='$sondas = @($cfg.exam.probes | Where-Object { $_ -and $_.name -and $_.key })'
       para='$sondas = @($cfg.exam.probes)'; suite='Test-Exam.ps1' }

    @{ id='BL-4c'; nome='filtro de exam.missing';                 arq='src\Invoke-Exam.ps1'
       de='foreach ($p in @($cfg.exam.missing | Where-Object { $_ -and $_.key })) {'
       para='foreach ($p in @($cfg.exam.missing)) {'; suite='Test-Exam.ps1' }
)

if ($Somente) { $mutantes = @($mutantes | Where-Object { $_.id -like "*$Somente*" }) }
if ($mutantes.Count -eq 0) { Write-Error "nenhum mutante casa '$Somente'"; exit 2 }

$vivos         = New-Object System.Collections.ArrayList
$naoAplic      = New-Object System.Collections.ArrayList
$inconclusivos = New-Object System.Collections.ArrayList

foreach ($m in $mutantes) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wm-mut-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        <#
            'tools' ENTRA NA CÓPIA, e a omissão era estrutural.

            Sem ela, nenhum mutante podia jamais apontar para esta ferramenta —
            a peça que decide se o portão aprova era a única do repositório
            impossível de sabotar. Medido: os dois consertos que ela recebeu (o
            INCONCLUSIVO e a âncora obsoleta) sobreviviam à reversão, e não
            havia como ser diferente.

            A ferramenta anti-"defesa sem defensor" era a defesa sem defensor.
        #>
        foreach ($d in 'src', 'config', 'tests', 'tools') {
            Copy-Item -LiteralPath (Join-Path $raiz $d) -Destination $tmp -Recurse -Force
        }

        $alvo = Join-Path $tmp $m.arq
        $txt  = [System.IO.File]::ReadAllText($alvo)

        <#
            Âncora ausente é FALHA, não silêncio. Uma mutação que não aplica
            passa por "morta" numa leitura desatenta, e a trava fica indefesa com
            aparência de coberta — que é a categoria inteira de defeito que esta
            ferramenta existe para acabar.
        #>
        if (-not $txt.Contains($m.de)) {
            [void]$naoAplic.Add("$($m.id): âncora não encontrada em $($m.arq)")
            "  ?? NÃO APLICOU  {0,-6} {1}" -f $m.id, $m.nome
            continue
        }

        [System.IO.File]::WriteAllText($alvo, $txt.Replace($m.de, $m.para), (New-Object System.Text.UTF8Encoding($true)))

        $saida = & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                     -File (Join-Path $tmp ('tests\' + $m.suite)) 2>&1 | Out-String
        $linha = (($saida -split "`n" | Select-String 'passou,').Line -join '').Trim()

        <#
            SILÊNCIO NÃO É MORTE — e esta ferramenta contava como se fosse.

            Sem linha de resumo, a comparação com ',0 falhou' dava falso e o
            código caía no ramo 'morto'. Medido: apontando o mutante para uma
            suíte inexistente, ela imprimia "morto" com a coluna vazia e depois
            "TODOS OS MUTANTES MORRERAM", saindo com zero. Nada tinha rodado.

            É o defeito A-06 deste projeto — etapa que não roda contando como
            verde — dentro da ferramenta construída para acabar com ele. Suíte
            que não chega ao fim é INCONCLUSIVO, e inconclusivo é vermelho:
            não sei se a trava é defendida, e não saber não é aprovar.
        #>
        if ([string]::IsNullOrWhiteSpace($linha)) {
            [void]$inconclusivos.Add("$($m.id): $($m.suite) não imprimiu resumo — a suíte não rodou até o fim")
            "  ?? INCONCLUSIVO {0,-6} {1}" -f $m.id, $m.nome
        } elseif ($linha -match ',\s*0\s+falhou') {
            [void]$vivos.Add("$($m.id) $($m.nome) — $($m.suite) ficou verde com a trava revertida")
            "  VIVO   {0,-6} {1,-48} {2}" -f $m.id, $m.nome, $linha
        } else {
            "  morto  {0,-6} {1,-48} {2}" -f $m.id, $m.nome, $linha
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

""
if ($vivos.Count -eq 0 -and $naoAplic.Count -eq 0 -and $inconclusivos.Count -eq 0) {
    "TODOS OS $($mutantes.Count) MUTANTES MORRERAM — cada trava tem quem a defenda."
    exit 0
}
foreach ($v in $vivos)         { "  x $v" }
foreach ($n in $naoAplic)      { "  x $n" }
foreach ($i in $inconclusivos) { "  x $i" }
"$($vivos.Count) trava(s) indefesa(s), $($naoAplic.Count) âncora(s) obsoleta(s), $($inconclusivos.Count) inconclusivo(s)"
exit 1
