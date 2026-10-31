# Projeto Farol · Vértice Tecnologia: contexto do projeto

Projeto técnico da Imersão Jornada de Dados (**19 a 22 de outubro de 2026**, 19h30,
ao vivo no YouTube). Este arquivo é o contexto do projeto: **leia antes de escrever
qualquer código**. Ele vale para os cinco prompts da noite 3 (bundle, silver, gold,
job, dashboard) e para o modelo e o Genie da noite 4.

---

## 1. O negócio

A **Vértice Tecnologia** desenvolve e implanta sistemas para grandes clientes de varejo,
financeiro, saúde, logística e indústria: 60 projetos, 520 pessoas, R$ 305 mi de carteira.
Quem constrói a Torre é o único profissional de dados da empresa, que faz os 4 papéis. O problema: cada
gerente controla o projeto numa ferramenta — **20 em planilhas Excel, 25 no ClickUp e 15 no
MS Project** — e ninguém sabe dizer quais projetos estão atrasados.

O dono fez **quatro perguntas**. A Torre responde as quatro:

1. **Quais projetos estão atrasados, e de quais clientes?** (SPI, CPI, situação)
2. **Quanto esse atraso vai me custar?** (EAC, estouro previsto, margem)
3. **Tenho gente parada enquanto outro projeto pede gente?** (utilização do timesheet + causa no status)
4. **O que vai dar errado no próximo mês?** (na noite 3: entregas de consultoria atrasadas e o change freeze da Black Friday; a resposta completa é o modelo da noite 4)

Regras de corte: SPI ou CPI **< 0,9 = atenção**, **< 0,8 = crítico**.

| KPI | Fórmula |
|---|---|
| SPI | EV ÷ PV. Nas tarefas: Σ horas × % concluído ÷ Σ horas × % do prazo baseline decorrido. < 1 é atraso |
| CPI | EV ÷ AC, com EV = orçamento × horas agregadas ÷ horas totais. < 1 é estouro |
| EAC | orçamento ÷ CPI |
| Estouro previsto | EAC − orçamento, só quando positivo |
| Margem projetada | (valor do contrato − EAC) ÷ valor do contrato |
| Atraso projetado (dias) | duração baseline ÷ SPI − duração baseline |
| Farol calculado | regra do manual da Vértice: verde com SPI ≥ 0,95; amarelo ≥ 0,90; vermelho abaixo |
| Melancia | farol do gerente verde e SPI < 0,9 |

**O "hoje" do dataset é 16/10/2026 (sexta).** Nunca use `current_date()`: o número
mudaria todo dia e não bateria com o de ninguém. Escreva `DATE'2026-10-16'`.

---

## 2. Onde está o dado

Catálogo **`lakehouse_vertice`**, criado na noite 1. Schemas `bronze`, `silver`, `gold`
e o volume `bronze.raw` já existem. **A bronze já está carregada** (9 tabelas, com a
sujeira, mais `feriados`) e é a ÚNICA entrada da silver. Nunca altere a bronze à mão.

Quem carrega a bronze é o **job de ingestão da noite 2**, montado clicando no workspace
(na aula, `vertice_ingestao`): a tarefa `api` grava `bronze.feriados` (BrasilAPI) e a tarefa
`data_lake` baixa os arquivos do Supabase Storage com `boto3` (protocolo S3), pousa no volume
`bronze.raw` e recria as 9 tabelas com `read_files`. As chaves do data lake chegam ao notebook
como parâmetros da tarefa (`S3_ENDPOINT`, `AWS_DEFAULT_REGION`, `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`). **No passo 1 (feito à mão, com a CLI) esse job vira código** e passa a ser a primeira etapa do
`vertice_farol`. **Chave nunca vai para arquivo versionado:** o repositório é público.

