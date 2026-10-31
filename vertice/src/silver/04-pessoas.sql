-- =============================================================================
-- silver.colaboradores e silver.apontamentos
-- =============================================================================


-- sujeira 16: COL0102, COL0257 e COL0433 aparecem duas vezes (a cópia tem nome
-- e papel em CAIXA ALTA). Fica o cadastro com o papel em minúsculas.
CREATE OR REFRESH MATERIALIZED VIEW colaboradores
COMMENT 'As 520 pessoas da Vértice, uma linha por colaborador_id: papel, senioridade, custo por hora, admissão e desligamento (NULL = ativo).'
AS
WITH numerado AS (
  SELECT
    *,
    row_number() OVER (
      PARTITION BY colaborador_id
      ORDER BY CASE WHEN papel = lower(papel) THEN 0 ELSE 1 END
    ) AS rn
  FROM lakehouse_vertice.bronze.colaboradores
)
SELECT
  colaborador_id,
  nome,
  papel,
  senioridade,
  CAST(replace(custo_hora, ',', '.') AS DECIMAL(10, 2)) AS custo_hora,
  to_date(nullif(trim(data_admissao), ''))     AS data_admissao,
  to_date(nullif(trim(data_desligamento), '')) AS data_desligamento
FROM numerado
WHERE rn = 1;


-- O timesheet semanal.
CREATE OR REFRESH MATERIALIZED VIEW apontamentos
COMMENT 'Timesheet semanal: horas disponíveis e apontadas por pessoa e projeto. semana é a sexta da semana (semana_inicio + 4), a mesma chave do status semanal.'
AS
SELECT
  colaborador_id,
  projeto_id,
  to_date(semana_inicio)                  AS semana_inicio,
  date_add(to_date(semana_inicio), 4)     AS semana,
  CAST(horas_disponiveis AS DOUBLE)       AS horas_disponiveis,
  CAST(horas_apontadas   AS DOUBLE)       AS horas_apontadas
FROM lakehouse_vertice.bronze.apontamentos;
