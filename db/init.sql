-- Esquema do ensaio preliminar.
-- Cada chamada bem-sucedida da ferramenta `charge` grava uma linha nesta tabela.
-- Não há restrição UNIQUE em (run_id, request_no) de propósito: o ensaio quer
-- observar os efeitos duplicados, não impedi-los.
--
-- run_id identifica uma repetição de uma condição (por exemplo "C-atraso-07");
-- request_no é o número do pedido lógico dentro dessa repetição (1..20).
-- replica é o nome da réplica que executou o efeito (REPLICA_NAME).
-- fault_injected indica se a réplica injetou o atraso pós-commit nesta chamada
-- (FAULT_DELAY_MS com probabilidade FAULT_PROB).

CREATE TABLE charges (
    id             serial PRIMARY KEY,
    run_id         text        NOT NULL,
    request_no     int         NOT NULL,
    amount_cents   int         NOT NULL,
    replica        text        NOT NULL,
    fault_injected boolean     NOT NULL DEFAULT false,
    created_at     timestamptz NOT NULL DEFAULT now()
);
