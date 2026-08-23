#requires -Version 5.1
<#
    Canal de aviso por Telegram — o único que alcança quem não está na máquina.

    POR QUE ELE EXISTE
    ------------------
    Os outros dois canais falham exatamente quando mais precisam funcionar:

      Notify-File   escreve num disco que pode ser o que está morrendo.
      Notify-Toast  aparece na sessão INTERATIVA — e a ronda passou a rodar em
                    S4U, fora dela. Ele já não alcança ninguém desde então.

    Se o disco começar a falhar às três da manhã, o canal que sobra é um arquivo
    no disco que está falhando. Este canal existe para isso não ser verdade.

    ONDE MORA O SEGREDO, e por que não é em config\secrets.json
    -----------------------------------------------------------
    O token fica em  ~\.claude\winmonitor-telegram.json  — FORA do repositório.

    Este repositório é público. 'config\secrets.json' está no .gitignore, e isso
    funciona enquanto ninguém editar o .gitignore, rodar 'git add -f', ou copiar
    o arquivo para outro lugar da árvore. Um segredo que vive fora da árvore não
    depende de ninguém lembrar de nada.

    É o mesmo desenho do bot do Juiz Lyra, e ele foi adotado lá pelo mesmo
    motivo. Bot SEPARADO, porém: aviso de disco morrendo não pode se perder no
    meio de conversa de desenvolvimento.

    O QUE ELE MANDA
    ---------------
    Um RESUMO, não o relatório inteiro. O Telegram corta em 4096 caracteres, e
    um relatório completo passa disso — cortar no meio entregaria meia frase
    sem dizer que cortou. Aqui o que importa vem primeiro (veredito, motivo do
    aviso, achados) e, se sobrar coisa de fora, a mensagem DIZ que sobrou.

    TEXTO PURO, sem parse_mode. Nome de disco vem do fabricante e pode conter
    '*', '_' e '[' — com Markdown ligado, o Telegram recusa a mensagem inteira e
    o aviso some sem erro nenhum do nosso lado. É a mesma lição do escape de XML
    no canal local, e o desfecho errado é o mesmo: o pior canal de aviso é o que
    falha em silêncio.
#>
param(
    [Parameter(Mandatory)][string]$Text,
    [Parameter(Mandatory)]$Report,
    [Parameter(Mandatory)]$Config,
    $Secrets,
    <#
        Costuras de teste. Nenhuma é usada em produção.

        -Transporte recebe (url, corpo) e devolve a resposta: com ele a suíte
        exercita a composição da mensagem e o tratamento de erro SEM rede. Sem
        essa costura, testar este arquivo exigiria internet e um bot de verdade,
        e um teste assim não roda no portão.
    #>
    [string]$CaminhoConfig,
    [scriptblock]$Transporte
)

# $Secrets faz parte do contrato de canal e NÃO é usado aqui: o token mora fora
# da árvore, pela razão escrita no cabeçalho.
$null = $Secrets

$LIMITE_TELEGRAM = 4096

