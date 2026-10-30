-- Medida do ensaio preliminar (Passo 6).
--
-- Junta o que o cliente registou (results/<condicao>.csv, carregado na tabela
-- pedidos_cliente pelo medir.sh) com o que ficou gravado em charges. A lista de
-- pedidos lógicos vem do cliente: só assim se contam os pedidos que não deixaram
-- nenhuma linha em charges.
--
-- A condição é o run_id sem o sufixo da repetição ("C-rede-07" -> "C-rede").
--
-- Definições:
--   duplicados          linhas em charges - pedidos lógicos com pelo menos uma linha
--   pedido duplicado    pedido lógico com 2 ou mais linhas
--   réplica da linha    a que executou o INSERT (coluna replica)
--   linha original      a primeira linha do pedido por ordem de id; as tentativas
--                       de um pedido são sequenciais, por isso a ordem de id é a
--                       ordem das tentativas

SET client_min_messages = warning;

DROP TABLE IF EXISTS pedidos_cliente CASCADE;

CREATE TABLE pedidos_cliente (
    run_id                   text NOT NULL,
    request_no               int  NOT NULL,
    tentativas               int  NOT NULL,
    resultado_final          text NOT NULL,
    replicas_que_responderam text,
    jsonrpc_ids              text NOT NULL,
    resultados_tentativas    text NOT NULL,
    duracao_ms               int  NOT NULL,
    PRIMARY KEY (run_id, request_no)
);

