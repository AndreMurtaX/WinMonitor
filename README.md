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
| F1 | Ronda: sondas baratas + tarefa agendada | pronto |
| F2 | Armazém: agregação por faixa de carga, linha-base | pronto |
| F3 | Exame completo: eventos, saúde de disco, SMART fino | pronto, com duas lacunas declaradas |
| F4 | Regras e limiares | pronto |
| F5 | Parecer com provedor plugável | pronto |
| F6 | Notificação: arquivo, notificação nativa, Telegram | pronto |

**As duas lacunas da F3 estão declaradas, não escondidas.** Contagem de setores
realocados exige decodificar os 512 bytes crus de `MSStorageDriver_FailurePredictData`,
cuja tabela varia por fabricante e não tem documento público a citar — decodificar
sem fonte seria inventar número. E temperatura de *núcleo* de CPU não é destravada
por elevação: medido, a zona ACPI responde 27,9 °C com o processador a 10% de uso,
o que é zona ambiente ou de chipset, não sensor de núcleo. Chamar aquilo de
temperatura de CPU seria fabricar leitura. As duas aparecem em todo relatório na
seção **NÃO VERIFICADO**.

**O que separa o projeto de dizer algo útil é tempo, não código.** A linha-base
precisa de 14 dias de ronda e 20 janelas de carga alta. Antes disso o sistema
responde "ainda não sei" em vez de fingir — e continua avisando se a coleta parar,
que é a única coisa que ele pode afirmar desde o primeiro dia.

---

## Do zero ao primeiro relatório

Requisito único: **Windows com PowerShell 5.1**, que já vem no sistema. Não há
dependência para instalar, nem runtime, nem pacote.

### 1. Conferir que o que você clonou está íntegro

```powershell
.\tests\Run-All.ps1 -Rapido
```

Roda as nove suítes num processo isolado cada. Leva cerca de dois minutos e
termina com `TODAS AS SUITES PASSARAM`. Se não terminar, **pare aqui**: o
projeto não está íntegro na sua máquina e nada abaixo vale.

O `-Rapido` pula a bateria de mutação, que recopia o projeto uma vez por
mutante e leva cerca de uma hora. Vale rodar sem ele pelo menos uma vez, para
ver o que este projeto entende por "testado":

```powershell
.\tests\Run-All.ps1
```

### 2. Ver uma coleta, sem gravar nada

```powershell
.\src\Invoke-Patrol.ps1 -NoWrite -PassThru
```

Devolve a amostra que a ronda gravaria: uso de CPU, memória disponível,
frequência efetiva, GPU se houver — e o bloco `cov`, que declara quais sondas
funcionaram e quais falharam. **É esse bloco que separa "não há problema" de
"não consegui olhar".**

### 3. Ligar o monitoramento contínuo

```powershell
.\tools\Register-Tasks.ps1 -Simular
```

Imprime o plano e **não registra nada**. Leia antes de executar: ele diz o que
cada tarefa faz, em que horário e por quê.

Para registrar de verdade, num **PowerShell como administrador**:

```powershell
.\tools\Register-Tasks.ps1 -Elevado
```

Isso cria três tarefas:

| tarefa | quando | o que faz |
| --- | --- | --- |
| `\WinMonitor\Patrol` | a cada minuto | coleta a amostra barata |
| `\WinMonitor\Exam` | todo dia às 23:50 | log de eventos, saúde de disco, SMART fino |
| `\WinMonitor\Daily` | todo dia às 00:20 | agrega, avalia as regras, entrega o relatório |

**Os horários não são intercambiáveis.** O exame grava o arquivo do dia
*corrente*; a cadeia diária fecha o dia *anterior*. Rodar os dois juntos depois
da meia-noite deixaria todo dia sem exame, e as duas regras de falha de hardware
cairiam em "sem dado" para sempre — em silêncio, com o veredito saindo `normal`.
Há teste que reprova quem juntar os dois.

**Por que precisa de elevação:** o gatilho de inicialização e o principal S4U
(que roda sem ninguém logado) exigem administrador para *registrar*. Depois de
registradas, as tarefas rodam sozinhas. O nível `Highest` é o que permite ao
exame ler os contadores de confiabilidade dos discos, que devolvem acesso negado
em sessão comum.

Para desfazer tudo:

```powershell
.\tools\Register-Tasks.ps1 -Unregister
```

