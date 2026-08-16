# WinMonitor

Agente de acompanhamento de saúde de máquina para Windows, em PowerShell.
Coleta telemetria de forma contínua e barata, compara contra a própria história
da máquina, e emite um parecer que pode ser conferido — não apenas acreditado.

Escrito para Windows PowerShell 5.1, sem dependência a instalar para a coleta
básica. Funciona em Windows em qualquer idioma.

---

## O princípio

A tentação óbvia é dar ferramentas a um modelo de linguagem e mandá-lo olhar a
máquina. Isso falha de duas formas que se disfarçam bem.

**O modelo inventa o limiar.** Ele lê 78 °C e decide, com toda a confiança do
mundo, que é preocupante — numa placa cujo projeto prevê 83 °C.

**Uma leitura isolada quase não diagnostica nada.** «39 °C» não significa nada
sozinho. «39 °C, e há três meses, na mesma carga, era 31 °C» significa tudo.

Daí a separação que organiza todo o projeto:

```
sondas → coletor → armazém → regras  ‖  parecer → entrega
└──────── determinístico, sem IA ─────┘  └── modelo ──┘
```

Quem produz número é script. Quem decide limiar é arquivo de configuração
versionado, com a fonte citada. O modelo recebe o exame pronto e escreve o
laudo. Ele nunca é o termômetro.

E uma regra que vale em todo lugar: **lacuna declarada nunca vira "tudo certo"**.
Se uma sonda falhou, o relatório diz que aquilo *não foi verificado* — jamais
que está normal. Métrica ausente e métrica boa não podem se parecer.

---

## Estado

| Fase | O que é | Situação |
| --- | --- | --- |
| F0 | Contratos, configuração, módulo comum | pronto |
| F1 | Ronda: sondas baratas + tarefa agendada | pronto (tarefa não registrada) |
| F2 | Armazém: agregação por faixa de carga, linha-base | pronto |
| F3 | Exame completo: SMART, eventos, sensores | a fazer |
| F4 | Regras e limiares | pronto |
| F5 | Parecer com provedor plugável | pronto |
| F6 | Notificação e relatório de tendência | pronto (canal remoto não configurado) |

