#requires -Version 5.1
<#
    Testes do exame: a sonda de eventos e o driver.

    A pergunta central desta suíte é uma só, e é a mesma que decide se o projeto
    inteiro vale alguma coisa: **quando a sonda não consegue olhar, ela diz que
    não conseguiu, ou diz que está tudo bem?**

    Get-WinEvent torna isso difícil de propósito, sem querer: devolve o mesmo
    erro (NoMatchingEventsFound) para "não há evento" e para "não pude ler o
    log". Um try/catch ingênuo transforma privilégio insuficiente em atestado de
    saúde de hardware.

    O teste usa o log 'Security', que numa sessão sem elevação é ilegível DE
    VERDADE nesta máquina. Não é dublê: é a condição real, e por isso o teste
    prova alguma coisa.

      .\tests\Test-Exam.ps1
#>
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TestKit.ps1')

Import-Module (Join-Path $root 'src\WinMonitor.psm1') -Force

$sonda = Join-Path $root 'src\probes\Probe-Events.ps1'

function Test-Elevada {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

try {

    # =====================================================================
    Start-TestGroup 'Sonda de eventos: o log legível'

    $r = & $sonda -WindowDays 30
    Assert-True $r.ok 'a sonda roda contra o log System'
    Assert-True ($r.data.logReadable -eq $true) 'e declara o log como legível'
    Assert-True ($r.data.wheaErrors -is [int]) 'com o log legível, a contagem WHEA é um número'
    Assert-True ($r.data.cleanShutdowns -is [int]) 'e a de desligamentos limpos também'
    Assert-True ($null -ne $r.data.since) 'a janela examinada é declarada'
    Assert-True ($r.data.since -match '^\d{4}-\d{2}-\d{2}T') 'em formato invariante'

    <#
        A JANELA IMPORTA. Uma contagem sem período é um número sem significado:
        "um desligamento inesperado" em 30 dias e em 3 anos são diagnósticos
        diferentes. Se a janela encolhe, a contagem não pode crescer.
    #>
    $curto = & $sonda -WindowDays 1
    $longo = & $sonda -WindowDays 365
    Assert-True ($curto.data.cleanShutdowns -le $longo.data.cleanShutdowns) 'janela menor nunca conta mais que a maior'

    # =====================================================================
    Start-TestGroup 'Sonda de eventos: o log ILEGÍVEL  [o teste que importa]'

    if (Test-Elevada) {
        Add-TestResult -Ok $true -Name 'sessão elevada: o log Security é legível, teste não aplicável' -Detail ''
    } else {
        $s = & $sonda -LogName 'Security' -WindowDays 30

        Assert-True $s.ok 'a sonda NÃO explode com log inacessível'
        Assert-True ($s.data.logReadable -eq $false) 'ela declara o log como ilegível'

        <#
            O CORAÇÃO DE TUDO. Zero seria uma afirmação: "não houve erro de
            hardware". Nulo é a verdade: "não sei se houve". As duas coisas
            entram na regra de formas completamente diferentes — zero satisfaz
            'wheaErrors gt 0' como falso e vira laudo de máquina sã.
        #>
        Assert-True ($null -eq $s.data.wheaErrors) 'wheaErrors é NULO, não zero'
        Assert-True ($null -eq $s.data.unexpectedShutdowns) 'unexpectedShutdowns é NULO, não zero'
        Assert-True ($null -eq $s.data.cleanShutdowns) 'cleanShutdowns é NULO, não zero'
        Assert-True (-not [string]::IsNullOrWhiteSpace($s.reason)) 'e o motivo fica registrado'
        Assert-True ($s.reason -match 'privil|Security') 'dizendo qual log e por quê'

        <#
            MUTAÇÃO: trocar os nulos por 0 nesta sonda faz o bloco acima ficar
            vermelho e NADA MAIS no projeto reclamar — a regra passaria, o
            veredito sairia 'normal', o laudo diria que não há erro de hardware,
            e as quatro conferências do laudo aprovariam, porque o zero veio
            mesmo do pacote. Esta é a única linha de defesa contra esse caminho.
        #>
        Assert-True ($s.data.wheaErrors -isnot [int]) 'e não é um inteiro disfarçado de ausência'
    }

    # =====================================================================
    Start-TestGroup 'Invoke-Exam: sonda ausente vira lacuna, nunca silêncio'

    $ex = & (Join-Path $root 'src\Invoke-Exam.ps1') -PassThru -NoWrite

    Assert-True ($null -ne $ex) 'o exame roda'
    Assert-True ($null -ne $ex.evt) 'e traz o bloco de eventos'
    Assert-True ($ex.complete -eq $false) 'e se declara INCOMPLETO enquanto faltar sonda'

    <#
        -PassThru devolve o objeto ANTES de passar por JSON, e aí coverage ainda
        é um dicionário ordenado, não um PSCustomObject: PSObject.Properties não
        enxerga chave nenhuma. Depois de gravado e relido, é o contrário. O teste
        precisa ler os dois, senão passa a verificar o tipo em vez do conteúdo.
    #>
    $chaves = if ($ex.coverage -is [System.Collections.IDictionary]) { @($ex.coverage.Keys) }
              else { @($ex.coverage.PSObject.Properties.Name) }
    Assert-True ($chaves -contains 'smart')   'SMART consta como lacuna declarada'
    Assert-True ($chaves -contains 'cpuTemp') 'temperatura de CPU também'
    Assert-True (($ex.coverage['smart'] -match 'eleva') -or ($ex.coverage.smart -match 'eleva')) 'e a lacuna do SMART diz que falta elevação'

    <#
        O exame nunca inventa o bloco de uma sonda que não rodou. Um {} vazio
        seria lido por qualquer regra seguinte como "rodou e não achou nada".
    #>
    Assert-True ($null -eq $ex.smart) 'a sonda que não existe não deixa objeto vazio no lugar'

} finally { }

Show-TestSummary
exit (Get-TestExitCode)
