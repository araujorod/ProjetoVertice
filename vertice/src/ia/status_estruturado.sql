-- =============================================================================
-- gold.status_estruturado: o texto livre do status semanal vira coluna
-- (sql_task no warehouse, caminho completo das tabelas)
--
-- Três métodos, do mais barato ao mais caro:
--   regra          texto vazio ou "sem bloqueio" (não precisa de IA)
--   palavra_chave  histórico antigo: RLIKE no trecho de bloqueio
--   ia             últimos 90 dias com bloqueio: ai_classify + ai_extract (~5 s cada)
--
-- A tabela ACUMULA: o MERGE só insere os status que ainda não estão nela,
-- então a IA roda uma vez por status, nunca de novo.
-- Atenção: a sql_task corta o arquivo em todo ponto e vírgula. Só há três,
-- um no fim de cada comando.
-- =============================================================================


-- a. A tabela (IF NOT EXISTS, nunca OR REPLACE: apagaria o que a IA já fez)
CREATE TABLE IF NOT EXISTS lakehouse_vertice.gold.status_estruturado (
  projeto_id       STRING    COMMENT 'Código do projeto (PRJ-xxx)',
  data_status      DATE      COMMENT 'Sexta do status semanal',
  farol            STRING    COMMENT 'Farol declarado pelo gerente: verde, amarelo ou vermelho',
  causa_bloqueio   STRING    COMMENT 'Causa do bloqueio: change_freeze, falta_sre, dependencia_fornecedor, rotatividade, mudanca_escopo, bug_retrabalho, aprovacao_cliente, sem_bloqueio, nao_reportado (status vazio) ou outro',
  bloqueio         STRING    COMMENT 'O bloqueio em uma frase (IA) ou o trecho após "Bloqueios:" do texto',
  quem_destrava    STRING    COMMENT 'Quem precisa agir para destravar (só nos status lidos pela IA)',
  dias_impacto     DOUBLE    COMMENT 'Dias de impacto no cronograma declarados no status (1 semana = 7)',
  metodo           STRING    COMMENT 'Como foi classificado: regra, ia (últimos 90 dias com bloqueio) ou palavra_chave (histórico)',
  texto_status     STRING    COMMENT 'Texto livre original do status semanal',
  _classificado_em TIMESTAMP COMMENT 'Quando a linha foi classificada (hora do processamento)'
)
COMMENT 'O status semanal de cada projeto com o texto livre estruturado em colunas: causa do bloqueio, o bloqueio, quem destrava e os dias de impacto. Responde à pergunta 3 (falta de gente aparece como falta_sre) e alimenta a 4. Incremental: cada status é classificado uma vez só.';


