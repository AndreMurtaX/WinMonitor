#requires -Version 5.1
<#
    Varre os blocos param() procurando variável local que colide com um
    parâmetro APENAS NA CAIXA.

    POR QUE ISTO EXISTE
    -------------------
    Nomes de variável em PowerShell são insensíveis a caixa. Então isto:

        param([int]$WindowDays)
        $windowDays = @(...)          # É A MESMA VARIÁVEL

    não é sombra: é sobrescrita, e ela não avisa. O código roda, o parâmetro
    some, e o teste passa a medir o caminho errado.

    A armadilha mordeu o projeto TRÊS vezes — F2 ($windowDays), F5 ($Suites),
    F3 ($discos) — e a terceira aconteceu com ela JÁ DOCUMENTADA no repositório,
    na mesma sessão que citava as duas anteriores. Documentar armadilha não
    previne armadilha.

    A PRIMEIRA VERSÃO DESTA FERRAMENTA NASCEU MORTA
    -----------------------------------------------
    Ela descartava as colisões com 'if ($nomeV -eq $nomeP) { continue }'. '-eq'
    é insensível a caixa, então a linha descartava exatamente o que a ferramenta
    procurava. Rodada contra as duas sabotagens históricas: limpo, código 0.

    E A SEGUNDA VERSÃO FALHAVA ABERTA, E ERA CEGA PARA TRÊS FORMAS
    --------------------------------------------------------------
    Medido pela décima primeira verificação, cada linha executada:

      - Substring($raiz.Length) estourava com arquivo fora de $raiz. A exceção
        ia para stderr, a lista ficava vazia, e ela declarava "nenhuma colisão"
        com código 0 — HAVENDO colisão no arquivo. Falha aberta é pior que
        ausência de trava: ausência ninguém confia, falha aberta todo mundo.
      - '-Include' com '-LiteralPath -Recurse' é IGNORADO no PowerShell 5.1.
        Ela varria 46 arquivos num projeto de 39 scripts, incluindo README.md,
        LICENSE e os JSONs.
      - 'function F ($Discos) { $discos = $null }'  — parâmetro inline: cega.
      - '$script:discos = $null'                    — prefixo de escopo: cega.
      - '{ param($Discos) $discos = $null }'        — scriptblock: cega, e essa
        forma está EM USO na produção deste projeto, em quatro lugares.
      - E acusava função aninhada dentro de função com param(), que é legítima.

    O MODELO AGORA É DE ESCOPO, e é ele que resolve as cinco de uma vez: cada
    variável é atribuída ao escopo MAIS INTERNO que a contém, e comparada só
    com os parâmetros daquele escopo.

    O QUE ELA NÃO PEGA, dito em vez de negado
    -----------------------------------------
    Só colisão com CAIXA DIFERENTE. '$Discos = $null' sobrescrevendo '$Discos'
    é reatribuição legítima e indistinguível de um erro. As três ocorrências
    reais foram todas de caixa diferente, que é a forma natural de cair nela.

    E o escopo dinâmico do PowerShell tem casos que análise estática não decide:
    um scriptblock dot-sourced escreve no escopo de quem chama, não no dele.
    Aqui o scriptblock é tratado como escopo próprio, que é o caso comum e o que
    a produção usa. O caso dot-source fica DECLARADO, não coberto.

      .\tools\Find-ParamShadow.ps1
      .\tools\Find-ParamShadow.ps1 -Caminho src\probes
#>
[CmdletBinding()]
param(
    [string]$Caminho,
    [switch]$Quiet
)

$TIPO = [System.Management.Automation.Language.Parser]
$EXT  = @('.ps1', '.psm1', '.psd1')

$raiz = Split-Path -Parent $PSScriptRoot
$alvo = if ($Caminho) {
    if ([System.IO.Path]::IsPathRooted($Caminho)) { $Caminho } else { Join-Path $raiz $Caminho }
} else { $raiz }

