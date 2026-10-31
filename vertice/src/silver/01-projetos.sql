-- =============================================================================
-- silver.projetos · o cadastro do PMO
-- É o de-para da integração: cada projeto diz em que ferramenta o gerente
-- controla as tarefas (excel, clickup ou msproject) e qual o código lá dentro
-- (nome do arquivo no Excel e no MS Project, list_id no ClickUp).
-- =============================================================================

CREATE OR REFRESH MATERIALIZED VIEW projetos (
  CONSTRAINT data_inicio_valida   EXPECT (data_inicio IS NOT NULL)                         ON VIOLATION FAIL UPDATE,
  CONSTRAINT ferramenta_conhecida EXPECT (ferramenta IN ('excel', 'clickup', 'msproject')) ON VIOLATION FAIL UPDATE
)
COMMENT 'Cadastro dos 60 projetos da Vértice (PMO): cliente, segmento, contrato, orçamento, datas e a ferramenta onde o gerente controla as tarefas. ferramenta e codigo_ferramenta são o de-para que integra Excel, ClickUp e MS Project em silver.tarefas.'
AS
SELECT
  projeto_id,
  nome_projeto,
  cliente,
  segmento,
  tipo_projeto,

  -- sujeira 2: a ferramenta escrita de 8 jeitos vira 3 valores
  CASE
    WHEN lower(ferramenta) LIKE '%click%'                                   THEN 'clickup'
    WHEN lower(ferramenta) LIKE '%project%' OR lower(ferramenta) LIKE '%mpp%' THEN 'msproject'
    WHEN lower(ferramenta) LIKE '%excel%'   OR lower(ferramenta) LIKE '%planilha%'
      OR lower(ferramenta) LIKE '%xls%'                                     THEN 'excel'
  END AS ferramenta,
  ferramenta AS ferramenta_como_veio,

  -- sujeira 3: código vazio vira NULL (o casamento cai no plano B em silver.tarefas)
  nullif(trim(codigo_ferramenta), '') AS codigo_ferramenta,

  CAST(replace(valor_contrato,  ',', '.') AS DECIMAL(18, 2)) AS valor_contrato,
  CAST(replace(orcamento_custo, ',', '.') AS DECIMAL(18, 2)) AS orcamento_custo,

  -- sujeira 1: data em yyyy-MM-dd e em dd/MM/yyyy
  coalesce(try_to_date(data_inicio, 'yyyy-MM-dd'),       try_to_date(data_inicio, 'dd/MM/yyyy'))       AS data_inicio,
  coalesce(try_to_date(data_fim_baseline, 'yyyy-MM-dd'), try_to_date(data_fim_baseline, 'dd/MM/yyyy')) AS data_fim_baseline,

  status,
  gerente_projeto
FROM lakehouse_vertice.bronze.projetos;
