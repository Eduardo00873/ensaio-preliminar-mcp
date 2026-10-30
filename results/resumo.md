# Resumo do ensaio preliminar

Gerado por `medir.sh` em 2026-10-30 17:24 a partir de `results/C-*.csv` e da tabela `charges`.

## Duplicados por condição

| Condição | Repetições | Pedidos lógicos | Linhas em `charges` | Duplicados | Duplicados por repetição (média ± dp) | Pedidos com 2+ linhas | Pedidos lógicos duplicados | Pedidos sem linha |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| C-controlo | 30 | 600 | 600 | 0 | 0,00 ± 0,00 | 0 | 0,0 % | 0 |
| C-atraso | 30 | 600 | 817 | 217 | 7,23 ± 2,65 | 172 | 28,7 % | 0 |
| C-rede | 30 | 600 | 835 | 235 | 7,83 ± 3,61 | 180 | 30,0 % | 0 |
| C-atraso-cache | 30 | 600 | 766 | 166 | 5,53 ± 1,81 | 166 | 27,7 % | 0 |

- Duplicados = linhas em `charges` menos pedidos lógicos com pelo menos uma linha.
- Duplicados por repetição: média e desvio-padrão amostral (n - 1) sobre as repetições;
  cada repetição tem pedidos lógicos / repetições pedidos.
- Pedidos lógicos duplicados = pedidos com 2 ou mais linhas / pedidos lógicos.

## Réplica das repetições

| Condição | Duplicados | Noutra réplica que não a original | Noutra réplica que não a da tentativa anterior | Pedidos duplicados com alguma repetição noutra réplica | Pedidos sem resposta no cliente |
|---|---:|---:|---:|---:|---:|
| C-controlo | 0 | 0 (-) | 0 | 0 de 0 | 0 |
| C-atraso | 217 | 172 (79,3 %) | 217 | 172 de 172 | 14 |
| C-rede | 235 | 180 (76,6 %) | 235 | 180 de 180 | 9 |
| C-atraso-cache | 166 | 166 (100,0 %) | 166 | 166 de 166 | 0 |

- A linha original de um pedido é a primeira por ordem de `id`; as seguintes são os duplicados.
- "Noutra réplica que não a original": duplicados gravados por uma réplica diferente da que gravou
  a linha original. A coluna seguinte compara com a tentativa imediatamente anterior.
- "Pedidos sem resposta no cliente": pedidos cujas tentativas falharam todas (`esgotado`); o
  efeito pode existir na mesma (ver "Pedidos sem linha").

## Latência de um tools/call sem falhas (C-controlo)

| Rota | Chamadas | Mediana | p95 | Mediana sem a 1.ª chamada | p95 sem a 1.ª chamada |
|---|---:|---:|---:|---:|---:|
| toxiproxy + nginx | 600 | 2,14 ms | 10,39 ms | 2,11 ms | 3,94 ms |
| nginx | 600 | 1,86 ms | 21,96 ms | 1,85 ms | 4,24 ms |
| direto | 600 | 1,56 ms | 9,59 ms | 1,54 ms | 2,60 ms |

- Duração do `call_tool` medida no cliente, só das tentativas com resposta `ok`, sem falhas
  injetadas; cada pedido abre uma ligação TCP nova. A 1.ª chamada de cada repetição é a
  primeira de um Client novo e é mais lenta; as duas últimas colunas deixam-na de fora.
- "toxiproxy + nginx" é o caminho do ensaio (registo de C-controlo); "nginx" passa só pelo
  balanceador; "direto" vai a server-a sem intermediários. Base para o custo aceitável do gateway.