<#
    FILTRO DE VERDADE, e não '-Include'.

    Com -LiteralPath e -Recurse o Get-ChildItem do 5.1 ignora -Include em
    silêncio — o filtro fica lá, com cara de defesa, sem filtrar nada. Este
    projeto tem doutrina escrita sobre isso ("código morto com cara de defesa é
    pior que defesa nenhuma") e a versão anterior desta ferramenta a violava.
#>
$arquivos = @(
    Get-ChildItem -LiteralPath $alvo -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $EXT -contains $_.Extension -and $_.FullName -notmatch '\\(data|logs|\.git)\\' }
)

$colisoes = New-Object System.Collections.ArrayList
$ilegiveis = New-Object System.Collections.ArrayList

<#
    Caminho relativo que não estoura. A versão anterior fazia
    Substring($raiz.Length) supondo que todo arquivo está sob $raiz — e com
    -Caminho absoluto fora do projeto a chamada lançava, a exceção sumia no
    stderr e a ferramenta declarava limpo.
#>
function Get-Relativo {
    param([string]$Completo, [string]$Base)
    if ($Completo.StartsWith($Base, [StringComparison]::OrdinalIgnoreCase)) {
        return $Completo.Substring($Base.Length).TrimStart('\')
    }
    return $Completo
}

foreach ($arq in $arquivos) {
    <#
        FALHA FECHADA, por arquivo.

        Qualquer arquivo que não possa ser lido ou analisado entra na lista de
        ilegíveis, e ilegível é VERMELHO. "Não consegui olhar" nunca vira
        "não há nada aqui" — é a mesma regra que a sonda de disco segue ao
        devolver NULO em vez de zero quando a leitura falha.
    #>
    $ast = $null
    try {
        $errosParse = $null
        $ast = $TIPO::ParseFile($arq.FullName, [ref]$null, [ref]$errosParse)
        if (@($errosParse).Count -gt 0) {
            [void]$ilegiveis.Add((Get-Relativo $arq.FullName $raiz) + ": $(@($errosParse).Count) erro(s) de sintaxe")
            continue
        }
    } catch {
        [void]$ilegiveis.Add((Get-Relativo $arq.FullName $raiz) + ": $($_.Exception.Message)")
        continue
    }
    if ($null -eq $ast) {
        [void]$ilegiveis.Add((Get-Relativo $arq.FullName $raiz) + ': o analisador devolveu nada')
        continue
    }

    <#
        OS ESCOPOS. Três formas produzem parâmetros, e a versão anterior só via
        a primeira e a segunda-com-param-block:

          param(...)                      no corpo do script
          function F { param(...) }       bloco param dentro da função
          function F ($Discos) { ... }    parâmetro INLINE, na assinatura
          { param(...) ... }              scriptblock com param próprio

        A forma inline e a de scriptblock apagam o parâmetro exatamente como as
        outras — medido, executando —, e a de scriptblock está em uso hoje na
        produção deste projeto.
    #>
    $escopos = New-Object System.Collections.ArrayList

    if ($ast.ParamBlock) {
        [void]$escopos.Add(@{
            nome = '<script>'; ehScript = $true; no = $ast
            nomes = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        })
    }

    <#
        TODA FUNÇÃO É ESCOPO, TENHA PARÂMETRO OU NÃO — e o "ou não" era o que
        faltava.

        Medido: 'function A { param($Discos); function B { $discos = 1 } }' era
        ACUSADA. B não tinha parâmetro, então não entrava na lista de escopos, e
        a atribuição dela subia para o escopo de A. Mas em PowerShell B abre
        escopo próprio de qualquer jeito: ali nasce variável nova e o parâmetro
        de A fica intacto. Falso positivo.

        E SCRIPTBLOCK **NÃO** É ESCOPO PRÓPRIO, salvo quando invocado com '&'.

        A versão anterior deste arquivo afirmava, em comentário, que
        '| ForEach-Object { $x = 1 }' escreve no escopo do bloco. É FALSO, e eu
        implementei o modelo contra essa frase sem nunca medi-la. A décima
        segunda verificação mediu, executando, e eu refiz a medição:

            ForEach-Object { $discos = }   MUDOU o de quem chamou
            Where-Object   { $discos = }   MUDOU
            @(1).ForEach({ $discos = })    MUDOU
            . { $discos = }                MUDOU
            & { $discos = }                ORIGINAL   <- o unico com escopo proprio

        Superfície que isso deixava cega nesta árvore: 98 scriptblocks, 163
        linhas, em 26 dos 39 arquivos. A única defesa mecânica contra a
        armadilha que mordeu três vezes chegava com metade do alcance que
        declarava — e declarava por escrito.

        Agora só é escopo o bloco que tem param() PRÓPRIO (aí ele é lambda, e os
        parâmetros dele é que valem) ou o invocado com '&'. Todo o resto é
        transparente: a variável pertence a quem contém o bloco.
    #>
    foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        # Parâmetros vêm do bloco param() OU da assinatura inline — nunca dos dois.
        $ps = if ($f.Body -and $f.Body.ParamBlock) { $f.Body.ParamBlock.Parameters }
              elseif ($f.Parameters) { $f.Parameters }
              else { @() }
        [void]$escopos.Add(@{
            nome = $f.Name; ehScript = $false; no = $f.Body
            nomes = @($ps | ForEach-Object { $_.Name.VariablePath.UserPath })
        })
    }

    foreach ($sb in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)) {
        if (-not $sb.ScriptBlock) { continue }
        $pb = $sb.ScriptBlock.ParamBlock

        <#
            SÓ É ESCOPO O BLOCO COM param() PRÓPRIO OU INVOCADO COM '&'.

            Bloco com param() é lambda: quem o chama passa argumentos, e os
            parâmetros dele é que governam ali dentro.

            '& { ... }' abre escopo próprio — medido, é o único dos cinco
            idiomas testados que abre. Detectado pelo operador de invocação no
            AST, não por adivinhação.

            Todo o resto — ForEach-Object, Where-Object, .ForEach(), dot-source
            — é TRANSPARENTE: a atribuição lá dentro apaga a variável de quem
            contém o bloco, e por isso o bloco não entra como escopo.
        #>
        $pai = $sb.Parent
        $ehChamado = ($pai -is [System.Management.Automation.Language.CommandAst] -and
                      $pai.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand)

        if ($null -eq $pb -and -not $ehChamado) { continue }

        $ps = if ($pb) { $pb.Parameters } else { @() }
        [void]$escopos.Add(@{
            nome = '<scriptblock>'; ehScript = $false; no = $sb.ScriptBlock
            nomes = @($ps | ForEach-Object { $_.Name.VariablePath.UserPath })
        })
    }

    # Sem nenhum parâmetro no arquivo inteiro, não há o que colidir.
    if (-not (@($escopos | Where-Object { @($_.nomes).Count -gt 0 })).Count) { continue }

    foreach ($v in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        <#
            CADA VARIÁVEL PERTENCE AO ESCOPO MAIS INTERNO QUE A CONTÉM.

            É este modelo que mata o falso positivo da função aninhada: um
            '$discos = 1' dentro de 'function B' pertence a B, e B não tem
            parâmetro nenhum — o param() de A não é consultado, porque ali
            nasce variável nova em vez de o parâmetro de A ser apagado.

            A versão anterior comparava contra o escopo do script e acusava.
        #>
        $dono = $null
        foreach ($e in $escopos) {
            if ($v.Extent.StartOffset -ge $e.no.Extent.StartOffset -and
                $v.Extent.EndOffset   -le $e.no.Extent.EndOffset) {
                if ($null -eq $dono -or $e.no.Extent.StartOffset -gt $dono.no.Extent.StartOffset) { $dono = $e }
            }
        }
        if ($null -eq $dono) { continue }

        <#
            PREFIXO DE ESCOPO. '$script:discos = $null' apaga o parâmetro do
            script tão bem quanto '$discos' — medido, executando —, e a versão
            anterior era cega porque comparava UserPath, que carrega o prefixo:
            'script:discos' nunca casa com 'Discos'.

            Mas o prefixo também restringe: dentro de uma função, '$script:x'
            escreve no escopo do SCRIPT e não toca o parâmetro da função. E
            'global:', 'env:' e 'using:' não são o escopo de ninguém aqui.
        #>
        <#
            O prefixo é separado À MÃO, e não por uma propriedade do
            VariablePath: 'UnqualifiedPath' NÃO EXISTE nessa classe. Eu a usei
            de memória, sem conferir, e ela devolvia $null — o que fez a
            ferramenta parar de acusar TUDO, inclusive a forma clássica que ela
            já pegava. Medido rodando os sete casos, não lido.
        #>
        $qualificado = $v.VariablePath.UserPath
        $dp = $qualificado.IndexOf(':')
        $prefixo = if ($dp -ge 0) { $qualificado.Substring(0, $dp).ToLowerInvariant() } else { '' }
        $simples = if ($dp -ge 0) { $qualificado.Substring($dp + 1) } else { $qualificado }

        <#
            'local:' e 'private:' escrevem no escopo CORRENTE — medido,
            executando: os dois apagam a variável de quem está ali. Eles são
            sinônimos do não qualificado para o efeito que interessa aqui, e a
            versão anterior os descartava junto com 'global:', que é o único
            que de fato escreve noutro lugar.
        #>
        if ($prefixo -eq 'script') {
            # Só alcança parâmetro do script, e só se o escopo do script tiver um.
            $dono = $escopos | Where-Object { $_.ehScript } | Select-Object -First 1
            if ($null -eq $dono) { continue }
        } elseif ($prefixo -ne '' -and $prefixo -ne 'local' -and $prefixo -ne 'private') {
            continue
        }

        foreach ($nomeP in $dono.nomes) {
            <#
                -ine e -ceq, NUNCA -eq: o operador insensível a caixa considera
                'discos' igual a 'Discos', e a condição inteira passa a
                descartar a única coisa que ela procura. Foi assim que a
                primeira versão desta ferramenta nasceu morta.
            #>
            if ($simples -ine $nomeP) { continue }
            if ($simples -ceq $nomeP) { continue }

            [void]$colisoes.Add([pscustomobject]@{
                arquivo   = Get-Relativo $arq.FullName $raiz
                linha     = $v.Extent.StartLineNumber
                escopo    = $dono.nome
                local     = $qualificado
                parametro = $nomeP
            })
        }
    }
}

