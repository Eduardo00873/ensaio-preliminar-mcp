#!/usr/bin/env bash
# Executa o ensaio preliminar: para cada condição, REPETICOES repetições de
# PEDIDOS pedidos lógicos (uma repetição = um run_id = uma execução do cliente).
# Mede também a latência sem falhas pelo nginx e diretamente a uma réplica.
# No fim corre ./medir.sh, que gera o resumo.
#
# Resultados:
#   results/<condicao>.csv               uma linha por pedido lógico (ver client/ensaio.py)
#   results/<condicao>_trace.jsonl       registo do cliente de teste, uma linha por tentativa
#   results/latencia/L-<rota>.csv e L-<rota>_trace.jsonl   o mesmo, para a latência
#   results/logs/<condicao>.log          log do cliente, com o id JSON-RPC de cada tentativa
#   results/logs/<condicao>-servidores.log  commits, respostas e acertos de cache
#   results/execucao.log                 configuração aplicada a cada condição e progresso
#   results/resumo.csv, results/latencia.csv, results/resumo.md   medida (medir.sh)
#
# Uso:
#   ./executar_ensaio.sh
# Variáveis opcionais (valores por omissão entre parênteses):
#   CONDICOES   ("C-controlo C-rede C-atraso")
#   REPETICOES  (30)   PEDIDOS (20)   TIMEOUT_S (2)   TENTATIVAS (3)
#   ATRASO_MS   (3000) atraso pós-commit em C-atraso e C-atraso-cache
#   PROB_ATRASO (0.3)  probabilidade de injetar o atraso em cada chamada
#   SEMENTE     (42)   semente do sorteio do atraso nas réplicas
#   TOXICIDADE  (0.3)  probabilidade do toxic em C-rede, por ligação
#   LATENCIA    (1)    1 = mede a latência sem falhas pelo nginx e direto a server-a
#   RECRIAR_BD  (1)    1 = começa com a base de dados vazia (docker compose down -v);
#                      0 = mantém a base de dados e apaga só as linhas das condições
#                          que vai correr
#
# Condições:
#   C-controlo  sem atraso, sem toxics
#   C-atraso    FAULT_DELAY_MS=ATRASO_MS com probabilidade PROB_ATRASO, sem toxics
#   C-rede      sem atraso, toxic reset_peer (timeout=0) no sentido downstream
#               com toxicidade TOXICIDADE
#   C-atraso-cache  (Passo 7, opcional; não faz parte de CONDICOES por omissão)
#               como C-atraso, com DEDUP_MEMORIA=1 nas réplicas
#
# As réplicas são recriadas no início de cada condição, para o sorteio do atraso
# começar sempre do mesmo ponto da sequência da semente.

set -euo pipefail
cd "$(dirname "$0")"

CONDICOES=${CONDICOES:-"C-controlo C-rede C-atraso"}
REPETICOES=${REPETICOES:-30}
PEDIDOS=${PEDIDOS:-20}
TIMEOUT_S=${TIMEOUT_S:-2}
TENTATIVAS=${TENTATIVAS:-3}
ATRASO_MS=${ATRASO_MS:-3000}
PROB_ATRASO=${PROB_ATRASO:-0.3}
SEMENTE=${SEMENTE:-42}
TOXICIDADE=${TOXICIDADE:-0.3}
LATENCIA=${LATENCIA:-1}
RECRIAR_BD=${RECRIAR_BD:-1}

mkdir -p results/logs results/latencia

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a results/execucao.log
}

psql_ensaio() {
    docker compose exec -T postgres psql -U ensaio -d ensaio -v ON_ERROR_STOP=1 -qAt "$@"
}

preparar_pilha() {
    if [ "$RECRIAR_BD" = "1" ]; then
        log "a recriar a pilha com a base de dados vazia"
        docker compose --profile cliente down -v --remove-orphans
    fi
    docker compose --profile cliente build --quiet
    FAULT_DELAY_MS=0 DEDUP_MEMORIA=0 docker compose up -d --wait
}

# Aplica uma condição: $1 = atraso pós-commit (ms), $2 = toxicidade ("" = sem toxic),
# $3 = deduplicação em memória por réplica (0 ou 1).
configurar() {
    local atraso=$1 toxicidade=$2 dedup=$3 s v esperado

    # --force-recreate: réplicas novas, com o gerador do atraso no início da sequência.
    FAULT_DELAY_MS=$atraso FAULT_PROB=$PROB_ATRASO FAULT_SEED=$SEMENTE DEDUP_MEMORIA=$dedup \
        docker compose up -d --wait --force-recreate --no-deps server-a server-b
    esperado="$atraso $PROB_ATRASO $SEMENTE $dedup "
    for s in server-a server-b; do
        v=$(docker compose exec -T "$s" printenv FAULT_DELAY_MS FAULT_PROB FAULT_SEED DEDUP_MEMORIA | tr '\n' ' ')
        if [ "$v" != "$esperado" ]; then
            log "ERRO: $s está com FAULT_DELAY_MS FAULT_PROB FAULT_SEED DEDUP_MEMORIA = $v; esperado $esperado"
            exit 1
        fi
    done

    # O nginx só resolve os nomes das réplicas quando arranca; reinicia-se depois
    # de as recriar. Isto também repõe o round-robin no início de cada condição.
    # O Toxiproxy reinicia sem toxics (só o proxy definido em toxiproxy.json).
    docker compose restart nginx toxiproxy
    sleep 2

    if [ -n "$toxicidade" ]; then
        docker compose exec -T toxiproxy /toxiproxy-cli toxic add \
            -n corte -t reset_peer -d --tox "$toxicidade" -a timeout=0 mcp
    fi
    local toxics
    toxics=$(docker compose exec -T toxiproxy /toxiproxy-cli inspect mcp | grep 'type=' || true)
    log "réplicas com FAULT_DELAY_MS=$atraso FAULT_PROB=$PROB_ATRASO FAULT_SEED=$SEMENTE" \
        "DEDUP_MEMORIA=$dedup; toxics no proxy mcp: ${toxics:-nenhum}"
}