-- b. Só os status novos entram
MERGE INTO lakehouse_vertice.gold.status_estruturado AS alvo
USING (
  WITH

  -- 1 · os status da silver que ainda não estão na tabela
  novos AS (
    SELECT s.projeto_id, s.data_status, s.farol, s.texto_status, s.status_vazio
    FROM lakehouse_vertice.silver.status_semanal s
    LEFT ANTI JOIN lakehouse_vertice.gold.status_estruturado g
      ON s.projeto_id = g.projeto_id AND s.data_status = g.data_status
  ),

  -- 2 · decide o método e tira do texto o que dá para tirar sem IA
  com_metodo AS (
    SELECT
      *,
      CASE
        WHEN status_vazio
          OR lower(texto_status) RLIKE 'bloqueios: nenhum|sem bloqueios|nada relevante' THEN 'regra'
        WHEN data_status >= DATE'2026-07-18' THEN 'ia'     -- últimos 90 dias até 16/10/2026
        ELSE 'palavra_chave'
      END AS metodo,
      -- o trecho depois de "Bloqueios:" (assim a palavra-chave não casa com as entregas).
      -- (?i): há status escritos TODO EM MAIÚSCULAS ("BLOQUEIOS:")
      nullif(regexp_extract(texto_status, '(?i)Bloqueios: (.*)', 1), '') AS trecho_bloqueio,
      -- "Impacto estimado de 9 dias" ou "Impacto estimado: 1 semana"
      CASE
        WHEN lower(texto_status) RLIKE 'impacto estimado de [0-9]+ dias'
          THEN CAST(regexp_extract(lower(texto_status), 'impacto estimado de ([0-9]+) dias', 1) AS DOUBLE)
        WHEN lower(texto_status) LIKE '%impacto estimado: 1 semana%' THEN 7.0
      END AS dias_regex
    FROM novos
  ),

  -- 3 · a IA, SÓ nas linhas do método ia (~160, não nas 3.911)
  chamadas_ia AS (
    SELECT
      projeto_id,
      data_status,
      ai_classify(
        texto_status,
        '["change_freeze","falta_sre","dependencia_fornecedor","rotatividade","mudanca_escopo","bug_retrabalho","aprovacao_cliente","sem_bloqueio"]',
        map('version', '2.0')
      ) AS classificacao,
      ai_extract(
        texto_status,
        '{"bloqueio":{"type":"string","description":"o bloqueio do projeto em uma frase curta"},"quem_destrava":{"type":"string","description":"quem precisa agir para destravar (cliente, fornecedor, time de infraestrutura...)"},"dias_impacto":{"type":"number","description":"dias de impacto no cronograma, 1 semana = 7"}}',
        map('version', '2.0')
      ) AS extracao
    FROM com_metodo
    WHERE metodo = 'ia'
  ),

  -- o resultado da IA é VARIANT: lê-se com :response
  via_ia AS (
    SELECT
      projeto_id,
      data_status,
      classificacao:response[0]::STRING        AS ia_causa,
      extracao:response:bloqueio::STRING       AS ia_bloqueio,
      extracao:response:quem_destrava::STRING  AS ia_quem_destrava,
      extracao:response:dias_impacto::DOUBLE   AS ia_dias_impacto
    FROM chamadas_ia
  )

  -- 4 · junta tudo, uma linha por status
  SELECT
    m.projeto_id,
    m.data_status,
    m.farol,
    CASE
      WHEN m.status_vazio      THEN 'nao_reportado'
      WHEN m.metodo = 'regra'  THEN 'sem_bloqueio'
      WHEN m.metodo = 'ia'     THEN i.ia_causa
      -- palavra-chave, na ordem: o primeiro que casar vence
      WHEN lower(m.trecho_bloqueio) RLIKE 'freeze|congelamento|janela de deploy'               THEN 'change_freeze'
      WHEN lower(m.trecho_bloqueio) RLIKE '\\bsre\\b|infraestrutura|ambiente de homologação'   THEN 'falta_sre'
      WHEN lower(m.trecho_bloqueio) RLIKE 'forge|consultoria|fornecedor'                       THEN 'dependencia_fornecedor'
      WHEN lower(m.trecho_bloqueio) RLIKE 'saída de|rotatividade|onboarding'                   THEN 'rotatividade'
      WHEN lower(m.trecho_bloqueio) RLIKE 'escopo|change request|regra de negócio'             THEN 'mudanca_escopo'
      WHEN lower(m.trecho_bloqueio) RLIKE 'bugs|regressão|refazendo'                           THEN 'bug_retrabalho'
      WHEN lower(m.trecho_bloqueio) RLIKE 'aprovação do cliente|homologação do cliente'        THEN 'aprovacao_cliente'
      ELSE 'outro'
    END                                                         AS causa_bloqueio,
    CASE WHEN m.metodo = 'ia' THEN i.ia_bloqueio
         WHEN m.status_vazio THEN NULL
         ELSE m.trecho_bloqueio END                             AS bloqueio,
    i.ia_quem_destrava                                          AS quem_destrava,
    coalesce(i.ia_dias_impacto, m.dias_regex)                   AS dias_impacto,
    m.metodo,
    m.texto_status,
    current_timestamp()                                         AS _classificado_em
  FROM com_metodo m
  LEFT JOIN via_ia i
    ON m.projeto_id = i.projeto_id AND m.data_status = i.data_status
) AS novo
ON alvo.projeto_id = novo.projeto_id AND alvo.data_status = novo.data_status
WHEN NOT MATCHED THEN INSERT *;


-- c. Leitura: quantos status por método e causa
SELECT metodo, causa_bloqueio, count(*) AS status, round(sum(dias_impacto), 0) AS dias_impacto
FROM lakehouse_vertice.gold.status_estruturado
GROUP BY metodo, causa_bloqueio
ORDER BY metodo, status DESC;
