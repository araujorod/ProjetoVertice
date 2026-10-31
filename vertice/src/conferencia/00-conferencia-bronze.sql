-- Conferência da bronze, antes de montar a silver.
-- As 9 tabelas contra a contagem esperada (seed 42).
-- bronze.feriados fica de fora: cresce a cada execução.
-- Se alguma divergir, raise_error() derruba a tarefa e o medalhão não roda.

WITH esperado AS (
  SELECT * FROM VALUES
    ('projetos',             60),
    ('status_semanal',     3911),
    ('excel_tarefas',      1663),
    ('clickup_tarefas',    2119),
    ('msproject_tarefas',  1260),
    ('colaboradores',       523),
    ('apontamentos',      30883),
    ('custos',            23640),
    ('entregas_fornecedor', 640)
  AS t(tabela, esperado)
),
obtido AS (
  SELECT 'projetos' AS tabela, COUNT(*) AS obtido FROM lakehouse_vertice.bronze.projetos
  UNION ALL SELECT 'status_semanal',      COUNT(*) FROM lakehouse_vertice.bronze.status_semanal
  UNION ALL SELECT 'excel_tarefas',       COUNT(*) FROM lakehouse_vertice.bronze.excel_tarefas
  UNION ALL SELECT 'clickup_tarefas',     COUNT(*) FROM lakehouse_vertice.bronze.clickup_tarefas
  UNION ALL SELECT 'msproject_tarefas',   COUNT(*) FROM lakehouse_vertice.bronze.msproject_tarefas
  UNION ALL SELECT 'colaboradores',       COUNT(*) FROM lakehouse_vertice.bronze.colaboradores
  UNION ALL SELECT 'apontamentos',        COUNT(*) FROM lakehouse_vertice.bronze.apontamentos
  UNION ALL SELECT 'custos',              COUNT(*) FROM lakehouse_vertice.bronze.custos
  UNION ALL SELECT 'entregas_fornecedor', COUNT(*) FROM lakehouse_vertice.bronze.entregas_fornecedor
),
conferencia AS (
  SELECT e.tabela, e.esperado, coalesce(o.obtido, 0) AS obtido
  FROM esperado e
  LEFT JOIN obtido o USING (tabela)
)
-- Uma linha por tabela: esperado, obtido e se bateu.
-- Na primeira divergência, raise_error diz qual tabela e onde olhar.
SELECT
  tabela,
  esperado,
  obtido,
  CASE
    WHEN obtido = esperado THEN 'ok'
    ELSE raise_error(concat(
      'bronze.', tabela, ' diverge: esperado ', esperado, ', obtido ', obtido,
      '. Veja a saída da tarefa ingestao_data_lake.'))
  END AS resultado
FROM conferencia
ORDER BY tabela;
