# Resumo do ensaio preliminar

Gerado por `medir.sh` em 2026-10-29 21:11 a partir de `results/C-*.csv` e da tabela `charges`.

## Duplicados por condição

| Condição | Repetições | Pedidos lógicos | Linhas em `charges` | Duplicados | Duplicados por repetição (média ± dp) | Pedidos com 2+ linhas | Pedidos lógicos duplicados | Pedidos sem linha |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| C-controlo | 30 | 600 | 600 | 0 | 0,00 ± 0,00 | 0 | 0,0 % | 0 |
| C-atraso | 30 | 600 | 1800 | 1200 | 40,00 ± 0,00 | 600 | 100,0 % | 0 |
| C-rede | 30 | 600 | 838 | 238 | 7,93 ± 2,79 | 176 | 29,3 % | 0 |
| C-atraso-cache | 30 | 600 | 1200 | 600 | 20,00 ± 0,00 | 600 | 100,0 % | 0 |

- Duplicados = linhas em `charges` menos pedidos lógicos com pelo menos uma linha.
- Duplicados por repetição: média e desvio-padrão amostral (n - 1) sobre as repetições;
  cada repetição tem 20 pedidos lógicos.
- Pedidos lógicos duplicados = pedidos com 2 ou mais linhas / pedidos lógicos.

## Réplica das repetições

| Condição | Duplicados | Noutra réplica que não a original | Noutra réplica que não a da tentativa anterior | Pedidos duplicados com alguma repetição noutra réplica | Pedidos sem resposta no cliente |
|---|---:|---:|---:|---:|---:|
| C-controlo | 0 | 0 (-) | 0 | 0 de 0 | 0 |
| C-atraso | 1200 | 600 (50,0 %) | 1200 | 600 de 600 | 600 |
| C-rede | 238 | 176 (73,9 %) | 238 | 176 de 176 | 19 |
| C-atraso-cache | 600 | 600 (100,0 %) | 600 | 600 de 600 | 0 |

- A linha original de um pedido é a primeira por ordem de `id`; as seguintes são os duplicados.
- "Noutra réplica que não a original": duplicados gravados por uma réplica diferente da que gravou
  a linha original. A coluna seguinte compara com a tentativa imediatamente anterior.
- "Pedidos sem resposta no cliente": pedidos cujas tentativas falharam todas (`esgotado`); o
  efeito pode existir na mesma (ver "Pedidos sem linha").
