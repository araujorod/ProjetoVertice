Use as skills databricks-core, databricks-dabs e databricks-pipelines.
Sempre --profile DEFAULT.

Primeiro, o contexto do curso: troque o CLAUDE.md da raiz (o do template)
por este, e leia antes de continuar:
  curl -fsSL -o CLAUDE.md https://raw.githubusercontent.com/lvgalvao/ImersaoControlTower/main/aulas/aula-03-modelagem-claude-code/claude-code/prd/CLAUDE.md
  mkdir -p scripts && curl -fsSL -o scripts/run_sql.py https://raw.githubusercontent.com/lvgalvao/ImersaoControlTower/main/scripts/run_sql.py

O bundle vertice está na raiz: eu criei à mão com bundle init
default-minimal e importei o job de ontem com bundle generate
(resources/ingestão.job.yml, com as chaves do data lake já em variáveis).
NÃO mexa nos valores das chaves, nem no
.databricks/bundle/dev/variable-overrides.json, nem no catálogo e nos
schemas (já existem). Se um comando for recusado por causa das chaves,
pare e me mostre o comando para eu rodar com `!`.

Confira antes: o databricks.yml está na pasta onde você abriu, e existe
resources/*.job.yml com as chaves em ${var.…}. Se faltar, NÃO rode o
bundle generate (ele grava as chaves em texto): pare e me diga qual passo
do bundle-na-mao.md refazer.

Antes de tudo, arrume o bundle:
- databricks.yml: tire o mode: development do target dev (ele prefixa os
  nomes) e ponha presets: trigger_pause_status: PAUSED. Variáveis catalog
  (default lakehouse_vertice) e warehouse_id (descubra com
  databricks warehouses list); saem as variáveis catalog/schema do template.
  Mova os dois notebooks que o generate pôs em src/ para src/ingestao/
  (ajuste o notebook_path). Deixe fixtures/ e tests/ do template onde estão.
- o job: renomeie o arquivo para resources/vertice.job.yml, a chave e o
  name para vertice_farol, as tarefas para ingestao_feriados (a da API) e
  ingestao_data_lake (a do boto3), e schedule.pause_status para PAUSED. O
  bloco variables das duas chaves pode ir para o databricks.yml.
- depois do deploy, pause o agendamento do job antigo "Ingestão" (dois jobs
  recarregando a mesma bronze às 6h brigam). Não apague.

0. Antes da silver, a conferência da bronze: src/conferencia/00-conferencia-bronze.sql,
   sql_task no warehouse ${var.warehouse_id}, tarefa conferencia_bronze no job,
   depois das duas ingestões. Confere as 9 tabelas contra a contagem esperada
   (seed 42): projetos 60 · status_semanal 3911 · excel_tarefas 1663 ·
   clickup_tarefas 2119 · msproject_tarefas 1260 · colaboradores 523 ·
   apontamentos 30883 · custos 23640 · entregas_fornecedor 640
   (bronze.feriados fica de fora: cresce a cada execução). Uma linha por
   tabela com esperado e obtido; se alguma divergir, raise_error() dizendo
   qual tabela e onde olhar (a saída da tarefa ingestao_data_lake).

Agora a silver: integrar as três ferramentas, limpar, tipar e declarar o
contrato.

Crie um pipeline Lakeflow Spark Declarative Pipelines em SQL:
resources/vertice_medalhao.pipeline.yml com name vertice_medalhao, catalog
${var.catalog}, schema silver, serverless: true, photon: true, e libraries com
um glob em ../src/silver/** (o prompt 2 vai acrescentar ../src/gold/**).

Use CREATE OR REFRESH MATERIALIZED VIEW (nunca CREATE OR REPLACE, que não
existe no pipeline) e CREATE TEMPORARY VIEW para as visões intermediárias.
Leia a bronze pelo nome completo lakehouse_vertice.bronze.<tabela>; dentro do
pipeline, referencie as tabelas silver só pelo nome. COMMENT em toda tabela.
Siga a tabela de sujeiras da seção 3 do CLAUDE.md.

Um arquivo por assunto em src/silver/:

01-projetos.sql — o cadastro do PMO (é o de-para da integração)
- data_inicio em yyyy-MM-dd e dd/MM/yyyy: coalesce de dois try_to_date.
- ferramenta escrita de 8 jeitos → 'excel', 'clickup' ou 'msproject'
  (guarde ferramenta_como_veio). codigo_ferramenta vazio → NULL.
- EXPECT data_inicio IS NOT NULL e ferramenta IN (...), FAIL UPDATE.

02-tarefas.sql — AS TRÊS FERRAMENTAS VIRAM UMA
Três CREATE TEMPORARY VIEW com as MESMAS colunas (projeto_id, ferramenta,
id_na_ferramenta, fase, tarefa, responsavel, inicio_baseline, fim_baseline,
inicio_real, fim_real, pct_como_veio, horas, status_na_ferramenta):
- tarefas_excel: projeto pelo de-para (codigo_ferramenta = arquivo) e, se não
  casar (código vazio, ou o arquivo chegou sem acento: 'Core bancario' ×
  'Core bancário'), o PRJ-xxx do nome do arquivo:
  coalesce(p.projeto_id, regexp_extract(arquivo, 'PRJ-[0-9]{3}', 0)). Datas: com '/' é dd/MM/yyyy,
  senão é número de série do Excel: date_add(DATE'1899-12-30', CAST(x AS INT)).
  %: com '%' tire o '%' e troque vírgula por ponto; sem '%' é fração (× 100).
  Horas: tire o 'h'. TIRE a linha onde tarefa = 'TOTAL'.
- tarefas_clickup: projeto pelo de-para (codigo_ferramenta = list_id) e, se o
  código faltar, pelo nome da lista. Datas em milissegundos:
  to_date(timestamp_millis(CAST(x AS BIGINT))). % e baseline estão em
  custom_fields: filter(custom_fields, f -> f.name = 'Progresso (%)')[0].value
  (e 'Início baseline', 'Fim baseline', 'Fase'). Horas = time_estimate / 3600000.
  Status de 12 jeitos → concluida / a_fazer / em_andamento.
- tarefas_msproject: projeto pelo de-para (codigo_ferramenta = arquivo). Só
  Summary = 0 (as tarefas-resumo somam as de baixo). A fase é a última
  tarefa-resumo de OutlineLevel 1 antes da tarefa:
  last_value(CASE WHEN OutlineLevel = 1 THEN Name END, true) OVER (PARTITION
  BY arquivo ORDER BY UID). Baseline.Start/Finish, ActualStart/ActualFinish,
  PercentComplete, horas de 'PT40H0M0S'.
MATERIALIZED VIEW tarefas = UNION ALL das três, com tarefa_id
(projeto-ferramenta-id), pct_concluido = least(pct_como_veio, 100) e a flag
pct_veio_acima_de_100. EXPECT projeto_id IS NOT NULL (achou_o_projeto),
pct entre 0 e 100 e horas > 0, todos FAIL UPDATE.

03-status-e-custos.sql
- status_semanal: data_status DATE, farol em minúsculas (EXPECT farol IN
  ('verde','amarelo','vermelho') FAIL UPDATE), pct_concluido INT, flag
  status_vazio ('', 'N/A', 'ver ata da reunião') — NÃO descarte.
- custos: valor com 671 vírgulas decimais: replace(',', '.') ANTES do CAST,
  nunca try_cast. estorno (negativo) FICA, com a coluna estorno. semana =
  sexta da semana: date_add(date_trunc('WEEK', data), 4).

04-pessoas.sql
- colaboradores: COL0102, COL0257 e COL0433 aparecem duas vezes (nome e papel
  em CAIXA ALTA). Mantenha o cadastro com papel em minúsculas (row_number).
- apontamentos com semana = semana_inicio + 4 (sexta).

05-fornecedores.sql — entregas_fornecedor: a CodeForge vem de 4 jeitos
('CodeForge Consultoria Ltda', 'Codeforge Consultoria', 'CODEFORGE CONSULTORIA
LTDA', 'Code Forge Consultoria'): normalize (replace(lower(x), ' ', '') LIKE
'%codeforge%') e guarde fornecedor_como_veio. data_entrega vazia = em aberto
(não é sujeira). prazo_prometido_dias, prazo_real_dias,
dias_de_atraso_na_entrega, em_aberto e em_atraso (em aberto e data_prometida
antes de DATE'2026-10-16').

São 7 tabelas na silver, nem uma a mais: projetos, tarefas, status_semanal,
custos, colaboradores, apontamentos e entregas_fornecedor.

Acrescente ao job vertice_farol a tarefa medalhao (pipeline_task apontando
para ${resources.pipelines.vertice_medalhao.id}), depois de conferencia_bronze.

Trabalhe direto, sem testar cada SELECT antes do deploy: o EXPECT e o
pipeline são o teste. Se o pipeline falhar, leia o PRIMEIRO erro do evento,
corrija e rode de novo. Nunca dispare um run com outro ainda ativo: o Free
Edition tem limite de compute serverless (RESOURCE_EXHAUSTED).

Rode e me mostre a saída (a bronze já está carregada: a ingestão fica para
o prompt 3):
  databricks bundle validate --profile DEFAULT
  databricks bundle deploy --profile DEFAULT
  databricks bundle run vertice_farol --only conferencia_bronze,medalhao --profile DEFAULT
E no fim, numa tabela: cada tarefa, quanto tempo levou e o resultado.
O que conferir
-- as três ferramentas, num modelo só
SELECT ferramenta, COUNT(DISTINCT projeto_id) AS projetos, COUNT(*) AS tarefas
FROM lakehouse_vertice.silver.tarefas GROUP BY 1;
-- excel 20 · 1.643 | clickup 25 · 2.119 | msproject 15 · 1.155

-- a limpeza NÃO mudou o custo: o mesmo número da noite 1
SELECT ROUND(SUM(valor) / 1e6, 2) FROM lakehouse_vertice.silver.custos;               -- 193,35

SELECT COUNT(*), COUNT(DISTINCT colaborador_id) FROM lakehouse_vertice.silver.colaboradores;   -- 520 e 520
SELECT fornecedor, COUNT(DISTINCT fornecedor_como_veio) FROM lakehouse_vertice.silver.entregas_fornecedor
WHERE fornecedor LIKE 'CodeForge%' GROUP BY 1;                                         -- 1 fornecedor, 4 grafias
SELECT COUNT_IF(pct_veio_acima_de_100) FROM lakehouse_vertice.silver.tarefas;             -- 11