**O que ainda não roda sozinho.** A tarefa agendada não está registrada, então
não há coleta contínua — e sem coleta não se forma linha-base, e sem linha-base
metade das regras fica permanentemente "sem referência". É o único item que
separa o projeto de estar funcionando de verdade. Duas formas de resolver, em
[Uso](#uso).

Sem semanas de dado acumulado, qualquer conclusão seria só uma releitura em voz
alta do Gerenciador de Tarefas. Isso é intencional, e o sistema diz "ainda não
sei" em vez de fingir.

---

## As duas cadências

**Ronda** — a cada minuto, só sondas baratas, sem privilégio administrativo.
A função dela **não é** detectar problema: é capturar as janelas de carga alta.
O dado que diagnostica refrigeração é a temperatura de quando a máquina estava
trabalhando de verdade, e um exame agendado quase sempre pega a máquina parada.
Assim o trabalho real da máquina vira o teste de estresse, sem rodar nenhum.

**Exame** — sob demanda ou semanal, com tudo, inclusive o que exige privilégio.

---

## Uso

Rodar uma coleta e ver o resultado, sem gravar nada:

```powershell
.\src\Invoke-Patrol.ps1 -PassThru -NoWrite | ConvertTo-Json -Depth 8
```

Instalar a ronda como tarefa agendada. Dois modos, e a diferença importa:

```powershell
.\tools\Register-PatrolTask.ps1 -CurrentUserOnly
```

Sem elevação. A ronda roda enquanto a conta estiver logada. É a opção para
começar a coletar hoje.

```powershell
.\tools\Register-PatrolTask.ps1
```

Modo S4U: roda mesmo sem ninguém logado, que é o certo para um servidor. O
**registro** exige elevação (a ronda em si, não):

```powershell
Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\Dev\WinMonitor\tools\Register-PatrolTask.ps1'
```

Remover:

```powershell
.\tools\Register-PatrolTask.ps1 -Unregister
```

Agregar os dias já completos (roda uma vez por dia; ignora o dia corrente, que
ainda está sendo escrito):

```powershell
.\src\Invoke-Rollup.ps1
```

Ver se já há dado suficiente para congelar a linha-base, e congelá-la:

```powershell
.\src\New-Baseline.ps1 -CheckOnly
.\src\New-Baseline.ps1 -Reason "primeira linha-base"
```

Avaliar as regras contra o agregado do dia, e depois pedir o parecer:

```powershell
.\src\Invoke-Rules.ps1
.\src\Invoke-Laudo.ps1
```

Ver o pacote exato que o modelo receberia, sem chamar modelo nenhum:

```powershell
.\src\Invoke-Laudo.ps1 -DryRun
```

Rodar o portão — todas as suítes, a varredura de sombra de parâmetro e a
bateria de mutação:

```powershell
.\tests\Run-All.ps1
```

Sem a bateria, que recopia o projeto uma vez por mutante e leva minutos:

```powershell
.\tests\Run-All.ps1 -Rapido
```

---

## O que o portão confere, além de "os testes passaram"

Este projeto teve dez verificações adversariais, e nenhuma voltou vazia. O
padrão que elas expuseram não foi código errado — foi **verde que não
significava nada**. Cada trava abaixo nasceu de um caso medido em que o portão
aprovava algo que não devia:

| Trava | O caso que a gerou |
|---|---|
| Execução isolada por suíte | `$LASTEXITCODE` guardava o zero da suíte anterior: 135 testes que nunca rodaram saíram como "passaram" |
| Piso por suíte, mantido à mão | suíte esvaziada continuava verde |
| Resumo obrigatório, único e conferido contra as linhas impressas | suíte que imprime o resumo sem rodar teste nenhum |
| Varredura do diretório | apagar uma linha da lista sumia com uma suíte inteira |
| Prazo por suíte, no conjunto e na bateria | a bateria rodava fora de todo teto: 93 s depois do teto global de 1 s |
| A bateria julgada pelas mesmas doutrinas | bateria muda, com zero mutantes, ou anunciando trava indefesa e saindo com zero: as três passavam |
| Varredura de sombra de parâmetro | `$discos = $null` apagava o parâmetro `$Discos` — a mesma armadilha três vezes |

A **bateria de mutação** (`tools\Test-Mutantes.ps1`) é a régua da régua: cada
entrada reverte uma correção numa cópia do projeto e roda a suíte que deveria
defendê-la. Verde depois da reversão significa trava indefesa. Na primeira
aplicação, contra dez correções que eu daria por prontas, **cinco mutantes
sobreviveram**.

A **varredura de sombra** (`tools\Find-ParamShadow.ps1`) existe porque nomes de
variável em PowerShell são insensíveis a caixa: `$discos = $null` e o parâmetro
`$Discos` são a mesma variável, e a atribuição local apaga o parâmetro sem erro
e sem aviso. Isso aconteceu três vezes — a terceira com a armadilha já
documentada no repositório. Documentar armadilha não previne armadilha.

E o que nenhuma delas pega, dito em vez de negado: **teste que virou vácuo**.
Vinte `Assert-True $true` imprimem vinte linhas legítimas e nenhuma contagem os
separa de vinte testes de verdade. Só leitura humana e verificação adversarial
separam.

---

## Por que percentil por faixa de carga, e não média

Esta é a decisão que faz o projeto valer alguma coisa, então vale explicar.

Uma máquina passa a maior parte do tempo ociosa. A média diária de qualquer
métrica térmica é, portanto, dominada pelo ócio — e degradação real desaparece
nela. O agregado deste projeto classifica cada amostra numa faixa de carga
(0–25, 25–50, 50–75, 75–100%) e calcula os percentis **dentro** de cada faixa,
sempre usando a carga do próprio subsistema: temperatura de GPU é estratificada
pela carga da GPU, nunca pela da CPU, porque a placa pode estar a 100% com o
processador dormindo.

O teste `tests\Test-Rollup.ps1` mede isso com pares de dias sintéticos
idênticos, exceto por +8 °C aplicados somente às amostras de carga alta — o
efeito de pasta térmica secando ou poeira acumulando. Comparando p95 contra p95:

```
carga alta em  2,1% do dia :  p95 do dia  0,0 °C   p95 da faixa  8,0 °C
carga alta em 13,9% do dia :  p95 do dia  8,0 °C   p95 da faixa  8,0 °C
```

**O ganho depende do regime, e o teste mede os dois.** Num servidor que passa a
quase totalidade do tempo ocioso — a linha de cima, e o caso normal — a
estatística do dia inteiro é completamente cega e só a faixa enxerga. Quando a
carga alta ocupa uma fatia grande do dia, ela entra na cauda do p95 diário e a
estatística simples também enxerga; aí a estratificação ganha pouco.

Isto está escrito assim porque a versão anterior deste README afirmava que a
estatística do dia "não se move um décimo", apoiada num teste que comparava a
*mediana* do dia contra o *p95* da faixa — duas estatísticas diferentes. Na
mesma fixture, o p95 do dia movia os mesmos 8 °C. A tese é verdadeira no regime
que importa; a demonstração é que estava errada.

### O caso em que só a estratificação resolve

O argumento acima mostra que a visão por faixa é mais *sensível*. O que a torna
**insubstituível** é outro caso: distinguir duas causas que produzem exatamente
a mesma subida em qualquer número não-estratificado.

```
                          sala quente   refrigeração degradando
  máximo do dia               8 °C          8 °C     <- iguais: não distingue
  faixa ociosa  (b00)         8 °C          0 °C     <- aqui está a diferença
  faixa de carga (b75)        8 °C          8 °C
```

Ar-condicionado quebrado desloca a curva inteira; dissipador entupido desloca só
a ponta de carga alta. O máximo do dia dá a mesma resposta para os dois, e a
ação necessária é completamente diferente. Só a comparação por faixa separa as
duas — e é isso que justifica o custo de manter o agregado estratificado.

A linha-base se recusa a existir sobre dado insuficiente: exige 14 dias de ronda
**e** 20 janelas de carga alta sustentada, ambos medidos dentro da mesma janela
que será congelada, e recusa também se o perfil resultante não contiver a faixa
de carga alta — sem ela não há contra o que comparar. Antes disso a resposta é
"ainda não sei" — que é honesta, e melhor que um diagnóstico apoiado em ruído.

---

## Por que o monitor fala quando não há nada a dizer

Um monitor que só fala quando há problema é indistinguível de um monitor morto.
Três semanas de silêncio significam «máquina saudável» ou «o agente parou em 12
de julho e ninguém percebeu»? As duas hipóteses produzem exatamente a mesma
caixa de entrada vazia.

Essa ambiguidade não se resolve com mais regra de alerta. Resolve-se obrigando o
sistema a falar quando **não** há nada a dizer:

- **Pulso.** Passados `heartbeatDays` sem nenhuma notificação, o relatório sai
  assim mesmo dizendo que nada mereceu atenção. Silêncio deixa de ser ambíguo
  porque silêncio deixa de existir.
- **Saúde da própria coleta.** Antes de qualquer conclusão sobre a máquina,
  confere-se se a ronda realmente rodou. Um veredito «normal» calculado sobre
  dado de anteontem não é uma boa notícia — é uma notícia falsa, e a mais
  perigosa que este projeto pode dar. Aparece na primeira linha do relatório.
- **Cegueira prolongada.** Cobertura incompleta por `blindDays` seguidos vira
  aviso mesmo sem nenhum achado, porque o veredito continua saindo «normal» —
  verdade sobre o que foi medido, silêncio sobre o que não foi.

E a regra que sustenta as três: **o estado só avança se a entrega deu certo.** Se
todos os canais falharem, o dia não é marcado como notificado e a próxima
execução tenta de novo. Gravar «notificado» quando ninguém foi notificado é a
forma mais fácil de construir um monitor que se acha em dia.

```powershell
.\src\Invoke-Report.ps1 -DryRun     # monta e mostra, não entrega nem grava estado
.\src\Invoke-Report.ps1             # decide, entrega, registra
```

O canal `File` funciona sem configurar nada — mas um arquivo numa máquina que
você não está olhando não notifica ninguém. Para receber de fato, configure
`webhook.url` em `config/secrets.json` (ntfy, Discord, Slack, Teams ou endpoint
próprio) e acrescente `"Webhook"` a `notify.channels`.

---

## Como o laudo é conferido

O modelo escreve o parecer, e nada do que ele escreve é aceito por confiança. O
pacote que ele recebe é fechado — só os Achados, as séries que os Achados citam,
o bloco de cobertura e o laudo anterior. Sem acesso à máquina, ao dado bruto ou
à tabela de limiares: o que não está no pacote ele não tem como inventar com
aparência de dado.

O que volta passa por quatro conferências, todas determinísticas — a tabela tem
cinco linhas porque a última função confere duas obrigações distintas. Nenhuma
precisa de um segundo modelo concordar:

| Guarda | O que exige |
| --- | --- |
| Números | todo número extraído do texto tem de existir no pacote |
| Regras citadas | só cita identificador de regra que o pacote contém, na prosa **e** no campo estruturado |
| Achados | os achados do laudo são **exatamente** os do pacote, com contagem |
| Lacunas | `notVerified` cobre **todas** as lacunas do pacote, e **só** elas |
| Forma | cobertura incompleta obriga a declarar a lacuna; pacote sem achados proíbe hipótese |

Reprovado, o laudo é reapresentado uma vez com os motivos exatos. Falhando de
novo, ele **não é mostrado**: grava-se o texto cru para perícia e apresentam-se
os Achados crus, que são verdade verificável. Um parecer que não passa na
própria conferência é pior que nenhum parecer, porque tem a forma de resposta.

### Quase nenhuma dessas guardas foi projetada

Uma foi. As outras existem porque modelos de verdade, e depois uma verificação
adversarial, fizeram exatamente o que a teoria não previu.

**O falso positivo, e o buraco que o conserto dele abriu.** O laudo escreveu
"RTX 3080" e a conferência acusou `3080` de ser inventado — estava no pacote,
dentro de `NVIDIA GeForce RTX 3080`, mas a remoção de literais só casava a
string inteira. O conserto óbvio foi liberar os números embutidos em nomes de
peça. Foi o pior erro do projeto até agora: o disco desta máquina chama-se
`ST10000NM001G-2MW103`, dele saía o `103`, e a tolerância de 5% transformava
isso na faixa contínua **98–108** — onde mora uma temperatura de CPU plausível.
Um laudo afirmando "a CPU chegou a 100 graus" passou nas quatro guardas contra
um pacote com zero achados e nenhuma temperatura.

Hoje nome de peça não libera número nenhum: remove-se a **frase** do texto.
`i9-11900K` sai sozinho, porque ninguém confunde isso com medida; `3080` só sai
acompanhado, como em "RTX 3080". Escrever "3080 graus" é órfão.

**O achado sem número.** Num pacote com zero achados e veredito `normal`, o
modelo devolveu:

```
ruleId : R-GPU-TEMP-SPEC-3080
reading: A temperatura da RTX 3080 está acima do especificado.
action : O valor não foi fornecido no pacote.
```

Ele sabia que não tinha dado e afirmou assim mesmo. A guarda de números não
pega — o achado não tem número. A de regras não pega — aquele identificador é
legítimo de citar, está em `coverage` como não avaliado, e o campo estruturado
nem chegava ao texto examinado. Foi rejeitado só porque outra frase trazia um
número inventado: sorte, não defesa. A distinção que faltava é que regra em
`coverage` é **citável** e nunca é **achado**.

**A lacuna calada.** Outro modelo passou nas três guardas e devolveu o campo
`notVerified` vazio com a cobertura incompleta, mais uma hipótese afirmando que
a placa parecia quente — num pacote sem nenhuma temperatura. A primeira é o pior
modo de falhar deste projeto: um laudo silencioso sobre a própria ignorância
lê-se como "está tudo bem". O lema **lacuna declarada nunca vira "tudo certo"**
só vale se alguém conferir que ela foi declarada. A segunda é a invenção
mudando de campo — sem número, a guarda aritmética dorme; em `observations`, a
de achados dorme.

Cada guarda nova traz junto o teste que prova que as **anteriores** deixavam
aquele caso passar. Sem isso não há como saber se ela é necessária ou
decorativa.

---

## Onde ficam os dados

Nada de telemetria entra no repositório — `data/` e `logs/` estão fora do
versionamento.

```
data/host.json          fatos estáticos da máquina, coletados uma vez
data/patrol/AAAA-MM-DD.jsonl   uma linha por amostra da ronda
logs/AAAA-MM-DD.log     falhas da própria coleta
```

Configuração em duas camadas: `config/config.json` é versionado e genérico;
`config/config.local.json` fica fora do repositório e sobrepõe o que for
específico da sua máquina. Credenciais vão em `config/secrets.json`, também
fora do repositório — veja `config/secrets.example.json` para a estrutura.

---

## Decisões que merecem explicação

**Classes CIM em vez de `Get-Counter`.** Os nomes de contador do Windows são
traduzidos para o idioma do sistema: em português, `\Processor Information`
simplesmente não existe. As propriedades das classes CIM de performance não são
traduzidas. Usar `Get-Counter` com caminho em inglês quebraria em silêncio em
qualquer Windows não-inglês.

**Processo novo a cada minuto, em vez de laço residente.** O laço é mais
eficiente, mas se morrer fica morto até alguém perceber. A tarefa agendada se
cura sozinha. Num monitor, auto-recuperação vale mais que eficiência.

**A máscara de contenção da GPU é decodificada bit a bit.** `nvidia-smi`
devolve `0x1` — bit `GpuIdle` — numa placa perfeitamente saudável que só está
ociosa. Tratar "diferente de zero" como defeito produziria alarme falso a cada
minuto. Só `SwThermalSlowdown`, `HwThermalSlowdown`, `HwSlowdown` e
`HwPowerBrake` são sinais de verdade.

**Prioridade 7 e sondas baratas na ronda.** O monitor não pode ser a doença.

---

## Limitações conhecidas

Registradas aqui porque o mesmo princípio que vale para as sondas vale para o
projeto: o que não foi verificado precisa estar dito.

- **Latência de disco não é coletada na ronda.** A classe CIM formatada tipa
  `AvgDisksecPerRead` como inteiro, e latências de sub-segundo podem truncar
  para zero — o que pareceria um disco perfeito. Fica para o exame, com leitura
  de contador feita corretamente.
- **Temperatura de CPU ainda não é coletada.** Exige driver de kernel
  (LibreHardwareMonitor). Até lá, throttling de CPU é inferido pela frequência
  efetiva comparada à própria história.
- **O viés de CPU da própria ronda foi medido e é desprezível.** O arranque do
  PowerShell é carga, então a suspeita era razoável. Seis leituras seguidas no
  mesmo processo deram 8–15%, com a primeira em 12% — no meio da faixa, sem
  inflação sistemática da primeira leitura. O respiro de 400 ms antes de
  amostrar fica como margem.
- **Sem histórico, nada aqui diagnostica.** A linha-base precisa de semanas.
- **Modelo pequeno não escreve laudo aproveitável.** Medido, não suposto: contra
  um pacote sem achados, o `gemma3:4b` inventou achados em todas as tentativas
  de todas as execuções. O `mistral:latest` passa nas quatro conferências, mas o
  texto sai mecânico — lista identificador de regra em vez de explicar. As
  guardas compram correção, não eloquência; para laudo de produção o provedor
  remoto continua sendo a escolha defensável.
- **A extração de números é forte, não é total.** Cobre algarismo, decimal,
  notação científica, milhar com ponto, e numeral por extenso em português
  incluindo `mil` e seus compostos. Continuam de fora: fração por extenso
  ("meio grau"), `milhão`, algarismo romano e numeral em outro idioma. Dígito
  que o conversor invariante recusa — Unicode de largura inteira, por exemplo —
  vira órfão em vez de ser descartado em silêncio.
- **O leitor de numeral por extenso tem falso positivo conhecido.** "mil vezes"
  numa frase idiomática vira órfão e reprova um laudo honesto. Aceito porque a
  reapresentação absorve o custo, e porque errar para o lado de acusar é o lado
  certo de errar aqui.
- **A prosa livre sem número ainda não é conferida.** As quatro guardas cobrem
  número, regra citada, achado e forma. Uma afirmação vaga e sem dígito dentro
  do `summary` passa — inclusive uma que contradiga o veredito. O que se faz
  contra isso não é conferência, é ordem de leitura: o parecer imprime veredito,
  achados medidos e lacunas **antes** do texto do modelo, para que a
  discordância fique visível em vez de plausível. É a fronteira conhecida do
  método, e ela não fechou.
- **O campo `note` de cada lacuna é prosa livre.** A lista de lacunas é
  estrutural e obrigatória, mas o comentário ao lado de cada uma não é conferido
  — um modelo pode listar a lacuna e escrever ali que ela está normal. O título
  "Não verificado" e a lista permanecem; a negação fica ao lado.

---

## Licença

MIT — veja [LICENSE](LICENSE).
