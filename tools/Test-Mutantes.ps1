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

    @{ id='BL-4a'; nome='o portão lê a saída com OEM';            arq='tests\Run-All.ps1'
       de='-Raw -Encoding OEM -ErrorAction SilentlyContinue'
       para='-Raw -Encoding UTF8 -ErrorAction SilentlyContinue'; suite='Test-Gate.ps1' }

    @{ id='BL-4b'; nome='recuo de exam.probes ausente';           arq='src\Invoke-Exam.ps1'
       de='$sondas = @($cfg.exam.probes | Where-Object { $_ -and $_.name -and $_.key })'
       para='$sondas = @($cfg.exam.probes)'; suite='Test-Exam.ps1' }

    @{ id='BL-4c'; nome='filtro de exam.missing';                 arq='src\Invoke-Exam.ps1'
       de='foreach ($p in @($cfg.exam.missing | Where-Object { $_ -and $_.key })) {'
       para='foreach ($p in @($cfg.exam.missing)) {'; suite='Test-Exam.ps1' }
)

if ($Somente) { $mutantes = @($mutantes | Where-Object { $_.id -like "*$Somente*" }) }
if ($mutantes.Count -eq 0) { Write-Error "nenhum mutante casa '$Somente'"; exit 2 }

$vivos    = New-Object System.Collections.ArrayList
$naoAplic = New-Object System.Collections.ArrayList

foreach ($m in $mutantes) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wm-mut-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        foreach ($d in 'src', 'config', 'tests') {
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

        if ($linha -match ',\s*0\s+falhou') {
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
if ($vivos.Count -eq 0 -and $naoAplic.Count -eq 0) {
    "TODOS OS $($mutantes.Count) MUTANTES MORRERAM — cada trava tem quem a defenda."
    exit 0
}
foreach ($v in $vivos)    { "  x $v" }
foreach ($n in $naoAplic) { "  x $n" }
"$($vivos.Count) trava(s) indefesa(s), $($naoAplic.Count) âncora(s) obsoleta(s)"
exit 1
