#requires -Version 5.1
<#
    Testes de ponta a ponta de Invoke-Laudo.ps1.

    POR QUE ESTE ARQUIVO EXISTE
    ---------------------------
    A verificação adversarial mediu que NENHUMA suíte executava Invoke-Laudo.ps1.
    Toda a correção dos caminhos de falha do provedor — a que garante que o texto
    cru é gravado para perícia e que a reapresentação leva o motivo — estava sem
    rede: verificada à mão uma vez, indefesa contra a próxima edição.

    É o mesmo aprendizado que criou Test-Drivers.ps1: um script que nenhum teste
    executa é um script que nunca foi executado.

    O provedor é um DUBLÊ plantado em src\providers, escolhido por config. Assim
    o driver roda inteiro, de verdade, sem rede e sem chave.

      .\tests\Test-LaudoDriver.ps1
#>
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TestKit.ps1')

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wm-lau-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$enc = New-Object System.Text.UTF8Encoding($false)
$dia = '2026-08-15'

$ACHADOS = '{"v":1,"window":"2026-08-15","host":"T","verdict":"agir","findings":[{"id":"R-DISK-SPACE-LOW#sto.volFreeGB.C:.min","ruleId":"R-DISK-SPACE-LOW","severity":"agir","subsystem":"sto","claim":"O volume ficou com pouco espaco livre","evidence":[{"metric":"sto.volFreeGB.C:.min","value":3,"from":"agregado"}],"rule":{"kind":"absolute","operator":"lt","threshold":20,"source":{"kind":"policy","text":"folga"}}}],"coverage":{"complete":false,"evaluated":["R-DISK-SPACE-LOW"],"unsourced":{"R-CPU-TEMP-SPEC":"pendente"},"malformed":{},"noData":{},"noBaseline":{},"notApplicable":{}}}'

$projSeq = 0
function New-Proj {
    param([string]$ProviderBody)
    $script:projSeq++
    $p = Join-Path $tmp ("p{0}" -f $script:projSeq)
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'src')    -Destination $p -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $root 'config') -Destination $p -Recurse -Force
    New-Item -ItemType Directory -Path (Join-Path $p 'data\findings') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $p "data\findings\$dia.json"), $ACHADOS, $enc)
    [System.IO.File]::WriteAllText((Join-Path $p 'src\providers\Provider-Duble.ps1'), $ProviderBody, $enc)

    $cfgP = Join-Path $p 'config\config.json'
    $c = Get-Content $cfgP -Raw -Encoding UTF8 | ConvertFrom-Json
    $c.laudo.provider = 'Duble'
    [System.IO.File]::WriteAllText($cfgP, (ConvertTo-Json -InputObject $c -Depth 14), $enc)
    $p
}

function Read-Laudo { param([string]$Proj) Get-Content (Join-Path $Proj "data\laudo\$dia.json") -Raw -Encoding UTF8 | ConvertFrom-Json }

# Cabeçalho comum: registra o pacote recebido, para provar que a reapresentação
# leva o motivo da rejeição.
$cab = @'
param($Package, $Config, $Secrets, $SystemPrompt, $Schema)
$n = 0
while (Test-Path (Join-Path $env:TEMP "wmdub.$n.json")) { $n++ }
ConvertTo-Json -InputObject $Package -Depth 14 | Set-Content -LiteralPath (Join-Path $env:TEMP "wmdub.$n.json") -Encoding UTF8

'@

<#
    O JSON do laudo vai para o dublê dentro de um here-string LITERAL.

    Escapar aspas dentro de string dupla do PowerShell produzia um corpo que não
    era JSON válido — e o teste então media o caminho de erro achando que media o
    de sucesso. Falso vermelho é tão ruim quanto falso verde: os dois ensinam a
    coisa errada sobre o código.
#>
function New-DubleBody {
    param([string]$Json)
    "@{ ok = `$true; text = @'`r`n$Json`r`n'@; model = 'duble' }`r`n"
}

