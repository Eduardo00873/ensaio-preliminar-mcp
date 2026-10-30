# Ensaio preliminar: cobranças duplicadas com réplicas MCP sem estado

Este ensaio reproduz, sem qualquer solução, o problema que a dissertação aborda.
Na revisão 2026-07-28 da especificação MCP não há sessão: quando a resposta de um
`tools/call` se perde, o cliente tem de repetir o pedido como pedido novo, com um
id JSON-RPC novo. Se a ferramenta já tinha produzido o efeito, o efeito fica
duplicado.

O ensaio mede quantas cobranças a mais ficam numa tabela PostgreSQL quando a
resposta se perde depois de a cobrança ser gravada, com duas réplicas MCP sem
estado atrás de um balanceador round-robin. Mede também a latência de um
`tools/call` sem falhas, como base para o custo aceitável do gateway.

É um ensaio preliminar. Não há gateway nem deduplicação partilhada, e não é a
avaliação da dissertação (ver [Limitações](#limitações)).

## Versões do ensaio

| Versão | Data | O que mudou |
|---|---|---|
| v1 | 29/10/2026 | Primeira execução. Em C-atraso o atraso era aplicado em todas as chamadas. Resultados arquivados em `results/v1_2026-10-29/` |
| v2 | 30/10/2026 | Emendas ao plano: atraso sorteado com probabilidade e semente, coluna `fault_injected`, registo JSONL do cliente de teste, verificação das repetições do SDK e latência no resumo. É a versão atual em `results/` |

## Resultados (v2)

Execução de 30/10/2026: 30 repetições de 20 pedidos lógicos por condição, com
timeout de cliente de 2 s e até 3 tentativas por pedido. As tabelas são as de
`results/resumo.md`, geradas por `medir.sh`.

### Duplicados por condição

| Condição | Repetições | Pedidos lógicos | Linhas em `charges` | Duplicados | Duplicados por repetição (média ± dp) | Pedidos com 2+ linhas | Pedidos lógicos duplicados | Pedidos sem linha |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| C-controlo | 30 | 600 | 600 | 0 | 0,00 ± 0,00 | 0 | 0,0 % | 0 |
| C-atraso | 30 | 600 | 817 | 217 | 7,23 ± 2,65 | 172 | 28,7 % | 0 |
| C-rede | 30 | 600 | 835 | 235 | 7,83 ± 3,61 | 180 | 30,0 % | 0 |
| C-atraso-cache | 30 | 600 | 766 | 166 | 5,53 ± 1,81 | 166 | 27,7 % | 0 |

- Duplicados = linhas em `charges` menos pedidos lógicos com pelo menos uma linha.
- Média e desvio-padrão amostral (n - 1) dos duplicados por repetição.
- Pedidos lógicos duplicados = pedidos com 2 ou mais linhas / pedidos lógicos.

### Réplica das repetições

| Condição | Duplicados | Noutra réplica que não a original | Noutra réplica que não a da tentativa anterior | Pedidos duplicados com alguma repetição noutra réplica | Pedidos sem resposta no cliente |
|---|---:|---:|---:|---:|---:|
| C-controlo | 0 | 0 (-) | 0 | 0 de 0 | 0 |
| C-atraso | 217 | 172 (79,3 %) | 217 | 172 de 172 | 14 |
| C-rede | 235 | 180 (76,6 %) | 235 | 180 de 180 | 9 |
| C-atraso-cache | 166 | 166 (100,0 %) | 166 | 166 de 166 | 0 |

A linha original de um pedido é a primeira por ordem de `id`. As tentativas de um
pedido são sequenciais, por isso a ordem de `id` é a ordem das tentativas.

### Latência de um `tools/call` sem falhas

| Rota | Chamadas | Mediana | p95 | Mediana sem a 1.ª chamada | p95 sem a 1.ª chamada |
|---|---:|---:|---:|---:|---:|
| Toxiproxy + nginx (caminho do ensaio, C-controlo) | 600 | 2,14 ms | 10,39 ms | 2,11 ms | 3,94 ms |
| nginx | 600 | 1,86 ms | 21,96 ms | 1,85 ms | 4,24 ms |
| direto a server-a | 600 | 1,56 ms | 9,59 ms | 1,54 ms | 2,60 ms |

- Duração do `call_tool` medida no cliente, só das tentativas `ok`, sem falhas
  injetadas, com uma ligação TCP nova por pedido.
- A 1.ª chamada de cada repetição é a primeira de um `Client` novo e é mais lenta
  (20 a 60 ms). São 30 de 600 chamadas, exatamente 5 %, e dominam o p95 com elas
  incluídas. As colunas sem a 1.ª chamada são as mais estáveis para fixar o custo
  aceitável do gateway.
- Sem a 1.ª chamada, o nginx acrescenta cerca de 0,3 ms à mediana e 1,6 ms ao p95
  face à chamada direta.

### Verificações sobre o SDK (emenda 3)

**O SDK não repete pedidos sozinho.** Um cliente do SDK sem o ciclo de repetição
do ensaio, perante cortes com RST, cortes com FIN e timeouts, nos modos
`2026-07-28` e `auto`, enviou sempre um único `tools/call`, e ficou sempre uma
única linha. O cliente de ensaio com `--tentativas 1` também deu um pedido, uma
tentativa e uma linha. Os duplicados vêm só da repetição feita pelo cliente.

**Entre a tentativa original e a repetição** (15 repetições comparadas campo a
campo):

| Campo | Na repetição |
|---|---|
| id JSON-RPC | muda sempre |
| hora de envio | muda sempre |
| método, argumentos | iguais |
| `_meta` (protocolVersion, clientInfo, clientCapabilities) | igual |
| headers `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` | iguais |
| outros headers (`host`, `content-type`, `accept`, `user-agent`, ...) | iguais |
| header `content-length` | igual, exceto quando o id ganha um algarismo |

Nada no pedido identifica a repetição como tal, e o `clientInfo` é o mesmo para
qualquer cliente feito com o SDK.

### Leitura

- **C-controlo.** Sem falhas, cada pedido lógico dá exatamente uma cobrança.
- **C-atraso e C-rede ficam equivalentes.** Com a resposta perdida em cerca de
  30 % das tentativas, por atraso no servidor ou por corte de rede, cerca de 30 %
  dos pedidos ficam duplicados (7 a 8 duplicados por repetição). Um modelo com
  probabilidade p = 0,3 por tentativa, independente, prevê 7,80 ± 2,89.
- **Pedidos sem linha.** Não houve nenhum: em todas as tentativas o efeito
  aconteceu, e a resposta só se perdeu depois. Os pedidos "sem resposta no
  cliente" (esgotados) deixaram 3 cobranças cada.
- **C-atraso-cache (Passo 7).** A deduplicação em memória por réplica só apanhou
  as 50 repetições que voltaram à réplica original. Os 166 duplicados que restam
  estão todos na outra réplica, e os pedidos duplicados quase não descem (de
  28,7 % para 27,7 %). Com réplicas sem estado, a deduplicação tem de usar estado
  partilhado.
- **Distribuição pelas réplicas.** É um artefacto desta montagem: com o round-robin
  estrito e um cliente sequencial, cada repetição cai na réplica que não atendeu a
  tentativa anterior.

### Comparação com a v1

| Condição | v1 (29/10) | v2 (30/10) |
|---|---|---|
| C-controlo | 0 duplicados | 0 duplicados |
| C-atraso | 40,00 ± 0,00 por repetição; atraso em todas as chamadas | 7,23 ± 2,65; atraso em 30 % das chamadas |
| C-rede | 7,93 ± 2,79 | 7,83 ± 3,61 |
| C-atraso-cache | 20,00 ± 0,00; a cache cortou metade | 5,53 ± 1,81; a cache cortou 50 repetições |

Na v1, com o atraso em todas as chamadas, as três tentativas de cada pedido davam
timeout e o resultado era determinístico. A v2 aproxima o C-atraso de uma falha
parcial e torna-o comparável ao C-rede.

## Como reproduzir

Requisitos: Docker com o plugin Compose v2 e `bash`. Não é preciso instalar mais
nada no anfitrião: imagens, dependências Python e ferramentas correm em
contentores. Nenhum serviço publica portas no anfitrião.

Na pasta do projeto, um só comando:

```bash
CONDICOES="C-controlo C-rede C-atraso C-atraso-cache" ./executar_ensaio.sh
```

O script faz o seguinte:

1. constrói as imagens e recria a pilha com a base de dados vazia
   (`docker compose down -v`);
2. corre as condições, 30 repetições de 20 pedidos cada, recriando as réplicas no
   início de cada condição para o sorteio do atraso começar sempre no mesmo ponto;
3. mede a latência sem falhas pelo nginx e diretamente a server-a;
4. corre `./medir.sh`, que gera `results/resumo.csv`, `results/latencia.csv` e
   `results/resumo.md`.

Demorou 19 minutos na v2. Sem `CONDICOES`, corre C-controlo, C-rede e C-atraso.

### Parâmetros

Todos são variáveis de ambiente do `executar_ensaio.sh`.

| Variável | Omissão | Significado |
|---|---|---|
| `CONDICOES` | `C-controlo C-rede C-atraso` | condições a correr, por esta ordem |
| `REPETICOES` | 30 | repetições por condição |
| `PEDIDOS` | 20 | pedidos lógicos por repetição |
| `TIMEOUT_S` | 2 | timeout do cliente por tentativa, em segundos |
| `TENTATIVAS` | 3 | máximo de tentativas por pedido lógico, no total |
| `ATRASO_MS` | 3000 | atraso depois do commit em C-atraso e C-atraso-cache |
| `PROB_ATRASO` | 0.3 | probabilidade de injetar o atraso em cada chamada |
| `SEMENTE` | 42 | semente do sorteio do atraso nas réplicas |
| `TOXICIDADE` | 0.3 | probabilidade do toxic em C-rede, por ligação |
| `LATENCIA` | 1 | 1 = mede a latência pelo nginx e direto a server-a |
| `RECRIAR_BD` | 1 | 1 = começa com a base de dados vazia; 0 = mantém-na e apaga só as linhas das condições que vai correr |

Por exemplo, para repetir só C-rede sem perder as outras condições:

```bash
CONDICOES=C-rede LATENCIA=0 RECRIAR_BD=0 ./executar_ensaio.sh
```

### Ficheiros produzidos

| Ficheiro | Conteúdo |
|---|---|
| `results/<condicao>.csv` | uma linha por pedido lógico (colunas abaixo) |
| `results/<condicao>_trace.jsonl` | registo do cliente de teste: uma linha por tentativa (campos abaixo) |
| `results/latencia/L-nginx*` e `L-direto*` | CSV e registo JSONL das medições de latência |
| `results/logs/<condicao>.log` | log do cliente: uma linha por tentativa, com o id JSON-RPC e o resultado |
| `results/logs/<condicao>-servidores.log` | log das réplicas: `commit` (com `fault_injected`), `resposta` e acertos de `cache` |
| `results/execucao.log` | configuração aplicada a cada condição e progresso |
| `results/resumo.csv` | uma linha por condição, com todas as medidas de duplicados |
| `results/latencia.csv` | mediana e p95 por rota, com e sem a 1.ª chamada |
| `results/resumo.md` | as mesmas medidas em tabelas Markdown |
| `results/v1_2026-10-29/` | resultados da v1, com um dump da tabela `charges` |

Colunas de `results/<condicao>.csv`:

| Coluna | Conteúdo |
|---|---|
| `run_id` | identificador da repetição, por exemplo `C-rede-07` |
| `request_no` | número do pedido lógico na repetição, de 1 a 20 |
| `tentativas` | número de `tools/call` enviados para este pedido |
| `resultado_final` | `ok`, ou `esgotado` se todas as tentativas falharam |
| `replicas_que_responderam` | réplica indicada na resposta `ok`; vazio se não houve resposta |
| `jsonrpc_ids` | id JSON-RPC de cada tentativa, separados por `;` |
| `resultados_tentativas` | resultado de cada tentativa (`ok`, `timeout`, `ligacao`) |
| `duracao_ms` | duração do pedido lógico, todas as tentativas incluídas |

Campos de cada linha de `results/<condicao>_trace.jsonl`: `run_id`, `request_no`,
`tentativa`, `jsonrpc_id`, `metodo`, `enviado_em`, `recebido_em` (hora dos headers
da resposta; `null` num timeout), `http_status`, `headers_enviados`,
`headers_recebidos`, `resposta_sintetica` (`true` no 502 criado pelo cliente num
corte), `meta` (o `_meta` completo), `argumentos`, `concluido_em`, `duracao_ms`,
`resultado`, `resposta` (o `CallToolResult` interpretado pelo SDK), `erro` e
`replica`.

Para consultar a base de dados com a pilha a correr:

```bash
docker compose exec postgres psql -U ensaio -d ensaio
```

Para parar tudo e apagar a base de dados:

```bash
docker compose --profile cliente down -v
```

## Montagem

```
cliente de ensaio (client)          uma ligação TCP nova por pedido
        |
        v
toxiproxy:8666                      C-rede: toxic reset_peer no sentido downstream
        |
        v
nginx:80                            round-robin, 1 processo, sem repetições próprias
      /     \
     v       v
server-a   server-b                 a mesma imagem; FAULT_DELAY_MS, FAULT_PROB,
      \     /                       FAULT_SEED, DEDUP_MEMORIA
       v   v
postgres:5432                       tabela charges
```

| Caminho | Conteúdo |
|---|---|
| `docker-compose.yml` | serviços, imagens fixadas por etiqueta e digest |
| `server/` | servidor MCP: `server.py`, `Dockerfile`, `requirements.txt` e `requirements.lock` |
| `client/` | cliente de ensaio: `ensaio.py`, `Dockerfile`, `requirements.txt` e `requirements.lock` |
| `nginx/nginx.conf` | balanceador round-robin |
| `toxiproxy/toxiproxy.json` | proxy `mcp`: escuta em 8666 e encaminha para `nginx:80` |
| `db/init.sql` | esquema da tabela `charges` |
| `db/medida.sql` | tabelas e vistas da medida (duplicados e latência) |
| `executar_ensaio.sh` | executa as condições, a latência e no fim a medida |
| `medir.sh` | carrega os CSVs e os registos JSONL e gera o resumo |
| `results/` | CSVs, registos, logs e resumo |

### Servidor MCP

`server/server.py` usa o SDK Python oficial (`mcp` 2.3.0, `MCPServer`) e serve-se
por Streamable HTTP com uvicorn, um processo por réplica. Expõe uma ferramenta,
`charge(run_id, request_no, amount_cents)`, que faz quatro coisas:

1. sorteia se esta chamada leva atraso: sim com probabilidade `FAULT_PROB`, se
   `FAULT_DELAY_MS > 0`;
2. insere uma linha em `charges`, com `fault_injected`, e faz COMMIT; é um efeito
   real, não idempotente;
3. só depois do commit, se a chamada foi sorteada, espera `FAULT_DELAY_MS`;
4. devolve `{"charge_id", "replica"}`.

O sorteio usa `random.Random("<FAULT_SEED>:<REPLICA_NAME>")`: as duas réplicas não
seguem a mesma sequência, e a mesma réplica recriada com a mesma semente repete a
sequência de decisões. Verificou-se com 30 chamadas antes e depois de recriar a
réplica: a mesma sequência, nos tempos de resposta e na coluna `fault_injected`.

Por omissão o servidor não deduplica nada. Com `DEDUP_MEMORIA=1` (Passo 7) guarda
o resultado numa cache em memória do próprio processo, com a chave
`(run_id, request_no)`, e devolve-o sem novo `INSERT` (e sem sorteio nem atraso)
quando o mesmo pedido volta a essa réplica. A cache não é partilhada entre
réplicas, de propósito.

A proteção contra DNS rebinding do SDK está desligada: atrás do nginx e do
Toxiproxy o cabeçalho `Host` não é `localhost`, e a documentação do SDK indica
desligá-la quando há um proxy à frente.

### Cliente de ensaio (cliente de teste da dissertação)

`client/ensaio.py` corre uma repetição. Para cada pedido lógico
`(run_id, request_no)`:

1. faz `tools/call charge` com `read_timeout_seconds` igual a `TIMEOUT_S`;
2. se der timeout (`MCPError` -32001) ou houver um corte de ligação, repete
   imediatamente, com os mesmos argumentos e um id JSON-RPC novo, até ao máximo
   de tentativas;
3. acrescenta uma linha ao CSV e, por cada tentativa, uma linha ao registo JSONL.

O cliente confirma que cada tentativa corresponde a exatamente um POST
`tools/call` com um id novo, e aborta se não for assim. O registo JSONL é feito
com os event hooks do httpx2: a hora de envio antes de o pedido sair e a hora de
receção quando chegam os headers da resposta.

Algumas decisões vêm do comportamento observado do SDK 2.3.0:

- **Um `Client` por repetição.** A revisão está fixada com `mode="2026-07-28"`:
  sem `server/discover`, sem handshake, sem sessão. Os ids JSON-RPC são
  atribuídos pelo SDK e crescem dentro do mesmo `Client`.
- **Sem keep-alive.** Cada POST abre uma ligação TCP nova. O Toxiproxy aplica a
  probabilidade de um toxic por ligação, por isso só assim ela vale por pedido. O
  header `connection: keep-alive` é enviado na mesma (é o do httpx2), mas o pool
  não guarda ligações.
- **`list_tools()` de aquecimento.** O SDK pede `tools/list` a seguir ao primeiro
  `tools/call` de um `Client`, para validar a resposta estruturada. O aquecimento
  evita que um corte nesse pedido extra seja confundido com a perda da resposta.
- **`TransporteComCortes`.** No SDK 2.3.0, um corte de ligação durante a resposta
  (`httpx2.ReadError` ou `httpx2.RemoteProtocolError`) não falha só aquela
  chamada: termina o transporte e o `Client` inteiro. Um `Client` novo recomeçaria
  os ids em 1. O cliente usa por isso um transporte httpx2 que regista o corte e o
  entrega ao SDK como uma resposta HTTP 502 sintética. O SDK transforma respostas
  não-2xx num `MCPError` só dessa chamada, e o `Client` continua.
- **Cancelamento.** Quando o cliente desiste de uma tentativa, o SDK não envia
  nenhum POST de cancelamento e o servidor cancela o handler (o nginx regista 499).
  Como a cobrança já foi gravada antes da espera, isto não muda o efeito.

## Condições

| Condição | Réplicas | Toxiproxy | O que acontece |
|---|---|---|---|
| C-controlo | sem atraso | sem toxics | todas as respostas chegam |
| C-atraso | `FAULT_DELAY_MS=3000`, `FAULT_PROB=0.3`, `FAULT_SEED=42` | sem toxics | cerca de 30 % das tentativas recebem a resposta depois do timeout de 2 s |
| C-rede | sem atraso | `reset_peer`, `timeout=0`, downstream, toxicidade 0.3 | cerca de 30 % das tentativas perdem a resposta |
| C-atraso-cache | como C-atraso, com `DEDUP_MEMORIA=1` | sem toxics | como C-atraso, com a deduplicação em memória por réplica (Passo 7) |

Na v2 observou-se: 231 tentativas com atraso em 817 em C-atraso (28,3 %, iguais
às tentativas com timeout) e 244 cortes em 835 tentativas em C-rede (29,2 %).

### O toxic de C-rede

- **`reset_peer` com `timeout=0`, só no sentido downstream** (do servidor para o
  cliente), para o pedido chegar intacto ao servidor.
- **Como funciona.** No código do Toxiproxy 2.13.0 (`toxics/reset_peer.go`), este
  toxic espera pelo primeiro bloco de dados da resposta, descarta-o e fecha a
  ligação com `SO_LINGER` 0, ou seja com um TCP RST. O cliente recebe
  `httpx2.ReadError` (connection reset by peer).
- **Porque o corte é sempre depois do commit.** No caminho 2026-07-28 o servidor
  responde com `application/json` e só envia o primeiro byte da resposta depois de
  o handler terminar.
- **Alternativas consideradas.** `limit_data` com `bytes=0` corta no mesmo
  momento, mas fecha com FIN (`RemoteProtocolError`); foi testado e funciona, mas
  representa pior uma falha de rede. O toxic `timeout` levaria o cliente ao
  timeout de 2 s, como em C-atraso.

## Medida

`medir.sh` carrega os CSVs do cliente na tabela `pedidos_cliente` e os registos
JSONL na tabela `tentativas_cliente` (uma coluna `jsonb`), e cria as vistas de
`db/medida.sql`:

- **`medida_por_pedido`:** linhas, duplicados e réplica de cada duplicado, por
  pedido lógico. A lista de pedidos vem do cliente, para contar também os pedidos
  sem nenhuma linha.
- **`medida_por_repeticao`:** duplicados por `run_id`.
- **`resumo`:** uma linha por condição. É o conteúdo de `results/resumo.csv`.
- **`latencia`:** mediana e p95 do `call_tool` por rota, com e sem a 1.ª chamada.
- **`resumo_md_duplicados`, `resumo_md_replicas` e `latencia_md`:** as tabelas
  Markdown.

Verificação da v2: em todas as condições, o número de tentativas no CSV é igual
ao número de linhas do registo JSONL e, sem cache, ao número de linhas em
`charges` de cada pedido. Em C-atraso-cache há 50 tentativas a mais do que linhas,
que são os 50 acertos da cache registados nos logs das réplicas.

## Versões exatas

| Componente | Versão | Origem |
|---|---|---|
| SDK Python do MCP | `mcp` 2.3.0, `mcp-types` 2.3.0 | PyPI, publicado a 2026-10-02 |
| Revisão do protocolo MCP | 2026-07-28 | `Client(..., mode="2026-07-28")` |
| Python | 3.13.18, pip 26.2.2 | `python:3.13.18-slim-trixie@sha256:76baad6037690d6e8c4397fbcaef17bca6f19eecef822b708fe8fa3417d30bb5` |
| PostgreSQL | 18.6 | `postgres:18.6-alpine@sha256:10a5c69a83035ab5239f5620d708520e8b28f5aa1f2b20143e6024532edadfb5` |
| nginx | 1.30.6 (ramo estável) | `nginx:1.30.6-alpine@sha256:0e52bd054126cdc040b1276c0af347aeb02a41b9cfe305d6094767ac30e97949` |
| Toxiproxy | 2.13.0 | `ghcr.io/shopify/toxiproxy:2.13.0@sha256:5d3dae09bc185dcc5ff6cf43abf6062a4a720aff0c4306a471e773acdcd107aa` |
| Outras dependências Python | httpx2 2.16.0, starlette 1.10.0, uvicorn 0.54.0, pydantic 2.14.2, anyio 4.15.1, sse-starlette 3.6.0, psycopg 3.3.6, psycopg-pool 3.3.3 | `server/requirements.lock`, `client/requirements.lock` |

Os digests são de índices multi-arquitetura. Os ficheiros `requirements.lock` têm
todas as dependências, diretas e transitivas, resolvidas dentro da imagem Python
fixada (`pip install -r requirements.txt && pip freeze`). As imagens instalam a
partir deles.

Ambiente onde o ensaio correu: macOS 15.7.4 (arm64), Docker 29.1.3 (linux/arm64),
Docker Compose v2.40.3.

### Porque o SDK 2.3.0 serve para o ensaio

Segundo a documentação do SDK (páginas "What's new in v2", "Protocol versions" e
"Deploy & scale" em <https://py.sdk.modelcontextprotocol.io/>):

- a versão 2 implementa a revisão 2026-07-28, que elimina o handshake `initialize`
  e a sessão;
- no caminho 2026-07-28 sobre Streamable HTTP o servidor nunca define
  `Mcp-Session-Id`: cada pedido é um POST independente e qualquer réplica atrás de
  um balanceador round-robin o pode atender;
- `stateless_http=True` só afeta clientes da era 2025, por isso não é necessário;
- o cliente pode fixar a revisão com `Client(url, mode="2026-07-28")`, sem sonda
  `server/discover` nem handshake.

No ensaio confirmou-se que nenhuma resposta traz `Mcp-Session-Id` e que pedidos
seguidos do mesmo cliente são atendidos alternadamente pelas duas réplicas.

## Esquema

```sql
charges(id serial PK, run_id text, request_no int, amount_cents int,
        replica text, fault_injected boolean default false,
        created_at timestamptz default now())
```

Não há restrição `UNIQUE` em `(run_id, request_no)`, de propósito.

## Limitações

- **O atraso de C-atraso é injetado no próprio servidor.** Depois do commit, a
  réplica sorteada espera `FAULT_DELAY_MS` antes de responder. Não é uma falha de
  rede real.
- **Não há gateway.** O ensaio só reproduz o problema; não avalia nenhuma solução.
  A cache do Passo 7 é uma variante ingénua, para mostrar porque é que estado
  local não chega.
- **É um ensaio preliminar, não a avaliação da dissertação.** Uma máquina, um
  cliente, duas réplicas, uma ferramenta e uma política de repetição fixa.
- **A réplica de cada repetição é determinada pela montagem.** Com o round-robin
  estrito (um processo nginx), um cliente sequencial e nenhum outro tráfego, as
  tentativas alternam entre as réplicas. Com mais réplicas, tráfego concorrente ou
  outro algoritmo de balanceamento, as percentagens de "outra réplica" e o efeito
  da cache por réplica seriam diferentes. Com N réplicas e um balanceador
  aleatório, a probabilidade de a repetição cair na mesma réplica seria cerca de
  1/N.
- **Não há pedidos concorrentes.** Duas tentativas do mesmo pedido nunca estão em
  curso ao mesmo tempo. Também não se testa a corrida de verificar e depois
  inserir.
- **A política de repetição é do cliente de ensaio, não do SDK.** O SDK não repete
  pedidos sozinho (verificado na emenda 3). A política usada é repetição imediata,
  sem backoff, com até 3 tentativas e timeout de 2 s, e os números dependem destes
  valores.
- **O transporte do cliente foi adaptado.** No SDK 2.3.0 um corte de ligação
  termina o `Client`. O cliente converte esses cortes em respostas 502 sintéticas
  para continuar no mesmo `Client`; um cliente real teria de tratar este caso de
  outra forma.
- **O registo JSONL guarda a resposta interpretada pelo SDK**, e não o corpo HTTP
  original da resposta.
- **C-rede cobre só cortes depois de o servidor responder.** O toxic corta no
  primeiro byte da resposta, por isso o efeito acontece sempre. Não cobre cortes
  antes de o pedido chegar ao servidor (que não geram duplicados) nem durante o
  processamento.
- **A rede é local.** O cliente abre uma ligação por pedido para a probabilidade do
  toxic valer por pedido; um cliente com keep-alive veria outro padrão de cortes.
  Tudo corre em Docker numa só máquina, com latências de rede quase nulas, por isso
  a latência medida é um limite inferior.
- **C-rede é aleatório.** O Toxiproxy não usa uma semente fixa, por isso repetir o
  ensaio dá valores próximos, mas não iguais. O sorteio do atraso de C-atraso tem
  semente; com o cliente sequencial e o round-robin estrito, a mesma execução deve
  repetir as mesmas decisões.
