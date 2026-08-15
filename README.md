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
| F2 | Armazém: agregação por faixa de carga, linha-base | a fazer |
| F3 | Exame completo: SMART, eventos, sensores | a fazer |
| F4 | Regras e limiares | a fazer |
| F5 | Parecer com provedor plugável | a fazer |
| F6 | Notificação e relatório de tendência | a fazer |

Enquanto F2–F5 não existirem, o projeto grava história e não conclui nada. Isso
é intencional: sem semanas de dado acumulado, qualquer conclusão seria só uma
releitura em voz alta do Gerenciador de Tarefas.

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

Instalar a ronda como tarefa agendada (o registro pede elevação; a ronda em si
não):

```powershell
.\tools\Register-PatrolTask.ps1
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

Rodar os testes:

```powershell
.\tests\Test-Rollup.ps1
```

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
"ainda não sei".

E a linha-base se recusa a existir sobre dado insuficiente: exige 14 dias de
ronda **e** 20 janelas de carga alta sustentada. Antes disso a resposta é
"ainda não sei", que é honesta — e melhor que um diagnóstico apoiado em ruído.

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

---

## Licença

MIT — veja [LICENSE](LICENSE).
