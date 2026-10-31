-- =============================================================================
-- silver.entregas_fornecedor · as entregas das consultorias
-- =============================================================================

CREATE OR REFRESH MATERIALIZED VIEW entregas_fornecedor
COMMENT 'Entregas das consultorias contratadas: prometido × entregue. fornecedor normalizado (a CodeForge vinha de 4 jeitos, ver fornecedor_como_veio). data_entrega NULL = em aberto. em_atraso = em aberto com data prometida antes de 16/10/2026.'
AS
WITH tipado AS (
  SELECT
    entrega_id,
    projeto_id,
    -- sujeira 15: a mesma consultoria com 4 grafias
    CASE WHEN replace(lower(fornecedor), ' ', '') LIKE '%codeforge%'
         THEN 'CodeForge Consultoria Ltda'
         ELSE trim(fornecedor) END                         AS fornecedor,
    fornecedor                                             AS fornecedor_como_veio,
    item,
    CAST(replace(valor, ',', '.') AS DECIMAL(18, 2))       AS valor,
    to_date(nullif(trim(data_pedido), ''))                 AS data_pedido,
    to_date(nullif(trim(data_prometida), ''))              AS data_prometida,
    -- vazio = ainda não entregue (não é sujeira)
    to_date(nullif(trim(data_entrega), ''))                AS data_entrega,
    CAST(prazo_contratado_dias AS INT)                     AS prazo_contratado_dias,
    status
  FROM lakehouse_vertice.bronze.entregas_fornecedor
)
SELECT
  entrega_id,
  projeto_id,
  fornecedor,
  fornecedor_como_veio,
  item,
  valor,
  data_pedido,
  data_prometida,
  data_entrega,
  prazo_contratado_dias,
  status,
  datediff(data_prometida, data_pedido)                    AS prazo_prometido_dias,
  datediff(data_entrega,   data_pedido)                    AS prazo_real_dias,
  greatest(datediff(data_entrega, data_prometida), 0)      AS dias_de_atraso_na_entrega,
  data_entrega IS NULL                                     AS em_aberto,
  data_entrega IS NULL AND data_prometida < DATE'2026-10-16' AS em_atraso
FROM tipado;