### 4. Pedir um relatório agora, sem esperar a cadência

```powershell
.\src\Invoke-Diario.ps1
```

Agrega, avalia e entrega — na ordem, conferindo que cada etapa **produziu** o
arquivo dela. Etapa que não produz não conta como sucesso, mesmo sem erro.

**No primeiro dia isto REPROVA, e está certo.** O agregador só fecha dias
completos e ignora o dia corrente, que ainda está sendo escrito. Antes da
primeira meia-noite não há nada a agregar, e a cadeia diz exatamente isso:

```
  x agregar: nao produziu nada em data\rollup - a etapa nao fez o trabalho dela
  x avaliar: nao produziu nada em data\findings - ...
  x entregar: nao produziu nada em data\report - ...
```

A alternativa seria ela sair com zero anunciando "cadeia completa" sobre um dia
em que nada aconteceu — que foi exatamente o defeito da primeira versão deste
arquivo, e a razão de a conferência de artefato existir. Depois da primeira
virada de dia com a ronda registrada, isso passa a sair verde sozinho.

---

## Aviso no celular, por Telegram

Opcional, e desligado por padrão até você criar o arquivo de configuração.

**Por que ele existe:** os outros dois canais falham exatamente quando mais
precisam funcionar. O canal de arquivo escreve num disco que pode ser o que está
morrendo; a notificação nativa aparece na sessão interativa, e a ronda roda em
S4U, fora dela. Se o disco começar a falhar às três da manhã, sem este canal o
aviso vai para um arquivo no disco que está falhando.

### Configurar