$unicas = @($colisoes | Sort-Object arquivo, linha, local -Unique)

<#
    A CONTAGEM SAI NOS DOIS DESFECHOS.

    O portão confere o número de arquivos varridos contra um piso — reduzir o
    alcance da varredura pela metade deixava tudo verde, porque o cenário de
    sabotagem toca UM arquivo e alcançar aquele arquivo bastava. Se a contagem
    só saísse no caminho limpo, o piso seria inconferível justamente quando há
    algo a esconder.
#>
$resumo = "($($arquivos.Count) arquivo(s) varrido(s))"

if ($ilegiveis.Count -gt 0) {
    foreach ($i in $ilegiveis) { "  x ILEGIVEL $i" }
    "$($ilegiveis.Count) arquivo(s) que eu NAO CONSEGUI analisar $resumo - nao olhar nao e nao ter nada"
    exit 2
}

if ($unicas.Count -eq 0) {
    if (-not $Quiet) { "nenhuma colisao de caixa entre variavel local e parametro $resumo" }
    exit 0
}

foreach ($c in $unicas) {
    "  x {0}:{1}  {2}: `${3} colide com o parametro `${4}" -f $c.arquivo, $c.linha, $c.escopo, $c.local, $c.parametro
}
"$($unicas.Count) colisao(oes) $resumo - em PowerShell essas sao A MESMA variavel, e a atribuicao local apaga o parametro sem avisar"
exit 1
