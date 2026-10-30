#!/usr/bin/env bash
# Mede os duplicados do ensaio (Passo 6).
#
# Carrega os CSVs do cliente (results/C-*.csv) na tabela pedidos_cliente, cria as
# vistas de db/medida.sql e gera:
#   results/resumo.csv    uma linha por condição (vista `resumo`)
#   results/latencia.csv  latência sem falhas por rota (vista `latencia`)
#   results/resumo.md     as mesmas medidas em tabelas Markdown
#
# Uso: ./medir.sh   (com a pilha a correr e depois de ./executar_ensaio.sh)

set -euo pipefail
cd "$(dirname "$0")"

psql_ensaio() {
    docker compose exec -T postgres psql -U ensaio -d ensaio -v ON_ERROR_STOP=1 -q "$@"
}

psql_ensaio -f - < db/medida.sql

shopt -s nullglob
csvs=(results/C-*.csv)
if [ ${#csvs[@]} -eq 0 ]; then
    echo "ERRO: não há results/C-*.csv; corre primeiro ./executar_ensaio.sh" >&2
    exit 1
fi
for f in "${csvs[@]}"; do
    psql_ensaio -c "\copy pedidos_cliente FROM STDIN WITH (FORMAT csv, HEADER true)" < "$f"
    echo "carregado: $f"
done

# Registos do cliente de teste usados para a latência (emenda 4): C-controlo passa
# pelo Toxiproxy e pelo nginx; L-nginx e L-direto vêm do executar_ensaio.sh.
# Cada linha JSON entra inteira numa coluna jsonb; o formato CSV com aspas e
# separador que não aparecem no JSON evita que o COPY interprete as barras.
carregar_trace() {
    local rota=$1 f=$2
    [ -f "$f" ] || { echo "aviso: falta $f (latência '$rota' fica de fora)"; return; }
    psql_ensaio -c "\copy tentativas_cliente(linha) FROM STDIN WITH (FORMAT csv, QUOTE E'\x01', DELIMITER E'\x02')" < "$f"
    psql_ensaio -c "UPDATE tentativas_cliente SET rota = '$rota' WHERE rota IS NULL;"
    echo "carregado: $f"
}
carregar_trace "toxiproxy + nginx" results/C-controlo_trace.jsonl
carregar_trace "nginx" results/latencia/L-nginx_trace.jsonl
carregar_trace "direto" results/latencia/L-direto_trace.jsonl
psql_ensaio --csv -c "SELECT rota, chamadas, mediana_ms, p95_ms, chamadas_sem_primeira,
                             mediana_sem_primeira_ms, p95_sem_primeira_ms
                      FROM latencia ORDER BY ordem" > results/latencia.csv

COLUNAS="condicao, repeticoes, pedidos_logicos, linhas, duplicados, pedidos_2_ou_mais_linhas,
         pedidos_sem_linha, duplicados_por_repeticao_media, duplicados_por_repeticao_dp,
         duplicados_por_repeticao_min, duplicados_por_repeticao_max, pct_pedidos_duplicados,
         duplicados_replica_dif_original, pct_duplicados_replica_dif_original,
         duplicados_replica_dif_anterior, pedidos_dup_com_repeticao_noutra_replica,
         pedidos_sem_resposta"
psql_ensaio --csv -c "SELECT $COLUNAS FROM resumo ORDER BY ordem, condicao" > results/resumo.csv

md() {
    psql_ensaio -At -c "SELECT linha FROM $1 ORDER BY k, linha"
}

{
    echo "# Resumo do ensaio preliminar"
    echo
    echo "Gerado por \`medir.sh\` em $(date '+%Y-%m-%d %H:%M') a partir de \`results/C-*.csv\` e da tabela \`charges\`."
    echo
    echo "## Duplicados por condição"
    echo
    md resumo_md_duplicados
    echo
    echo "- Duplicados = linhas em \`charges\` menos pedidos lógicos com pelo menos uma linha."
    echo "- Duplicados por repetição: média e desvio-padrão amostral (n - 1) sobre as repetições;"
    echo "  cada repetição tem pedidos lógicos / repetições pedidos."
    echo "- Pedidos lógicos duplicados = pedidos com 2 ou mais linhas / pedidos lógicos."
    echo
    echo "## Réplica das repetições"
    echo
    md resumo_md_replicas
    echo
    echo "- A linha original de um pedido é a primeira por ordem de \`id\`; as seguintes são os duplicados."
    echo "- \"Noutra réplica que não a original\": duplicados gravados por uma réplica diferente da que gravou"
    echo "  a linha original. A coluna seguinte compara com a tentativa imediatamente anterior."
    echo "- \"Pedidos sem resposta no cliente\": pedidos cujas tentativas falharam todas (\`esgotado\`); o"
    echo "  efeito pode existir na mesma (ver \"Pedidos sem linha\")."
    echo
    echo "## Latência de um tools/call sem falhas (C-controlo)"
    echo
    md latencia_md
    echo
    echo "- Duração do \`call_tool\` medida no cliente, só das tentativas com resposta \`ok\`, sem falhas"
    echo "  injetadas; cada pedido abre uma ligação TCP nova. A 1.ª chamada de cada repetição é a"
    echo "  primeira de um Client novo e é mais lenta; as duas últimas colunas deixam-na de fora."
    echo "- \"toxiproxy + nginx\" é o caminho do ensaio (registo de C-controlo); \"nginx\" passa só pelo"
    echo "  balanceador; \"direto\" vai a server-a sem intermediários. Base para o custo aceitável do gateway."
} > results/resumo.md

echo "gerado: results/resumo.csv, results/latencia.csv, results/resumo.md"
