#requires -Version 5.1
<#
    Contadores finos de confiabilidade de disco — o degrau acima do veredito
    grosso que Probe-DiskHealth já cobre.

    O QUE ELE ACRESCENTA, E POR QUE ISSO IMPORTA
    --------------------------------------------
    'HealthStatus = Healthy' é o Windows dizendo que ainda não desistiu do
    disco. Um disco que começou a realocar setores continua Healthy por um bom
    tempo — e é exatamente nesse tempo que dá para agir. Os contadores de
    confiabilidade mostram o degrau de baixo: temperatura, horas ligado, erros
    de leitura e desgaste.

    ELE EXIGE ELEVAÇÃO, e isso é o motivo de ele não ter existido antes.
    Get-StorageReliabilityCounter devolve acesso negado em sessão comum —
    medido, item por item, na F3. Desde que a ronda passou a rodar com
    RunLevel HighestAvailable, os contadores respondem.

    O QUE A MÁQUINA REAL ENTREGOU, e o que isso obrigou no desenho
    --------------------------------------------------------------
    Medido nesta máquina, com elevação, três discos:

        disco 0: temp=38  horas=13006  erros=0     desgaste=0
        disco 2: temp=35  horas=4053   erros=0     desgaste=0
        disco 1: temp=50  horas=VAZIO  erros=VAZIO desgaste=0

    O disco 1 responde temperatura e NÃO responde horas nem erros de leitura. Se
    esta sonda somasse campos, aquele vazio viraria zero — e "zero erro de
    leitura" é a leitura mais tranquilizadora possível para um disco que NÃO
    INFORMOU erro de leitura. E ele é o mais quente dos três.

    Por isso a ausência aqui é POR CAMPO, não por disco: cada disco declara
    quais campos ficaram sem resposta, e nenhum campo ausente vira número.

    E A COBERTURA DA PREVISÃO DE FALHA É PARCIAL
    --------------------------------------------
    MSStorageDriver_FailurePredictStatus respondeu por UM dos três discos.
    Um resumo honesto disso não é "nenhum disco prevê falha" — é "um disco não
    prevê falha, e dois não têm previsão nenhuma". Cobertura parcial com cara de
    cobertura total é o defeito que este projeto inteiro existe para não ter,
    então a contagem de cobertos e de descobertos sai declarada.

    O QUE ELE NÃO COBRE, dito em vez de negado
    ------------------------------------------
    Contagem de setores realocados: a classe MSStorageDriver_FailurePredictData
    devolve os 512 bytes crus do fabricante, e decodificar atributo SMART por
    fabricante sem tabela publicada seria inventar número. Fica como lacuna
    declarada até haver fonte a citar.

      .\src\probes\Probe-SmartDetail.ps1
#>
[CmdletBinding()]
param(
    [object]$Facts,
    [int]$TimeoutSec,
    [int]$WindowDays,
    <#
        Costuras de injeção, para os ramos serem alcançáveis por teste. Nenhuma
        é usada em produção.

        Os nomes locais NUNCA repetem estes com outra caixa: '$discos' e o
        parâmetro '$Discos' são A MESMA variável em PowerShell, e essa armadilha
        já mordeu este projeto três vezes. tools\Find-ParamShadow.ps1 varre isso
        mecanicamente a cada portão.
    #>
    [object[]]$Discos,
    [object[]]$Contadores,
    [object[]]$Previsao,
    [switch]$Falhar,
    <#
        -FalharContadores e SEPARADO de -Falhar, e a separacao e o ponto.

        -Falhar estoura no Get-PhysicalDisk, que funciona SEM elevacao. O
        caminho que esta maquina de fato percorre em sessao comum e o outro: os
        discos sao lidos, e o Get-StorageReliabilityCounter e que devolve acesso
        negado. Medido agora, sem elevacao:

            readable=False  reason="Get-StorageReliabilityCounter falhou
                                    (exige elevacao): ..."

        Test-Exam afirmava que -Falhar percorria esse caminho. Nao percorria: o
        catch dos contadores nunca executou sob teste nenhum, e um mutante que
        trocava ok=$true por ok=$false ali sobrevivia as nove suites - em
        producao, essa troca muda o exame de "sonda com ressalva e dados nulos
        declarados" para "sonda falhou", que e exatamente a distincao que esta
        sonda existe para fazer.
    #>
    [switch]$FalharContadores
)

