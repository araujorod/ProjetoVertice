-- =============================================================================
-- silver.status_semanal e silver.custos
-- =============================================================================


-- O status que o gerente manda toda sexta. É o histórico do avanço.
CREATE OR REFRESH MATERIALIZED VIEW status_semanal (
  CONSTRAINT farol_valido EXPECT (farol IN ('verde', 'amarelo', 'vermelho')) ON VIOLATION FAIL UPDATE
)
COMMENT 'Status semanal (toda sexta) de cada projeto: % concluído declarado, farol do gerente (verde, amarelo ou vermelho) e o texto livre com bloqueios. status_vazio marca o texto vazio, N/A ou "ver ata da reunião" (a linha é mantida).'
AS
SELECT
  projeto_id,
  coalesce(try_to_date(data_status, 'yyyy-MM-dd'), try_to_date(data_status, 'dd/MM/yyyy')) AS data_status,
  gerente,
  -- sujeira 17: 'Verde', 'VERDE'
  lower(trim(farol))           AS farol,
  CAST(pct_concluido AS INT)   AS pct_concluido,
  texto_status,
  -- sujeira 18: NÃO descarta, só sinaliza
  coalesce(trim(texto_status), '') IN ('', 'N/A', 'ver ata da reunião') AS status_vazio
FROM lakehouse_vertice.bronze.status_semanal;


-- Os lançamentos de custo real.
CREATE OR REFRESH MATERIALIZED VIEW custos
COMMENT 'Lançamentos de custo real dos projetos (pessoal, consultoria, cloud, licenças, despesas). valor é líquido: o estorno (negativo) fica, marcado em estorno. semana é a sexta da semana do lançamento. Total: R$ 193,35 mi.'
AS
WITH tipado AS (
  SELECT
    lancamento_id,
    projeto_id,
    to_date(data) AS data,
    categoria,
    descricao,
    -- sujeira 13: 671 valores com vírgula decimal. replace ANTES do CAST,
    -- nunca try_cast (jogaria R$ 5,4 mi fora em silêncio)
    CAST(replace(valor, ',', '.') AS DECIMAL(18, 2)) AS valor,
    centro_custo
  FROM lakehouse_vertice.bronze.custos
)
SELECT
  lancamento_id,
  projeto_id,
  data,
  -- a sexta da semana do lançamento
  date_add(to_date(date_trunc('WEEK', data)), 4) AS semana,
  categoria,
  descricao,
  valor,
  -- sujeira 14: o estorno fica (custo é líquido), só sinaliza
  valor < 0 AS estorno,
  centro_custo
FROM tipado;