function Clear-Dubles { Get-ChildItem $env:TEMP -Filter 'wmdub.*.json' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
function Get-Dubles   { @(Get-ChildItem $env:TEMP -Filter 'wmdub.*.json' -ErrorAction SilentlyContinue | Sort-Object Name) }

try {

    # =====================================================================
    Start-TestGroup 'Driver: provedor que FALHA  [MUTAÇÃO]'

    Clear-Dubles
    $p1 = New-Proj ($cab + "@{ ok = `$false; reason = 'sem chave de teste' }`r`n")
    $out = & (Join-Path $p1 'src\Invoke-Laudo.ps1') -Day $dia 2>&1 | Out-String
    $l1 = Read-Laudo $p1

    Assert-True ($l1.rejected -eq $true) 'provedor falho: o laudo é gravado como reprovado'
    Assert-Equal 2 (@($l1.attemptLog).Count) 'as DUAS tentativas ficam registradas'
    Assert-Equal 2 $l1.attempts 'e a contagem bate com o registro'
    Assert-True ($l1.attempts -is [int]) "'attempts' é número no reprovado, como já era no aprovado"
    Assert-True ((@($l1.violations) -join ' ') -match 'sem chave de teste') 'e o motivo do provedor aparece'
    Assert-True ($out -match 'REPROVADO') 'o driver diz que reprovou'
    Assert-True ($out -match 'pouco espaco livre') 'e mostra o achado CRU, que é verdade verificável'

    <#
        A REAPRESENTAÇÃO PRECISA LEVAR O MOTIVO. O 'continue' antigo pulava
        tanto o registro quanto a anexação de rejectedBecause, e a segunda
        tentativa ia idêntica à primeira — exatamente o "refaça" sozinho que o
        próprio driver afirma, num comentário, que não corrige nada.
    #>
    $recebidos = Get-Dubles
    Assert-Equal 2 $recebidos.Count 'o provedor foi chamado duas vezes'
    $seg = Get-Content $recebidos[1].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($seg.rejectedBecause).Count -gt 0) 'a 2a chamada recebeu o motivo da rejeição'

    # =====================================================================
    Start-TestGroup 'Driver: resposta que não é JSON  [MUTAÇÃO]'

    Clear-Dubles
    $p2 = New-Proj ($cab + "@{ ok = `$true; text = 'isto nao e json'; model = 'duble' }`r`n")
    & (Join-Path $p2 'src\Invoke-Laudo.ps1') -Day $dia 2>&1 | Out-Null
    $l2 = Read-Laudo $p2

    Assert-True ($l2.rejected -eq $true) 'resposta não-JSON: reprovado'
    Assert-Equal 2 (@($l2.attemptLog).Count) 'as duas tentativas registradas'
    Assert-True ((@($l2.attemptLog)[0].text) -match 'isto nao e json') 'o TEXTO CRU é preservado para perícia'
    $seg = Get-Content (Get-Dubles)[1].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($seg.rejectedBecause).Count -gt 0) 'e a 2a chamada recebeu o motivo'

    # =====================================================================
    Start-TestGroup 'Driver: provedor que EXPLODE  [MUTAÇÃO]'

    Clear-Dubles
    $p3 = New-Proj ($cab + "throw 'o provedor explodiu'`r`n")
    & (Join-Path $p3 'src\Invoke-Laudo.ps1') -Day $dia 2>&1 | Out-Null
    $l3 = Read-Laudo $p3

    Assert-True ($null -ne $l3) 'exceção no provedor NÃO mata o driver: o arquivo existe'
    Assert-True ($l3.rejected -eq $true) 'e está marcado como reprovado'
    Assert-True ((@($l3.violations) -join ' ') -match 'exceção|explodiu') 'com a exceção registrada'

    # =====================================================================
    Start-TestGroup 'Driver: laudo que APAGA o achado é reprovado  [MUTAÇÃO]'

    Clear-Dubles
    $apaga = '{"summary":"A maquina esta saudavel e nao ha nada a fazer.","findings":[],"notVerified":[{"ruleId":"R-CPU-TEMP-SPEC","note":"n"}],"changedSinceLast":"","observations":[]}'
    $p4 = New-Proj ($cab + (New-DubleBody $apaga))
    $out4 = & (Join-Path $p4 'src\Invoke-Laudo.ps1') -Day $dia 2>&1 | Out-String
    $l4 = Read-Laudo $p4

    Assert-True ($l4.rejected -eq $true) 'laudo que apaga o achado NÃO é apresentado'
    Assert-True ($out4 -match 'APAGOU') 'e o motivo diz que ele apagou'

    # =====================================================================
    Start-TestGroup 'Driver: laudo honesto é aceito e o veredito vem das regras'

    Clear-Dubles
    $bom = '{"summary":"O volume de sistema esta com pouco espaco.","findings":[{"ruleId":"R-DISK-SPACE-LOW","reading":"o volume ficou com 3 GB livres, abaixo dos 20 GB","action":"liberar espaco"}],"notVerified":[{"ruleId":"R-CPU-TEMP-SPEC","note":"sem fonte primaria"}],"changedSinceLast":"","observations":[]}'
    $p5 = New-Proj ($cab + (New-DubleBody $bom))
    $out5 = & (Join-Path $p5 'src\Invoke-Laudo.ps1') -Day $dia 2>&1 | Out-String
    $l5 = Read-Laudo $p5

    Assert-True ($l5.rejected -eq $false) 'laudo honesto passa'
    Assert-Equal 'agir' $l5.verdict 'e o veredito vem das REGRAS'
    Assert-Equal 1 $l5.attempts 'na primeira tentativa'

    <#
        A ORDEM DA SAÍDA É DEFESA: o veredito e os achados medidos aparecem ANTES
        da prosa do modelo. Uma frase sem número que negue o veredito não pode ser
        a primeira coisa que alguém lê.
    #>
    Assert-True ($out5.IndexOf('Achados medidos pelas regras') -lt $out5.IndexOf('Leitura do modelo')) 'o medido vem antes do escrito'
    Assert-True ($out5.IndexOf('Veredito') -lt $out5.IndexOf('Leitura do modelo')) 'e o veredito antes dos dois'

} finally {
    Clear-Dubles
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Show-TestSummary
exit (Get-TestExitCode)
