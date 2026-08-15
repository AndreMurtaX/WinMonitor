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
