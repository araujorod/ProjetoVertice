-- =============================================================================
-- gold.projeto_situacao_atual e gold.utilizacao_pessoa_semana
-- =============================================================================


-- -----------------------------------------------------------------------------
-- A fotografia de hoje (16/10/2026): uma linha por projeto, com o cadastro e os
-- KPIs calculados sobre as tarefas das ferramentas (o % de HOJE de cada tarefa).
-- Responde às perguntas 1 e 2 do dono: quem está atrasado e quanto vai custar.
-- -----------------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW lakehouse_vertice.gold.projeto_situacao_atual (
  CONSTRAINT projeto_identificado EXPECT (projeto_id IS NOT NULL) ON VIOLATION FAIL UPDATE
)
COMMENT 'Fotografia de 16/10/2026 dos 60 projetos: cadastro (cliente, segmento, tipo, ferramenta, gerente, contrato, orçamento, prazo) e os KPIs de hoje calculados sobre as tarefas das ferramentas: pv, ev, ac, spi, cpi, eac, estouro_previsto, margem_projetada, atraso_projetado_dias, termino_projetado. situacao: concluído, crítico (SPI ou CPI < 0,8), atenção (< 0,9) ou ok. farol_calculado segue o manual da Vértice (verde >= 0,95, amarelo >= 0,90). melancia = em andamento, farol do gerente verde e SPI < 0,9.'
AS
WITH avanco_hoje AS (
  -- frações do projeto, ponderadas pelas horas de cada tarefa
  SELECT
    projeto_id,
    sum(horas * pct_concluido / 100) / sum(horas) AS fracao_executada,
    sum(horas * greatest(0, least(1, try_divide(
          datediff(DATE'2026-10-16', inicio_baseline),
          datediff(fim_baseline, inicio_baseline))))) / sum(horas) AS fracao_planejada
  FROM tarefas
  GROUP BY projeto_id
),

custo_ate_hoje AS (
  SELECT projeto_id, sum(valor) AS ac
  FROM custos
  WHERE data <= DATE'2026-10-16'
  GROUP BY projeto_id
),

ultimo_status AS (
  SELECT projeto_id, max_by(farol, data_status) AS farol_do_gerente
  FROM status_semanal
  WHERE data_status <= DATE'2026-10-16'
  GROUP BY projeto_id
),

kpis AS (
  SELECT
    p.*,
    datediff(p.data_fim_baseline, p.data_inicio)        AS duracao_baseline_dias,
    round(p.orcamento_custo * a.fracao_planejada, 2)    AS pv,
    round(p.orcamento_custo * a.fracao_executada, 2)    AS ev,
    coalesce(c.ac, 0)                                   AS ac,
    s.farol_do_gerente
  FROM projetos p
  LEFT JOIN avanco_hoje a    USING (projeto_id)
  LEFT JOIN custo_ate_hoje c USING (projeto_id)
  LEFT JOIN ultimo_status s  USING (projeto_id)
),

indices AS (
  SELECT
    *,
    round(try_divide(ev, pv), 4) AS spi,
    round(try_divide(ev, ac), 4) AS cpi
  FROM kpis
),

projecoes AS (
  SELECT
    *,
    round(try_divide(orcamento_custo, cpi), 2)                     AS eac,
    round(try_divide(duracao_baseline_dias, spi) - duracao_baseline_dias, 0) AS atraso_projetado_dias
  FROM indices
)

SELECT
  projeto_id,
  concat(projeto_id, ' · ', nome_projeto)          AS projeto,
  nome_projeto,
  cliente,
  segmento,
  tipo_projeto,
  ferramenta,
  gerente_projeto,
  valor_contrato,
  orcamento_custo                                  AS orcamento,
  data_inicio,
  data_fim_baseline,
  duracao_baseline_dias,
  status,
  pv,
  ev,
  ac,
  spi,
  cpi,
  eac,
  greatest(eac - orcamento_custo, 0)               AS estouro_previsto,
  round(try_divide(valor_contrato - eac, valor_contrato), 4) AS margem_projetada,
  atraso_projetado_dias,
  date_add(data_fim_baseline, CAST(atraso_projetado_dias AS INT)) AS termino_projetado,
  CASE
    WHEN status <> 'em_andamento' THEN 'concluído'
    WHEN spi < 0.8 OR cpi < 0.8   THEN 'crítico'
    WHEN spi < 0.9 OR cpi < 0.9   THEN 'atenção'
    ELSE 'ok'
  END                                              AS situacao,
  farol_do_gerente,
  -- regra do manual da Vértice
  CASE
    WHEN spi >= 0.95 THEN 'verde'
    WHEN spi >= 0.90 THEN 'amarelo'
    ELSE 'vermelho'
  END                                              AS farol_calculado,
  -- melancia: verde por fora (farol do gerente), vermelho por dentro (SPI)
  coalesce(status = 'em_andamento' AND farol_do_gerente = 'verde' AND spi < 0.9, false) AS melancia
FROM projecoes;


-- -----------------------------------------------------------------------------
-- Uso das pessoas: pessoa × projeto × semana. Responde à pergunta 3:
-- tenho gente parada (horas ociosas) enquanto outro projeto pede gente?
-- -----------------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW lakehouse_vertice.gold.utilizacao_pessoa_semana
COMMENT 'Uso das pessoas por projeto e semana (sexta): nome, papel e senioridade do colaborador, horas disponíveis, apontadas e ociosas, utilizacao (apontadas ÷ disponíveis, de 0 a 1), custo_ocioso (horas ociosas × custo por hora) e o spi_do_projeto naquela semana (de gold.fato_projeto_semana).'
AS
SELECT
  a.colaborador_id,
  c.nome,
  c.papel,
  c.senioridade,
  a.projeto_id,
  a.semana,
  a.horas_disponiveis,
  a.horas_apontadas,
  a.horas_disponiveis - a.horas_apontadas                         AS horas_ociosas,
  round(try_divide(a.horas_apontadas, a.horas_disponiveis), 4)    AS utilizacao,
  round((a.horas_disponiveis - a.horas_apontadas) * c.custo_hora, 2) AS custo_ocioso,
  f.spi                                                           AS spi_do_projeto
FROM apontamentos a
LEFT JOIN colaboradores c
  ON c.colaborador_id = a.colaborador_id
LEFT JOIN lakehouse_vertice.gold.fato_projeto_semana f
  ON f.projeto_id = a.projeto_id AND f.semana = a.semana;