1. Fale com o [`@BotFather`](https://t.me/BotFather) no Telegram, mande
   `/newbot` e guarde o token.
2. Mande qualquer mensagem para o seu bot — o Telegram só permite responder a
   quem falou primeiro.
3. Descubra o `chatId`:

```powershell
$t = 'SEU_TOKEN_AQUI'
(Invoke-RestMethod "https://api.telegram.org/bot$t/getUpdates").result[-1].message.chat.id
```

4. Crie `%USERPROFILE%\.claude\winmonitor-telegram.json`:

```json
{ "token": "123456:AA...", "chatId": "987654321" }
```

**O arquivo mora fora do repositório de propósito.** `config/secrets.json` está
no `.gitignore`, e isso funciona enquanto ninguém editar o `.gitignore`, rodar
`git add -f` ou copiar o arquivo para outro lugar da árvore. Um segredo que vive
fora da árvore não depende de ninguém lembrar de nada.

Sem esse arquivo, todo relatório imprime `Telegram FALHOU: não configurado` e
os outros canais entregam normalmente. Se você não quiser o canal, remova
`"Telegram"` de `notify.channels` no `config.json`.

### Quando ele fala

- **Mensagem idêntica à anterior não é reenviada.** Repetir a mesma frase todo
  dia treina a pessoa a ignorar o canal, e canal ignorado é pior que canal
  nenhum: dá impressão de cobertura que não existe.
- **Salvo quando há erro.** Com achado, ou com a coleta doente, a mensagem sai
  mesmo idêntica — "o disco continua doente" é notícia todo dia que continuar.
- **Só sobre esta máquina.** Relatório cujo host não é o desta máquina veio de
  fixture ou de outra origem, e alertar sobre o que não foi medido aqui seria
  afirmação sem lastro.

---

## O que esperar nos primeiros dias

| quando | o que o sistema diz |
| --- | --- |
| dia 1 | coleta viva, nenhum achado, cobertura incompleta — e diz *por que* está incompleta |
| dias 2 a 13 | o mesmo, mais as regras absolutas já valendo (WHEA, disco fora de `Healthy`) |
| dia 14+ | linha-base congelada, e as regras relativas passam a responder "isto está pior do que era?" |

As regras **absolutas** valem desde o primeiro dia: erro de hardware registrado
pelo Windows e disco que deixou de ser `Healthy` não precisam de histórico. As
**relativas** — deriva térmica, queda de frequência, vazamento de memória — só
significam alguma coisa contra um passado, e o sistema recusa-se a inventar um.

Uma regra fica presa a hardware específico: `R-GPU-TEMP-SPEC-3080` só se aplica
a uma GeForce RTX 3080, com o limiar publicado pela NVIDIA. Noutra placa ela
aparece como **não aplicável** no relatório, em vez de sumir. Para adaptar,
edite `config/thresholds.json` — e note que toda regra exige `source` com
procedência: `spec` com URL, ou `policy` com justificativa escrita. Regra sem
fonte é recusada pelo motor e declarada como não verificada.

---

## As duas cadências

**Ronda** — a cada minuto, só sondas baratas, sem privilégio administrativo.
A função dela **não é** detectar problema: é capturar as janelas de carga alta.
O dado que diagnostica refrigeração é a temperatura de quando a máquina estava
trabalhando de verdade, e um exame agendado quase sempre pega a máquina parada.
Assim o trabalho real da máquina vira o teste de estresse, sem rodar nenhum.

**Exame** — sob demanda ou semanal, com tudo, inclusive o que exige privilégio.

---

## Uso — comandos avulsos

Para instalar, veja [Do zero ao primeiro relatório](#do-zero-ao-primeiro-relatório).
Esta seção é referência: cada etapa da cadeia pode ser invocada sozinha, e é
assim que se investiga quando algo não bate.

Ver uma coleta sem gravar nada:

```powershell
.\src\Invoke-Patrol.ps1 -PassThru -NoWrite | ConvertTo-Json -Depth 8
```

Agregar os dias já completos — ignora o dia corrente, que ainda está sendo
escrito:

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

**Ver o pacote exato que o modelo receberia, sem chamar modelo nenhum.** É a
forma de auditar o que ele sabe — e de confirmar que ele não sabe mais nada
além daquilo:

```powershell
.\src\Invoke-Laudo.ps1 -DryRun
```

Entregar o relatório agora, ignorando a regra de "vale a pena incomodar":

```powershell
.\src\Invoke-Report.ps1 -Force
```

Rodar o exame completo sob demanda:

```powershell
.\src\Invoke-Exam.ps1
```

Só a ronda como tarefa agendada, sem as duas diárias — modo `-CurrentUserOnly`
dispensa elevação, ao preço de a ronda só rodar com a conta logada:

```powershell
.\tools\Register-PatrolTask.ps1 -CurrentUserOnly
```

Rodar o portão inteiro: as nove suítes, a varredura de sombra de parâmetro e a
bateria de mutação:

```powershell
.\tests\Run-All.ps1
```

Sem a bateria, que recopia o projeto uma vez por mutante:

```powershell
.\tests\Run-All.ps1 -Rapido
```

Conferir que nenhuma variável local está apagando um parâmetro por diferença de
caixa — a armadilha que mordeu este projeto três vezes:

```powershell
.\tools\Find-ParamShadow.ps1
```

Normalizar a codificação dos arquivos depois de editar:

```powershell
.\tools\Repair-Encoding.ps1
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
- **Temperatura de núcleo de CPU não é coletada, e elevação não resolve.**
  Medido nesta máquina depois de elevar a tarefa: `MSAcpi_ThermalZoneTemperature`
  responde, com uma zona a 27,9 °C e o processador a ~10% de uso. Um núcleo
  nesse regime estaria entre 35 e 50 °C — aquilo é zona ambiente ou de chipset.
  Chamar de temperatura de CPU seria fabricar leitura. Cobrir de verdade exige
  sensor por núcleo, que só um driver de kernel de terceiro (LibreHardwareMonitor)
  entrega, e isso não se justifica num servidor por esta métrica. Até lá,
  throttling de CPU é inferido pela frequência efetiva contra a própria história.
- **Contagem de setores realocados não é coletada.** Os contadores de
  confiabilidade (temperatura, horas ligado, erros de leitura, desgaste) passaram
  a ser lidos pela sonda `SmartDetail` desde que o exame roda elevado. O que falta
  é a contagem por atributo SMART, que só existe nos 512 bytes crus de
  `MSStorageDriver_FailurePredictData` — decodificação que varia por fabricante e
  não tem tabela pública a citar. Decodificar sem fonte seria inventar número.
- **Nem todo disco responde todo campo.** Medido nesta máquina, três discos: um
  informa temperatura e não informa horas ligado nem erros de leitura — e é o mais
  quente dos três. Por isso a ausência é registrada **por campo**, e os agregados
  do topo (`hottestC`, `readErrorsMax`) vêm acompanhados de quantos discos de fato
  responderam aquele campo.
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
