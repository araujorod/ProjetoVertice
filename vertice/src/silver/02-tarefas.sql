-- =============================================================================
-- silver.tarefas · AS TRÊS FERRAMENTAS VIRAM UMA
-- Uma visão temporária por ferramenta, todas com as MESMAS 13 colunas:
--   projeto_id, ferramenta, id_na_ferramenta, fase, tarefa, responsavel,
--   inicio_baseline, fim_baseline, inicio_real, fim_real,
--   pct_como_veio, horas, status_na_ferramenta
-- e no fim um UNION ALL numa materialized view.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Excel · 20 planilhas, tudo texto
-- -----------------------------------------------------------------------------
CREATE TEMPORARY VIEW tarefas_excel AS
WITH limpas AS (
  SELECT
    -- de-para pelo nome do arquivo e, se não casar (código vazio ou o arquivo
    -- chegou sem acento), o PRJ-xxx do próprio nome do arquivo
    coalesce(p.projeto_id, regexp_extract(e.arquivo, 'PRJ-[0-9]{3}', 0)) AS projeto_id,
    'excel'                     AS ferramenta,
    CAST(e.id AS STRING)        AS id_na_ferramenta,
    e.fase,
    e.tarefa,
    e.responsavel,

    -- sujeira 4: com '/' é dd/MM/yyyy, senão é número de série do Excel
    CASE WHEN e.inicio_previsto  LIKE '%/%' THEN to_date(e.inicio_previsto,  'dd/MM/yyyy')
         ELSE date_add(DATE'1899-12-30', CAST(nullif(trim(e.inicio_previsto), '')  AS INT)) END AS inicio_baseline,
    CASE WHEN e.termino_previsto LIKE '%/%' THEN to_date(e.termino_previsto, 'dd/MM/yyyy')
         ELSE date_add(DATE'1899-12-30', CAST(nullif(trim(e.termino_previsto), '') AS INT)) END AS fim_baseline,
    CASE WHEN e.inicio_real      LIKE '%/%' THEN to_date(e.inicio_real,      'dd/MM/yyyy')
         ELSE date_add(DATE'1899-12-30', CAST(nullif(trim(e.inicio_real), '')  AS INT)) END AS inicio_real,
    CASE WHEN e.termino_real     LIKE '%/%' THEN to_date(e.termino_real,     'dd/MM/yyyy')
         ELSE date_add(DATE'1899-12-30', CAST(nullif(trim(e.termino_real), '') AS INT)) END AS fim_real,

    -- sujeira 5: '45%' ou '10,5%' → tira o % e troca a vírgula; 0.45 → × 100
    CASE WHEN contains(e.pct_concluido, '%')
         THEN CAST(replace(replace(e.pct_concluido, '%', ''), ',', '.') AS DOUBLE)
         ELSE CAST(e.pct_concluido AS DOUBLE) * 100 END AS pct_como_veio,

    -- sujeira 7: horas '40h'
    CAST(replace(e.horas_previstas, 'h', '') AS DOUBLE) AS horas
  FROM lakehouse_vertice.bronze.excel_tarefas e
  LEFT JOIN projetos p
    ON p.ferramenta = 'excel' AND p.codigo_ferramenta = e.arquivo
  -- sujeira 6: a linha de TOTAL no fim de cada planilha
  WHERE e.tarefa <> 'TOTAL'
)
SELECT
  projeto_id, ferramenta, id_na_ferramenta, fase, tarefa, responsavel,
  inicio_baseline, fim_baseline, inicio_real, fim_real,
  pct_como_veio, horas,
  -- a planilha não tem status: deriva do %
  CASE WHEN pct_como_veio >= 100 THEN 'concluida'
       WHEN pct_como_veio <= 0   THEN 'a_fazer'
       ELSE 'em_andamento' END AS status_na_ferramenta
FROM limpas;


-- -----------------------------------------------------------------------------
-- ClickUp · 25 listas, datas em milissegundos, % e baseline em custom_fields
-- -----------------------------------------------------------------------------
CREATE TEMPORARY VIEW tarefas_clickup AS
SELECT
  -- de-para pelo list_id e, se o código faltar, pelo nome da lista
  coalesce(p_id.projeto_id, p_nome.projeto_id) AS projeto_id,
  'clickup' AS ferramenta,
  c.id      AS id_na_ferramenta,
  filter(c.custom_fields, f -> f.name = 'Fase')[0].value AS fase,
  c.name    AS tarefa,
  c.assignees[0].username AS responsavel,

  -- sujeira 8: datas em ms (o baseline mora em custom_fields)
  to_date(timestamp_millis(CAST(filter(c.custom_fields, f -> f.name = 'Início baseline')[0].value AS BIGINT))) AS inicio_baseline,
  to_date(timestamp_millis(CAST(filter(c.custom_fields, f -> f.name = 'Fim baseline')[0].value    AS BIGINT))) AS fim_baseline,
  to_date(timestamp_millis(CAST(nullif(trim(c.start_date), '') AS BIGINT))) AS inicio_real,
  to_date(timestamp_millis(CAST(nullif(trim(c.date_done), '')  AS BIGINT))) AS fim_real,

  CAST(filter(c.custom_fields, f -> f.name = 'Progresso (%)')[0].value AS DOUBLE) AS pct_como_veio,
  c.time_estimate / 3600000.0 AS horas,

  -- sujeira 9: status de 12 jeitos → 3
  CASE
    WHEN lower(trim(c.status.status)) IN ('done', 'closed', 'concluído', 'concluido', 'complete')     THEN 'concluida'
    WHEN lower(trim(c.status.status)) IN ('to do', 'a fazer', 'backlog', 'open')                      THEN 'a_fazer'
    WHEN lower(trim(c.status.status)) IN ('in progress', 'doing', 'em andamento', 'review')           THEN 'em_andamento'
  END AS status_na_ferramenta
