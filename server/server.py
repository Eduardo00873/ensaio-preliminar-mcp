"""Servidor MCP do ensaio preliminar.

Expõe uma única ferramenta, `charge`, com um efeito real e não idempotente:
cada chamada insere uma linha na tabela `charges` e faz COMMIT. Por omissão o
servidor não deduplica nada; é isso que o ensaio quer observar.

Variáveis de ambiente:
  DATABASE_URL    ligação ao PostgreSQL (obrigatória)
  REPLICA_NAME    nome desta réplica, gravado em cada linha e devolvido ao cliente
  FAULT_DELAY_MS  se > 0, espera este tempo DEPOIS do commit e antes de responder,
                  em cada chamada com probabilidade FAULT_PROB
  FAULT_PROB      probabilidade de injetar o atraso numa chamada (por omissão 0.3)
  FAULT_SEED      semente do gerador aleatório (por omissão 42). Cada réplica usa
                  a semente combinada com o seu nome, para que as duas não sigam a
                  mesma sequência; a mesma réplica com a mesma semente, recriada,
                  repete a sequência de decisões
  DEDUP_MEMORIA   se "1", liga a variante do Passo 7: deduplicação ingénua com uma
                  cache em memória deste processo, chave (run_id, request_no).
                  Cada réplica tem a sua cache; nada é partilhado.

Serve-se com uvicorn (ver Dockerfile): `uvicorn server:app`.
"""

import logging
import os
import random
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import TypedDict

import anyio
from psycopg_pool import AsyncConnectionPool
from starlette.requests import Request
from starlette.responses import JSONResponse, Response

from mcp.server import MCPServer
from mcp.server.mcpserver import Context
from mcp.server.transport_security import TransportSecuritySettings

DATABASE_URL = os.environ["DATABASE_URL"]
REPLICA_NAME = os.environ.get("REPLICA_NAME", "replica-desconhecida")
FAULT_DELAY_MS = int(os.environ.get("FAULT_DELAY_MS", "0"))
FAULT_PROB = float(os.environ.get("FAULT_PROB", "0.3"))
FAULT_SEED = os.environ.get("FAULT_SEED", "42")
DEDUP_MEMORIA = os.environ.get("DEDUP_MEMORIA", "0") == "1"

# Gerador com semente: a decisão de injetar o atraso é reproduzível. Só é consultado
# quando FAULT_DELAY_MS > 0 e a chamada faz INSERT (não nos acertos da cache).
_rng = random.Random(f"{FAULT_SEED}:{REPLICA_NAME}")

log = logging.getLogger("ensaio.server")


@dataclass
class AppContext:
    pool: AsyncConnectionPool


@asynccontextmanager
async def app_lifespan(server: MCPServer) -> AsyncIterator[AppContext]:
    # O lifespan corre uma vez por processo, por isso o pool é partilhado por
    # todos os pedidos que esta réplica atende.
    pool = AsyncConnectionPool(DATABASE_URL, min_size=1, max_size=10, open=False)
    await pool.open(wait=True)
    log.info("réplica %s pronta (FAULT_DELAY_MS=%d, FAULT_PROB=%s, FAULT_SEED=%s, DEDUP_MEMORIA=%d)",
             REPLICA_NAME, FAULT_DELAY_MS, FAULT_PROB, FAULT_SEED, DEDUP_MEMORIA)
    try:
        yield AppContext(pool=pool)
    finally:
        await pool.close()


# O nome do servidor é igual nas duas réplicas: são cópias da mesma imagem.
mcp = MCPServer("ensaio-cobrancas", lifespan=app_lifespan)


class ChargeResult(TypedDict):
    charge_id: int
    replica: str


# Variante do Passo 7: cache local deste processo, (run_id, request_no) -> resultado.
# É de propósito ingénua: não é partilhada entre réplicas, perde-se ao reiniciar e
# não protege contra dois pedidos iguais em simultâneo.
_cache: dict[tuple[str, int], ChargeResult] = {}


@mcp.tool()
async def charge(
    run_id: str,
    request_no: int,
    amount_cents: int,
    ctx: Context[AppContext],
) -> ChargeResult:
    """Grava uma cobrança e devolve o id da linha e a réplica que a gravou."""
    pool = ctx.request_context.lifespan_context.pool

    # Variante do Passo 7: se esta réplica já executou o pedido, devolve o resultado
    # guardado sem novo INSERT. Não houve commit, por isso também não há atraso.
    if DEDUP_MEMORIA:
        anterior = _cache.get((run_id, request_no))
        if anterior is not None:
            log.info(
                "cache: jsonrpc_id=%s run_id=%s request_no=%d -> charge_id=%d (sem INSERT)",
                ctx.request_id, run_id, request_no, anterior["charge_id"],
            )
            return anterior

    # A decisão de injetar o atraso é tomada antes do INSERT, para ficar gravada na
    # própria linha (fault_injected).
    injetar = FAULT_DELAY_MS > 0 and _rng.random() < FAULT_PROB

    # 1. Efeito real: INSERT e COMMIT. A transação fecha (commit) ao sair do bloco.
    async with pool.connection() as conn:
        async with conn.transaction():
            cur = await conn.execute(
                "INSERT INTO charges (run_id, request_no, amount_cents, replica, fault_injected)"
                " VALUES (%s, %s, %s, %s, %s) RETURNING id",
                (run_id, request_no, amount_cents, REPLICA_NAME, injetar),
            )
            row = await cur.fetchone()
    charge_id = row[0]
    log.info(
        "commit: jsonrpc_id=%s run_id=%s request_no=%d charge_id=%d fault_injected=%s",
        ctx.request_id, run_id, request_no, charge_id, injetar,
    )
    resultado: ChargeResult = {"charge_id": charge_id, "replica": REPLICA_NAME}
    # Guardado logo a seguir ao commit, antes do atraso: se o handler for cancelado
    # durante a espera, a repetição que chegue a esta réplica encontra-o na cache.
    if DEDUP_MEMORIA:
        _cache[(run_id, request_no)] = resultado

    # 2. Falha injetada: só depois do commit, e só nas chamadas sorteadas. Se o
    #    cliente desistir durante esta espera, o SDK cancela o handler, mas a linha
    #    já está gravada.
    if injetar:
        await anyio.sleep(FAULT_DELAY_MS / 1000)

    # 3. Resposta: id da linha e nome da réplica.
    log.info("resposta: jsonrpc_id=%s charge_id=%d", ctx.request_id, charge_id)
    return resultado


@mcp.custom_route("/health", methods=["GET"])
async def health(request: Request) -> Response:
    return JSONResponse({"status": "ok", "replica": REPLICA_NAME})


# Atrás do nginx e do Toxiproxy o cabeçalho Host não é localhost, e a proteção
# contra DNS rebinding rejeitaria todos os pedidos com 421. A documentação do SDK
# (Deploy & scale) indica desligá-la quando um proxy controla o Host.
app = mcp.streamable_http_app(
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
)