-- Registo do cliente de teste (results/*_trace.jsonl), uma linha JSON por
-- tentativa, com a rota por onde passou o pedido. Só é usado para a latência.
DROP TABLE IF EXISTS tentativas_cliente CASCADE;

CREATE TABLE tentativas_cliente (
    rota  text,          -- preenchida pelo medir.sh depois de carregar cada ficheiro
    linha jsonb NOT NULL
);

-- Latência de um tools/call sem falhas (emenda 4 do plano): duração do call_tool
-- no cliente, das tentativas com resposta ok. Base para o custo aceitável do gateway.
-- A 1.ª chamada de cada repetição é mais lenta (Client novo, primeiro tools/call);
-- por isso mostra-se também a latência sem ela.
CREATE VIEW latencia AS
WITH t AS (
    SELECT rota,
           (linha->>'duracao_ms')::float AS ms,
           (linha->>'request_no')::int = 1 AND (linha->>'tentativa')::int = 1 AS primeira
    FROM tentativas_cliente
    WHERE linha->>'resultado' = 'ok'
)
SELECT rota,
       count(*)                                                                         AS chamadas,
       round(percentile_cont(0.5)  WITHIN GROUP (ORDER BY ms)::numeric, 2)              AS mediana_ms,
       round(percentile_cont(0.95) WITHIN GROUP (ORDER BY ms)::numeric, 2)              AS p95_ms,
       count(*) FILTER (WHERE NOT primeira)                                             AS chamadas_sem_primeira,
       round((percentile_cont(0.5)  WITHIN GROUP (ORDER BY ms) FILTER (WHERE NOT primeira))::numeric, 2) AS mediana_sem_primeira_ms,
       round((percentile_cont(0.95) WITHIN GROUP (ORDER BY ms) FILTER (WHERE NOT primeira))::numeric, 2) AS p95_sem_primeira_ms,
       coalesce(array_position(ARRAY['toxiproxy + nginx', 'nginx', 'direto'], rota), 99) AS ordem
FROM t
GROUP BY rota;

CREATE VIEW latencia_md AS
SELECT -2 AS k, '| Rota | Chamadas | Mediana | p95 | Mediana sem a 1.ª chamada | p95 sem a 1.ª chamada |' AS linha
UNION ALL
SELECT -1, '|---|---:|---:|---:|---:|---:|'
UNION ALL
SELECT ordem,
       format('| %s | %s | %s ms | %s ms | %s ms | %s ms |', rota, chamadas,
              replace(mediana_ms::text, '.', ','), replace(p95_ms::text, '.', ','),
              replace(mediana_sem_primeira_ms::text, '.', ','), replace(p95_sem_primeira_ms::text, '.', ','))
FROM latencia;

-- Uma linha por pedido lógico.
CREATE VIEW medida_por_pedido AS
WITH linhas AS (
    SELECT run_id, request_no, id, replica,
           row_number()         OVER w AS ordem,
           first_value(replica) OVER w AS replica_original,
           lag(replica)         OVER w AS replica_anterior
    FROM charges
    WINDOW w AS (PARTITION BY run_id, request_no ORDER BY id)
)
SELECT regexp_replace(p.run_id, '-[0-9]+$', '') AS condicao,
       p.run_id,
       p.request_no,
       p.resultado_final,
       count(l.id)                                                             AS linhas,
       count(*) FILTER (WHERE l.ordem > 1)                                     AS duplicados,
       count(*) FILTER (WHERE l.ordem > 1 AND l.replica <> l.replica_original) AS dup_replica_dif_original,
       count(*) FILTER (WHERE l.ordem > 1 AND l.replica <> l.replica_anterior) AS dup_replica_dif_anterior
FROM pedidos_cliente p
LEFT JOIN linhas l USING (run_id, request_no)
GROUP BY p.run_id, p.request_no, p.resultado_final;

-- Uma linha por repetição (run_id).
CREATE VIEW medida_por_repeticao AS
SELECT condicao,
       run_id,
       count(*)                                           AS pedidos_logicos,
       sum(linhas)                                        AS linhas,
       sum(linhas) - count(*) FILTER (WHERE linhas >= 1)  AS duplicados
FROM medida_por_pedido
GROUP BY condicao, run_id;

-- Uma linha por condição: é o conteúdo de results/resumo.csv.
CREATE VIEW resumo AS
WITH c AS (
    SELECT condicao,
           count(*)                                          AS pedidos_logicos,
           sum(linhas)                                       AS linhas,
           sum(linhas) - count(*) FILTER (WHERE linhas >= 1) AS duplicados,
           count(*) FILTER (WHERE linhas >= 2)               AS pedidos_2_ou_mais_linhas,
           count(*) FILTER (WHERE linhas = 0)                AS pedidos_sem_linha,
           count(*) FILTER (WHERE resultado_final <> 'ok')   AS pedidos_sem_resposta,
           sum(dup_replica_dif_original)                     AS duplicados_replica_dif_original,
           sum(dup_replica_dif_anterior)                     AS duplicados_replica_dif_anterior,
           count(*) FILTER (WHERE dup_replica_dif_original > 0) AS pedidos_dup_com_repeticao_noutra_replica
    FROM medida_por_pedido
    GROUP BY condicao
), r AS (
    SELECT condicao,
           count(*)                AS repeticoes,
           avg(duplicados)         AS media,
           stddev_samp(duplicados) AS dp,
           min(duplicados)         AS minimo,
           max(duplicados)         AS maximo
    FROM medida_por_repeticao
    GROUP BY condicao
)
SELECT c.condicao,
       r.repeticoes,
       c.pedidos_logicos,
       c.linhas,
       c.duplicados,
       c.pedidos_2_ou_mais_linhas,
       c.pedidos_sem_linha,
       round(r.media, 2)                                                      AS duplicados_por_repeticao_media,
       round(r.dp, 2)                                                         AS duplicados_por_repeticao_dp,
       r.minimo                                                               AS duplicados_por_repeticao_min,
       r.maximo                                                               AS duplicados_por_repeticao_max,
       round(100.0 * c.pedidos_2_ou_mais_linhas / c.pedidos_logicos, 1)       AS pct_pedidos_duplicados,
       c.duplicados_replica_dif_original,
       round(100.0 * c.duplicados_replica_dif_original / nullif(c.duplicados, 0), 1) AS pct_duplicados_replica_dif_original,
       c.duplicados_replica_dif_anterior,
       c.pedidos_dup_com_repeticao_noutra_replica,
       c.pedidos_sem_resposta,
       -- Para ordenar as saídas: controlo, atraso, rede, variante do Passo 7, e o
       -- resto por nome.
       coalesce(array_position(ARRAY['C-controlo', 'C-atraso', 'C-rede', 'C-atraso-cache'],
                               c.condicao), 99) AS ordem
FROM c
JOIN r USING (condicao);

-- Tabelas em Markdown (decimais com vírgula). A coluna k só serve para ordenar.
CREATE VIEW resumo_md_duplicados AS
SELECT -2 AS k,
       '| Condição | Repetições | Pedidos lógicos | Linhas em `charges` | Duplicados '
       || '| Duplicados por repetição (média ± dp) | Pedidos com 2+ linhas '
       || '| Pedidos lógicos duplicados | Pedidos sem linha |' AS linha
UNION ALL
SELECT -1, '|---|---:|---:|---:|---:|---:|---:|---:|---:|'
UNION ALL
SELECT ordem,
       format('| %s | %s | %s | %s | %s | %s ± %s | %s | %s %% | %s |',
              condicao, repeticoes, pedidos_logicos, linhas, duplicados,
              replace(duplicados_por_repeticao_media::text, '.', ','),
              -- Com uma só repetição o desvio-padrão amostral não existe (NULL).
              coalesce(replace(duplicados_por_repeticao_dp::text, '.', ','), '-'),
              pedidos_2_ou_mais_linhas,
              replace(pct_pedidos_duplicados::text, '.', ','),
              pedidos_sem_linha)
FROM resumo;

CREATE VIEW resumo_md_replicas AS
SELECT -2 AS k,
       '| Condição | Duplicados | Noutra réplica que não a original '
       || '| Noutra réplica que não a da tentativa anterior '
       || '| Pedidos duplicados com alguma repetição noutra réplica '
       || '| Pedidos sem resposta no cliente |' AS linha
UNION ALL
SELECT -1, '|---|---:|---:|---:|---:|---:|'
UNION ALL
SELECT ordem,
       format('| %s | %s | %s (%s) | %s | %s de %s | %s |',
              condicao, duplicados, duplicados_replica_dif_original,
              coalesce(replace(pct_duplicados_replica_dif_original::text, '.', ',') || ' %', '-'),
              duplicados_replica_dif_anterior,
              pedidos_dup_com_repeticao_noutra_replica, pedidos_2_ou_mais_linhas,
              pedidos_sem_resposta)
FROM resumo;
