#requires -Version 5.1
<#
    Varre os blocos param() procurando variável local que colide com um
    parâmetro APENAS NA CAIXA.

    POR QUE ISTO EXISTE, E POR QUE É DIFERENTE DAS OUTRAS TRAVAS
    ------------------------------------------------------------
    Nomes de variável em PowerShell são insensíveis a caixa. Então isto:

        param([int]$WindowDays)
        $windowDays = @(...)          # É A MESMA VARIÁVEL

    não é sombra: é sobrescrita, e ela não avisa. O código roda, o parâmetro
    some, e o teste passa a medir o caminho errado.

    Esta armadilha mordeu o projeto TRÊS vezes:

        F2   $windowDays  colidindo com  [int]$WindowDays   (matou New-Baseline)
        F5   $Suites      colidindo com  [string]$Suites    (portão sem suíte)
        F3   $discos      colidindo com  $Discos            (teste media o caminho feliz)

    A terceira aconteceu com a armadilha JÁ DOCUMENTADA no repositório, num
    arquivo novo, na mesma sessão que citava as duas anteriores. É a evidência
    de que documentar armadilha não previne armadilha — e de que a defesa
    precisa ser mecânica, não editorial.

    O QUE ELA NÃO PEGA, dito em vez de negado
    -----------------------------------------
    Só colisão com CAIXA DIFERENTE. '$Discos = $null' sobrescrevendo '$Discos'
    é reatribuição legítima e indistinguível de um erro. As três ocorrências
    reais foram todas de caixa diferente, que é a forma natural de cair nela:
    a pessoa digita a local em minúsculas.

    E A ARMADILHA PEGOU A TRAVA CONTRA A ARMADILHA
    ----------------------------------------------
    A primeira versão desta ferramenta descartava as colisões assim:

        if ($nomeV -eq $nomeP) { continue }   # "grafia idêntica: legítimo"

    Ela nasceu MORTA. '-eq' é insensível a caixa, então 'discos' -eq 'Discos' é
    verdadeiro e a linha descartava exatamente o que procurava. Rodada contra as
    duas sabotagens históricas: limpo, código 0.

    Por isso a comparação usa -ceq, e por isso existe um mutante que a reverte:
    a diferença entre esta trava e as que esta série vem consertando não é quem
    a escreveu — é que ela foi atacada antes de ser declarada pronta.

      .\tools\Find-ParamShadow.ps1
      .\tools\Find-ParamShadow.ps1 -Caminho src\probes
#>
[CmdletBinding()]
param(
    [string]$Caminho,
    [switch]$Quiet
)

$raiz = Split-Path -Parent $PSScriptRoot
$alvo = if ($Caminho) {
    if ([System.IO.Path]::IsPathRooted($Caminho)) { $Caminho } else { Join-Path $raiz $Caminho }
} else { $raiz }

$arquivos = @(
    Get-ChildItem -LiteralPath $alvo -Recurse -File -Include '*.ps1', '*.psm1' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(data|logs|\.git)\\' }
)

$colisoes = New-Object System.Collections.ArrayList

foreach ($arq in $arquivos) {
    $erros = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($arq.FullName, [ref]$null, [ref]$erros)
    if ($null -eq $ast) { continue }

    <#
        Cada bloco param() com o corpo que o acompanha: o do script inteiro e o
        de cada função. Uma colisão só importa dentro do escopo onde as duas
        vivem.
    #>
    $funcoes = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))

    $escopos = New-Object System.Collections.ArrayList
    if ($ast.ParamBlock) { [void]$escopos.Add(@{ nome = '<script>'; param = $ast.ParamBlock; corpo = $ast; foraDeFuncao = $true }) }

    foreach ($f in $funcoes) {
        $pb = if ($f.Body -and $f.Body.ParamBlock) { $f.Body.ParamBlock } else { $null }
        if ($pb) { [void]$escopos.Add(@{ nome = $f.Name; param = $pb; corpo = $f.Body; foraDeFuncao = $false }) }
    }

    foreach ($e in $escopos) {
        $nomesParam = @($e.param.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        if ($nomesParam.Count -eq 0) { continue }

        foreach ($v in $e.corpo.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            <#
                O ESCOPO DO SCRIPT PARA NA PORTA DAS FUNÇÕES.

                O corpo do escopo '<script>' é a AST inteira, e ela contém os
                corpos das funções. Sem este recuo, uma função com '$discos = 1'
                dentro de um script cujo param() tem '$Discos' era acusada — e
                atribuir dentro de função cria variável NOVA no escopo dela, não
                apaga o parâmetro do script. É falso positivo.

                E falso positivo é o outro jeito de uma varredura morrer: não
                pela trava desligada, mas pelo relatório que ninguém mais lê.
            #>
            if ($e.foraDeFuncao) {
                $dentroDeFuncao = $false
                foreach ($fn in $funcoes) {
                    if ($v.Extent.StartOffset -ge $fn.Extent.StartOffset -and
                        $v.Extent.EndOffset   -le $fn.Extent.EndOffset) { $dentroDeFuncao = $true; break }
                }
                if ($dentroDeFuncao) { continue }
            }

            $nomeV = $v.VariablePath.UserPath
            foreach ($nomeP in $nomesParam) {
                <#
                    -ine e -ceq, NUNCA -eq: o operador insensível a caixa
                    considera 'discos' igual a 'Discos', e a condição inteira
                    passa a descartar a única coisa que ela procura. Foi assim
                    que a primeira versão desta ferramenta nasceu morta.
                #>
                if (($nomeV -ine $nomeP)) { continue }
                if (($nomeV -ceq $nomeP)) { continue }

                [void]$colisoes.Add([pscustomobject]@{
                    arquivo   = $arq.FullName.Substring($raiz.Length).TrimStart('\')
                    linha     = $v.Extent.StartLineNumber
                    escopo    = $e.nome
                    local     = $nomeV
                    parametro = $nomeP
                })
            }
        }
    }
}

$unicas = @($colisoes | Sort-Object arquivo, linha, local -Unique)

if ($unicas.Count -eq 0) {
    if (-not $Quiet) { "nenhuma colisão de caixa entre variável local e parâmetro ($($arquivos.Count) arquivo(s))" }
    exit 0
}

foreach ($c in $unicas) {
    "  x {0}:{1}  {2}: `${3} colide com o parâmetro `${4}" -f $c.arquivo, $c.linha, $c.escopo, $c.local, $c.parametro
}
"$($unicas.Count) colisão(ões) — em PowerShell essas são A MESMA variável, e a atribuição local apaga o parâmetro sem avisar"
exit 1
