-- =============================================================================
-- gold.fato_projeto_semana · a evolução de cada projeto, sexta a sexta
-- Uma linha por projeto e semana, da semana do início até 16/10/2026.
-- O avanço de cada semana vem do STATUS SEMANAL (as ferramentas só guardam o
-- % de hoje); o planejado vem do baseline das tarefas; o custo, dos lançamentos.
-- Regra do pipeline: função de janela num CTE, agregação no CTE seguinte.
-- =============================================================================

CREATE OR REFRESH MATERIALIZED VIEW lakehouse_vertice.gold.fato_projeto_semana (
  CONSTRAINT pv_nao_negativo     EXPECT (pv >= 0)               ON VIOLATION FAIL UPDATE,
  CONSTRAINT ev_ate_o_orcamento  EXPECT (ev <= orcamento_custo) ON VIOLATION FAIL UPDATE
)
COMMENT 'Fato semanal do portfólio: uma linha por projeto e sexta-feira, do início do projeto até 16/10/2026. pv (valor planejado pelo baseline das tarefas), ev (valor agregado pelo % do status semanal daquela sexta), ac (custo real acumulado), spi = ev/pv, cpi = ev/ac, eac = orçamento/cpi, o farol do gerente e as horas disponíveis, apontadas e ociosas da semana.'
AS
WITH semanas AS (
  -- a grade: todas as sextas desde a semana do início até hoje
  SELECT
    p.projeto_id,
    p.orcamento_custo,
    explode(sequence(
      date_add(to_date(date_trunc('WEEK', p.data_inicio)), 4),  -- a sexta da semana do início
      DATE'2026-10-16',
      INTERVAL 1 WEEK
    )) AS semana
  FROM projetos p
),

pv_semana AS (
  -- PV = orçamento × fração das horas que o baseline mandava ter feito até a semana
  SELECT
    s.projeto_id,
    s.semana,
    s.orcamento_custo * sum(
      t.horas * greatest(0, least(1, try_divide(
        datediff(s.semana, t.inicio_baseline),
        datediff(t.fim_baseline, t.inicio_baseline))))
    ) / sum(t.horas) AS pv
  FROM semanas s
  JOIN tarefas t ON t.projeto_id = s.projeto_id
  GROUP BY s.projeto_id, s.semana, s.orcamento_custo
),

status_semana AS (
  -- projeto concluído para de publicar: repete o último % e o último farol
  SELECT
    s.projeto_id,
    s.semana,
    last_value(st.pct_concluido, true) OVER janela AS pct_concluido,
    last_value(st.farol, true)         OVER janela AS farol_do_gerente
  FROM semanas s
  LEFT JOIN status_semanal st
    ON st.projeto_id = s.projeto_id AND st.data_status = s.semana
  WINDOW janela AS (PARTITION BY s.projeto_id ORDER BY s.semana
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
),

custo_semana AS (
  SELECT projeto_id, semana, sum(valor) AS custo_da_semana
  FROM custos
  GROUP BY projeto_id, semana
),

custo_acumulado AS (
  -- AC = soma acumulada do custo até a semana (semana sem lançamento soma 0)
  SELECT
    s.projeto_id,
    s.semana,
    sum(coalesce(c.custo_da_semana, 0)) OVER (
      PARTITION BY s.projeto_id ORDER BY s.semana
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS ac
  FROM semanas s
  LEFT JOIN custo_semana c
    ON c.projeto_id = s.projeto_id AND c.semana = s.semana
),

horas_semana AS (
  SELECT
    projeto_id,
    semana,
    sum(horas_disponiveis) AS horas_disponiveis,
    sum(horas_apontadas)   AS horas_apontadas
  FROM apontamentos
  GROUP BY projeto_id, semana
),

valores AS (
  SELECT
    s.projeto_id,
    s.semana,
    s.orcamento_custo,
    pv.pv,
    s.orcamento_custo * coalesce(st.pct_concluido, 0) / 100 AS ev,
    ca.ac,
    st.farol_do_gerente,
    coalesce(h.horas_disponiveis, 0) AS horas_disponiveis,
    coalesce(h.horas_apontadas, 0)   AS horas_apontadas
  FROM semanas s
  JOIN pv_semana pv       ON pv.projeto_id = s.projeto_id AND pv.semana = s.semana
  JOIN status_semana st   ON st.projeto_id = s.projeto_id AND st.semana = s.semana
  JOIN custo_acumulado ca ON ca.projeto_id = s.projeto_id AND ca.semana = s.semana
  LEFT JOIN horas_semana h ON h.projeto_id = s.projeto_id AND h.semana = s.semana
)

SELECT
  projeto_id,
  semana,
  orcamento_custo,
  round(pv, 2)                          AS pv,
  round(ev, 2)                          AS ev,
  ac,
  round(try_divide(ev, pv), 4)          AS spi,   -- < 1 é atraso
  round(try_divide(ev, ac), 4)          AS cpi,   -- < 1 é estouro
  round(try_divide(orcamento_custo, round(try_divide(ev, ac), 4)), 2) AS eac,
  farol_do_gerente,
  horas_disponiveis,
  horas_apontadas,
  horas_disponiveis - horas_apontadas   AS horas_ociosas
FROM valores;