$null = $Facts, $TimeoutSec, $WindowDays

<#
    Converte um campo de contador em número OU em nulo declarado.

    Nunca devolve zero por ausência: string vazia, $null e valor não numérico
    viram $null, e quem chama registra o campo como não respondido. É a mesma
    regra de ConvertTo-WMNumber no armazém, e a mesma razão.
#>
function ConvertTo-WMContador {
    param($Valor)
    if ($null -eq $Valor) { return $null }
    $texto = [string]$Valor
    if ([string]::IsNullOrWhiteSpace($texto)) { return $null }
    $saida = 0.0
    $estilo = [System.Globalization.NumberStyles]::Float
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if (-not [double]::TryParse($texto, $estilo, $inv, [ref]$saida)) { return $null }
    if ([double]::IsNaN($saida) -or [double]::IsInfinity($saida)) { return $null }
    return $saida
}

try {
    $lidosDiscos = $null
    try {
        if ($Falhar) { throw 'falha de leitura forçada pelo teste' }
        $lidosDiscos = if ($PSBoundParameters.ContainsKey('Discos')) { @($Discos) }
                       else { @(Get-PhysicalDisk -ErrorAction Stop) }
    } catch {
        return @{ ok = $true; reason = "Get-PhysicalDisk falhou: $($_.Exception.Message)"; data = [ordered]@{
            readable          = $false
            disks             = $null
            hottestC          = $null
            hottestOf         = $null
            readErrorsMax     = $null
            readErrorsOf      = $null
            disksTotal        = $null
            predictEntries    = $null
            predictTotal      = $null
            predictFailing    = $null
            predictUnknown    = $null
        } }
    }

    if (@($lidosDiscos).Count -eq 0) {
        return @{ ok = $true; reason = 'Get-PhysicalDisk respondeu sem nenhum disco: não há contador de coisa nenhuma'; data = [ordered]@{
            readable          = $false
            disks             = $null
            hottestC          = $null
            hottestOf         = $null
            readErrorsMax     = $null
            readErrorsOf      = $null
            disksTotal        = $null
            predictEntries    = $null
            predictTotal      = $null
            predictFailing    = $null
            predictUnknown    = $null
        } }
    }

    <#
        OS CONTADORES SÃO O QUE EXIGE ELEVAÇÃO. Sem ela, Get-StorageReliabilityCounter
        devolve acesso negado — e o desfecho é 'readable = $false' com o motivo,
        NUNCA uma lista de zeros. Não conseguir medir não é medir zero.
    #>
    $lidosContadores = $null
    try {
        if ($FalharContadores) { throw 'Acesso a um recurso CIM nao estava disponivel para o cliente.' }
        $lidosContadores = if ($PSBoundParameters.ContainsKey('Contadores')) { @($Contadores) }
                           else { @($lidosDiscos | Get-StorageReliabilityCounter -ErrorAction Stop) }
    } catch {
        return @{ ok = $true; reason = "Get-StorageReliabilityCounter falhou (exige elevação): $($_.Exception.Message)"; data = [ordered]@{
            readable          = $false
            disks             = $null
            hottestC          = $null
            hottestOf         = $null
            readErrorsMax     = $null
            readErrorsOf      = $null
            disksTotal        = $null
            predictEntries    = $null
            predictTotal      = $null
            predictFailing    = $null
            predictUnknown    = $null
        } }
    }

    <#
        A PREVISÃO DE FALHA É OPCIONAL E PARCIAL, e falhar nela não pode derrubar
        os contadores: são duas fontes independentes, e perder uma não é perder
        as duas. Quando ela falha, a cobertura sai NULA e os contadores seguem.
    #>
    $lidosPrevisao = $null
    $previsaoLegivel = $true
    try {
        $lidosPrevisao = if ($PSBoundParameters.ContainsKey('Previsao')) { @($Previsao) }
                         else { @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSStorageDriver_FailurePredictStatus' -ErrorAction Stop) }
    } catch {
        $previsaoLegivel = $false
        $lidosPrevisao = $null
    }

    $lista = New-Object System.Collections.ArrayList
    $maisQuente = $null
    $maiorErro  = $null

    <#
        Os contadores vêm numa lista própria, e casá-los com os discos por
        POSIÇÃO seria errado: se um disco não devolve contador, todos os
        seguintes deslizam e cada número passa a descrever o disco errado.

        O casamento é por DeviceId, e o disco sem contador fica com todos os
        campos nulos e a razão registrada — em vez de herdar os números do
        vizinho.
    #>
    $porId = @{}
    foreach ($c in @($lidosContadores)) {
        if ($null -eq $c) { continue }
        $id = [string]$c.DeviceId
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $porId[$id] = $c
    }

    foreach ($d in $lidosDiscos) {
        $id = [string]$d.DeviceId
        $c  = if ($porId.ContainsKey($id)) { $porId[$id] } else { $null }

        $temp   = if ($c) { ConvertTo-WMContador $c.Temperature }      else { $null }
        $horas  = if ($c) { ConvertTo-WMContador $c.PowerOnHours }     else { $null }
        $erros  = if ($c) { ConvertTo-WMContador $c.ReadErrorsTotal }  else { $null }
        $uso    = if ($c) { ConvertTo-WMContador $c.Wear }             else { $null }

        <#
            AUSÊNCIA POR CAMPO. Medido nesta máquina: um dos três discos
            responde temperatura e não responde horas nem erros de leitura.
            Somar campos faria aquele vazio virar zero, e "zero erro de leitura"
            é a leitura mais tranquilizadora possível para um disco que não
            informou erro de leitura nenhum.
        #>
        $semResposta = New-Object System.Collections.ArrayList
        if ($null -eq $temp)  { [void]$semResposta.Add('temperatureC') }
        if ($null -eq $horas) { [void]$semResposta.Add('powerOnHours') }
        if ($null -eq $erros) { [void]$semResposta.Add('readErrorsTotal') }
        if ($null -eq $uso)   { [void]$semResposta.Add('wearPct') }

        if ($null -ne $temp -and ($null -eq $maisQuente -or $temp -gt $maisQuente)) { $maisQuente = $temp }
        if ($null -ne $erros -and ($null -eq $maiorErro -or $erros -gt $maiorErro)) { $maiorErro = $erros }

        [void]$lista.Add([ordered]@{
            id              = $id
            name            = [string]$d.FriendlyName
            temperatureC    = $temp
            powerOnHours    = $horas
            readErrorsTotal = $erros
            wearPct         = $uso
            unanswered      = @($semResposta)
        })
    }

    <#
        COBERTURA DA PREVISÃO, declarada em vez de resumida.

        Nesta máquina a classe responde por UM dos três discos. "Nenhum disco
        prevê falha" seria verdade sobre o disco coberto e silêncio sobre os
        outros dois. Sai a contagem dos dois lados.
    #>
    <#
        A PREVISÃO É CONTAGEM DE LINHAS, E O NOME DIZ ISSO.

        MSStorageDriver_FailurePredictStatus devolve InstanceName no formato do
        driver de armazenamento, que não casa com o DeviceId de Get-PhysicalDisk
        sem uma tabela de tradução que este projeto não tem. Casar por posição
        seria o erro que o casamento por DeviceId dos contadores existe para
        evitar — então aqui NÃO se casa, e o campo se chama 'predictEntries',
        não 'predictCovered'.

        A versão anterior chamava de 'cobertos' e comparava com o número de
        discos. Medido pela décima terceira verificação: com 4 linhas para 2
        discos, saía 'covered=4, total=2' e a ressalva DESAPARECIA — cobertura
        parcial com cara de cobertura total, que é a frase que o cabeçalho deste
        arquivo usa para dizer o que ele não pode fazer. A comparação era
        '-lt', e ela só olhava um lado.

        Agora a ressalva sai nos DOIS lados: linhas de menos e linhas demais são
        as duas o mesmo fato — não dá para afirmar previsão disco a disco.
    #>
    $entradas = if ($previsaoLegivel) { @($lidosPrevisao).Count } else { $null }
    $qtdDiscos = @($lidosDiscos).Count

    <#
        PredictFailure é comparado como TEXTO, com -ceq.

        Medido: a string 'False' é VERDADEIRA em PowerShell, então testar o
        objeto por veracidade fazia um disco saudável contar como falha
        prevista; e uma linha SEM a propriedade contava como coberta e
        não-falhando. É a doutrina do BL-D3 — '-ceq e não -eq' — que valia para
        a saúde de disco e não tinha sido aplicada aqui.

        Linha que não traz a propriedade é INDETERMINADA, não saudável.
    #>
    $falhando = $null
    $indeterminadas = 0
    if ($previsaoLegivel) {
        $falhando = 0
        foreach ($pv in @($lidosPrevisao)) {
            if ($null -eq $pv -or $null -eq $pv.PredictFailure) { $indeterminadas++; continue }
            if ([string]$pv.PredictFailure -ceq 'True') { $falhando++ }
        }
    }

    $razao = if (-not $previsaoLegivel) {
        'contadores lidos, mas MSStorageDriver_FailurePredictStatus falhou: a previsão de falha por disco fica sem cobertura'
    } elseif ($null -ne $entradas -and $entradas -ne $qtdDiscos) {
        "previsão de falha devolveu $entradas linha(s) para $qtdDiscos disco(s), e InstanceName não casa com DeviceId: não há como afirmar previsão disco a disco"
    } elseif ($indeterminadas -gt 0) {
        "previsão de falha: $indeterminadas linha(s) sem o campo PredictFailure — indeterminado, não saudável"
    } else { $null }

    <#
        O RESUMO DO TOPO LAVAVA A AUSÊNCIA QUE A SONDA DECLARA POR DISCO.

        'readErrorsMax = 0' com os dados reais desta máquina é o máximo sobre
        DOIS de três discos — o terceiro não informa erro de leitura. Zero é a
        leitura mais tranquilizadora possível, e ela era afirmada sem dizer
        sobre quantos discos.

        A ausência por campo estava certa na lista; o resumo a descartava. Agora
        cada agregado vem com quantos discos de fato responderam aquele campo, e
        uma regra que leia o máximo pode exigir a cobertura junto.
    #>
    $respTemp  = @(@($lista) | Where-Object { $null -ne $_.temperatureC }).Count
    $respErros = @(@($lista) | Where-Object { $null -ne $_.readErrorsTotal }).Count

    @{
        ok     = $true
        reason = $razao
        data   = [ordered]@{
            readable          = $true
            disks             = @($lista)
            hottestC          = $maisQuente
            hottestOf         = $respTemp
            readErrorsMax     = $maiorErro
            readErrorsOf      = $respErros
            disksTotal        = $qtdDiscos
            predictEntries    = $entradas
            predictTotal      = $qtdDiscos
            predictFailing    = $falhando
            predictUnknown    = $(if ($previsaoLegivel) { $indeterminadas } else { $null })
        }
    }

} catch {
    @{ ok = $false; reason = $_.Exception.Message }
}