FROM lakehouse_vertice.bronze.clickup_tarefas c
LEFT JOIN projetos p_id
  ON p_id.ferramenta = 'clickup' AND p_id.codigo_ferramenta = c.list_id
LEFT JOIN projetos p_nome
  ON p_nome.ferramenta = 'clickup' AND p_nome.codigo_ferramenta IS NULL AND p_nome.nome_projeto = c.list_name;


-- -----------------------------------------------------------------------------
-- MS Project · 15 XML, tarefas-resumo e fase pela hierarquia
-- -----------------------------------------------------------------------------
CREATE TEMPORARY VIEW tarefas_msproject AS
WITH com_fase AS (
  -- sujeira 11: a fase é a última tarefa-resumo de nível 1 antes da tarefa
  -- (a janela roda sobre TODAS as linhas, antes de tirar as tarefas-resumo)
  SELECT
    m.*,
    last_value(CASE WHEN m.OutlineLevel = 1 THEN m.Name END, true)
      OVER (PARTITION BY m.arquivo ORDER BY m.UID) AS fase
  FROM lakehouse_vertice.bronze.msproject_tarefas m
)
SELECT
  p.projeto_id,
  'msproject'              AS ferramenta,
  CAST(f.UID AS STRING)    AS id_na_ferramenta,
  f.fase,
  f.Name                   AS tarefa,
  CAST(NULL AS STRING)     AS responsavel,
  to_date(f.Baseline.Start)  AS inicio_baseline,
  to_date(f.Baseline.Finish) AS fim_baseline,
  to_date(f.ActualStart)     AS inicio_real,
  to_date(f.ActualFinish)    AS fim_real,
  CAST(f.PercentComplete AS DOUBLE) AS pct_como_veio,
  -- sujeira 12: horas em 'PT40H0M0S'
  CAST(regexp_extract(f.Work, 'PT([0-9]+)H', 1) AS DOUBLE) AS horas,
  CASE WHEN f.PercentComplete >= 100 THEN 'concluida'
       WHEN f.PercentComplete <= 0   THEN 'a_fazer'
       ELSE 'em_andamento' END AS status_na_ferramenta
FROM com_fase f
LEFT JOIN projetos p
  ON p.ferramenta = 'msproject' AND p.codigo_ferramenta = f.arquivo
-- sujeira 10: as tarefas-resumo somam as horas de baixo
WHERE f.Summary = 0;


-- -----------------------------------------------------------------------------
-- A integração: as três num modelo só
-- -----------------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW tarefas (
  CONSTRAINT achou_o_projeto EXPECT (projeto_id IS NOT NULL)            ON VIOLATION FAIL UPDATE,
  CONSTRAINT pct_entre_0_100 EXPECT (pct_concluido BETWEEN 0 AND 100)   ON VIOLATION FAIL UPDATE,
  CONSTRAINT horas_positivas EXPECT (horas > 0)                         ON VIOLATION FAIL UPDATE
)
COMMENT 'Tarefas dos 60 projetos num modelo só: Excel (20 projetos), ClickUp (25) e MS Project (15) integrados pelo de-para de silver.projetos. Uma linha por tarefa folha, com baseline, real, % concluído (limitado a 100, com a flag pct_veio_acima_de_100) e horas previstas.'
AS
WITH tudo AS (
  SELECT * FROM tarefas_excel
  UNION ALL
  SELECT * FROM tarefas_clickup
  UNION ALL
  SELECT * FROM tarefas_msproject
)
SELECT
  concat_ws('-', projeto_id, ferramenta, id_na_ferramenta) AS tarefa_id,
  projeto_id,
  ferramenta,
  id_na_ferramenta,
  fase,
  tarefa,
  responsavel,
  inicio_baseline,
  fim_baseline,
  inicio_real,
  fim_real,
  pct_como_veio,
  least(pct_como_veio, 100.0)          AS pct_concluido,
  coalesce(pct_como_veio > 100, false) AS pct_veio_acima_de_100,
  horas,
  status_na_ferramenta
FROM tudo;