| Tabela bronze | Linhas | O que é |
|---|---|---|
| `projetos` | 60 | cadastro do PMO: cliente, segmento, valor, orçamento, datas, **ferramenta** e **código na ferramenta** (o de-para) |
| `status_semanal` | 3.911 | o status de toda sexta: % concluído, farol do gerente, texto livre com bloqueios |
| `excel_tarefas` | 1.663 | as 20 planilhas (colunas renomeadas; tudo texto) + `arquivo` |
| `clickup_tarefas` | 2.119 | as tarefas das 25 listas: `list_id`, `list_name`, `status` (struct), datas em ms, `custom_fields` (lista) |
| `msproject_tarefas` | 1.260 | as `<Task>` dos 15 XML: `UID`, `OutlineLevel`, `Summary`, `Work`, `PercentComplete`, `Baseline` (struct), `arquivo` |
| `colaboradores` | 523 | as 520 pessoas (3 duplicadas): papel, senioridade, custo/hora, admissão, desligamento |
| `apontamentos` | 30.883 | timesheet semanal: horas disponíveis × apontadas por pessoa e projeto |
| `custos` | 23.640 | lançamentos de custo real (pessoal, consultoria, cloud, licenças, despesas) |
| `entregas_fornecedor` | 640 | entregas das consultorias: prometido × entregue |

## 3. A sujeira é proposital — a limpeza e a integração são o conteúdo da noite

| # | Sujeira | Onde | Decisão certa |
|---|---|---|---|
| 1 | Data em `yyyy-MM-dd` e `dd/MM/yyyy` | `projetos.data_inicio` (24 de 60) | `coalesce(try_to_date(x,'yyyy-MM-dd'), try_to_date(x,'dd/MM/yyyy'))` |
| 2 | Ferramenta escrita de 8 jeitos | `projetos.ferramenta` | `excel`, `clickup` ou `msproject` por `LIKE` |
| 3 | Código da ferramenta vazio | `projetos.codigo_ferramenta` (2) | Excel: o nome do arquivo traz o `PRJ-xxx`; ClickUp: casa pelo nome da lista |
| 4 | Data do Excel em texto **ou** número de série | `excel_tarefas` (datas) | `dd/MM/yyyy` se tem `/`; senão `date_add(DATE'1899-12-30', CAST(x AS INT))` |
| 5 | % do Excel em `'45%'`, `'10,5%'` ou `0.45`; 11 acima de 100 | `excel_tarefas.pct_concluido` | com `%`: tira o `%` e troca a vírgula; sem: × 100. Depois `least(…, 100)` com flag |
| 6 | Linha de TOTAL no fim da planilha | `excel_tarefas` (20) | `WHERE tarefa <> 'TOTAL'` (e um teste: a soma da silver = o TOTAL) |
| 7 | Horas `'40h'` | `excel_tarefas.horas_previstas` | `replace(x, 'h', '')` |
| 8 | Datas em milissegundos; % e baseline dentro de `custom_fields` | `clickup_tarefas` | `to_date(timestamp_millis(CAST(x AS BIGINT)))`; `filter(custom_fields, f -> f.name = '...')[0].value` |
| 9 | Status escrito de 12 jeitos | `clickup_tarefas.status.status` | `concluida`, `a_fazer`, `em_andamento` |
| 10 | Tarefas-resumo somando as horas de baixo | `msproject_tarefas` (105) | `WHERE Summary = 0` |
| 11 | A fase não está na tarefa | `msproject_tarefas` | `last_value(CASE WHEN OutlineLevel = 1 THEN Name END, true) OVER (PARTITION BY arquivo ORDER BY UID)` |
| 12 | Horas em `'PT40H0M0S'` | `msproject_tarefas.Work` | `regexp_extract(Work, 'PT([0-9]+)H', 1)` |
| 13 | Vírgula decimal `12345,67` | `custos.valor` (671) | `replace(',', '.')` antes do CAST. `try_cast` jogaria R$ 5,4 mi fora em silêncio |
| 14 | Estorno como valor negativo | `custos` | **manter** (custo é líquido) e sinalizar `estorno` |
| 15 | A mesma consultoria com 4 grafias | `entregas_fornecedor.fornecedor` | normalizar para `CodeForge Consultoria Ltda` |
| 16 | Pessoa cadastrada duas vezes | `colaboradores` (COL0102, COL0257, COL0433) | manter o cadastro com `papel` em minúsculas |
| 17 | Farol `'Verde'`, `'VERDE'` | `status_semanal.farol` | `lower(trim())` |
| 18 | Status vazio (`''`, `N/A`, `ver ata da reunião`) | `status_semanal.texto_status` (51) | **não descartar**: flag `status_vazio` |

