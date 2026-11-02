-- Testes de qualidade, depois do medalhão (sql_task no warehouse).
-- Cada teste devolve uma linha: o que se esperava, o que se obteve e se passou.
-- No primeiro que falhar, raise_error() derruba a tarefa e diz qual foi.

WITH

-- 1 · os 60 projetos têm cronograma na silver.tarefas
t01 AS (
  SELECT '01 projetos com cronograma' AS teste, '60' AS esperado,
         CAST(count(DISTINCT projeto_id) AS STRING) AS obtido,
         count(DISTINCT projeto_id) = 60 AS passou
  FROM lakehouse_vertice.silver.tarefas
),

-- 2 · cada projeto veio de UMA ferramenta, a do cadastro do PMO
t02 AS (
  SELECT '02 uma ferramenta por projeto, a do cadastro' AS teste, '0 divergentes' AS esperado,
         concat(count(*), ' divergentes') AS obtido,
         count(*) = 0 AS passou
  FROM (
    SELECT t.projeto_id
    FROM lakehouse_vertice.silver.tarefas t
    JOIN lakehouse_vertice.silver.projetos p USING (projeto_id)
    GROUP BY t.projeto_id
    HAVING count(DISTINCT t.ferramenta) <> 1 OR max(t.ferramenta) <> max(p.ferramenta)
  )
),

-- 3 · as horas do Excel na silver = a soma das linhas de TOTAL das planilhas
t03 AS (
  SELECT '03 horas do Excel = linhas de TOTAL' AS teste,
         CAST(b.total AS STRING) AS esperado, CAST(s.horas AS STRING) AS obtido,
         s.horas = b.total AS passou
  FROM (SELECT sum(horas) AS horas FROM lakehouse_vertice.silver.tarefas WHERE ferramenta = 'excel') s
  CROSS JOIN (SELECT sum(CAST(replace(horas_previstas, 'h', '') AS DOUBLE)) AS total
              FROM lakehouse_vertice.bronze.excel_tarefas WHERE tarefa = 'TOTAL') b
),

-- 4 · uma linha por pessoa na silver
t04 AS (
  SELECT '04 uma linha por pessoa' AS teste,
         CAST(count(DISTINCT colaborador_id) AS STRING) AS esperado,
         CAST(count(*) AS STRING) AS obtido,
         count(*) = count(DISTINCT colaborador_id) AS passou
  FROM lakehouse_vertice.silver.colaboradores
),

-- 5 · a CodeForge virou um fornecedor só
t05 AS (
  SELECT '05 CodeForge com uma grafia' AS teste, '1' AS esperado,
         CAST(count(DISTINCT fornecedor) AS STRING) AS obtido,
         count(DISTINCT fornecedor) = 1 AS passou
  FROM lakehouse_vertice.silver.entregas_fornecedor
  WHERE replace(lower(fornecedor), ' ', '') LIKE '%codeforge%'
),

-- 6 · a limpeza não mudou o custo total (bronze com replace = silver)
t06 AS (
  SELECT '06 custo total bronze = silver' AS teste,
         CAST(b.total AS STRING) AS esperado, CAST(s.total AS STRING) AS obtido,
         b.total = s.total AS passou
  FROM (SELECT sum(CAST(replace(valor, ',', '.') AS DECIMAL(18, 2))) AS total
        FROM lakehouse_vertice.bronze.custos) b
  CROSS JOIN (SELECT sum(valor) AS total FROM lakehouse_vertice.silver.custos) s
),

-- 7 · os 60 projetos têm fotografia de hoje
t07 AS (
  SELECT '07 fotografia dos 60 projetos' AS teste, '60' AS esperado,
         CAST(count(DISTINCT projeto_id) AS STRING) AS obtido,
         count(DISTINCT projeto_id) = 60 AND count(*) = 60 AS passou
  FROM lakehouse_vertice.gold.projeto_situacao_atual
),

-- 8 · todo projeto em andamento tem SPI e CPI
t08 AS (
  SELECT '08 em andamento com SPI e CPI' AS teste, '0 sem índice' AS esperado,
         concat(count_if(spi IS NULL OR cpi IS NULL), ' sem índice') AS obtido,
         count_if(spi IS NULL OR cpi IS NULL) = 0 AS passou
  FROM lakehouse_vertice.gold.projeto_situacao_atual
  WHERE status = 'em_andamento'
),

-- 9 · o EV de hoje do status semanal bate com o das ferramentas (carteira em
--     andamento, diferença < 1%)
t09 AS (
  SELECT '09 EV status = EV ferramentas (< 1%)' AS teste, '< 1%' AS esperado,
         concat(round(100 * abs(f.ev - s.ev) / s.ev, 2), '%') AS obtido,
         abs(f.ev - s.ev) / s.ev < 0.01 AS passou
  FROM (SELECT sum(ev) AS ev FROM lakehouse_vertice.gold.projeto_situacao_atual
        WHERE status = 'em_andamento') s
  CROSS JOIN (
    SELECT sum(f.ev) AS ev
    FROM lakehouse_vertice.gold.fato_projeto_semana f
    JOIN lakehouse_vertice.silver.projetos p USING (projeto_id)
    WHERE f.semana = DATE'2026-10-16' AND p.status = 'em_andamento'
  ) f
),

-- 10 · AC de hoje no fato = soma dos lançamentos até hoje
t10 AS (
  SELECT '10 AC de hoje = lançamentos até hoje' AS teste,
         CAST(c.total AS STRING) AS esperado, CAST(f.total AS STRING) AS obtido,
         f.total = c.total AS passou
  FROM (SELECT sum(ac) AS total FROM lakehouse_vertice.gold.fato_projeto_semana
        WHERE semana = DATE'2026-10-16') f
  CROSS JOIN (SELECT sum(valor) AS total FROM lakehouse_vertice.silver.custos
              WHERE data <= DATE'2026-10-16') c
),

todos AS (
  SELECT * FROM t01 UNION ALL SELECT * FROM t02 UNION ALL SELECT * FROM t03
  UNION ALL SELECT * FROM t04 UNION ALL SELECT * FROM t05 UNION ALL SELECT * FROM t06
  UNION ALL SELECT * FROM t07 UNION ALL SELECT * FROM t08 UNION ALL SELECT * FROM t09
  UNION ALL SELECT * FROM t10
)

SELECT
  teste,
  esperado,
  obtido,
  CASE
    WHEN coalesce(passou, false) THEN 'ok'
    ELSE raise_error(concat('Teste ', teste, ' falhou: esperado ', esperado, ', obtido ', coalesce(obtido, 'NULL')))
  END AS resultado
FROM todos
ORDER BY teste;