try {
    $arqCfg = if ($CaminhoConfig) { $CaminhoConfig }
              else { Join-Path $env:USERPROFILE '.claude\winmonitor-telegram.json' }

    if (-not (Test-Path -LiteralPath $arqCfg)) {
        <#
            NÃO CONFIGURADO É FALHA DECLARADA, NUNCA EXCEÇÃO.

            Um throw aqui derrubaria a entrega dos OUTROS canais — o relatório
            deixaria de ser gravado em disco porque o Telegram não está montado.
            Canal que não entrega diz que não entregou, e o driver segue.
        #>
        return @{ ok = $false; detail = "não configurado: $arqCfg não existe (crie com token e chatId do bot)" }
    }

    $cfgBot = $null
    try {
        $cfgBot = Get-Content -LiteralPath $arqCfg -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return @{ ok = $false; detail = "configuração ilegível em $arqCfg : $($_.Exception.Message)" }
    }

    if ([string]::IsNullOrWhiteSpace([string]$cfgBot.token) -or
        [string]::IsNullOrWhiteSpace([string]$cfgBot.chatId)) {
        return @{ ok = $false; detail = "configuração incompleta em $arqCfg : falta token ou chatId" }
    }

    <#
        SÓ SE MANDA AVISO SOBRE ESTA MÁQUINA.

        A suíte de testes roda Invoke-Report contra projetos COPIADOS, com
        fixtures cujo host é 'FIXTURE-HOST'. Com o canal registrado no config,
        cada execução da suíte mandava mensagem de verdade para o celular do
        dono — dezenas em poucos minutos, todas sobre uma máquina que não
        existe.

        Teste com efeito colateral no mundo é pior que teste nenhum: ele treina
        a pessoa a ignorar o canal, que é o oposto do que um canal de aviso
        precisa.

        E a guarda não é só contra teste. Um relatório cujo host não é esta
        máquina veio de fixture ou de dado de outra máquina; nos dois casos,
        disparar alerta no telefone daqui afirma algo que não foi medido aqui.
    #>
    $daquiMesmo = [string]$env:COMPUTERNAME
    if (-not [string]::IsNullOrWhiteSpace([string]$Report.host) -and
        ([string]$Report.host) -ne $daquiMesmo) {
        return @{ ok = $false; detail = "relatório é de '$($Report.host)', não desta máquina ($daquiMesmo): não enviado" }
    }

    <#
        A MENSAGEM, montada do mais importante para o menos.

        Quem lê isto está no celular, provavelmente andando. A primeira linha
        precisa responder "preciso levantar agora?" sozinha.
    #>
    $linhas = New-Object System.Collections.ArrayList
    [void]$linhas.Add(("WinMonitor - {0} - {1}" -f $Report.host, $Report.window))

    $veredito = [string]$Report.verdict
    $achados  = @($Report.findings | Where-Object { $_ })

    [void]$linhas.Add(("Veredito: {0}   Achados: {1}" -f $veredito.ToUpperInvariant(), $achados.Count))

    <#
        A COLETA VEM ANTES DO VEREDITO EM IMPORTÂNCIA, e por isso vem logo aqui:
        um veredito 'normal' sobre coleta parada não é notícia boa, é ausência
        de notícia. O relatório em texto já põe isso no topo pelo mesmo motivo.
    #>
    if ($Report.health -and $Report.health.ok -ne $true) {
        [void]$linhas.Add(("COLETA: {0}" -f [string]$Report.health.reason))
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Report.notifyReason)) {
        [void]$linhas.Add(("Motivo do aviso: {0}" -f [string]$Report.notifyReason))
    }

    if ($achados.Count -gt 0) {
        [void]$linhas.Add('')
        foreach ($a in $achados) {
            [void]$linhas.Add(("- [{0}] {1}" -f [string]$a.severity, [string]$a.claim))
        }
    }

    <#
        A COBERTURA SAI SEMPRE, inclusive quando não há achado. "Nenhum achado"
        sem a ressalva do que não foi medido é a frase que este projeto inteiro
        existe para não dizer.
    #>
    if ($Report.coverage -and $Report.coverage.complete -ne $true) {
        [void]$linhas.Add('')
        [void]$linhas.Add('Cobertura INCOMPLETA: ha regra que nao pode ser verificada. Veja o relatorio completo.')
    }

    $corpo = ($linhas -join "`n")

    <#
        CORTE DECLARADO. Se a mensagem passar do teto do Telegram, ela é cortada
        e o corte é DITO — meia frase entregue como se fosse a mensagem inteira
        é a mesma família de defeito que ausência virando zero.
    #>
    if ($corpo.Length -gt $LIMITE_TELEGRAM) {
        $aviso = "`n[...] mensagem cortada no limite do Telegram; o relatorio completo esta em data\report"
        $corpo = $corpo.Substring(0, $LIMITE_TELEGRAM - $aviso.Length) + $aviso
    }

    <#
        MENSAGEM IGUAL À ANTERIOR NÃO É REENVIADA — salvo quando há erro.

        Repetir a mesma frase todo dia treina a pessoa a ignorar o canal, e um
        canal de aviso ignorado é pior que canal nenhum: ele dá a impressão de
        cobertura que não existe. O dono desta máquina pediu isso depois de
        receber onze mensagens idênticas.

        A EXCEÇÃO IMPORTA MAIS QUE A REGRA. Quando há achado, ou quando a coleta
        não está saudável, a mensagem SAI mesmo idêntica à anterior: "o disco
        continua doente" é notícia todo dia que continuar, e silenciar por
        repetição seria exatamente a ausência-virando-boa-notícia que este
        projeto inteiro recusa.

        A comparação é do CORPO da mensagem, não do dia: se o texto mudou, algo
        que interessa mudou.
    #>
    $temErro = (@($Report.findings | Where-Object { $_ }).Count -gt 0) -or
               ($Report.health -and $Report.health.ok -ne $true)

    $arqUltimo = Join-Path (Split-Path -Parent $arqCfg) 'winmonitor-telegram-ultimo.txt'
    if (-not $temErro) {
        $anterior = ''
        try { $anterior = [string](Get-Content -LiteralPath $arqUltimo -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) } catch { }
        if (([string]$anterior).Trim() -ceq ([string]$corpo).Trim()) {
            return @{ ok = $true; detail = 'idêntica à anterior e sem erro: não reenviada' }
        }
    }

    $url = "https://api.telegram.org/bot{0}/sendMessage" -f $cfgBot.token
    $payload = @{ chat_id = [string]$cfgBot.chatId; text = $corpo; disable_web_page_preview = $true }

    $resp = if ($Transporte) { & $Transporte $url $payload }
            else {
                Invoke-RestMethod -Uri $url -Method Post -TimeoutSec 20 `
                    -ContentType 'application/json; charset=utf-8' `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress)))
            }

    <#
        O TELEGRAM RESPONDE 200 COM ok=false. Tratar "houve resposta" como
        "entregou" faria o driver avançar o estado do dia e nunca mais tentar —
        o aviso sumiria com o sistema achando que avisou.
    #>
    if ($resp -and $resp.ok -eq $true) {
        <#
            O CORPO ENVIADO SÓ É GRAVADO DEPOIS DE O TELEGRAM CONFIRMAR.

            Gravar antes faria uma tentativa recusada silenciar a PRÓXIMA por
            "já mandei isso" — o aviso sumiria duas vezes: uma pela recusa e
            outra pela deduplicação baseada num envio que nunca aconteceu.
        #>
        try { [System.IO.File]::WriteAllText($arqUltimo, $corpo, (New-Object System.Text.UTF8Encoding($false))) } catch { }
        return @{ ok = $true; detail = "enviado ao chat $($cfgBot.chatId) ($($corpo.Length) caracteres)" }
    }

    $porque = if ($resp -and $resp.description) { [string]$resp.description } else { 'resposta sem ok=true' }
    return @{ ok = $false; detail = "o Telegram recusou: $porque" }

} catch {
    @{ ok = $false; detail = "falhou ao enviar: $($_.Exception.Message)" }
}