**O teste de uma boa limpeza:** o custo total não muda (R$ 193,35 mi na bronze com
`replace` = R$ 193,35 mi na silver), e as horas de cada planilha batem com a linha de TOTAL.

## 4. Arquitetura

```
 job vertice_farol · toda segunda às 6h
 ingestao_feriados ──┐
                     ├── conferencia_bronze ── medalhao (pipeline Lakeflow) ──┬── testes_de_qualidade
 ingestao_data_lake ─┘     sql_task             silver ×7  →  gold ×3         └── status_com_ia
 (noite 2, notebooks)                           (silver.tarefas = as 3            (ai_classify + ai_extract)
                                                 ferramentas num modelo só)
 dashboard_portfolio (recurso do bundle, lê a gold)

 noite 4: + ml_features → ml_modelo → ml_score · + metricas_governadas (mv_projetos) · + Genie
```

| Prompt (noite 3) | O que entra no bundle |
|---|---|
| 1 · à mão, com a CLI (não é prompt) | `databricks.yml` (`bundle init default-minimal`), o job importado com `bundle generate` (`ingestao_feriados`, `ingestao_data_lake`), as chaves em `variable-overrides.json` |
| 2 · conferência + silver | `conferencia_bronze`, pipeline `vertice_medalhao` (`src/silver/`), tarefa `medalhao` |
| 3 · gold + testes | `src/gold/` no mesmo pipeline, tarefa `testes_de_qualidade` |
| 4 · o job completo | tarefa `status_com_ia`, o agendamento de segunda, o job inteiro rodando |
| 5 · dashboard | `resources/dashboard.dashboard.yml` + o JSON gerado por `scripts/gerar_dashboard.py` |

**Pouca tabela, de propósito.** Silver: `projetos`, `tarefas`, `status_semanal`, `custos`,
`colaboradores`, `apontamentos`, `entregas_fornecedor`. Gold: `fato_projeto_semana`,
`projeto_situacao_atual` (que já traz o cadastro: cliente, segmento, tipo, ferramenta,
gerente, contrato, prazo), `utilizacao_pessoa_semana` e `status_estruturado` (a IA). Na
noite 4 entram `score_estouro_30d` e `mv_projetos` (a métrica governada). Fornecedor não tem
tabela gold: lê-se direto da `silver.entregas_fornecedor`. Não crie `dim_projeto`.

- **Um bundle só**, chamado `vertice`, na **raiz deste repositório** (o `databricks.yml`
  fica ao lado deste CLAUDE.md). O gabarito, testado, está em
  <https://github.com/lvgalvao/ImersaoControlTower/tree/main/aulas/aula-03-modelagem-claude-code/claude-code/vertice>:
  não copie dele, a graça da noite é construir.
- **Silver e gold num pipeline declarativo** (Lakeflow Spark Declarative Pipelines,
  SQL, serverless). Silver = schema padrão do pipeline; gold = nome completo
  `lakehouse_vertice.gold.x`. Um arquivo por assunto em `src/silver/` e `src/gold/`.
  Qualidade com `CONSTRAINT ... EXPECT (...) ON VIOLATION FAIL UPDATE`.
- **A integração mora em `silver.tarefas`**: três `CREATE TEMPORARY VIEW` (uma por
  ferramenta, todas com as mesmas colunas) e um `UNION ALL` numa materialized view.
- **O histórico do avanço vem do status semanal.** Excel, ClickUp e Project só guardam
  o % de hoje. `gold.fato_projeto_semana` usa o % do status de cada sexta; a fotografia
  de hoje (`gold.projeto_situacao_atual`) usa as tarefas das ferramentas.
- **IA, testes e métricas como `sql_task`** no warehouse, com o caminho completo das
  tabelas (`lakehouse_vertice.gold.x`).
- **A ingestão como `notebook_task` serverless** (`src/ingestao/`), com as chaves em
  variáveis do bundle (`${var.s3_access_key_id}`, `${var.s3_secret_access_key}`) e o valor em
  `.databricks/bundle/dev/variable-overrides.json`, que o `.gitignore` deixa fora do Git.
- **Dashboard (noite 3) e Genie (noite 4) como recursos do bundle** (`resources/*.yml` + JSON).

## 5. Armadilhas medidas neste workspace (Free Edition, outubro/2026)