# Corre REPETICOES execuções do cliente. $1 = prefixo do run_id, $2 = CSV (no
# contentor), $3 = log, $4 = URL do servidor MCP.
correr_cliente() {
    local prefixo=$1 csv=$2 logf=$3 url=$4 i
    for i in $(seq -w 1 "$REPETICOES"); do
        # --no-deps: o cliente não pode recriar as réplicas (perderia a condição).
        docker compose run --rm --no-deps -T client \
            --run-id "$prefixo-$i" --url "$url" --pedidos "$PEDIDOS" --timeout "$TIMEOUT_S" \
            --tentativas "$TENTATIVAS" --csv "$csv" >>"$logf" 2>&1
        log "$(tail -n 1 "$logf" | sed -E 's/^[0-9-]+ [0-9:,]+ //')"
    done
}

executar_condicao() {
    local cond=$1 logf="results/logs/$1.log"

    case "$cond" in
        C-controlo)     configurar 0 "" 0 ;;
        C-atraso)       configurar "$ATRASO_MS" "" 0 ;;
        C-rede)         configurar 0 "$TOXICIDADE" 0 ;;
        C-atraso-cache) configurar "$ATRASO_MS" "" 1 ;;
        *) log "ERRO: condição desconhecida: $cond"; exit 1 ;;
    esac

    # Expressão regular e não LIKE: 'C-atraso-%' apanharia também C-atraso-cache-NN.
    local filtro="run_id ~ '^${cond}-[0-9]+\$'"
    rm -f "results/$cond.csv" "results/${cond}_trace.jsonl" "$logf"
    psql_ensaio -c "DELETE FROM charges WHERE $filtro;"

    local inicio
    inicio=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log "$cond: início ($REPETICOES repetições x $PEDIDOS pedidos, timeout ${TIMEOUT_S}s, $TENTATIVAS tentativas)"
    correr_cliente "$cond" "/results/$cond.csv" "$logf" "http://toxiproxy:8666/mcp"
    log "$cond: fim; linhas na tabela: $(psql_ensaio -c "SELECT count(*) FROM charges WHERE $filtro;")"

    # Logs das réplicas desta condição (commit, resposta e acertos da cache, com o
    # id JSON-RPC), guardados antes de a próxima condição as recriar.
    docker compose logs --no-color --since "$inicio" server-a server-b \
        | grep -v 'GET /health' >"results/logs/$cond-servidores.log" || true
}

# Latência de um tools/call sem falhas (como C-controlo), por duas rotas sem o
# Toxiproxy: pelo nginx e diretamente a server-a. O caminho do ensaio (Toxiproxy e
# nginx) já fica medido no registo de C-controlo.
medir_latencia() {
    local rota url
    configurar 0 "" 0
    for rota in nginx direto; do
        case "$rota" in
            nginx)  url="http://nginx:80/mcp" ;;
            direto) url="http://server-a:8000/mcp" ;;
        esac
        rm -f "results/latencia/L-$rota.csv" "results/latencia/L-${rota}_trace.jsonl" "results/logs/L-$rota.log"
        psql_ensaio -c "DELETE FROM charges WHERE run_id ~ '^L-$rota-[0-9]+\$';"
        log "latência L-$rota: início ($url, $REPETICOES repetições x $PEDIDOS pedidos)"
        correr_cliente "L-$rota" "/results/latencia/L-$rota.csv" "results/logs/L-$rota.log" "$url"
    done
}

log "ensaio: CONDICOES='$CONDICOES' REPETICOES=$REPETICOES PEDIDOS=$PEDIDOS TIMEOUT_S=$TIMEOUT_S" \
    "TENTATIVAS=$TENTATIVAS ATRASO_MS=$ATRASO_MS PROB_ATRASO=$PROB_ATRASO SEMENTE=$SEMENTE" \
    "TOXICIDADE=$TOXICIDADE LATENCIA=$LATENCIA RECRIAR_BD=$RECRIAR_BD"
preparar_pilha
for cond in $CONDICOES; do
    executar_condicao "$cond"
done
if [ "$LATENCIA" = "1" ]; then
    medir_latencia
fi

# Deixa a pilha no estado normal: sem atraso, sem toxics e sem deduplicação.
configurar 0 "" 0
log "ensaio: concluído"

./medir.sh
