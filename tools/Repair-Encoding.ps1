#requires -Version 5.1
<#
    Normaliza a codificação dos arquivos do projeto.

      .ps1 .psm1 .psd1  ->  UTF-8 COM BOM
      todo o resto      ->  UTF-8 SEM BOM

    Os dois lados importam, por motivos opostos.

    COM BOM nos scripts: o Windows PowerShell 5.1 só interpreta um .ps1 como
    UTF-8 se houver BOM; sem BOM ele assume a página de código ANSI do sistema.
    Num projeto com mensagens em português isso corrompe silenciosamente todo
    texto acentuado que chega ao usuário, e a corrupção entra no histórico
    gravado. O PowerShell 7 lê os dois casos, então o BOM não custa nada.

    SEM BOM no resto: BOM em .gitignore pode fazer o git ignorar a primeira
    regra do arquivo; em .json pode quebrar o ConvertFrom-Json, que recebe o
    U+FEFF como primeiro caractere.

    Rode depois de criar ou editar qualquer arquivo do projeto.
#>
[CmdletBinding()]
param([switch]$WhatIfOnly)

$root       = Split-Path -Parent $PSScriptRoot
$withBom    = New-Object System.Text.UTF8Encoding($true)
$withoutBom = New-Object System.Text.UTF8Encoding($false)

$SCRIPT_EXT = @('.ps1', '.psm1', '.psd1')
$SKIP_DIRS  = '\\(data|logs|vendor|\.git)\\'

$checked = 0
$fixed   = 0

Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object { $_.FullName -notmatch $SKIP_DIRS } |
    ForEach-Object {
        $file      = $_
        $wantsBom  = $SCRIPT_EXT -contains $file.Extension.ToLower()
        $checked++

        $bytes  = [System.IO.File]::ReadAllBytes($file.FullName)
        $hasBom = $bytes.Length -ge 3 -and
                  $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF

        if ($hasBom -eq $wantsBom) { return }

        $rel = $file.FullName.Substring($root.Length + 1)

        if ($wantsBom) {
            $text   = [System.Text.Encoding]::UTF8.GetString($bytes)
            $target = $withBom
            $what   = 'BOM adicionado'
        } else {
            # Descarta os três bytes do BOM antes de decodificar.
            $text   = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
            $target = $withoutBom
            $what   = 'BOM removido '
        }

        if ($WhatIfOnly) {
            "{0}  {1}" -f $what, $rel
        } else {
            [System.IO.File]::WriteAllText($file.FullName, $text, $target)
            "{0}  {1}" -f $what, $rel
        }
        $fixed++
    }

""
"{0} arquivo(s) verificado(s), {1} ajustado(s)." -f $checked, $fixed