| Armadilha | O que fazer |
|---|---|
| `mode: development` prefixa nomes com `[dev usuario]` | Não use. No target `dev` use `presets: { trigger_pause_status: PAUSED }` |
| `bundle generate job` escreve `ingestão.job.yml` com a chave do job acentuada e as chaves do S3 em texto | Renomeie para `vertice.job.yml` / `vertice_farol` e troque cada chave por `${var.…}` |
| Variável sem default e sem valor: `no value assigned to required variable` | O valor vai em `.databricks/bundle/dev/variable-overrides.json` (JSON simples, nome → valor) |
| Dois jobs recarregando a mesma bronze | Depois do 1º deploy, pause o agendamento do job de ingestão da noite 2 |
| Função de janela dentro de agregação dá erro no pipeline | Calcule a janela num CTE e agregue no CTE seguinte |
| `CREATE OR REPLACE` não existe no pipeline | Use `CREATE OR REFRESH MATERIALIZED VIEW` (e `CREATE TEMPORARY VIEW` para as visões intermediárias) |
| Metric view falha com `METRIC_VIEW_INVALID_VIEW_DEFINITION` pelo `aitools tools query` | O YAML perde a indentação. Rode como `sql_task` ou com `python3 scripts/run_sql.py` (API de statements) |
| A `sql_task` do job corta o arquivo em todo `;`, inclusive dentro do `$$ ... $$` do YAML | Nunca use `;` dentro do YAML da metric view (nem em comment) |
| `ai_classify` + `ai_extract` levam ~5 s por texto | IA só nos status **com bloqueio** dos **últimos 90 dias** (~160); regra para "sem bloqueio"; palavra-chave no histórico; `MERGE` incremental |
| `ai_extract` sem schema devolve tudo como texto | Use a versão 2.0 com JSON schema tipado: `ai_extract(texto, '{"dias_impacto":{"type":"number"}}', map('version','2.0')):response:dias_impacto::DOUBLE` |
| Genie do bundle falha no deploy com `Table ... does not exist` | O Genie precisa das tabelas existindo. Do zero: deploy → run → deploy |
| Apagar o pipeline **não** apaga as materialized views | O `prd/00-reset.sh` apaga silver e gold uma a uma |
| `databricks fs` em Volume | Exige o prefixo `dbfs:` (`dbfs:/Volumes/...`) |

## 6. Convenções

- snake_case e português, como na bronze. Caminho completo nas `sql_task`.
- `COMMENT` em toda tabela da silver e da gold: é o que o Genie lê.
- Comentário pensando em quem assiste ao vivo pela primeira vez. SQL legível > SQL esperto.
- Sempre `--profile <perfil>` nos comandos `databricks`. Nunca deixe implícito.
- Warehouse: descubra com `databricks warehouses list --profile <perfil>` (o Free Edition tem um, o Serverless Starter Warehouse).

## 7. Números que servem como teste (seed 42)

| O que | Valor |
|---|---|
| Tarefas na silver | 4.917: Excel 1.643 (20 projetos), ClickUp 2.119 (25), MS Project 1.155 (15) |
| Projetos em andamento | 41 (19 concluídos) |
| Projetos críticos / em atenção | **7 / 10** (os mesmos da noite 1: a gold confirma o rascunho) |
| Estouro previsto (em andamento) | **R$ 6,47 mi** |
| SPI / CPI da carteira | 0,92 / 0,97 |
| Melancias (farol verde, SPI < 0,9) | 4: PRJ-012, PRJ-028, PRJ-034, PRJ-042 |
| Custo real total | R$ 193,35 mi |
| Entregas em atraso | 5, todas da CodeForge |
| CodeForge: prazo real ÷ prometido | 1,41 (0% no prazo) |
| SREs com < 20% de uso (12 semanas) | COL0017 e COL0018, no PRJ-007 (5,8% e 5,5%) |
| PRJ-011: causa no status (90 dias) | falta de SRE, 12 semanas, 57 dias de impacto declarado |
| Status classificados pela IA | 163 (últimos 90 dias, com bloqueio) |
| Job da noite 3 | 6 tarefas: 2 de ingestão, conferência, medalhão, testes, IA |

A conferência completa está em `prd/99-verificacao.sql`.
