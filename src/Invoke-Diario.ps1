#requires -Version 5.1
<#
    A CADEIA DIARIA: agrega, avalia e entrega.

    POR QUE ELE EXISTE
    ------------------
    A ronda tinha tarefa agendada e coletava havia oito dias, perfeitamente. A
    cadeia que TRANSFORMA aquilo em diagnostico nao tinha tarefa nenhuma: ela
    rodou nos dois primeiros dias porque alguem a invocou a mao, e parou quando
    essa pessoa parou.

    Medido em 22/08: 8 dias de bruto integro, e o ultimo agregado era de 16/08.
    O que a maquina tinha era um gravador de caixa-preta excelente com ninguem
    lendo a fita.

    A ORDEM, E POR QUE ELA IMPORTA
    ------------------------------
    Agregar -> avaliar -> entregar. Cada etapa le o que a anterior gravou, e
    pular uma faz a seguinte trabalhar sobre dado velho SEM ERRO NENHUM - que e
    a forma de falha que este projeto inteiro existe para nao ter.

    O EXAME NAO ESTA AQUI, e a ausencia e deliberada. Ele grava o arquivo do dia
    CORRENTE; esta cadeia fecha o dia ANTERIOR. Rodar os dois juntos depois da
    meia-noite deixaria todo dia sem exame, e as duas regras de falha de
    hardware cairiam em "sem dado" para sempre - em silencio, com o veredito
    saindo 'normal'. Por isso o exame tem tarefa propria, no fim do dia que ele
    descreve.

    O CODIGO DE SAIDA E O CONTRATO COM O AGENDADOR
    ----------------------------------------------
    E a unica coisa que alguem olha ao perguntar se isto esta vivo:

        0  a cadeia inteira rodou
        1  alguma etapa falhou, e a saida diz QUAL
        2  o modulo nao carregou: nada rodou

    Etapa que falha NAO interrompe as seguintes por padrao. Um agregado que
    falhou num dia nao deve impedir o relatorio de dizer que a coleta parou -
    calar o aviso porque a etapa anterior quebrou seria o pior desfecho
    possivel.

      .\src\Invoke-Diario.ps1
#>
[CmdletBinding()]
param(
    [switch]$Quiet,
    <#
        Costura de teste: troca a raiz dos scripts invocados. Nao e usada em
        producao, e existe para a suite exercitar a ORDEM e o tratamento de
        falha sem depender do estado real da maquina.
    #>
    [string]$RaizScripts
)

$raiz = if ($RaizScripts) { $RaizScripts } else { $PSScriptRoot }

<#
    CADA ETAPA DECLARA O QUE PRECISA TER PRODUZIDO, e a producao e CONFERIDA.

    A primeira versao deste arquivo so olhava se a etapa estourava. Medido na
    primeira execucao: as tres emitiram aviso, nenhuma produziu arquivo, e a
    cadeia imprimiu 'COMPLETA: agregado, avaliado e entregue' saindo com ZERO.

    Os scripts nao lancam - eles avisam com Write-Warning e retornam. Um
    orquestrador que so escuta excecao nao ouve nada disso, e o Agendador de
    Tarefas registra sucesso para um dia em que nada aconteceu.

    E o defeito assinatura deste projeto - etapa que nao roda contando como
    verde - cometido dentro da peca escrita para acabar com ele.
#>
$etapas = @(
    @{ nome = 'agregar';  script = 'Invoke-Rollup.ps1'; produz = 'rollup'   }
    @{ nome = 'avaliar';  script = 'Invoke-Rules.ps1';  produz = 'findings' }
    @{ nome = 'entregar'; script = 'Invoke-Report.ps1'; produz = 'report'   }
)

<#
    A raiz de dados vem do config, e nao de um caminho fixo: a suite roda contra
    copias, e um caminho fixo faria o teste medir os dados reais da maquina.
#>
$raizProjeto = Split-Path -Parent $raiz
$dirDados = Join-Path $raizProjeto 'data'

$falhas = New-Object System.Collections.ArrayList

foreach ($e in $etapas) {
    $alvo = Join-Path $raiz $e.script
    if (-not (Test-Path -LiteralPath $alvo)) {
        [void]$falhas.Add("$($e.nome): $($e.script) nao existe")
        continue
    }
    try {
        $saida = & $alvo 2>&1 | Out-String
        if (-not $Quiet) { "########  $($e.nome)  ########"; $saida.TrimEnd() }
        <#
            $LASTEXITCODE nao serve aqui: estes scripts sao invocados no MESMO
            processo, entao ele guarda o codigo do ultimo comando NATIVO - que
            pode ser de outra etapa, ou de nenhuma. E exatamente o defeito que o
            portao teve e que invalidou 135 testes de uma vez.

            Etapa que estoura cai no catch; etapa que termina, terminou.
        #>
    } catch {
        [void]$falhas.Add("$($e.nome): $($_.Exception.Message)")
        if (-not $Quiet) { "########  $($e.nome): FALHOU  ########"; $_.Exception.Message }
        continue
    }

    <#
        NAO ESTOURAR NAO E TER PRODUZIDO. A conferencia e do ARTEFATO: sem
        arquivo no diretorio da etapa, ela nao fez o trabalho dela, e dizer o
        contrario seria o Agendador registrando sucesso sobre um dia vazio.
    #>
    $dirEtapa = Join-Path $dirDados $e.produz
    $qtd = @(Get-ChildItem -LiteralPath $dirEtapa -File -ErrorAction SilentlyContinue).Count
    if ($qtd -eq 0) {
        [void]$falhas.Add("$($e.nome): nao produziu nada em data\$($e.produz) - a etapa nao fez o trabalho dela")
    }

    <#
        E o AVISO da etapa sobe para o resumo. Write-Warning nao interrompe
        nada, entao um 'nenhum agregado completo disponivel' ficava enterrado no
        meio da saida enquanto a cadeia anunciava sucesso.
    #>
    <#
        -cmatch E ANCORADO NO INICIO DA LINHA, e as duas coisas importam.

        A primeira versao usava -match 'AVISO|WARNING'. '-match' e INSENSIVEL A
        CAIXA, entao ela casava a palavra 'aviso' no corpo legitimo do relatorio
        - "Motivo do aviso: pulso" - e reprovava a cadeia inteira num dia em que
        as tres etapas produziram tudo. Medido na primeira execucao contra os
        oito dias reais.

        E a mesma armadilha do '-eq' que ja mordeu a saude de disco, noutra
        roupa: operador insensivel a caixa fazendo a condicao pegar o que ela
        nao queria.

        O que interessa e o PREFIXO que o PowerShell emite ao inicio da linha
        quando alguem chama Write-Warning, e nada mais.
    #>
    foreach ($linha in @($saida -split "`n")) {
        if ($linha -cmatch '^\s*(AVISO|WARNING):') { [void]$falhas.Add("$($e.nome) avisou: " + $linha.Trim()) }
    }
}

""
if ($falhas.Count -eq 0) {
    'CADEIA DIARIA COMPLETA: agregado, avaliado e entregue.'
    exit 0
}
foreach ($f in $falhas) { "  x $f" }
"$($falhas.Count) etapa(s) da cadeia diaria falharam"
exit 1
