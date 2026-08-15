#requires -Version 5.1
<#
    Canal: arquivo local.

    Sempre disponível, sem credencial, sem rede, sem decisão a tomar. É o canal
    padrão porque um monitor precisa funcionar antes de estar configurado — e
    porque, se o canal remoto falhar, o relatório ainda existe em algum lugar
    onde dá para achá-lo depois.

    Grava dois arquivos: o do dia, que é o histórico, e ultimo.txt, que é onde
    se olha sem precisar saber a data de hoje.

    NÃO substitui um canal remoto. Um arquivo numa máquina que você não está
    olhando não notifica ninguém — ele só garante que o relatório não se perdeu.
#>
param(
    [Parameter(Mandatory)][string]$Text,
    [Parameter(Mandatory)]$Report,
    [Parameter(Mandatory)]$Config,
    $Secrets
)

try {
    $dir = Get-WMPath $Config.paths.report
    $dir = Confirm-WMDirectory $dir

    $enc = New-Object System.Text.UTF8Encoding($false)
    $doDia  = Join-Path $dir ("{0}.txt" -f $Report.window)
    $ultimo = Join-Path $dir 'ultimo.txt'

    [System.IO.File]::WriteAllText($doDia,  $Text, $enc)
    [System.IO.File]::WriteAllText($ultimo, $Text, $enc)

    @{ ok = $true; detail = "gravado em $doDia" }
} catch {
    @{ ok = $false; detail = "falhou ao gravar: $($_.Exception.Message)" }
}
