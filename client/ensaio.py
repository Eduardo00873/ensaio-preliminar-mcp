"""Cliente de ensaio: uma repetição (run) de N pedidos lógicos à ferramenta `charge`.

Para cada pedido lógico (run_id, request_no) o cliente faz tools/call com um
timeout configurável. Se der timeout ou se a ligação for cortada, repete o pedido
como pedido NOVO, com um id JSON-RPC novo (o que a revisão 2026-07-28 manda), até
ao máximo de tentativas. Não há deduplicação de nenhum tipo: os argumentos da
repetição são iguais aos do original, e é o servidor que decide o que fazer.

Cada pedido lógico dá uma linha no CSV indicado em --csv (acrescenta ao ficheiro).
Cada tentativa dá uma linha no registo JSONL indicado em --trace: horas de envio e
de receção, id e método JSON-RPC, headers HTTP enviados e recebidos, `_meta`,
argumentos, resposta ou erro, e a réplica que respondeu. É o "cliente de teste" da
dissertação.

Decisões de implementação (ver README):
- Um único `Client` do SDK por repetição, com a revisão fixada em 2026-07-28 (sem
  server/discover, sem handshake, sem sessão). Os ids JSON-RPC são atribuídos pelo
  SDK e crescem dentro do mesmo `Client`; o cliente confirma que cada tentativa
  levou um id diferente e aborta se não for assim.
- Sem keep-alive: cada POST usa uma ligação TCP nova, para que a probabilidade de
  um toxic do Toxiproxy (aplicada por ligação) valha por pedido.
- Um `list_tools()` de aquecimento antes do primeiro pedido. Sem ele, o SDK pede
  tools/list a seguir ao primeiro tools/call (para validar a resposta estruturada),
  e um corte nesse pedido extra seria confundido com a perda da resposta.
- No SDK 2.3.0 um corte de ligação durante a resposta (httpx2.ReadError ou
  httpx2.RemoteProtocolError) não falha só a chamada: termina o transporte e o
  `Client` inteiro. O `TransporteComCortes` converte esse corte numa resposta HTTP
  502 sintética e regista-o; o SDK transforma respostas não-2xx num MCPError
  dessa chamada e o `Client` continua utilizável, com os ids a crescer.
"""

import argparse
import csv
import datetime
import json
import logging
import os
import sys
import time

import anyio
import httpx2
from mcp import Client
from mcp.client.streamable_http import streamable_http_client
from mcp.shared.exceptions import MCPError
from mcp.types import REQUEST_TIMEOUT

log = logging.getLogger("ensaio.cliente")

CAMPOS_CSV = [
    "run_id",
    "request_no",
    "tentativas",
    "resultado_final",
    "replicas_que_responderam",
    "jsonrpc_ids",
    "resultados_tentativas",
    "duracao_ms",
]

# Resultados de tentativa que levam a repetir o pedido.
REPETIVEIS = {"timeout", "ligacao"}


class TransporteComCortes(httpx2.AsyncBaseTransport):
    """Transporte httpx2 sem keep-alive que regista os cortes de ligação.

    Um corte (ligação fechada ou reposta antes de a resposta chegar) é devolvido
    ao SDK como HTTP 502 sintético, com o cabeçalho x-ensaio-corte, em vez de
    deixar a exceção terminar o transporte.
    """

    def __init__(self) -> None:
        self.interno = httpx2.AsyncHTTPTransport(limits=httpx2.Limits(max_keepalive_connections=0))
        self.cortes: list[str] = []

    async def handle_async_request(self, request: httpx2.Request) -> httpx2.Response:
        try:
            return await self.interno.handle_async_request(request)
        except (httpx2.NetworkError, httpx2.RemoteProtocolError) as e:
            self.cortes.append(f"{type(e).__name__}: {e}".strip(": "))
            return httpx2.Response(
                502,
                headers={"x-ensaio-corte": "1"},
                content=b"ligacao cortada (sintetico, cliente de ensaio)",
                request=request,
            )

    async def aclose(self) -> None:
        await self.interno.aclose()


def agora() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="microseconds")


class RegistoPedidos:
    """Regista cada POST que o SDK envia e, para os tools/call, a troca HTTP completa.

    Uma "troca" junta o que foi enviado (hora, id e método JSON-RPC, headers, `_meta`
    e argumentos) com o que foi recebido (hora, estado HTTP e headers). As horas são
    as dos event hooks do httpx2: envio antes de o pedido sair, receção quando chegam
    os headers da resposta.
    """

    def __init__(self) -> None:
        self.ids_tools_call: list[int | str] = []
        self.outros: list[str] = []
        self.trocas: list[dict] = []
        self._pendentes: dict[httpx2.Request, dict] = {}

    async def on_request(self, request: httpx2.Request) -> None:
        enviado_em = agora()
        try:
            corpo = json.loads(request.content)
        except (ValueError, httpx2.RequestNotRead):
            self.outros.append("corpo-ilegivel")
            return
        if corpo.get("method") != "tools/call":
            self.outros.append(f"{corpo.get('method')}#{corpo.get('id')}")
            return
        self.ids_tools_call.append(corpo.get("id"))
        params = corpo.get("params") or {}
        troca = {
            "jsonrpc_id": corpo.get("id"),
            "metodo": corpo.get("method"),
            "enviado_em": enviado_em,
            "recebido_em": None,
            "http_status": None,
            "headers_enviados": dict(request.headers),
            "headers_recebidos": None,
            "resposta_sintetica": False,
            "meta": params.get("_meta"),
            "argumentos": params.get("arguments"),
        }
        self.trocas.append(troca)
        self._pendentes[request] = troca

    async def on_response(self, response: httpx2.Response) -> None:
        troca = self._pendentes.pop(response.request, None)
        if troca is None:
            return
        troca["recebido_em"] = agora()
        troca["http_status"] = response.status_code
        troca["headers_recebidos"] = dict(response.headers)
        # Resposta 502 criada pelo TransporteComCortes: não veio da rede.
        troca["resposta_sintetica"] = response.headers.get("x-ensaio-corte") == "1"


async def aquecer(client: Client, max_tentativas: int = 10) -> None:
    # tools/list é só de leitura: repetir não tem efeitos.
    for tentativa in range(1, max_tentativas + 1):
        try:
            await client.list_tools()
            return
        except MCPError as e:
            log.warning("aquecimento: list_tools falhou (tentativa %d): %s", tentativa, e)
            await anyio.sleep(0.2)
    raise RuntimeError("aquecimento: list_tools falhou em todas as tentativas")


async def pedido_logico(
    client: Client,
    transporte: TransporteComCortes,
    registo: RegistoPedidos,
    args: argparse.Namespace,
    request_no: int,
    trace,
) -> dict[str, str | int]:
    argumentos = {"run_id": args.run_id, "request_no": request_no, "amount_cents": args.montante}
    ids: list[int | str] = []
    resultados: list[str] = []
    replicas: list[str] = []
    inicio = time.monotonic()

    for tentativa in range(1, args.tentativas + 1):
        n_ids = len(registo.ids_tools_call)
        n_trocas = len(registo.trocas)
        n_cortes = len(transporte.cortes)
        t0 = time.monotonic()
        detalhe = ""
        resposta = erro = replica = None
        try:
            r = await client.call_tool("charge", argumentos, read_timeout_seconds=args.timeout)
        except MCPError as e:
            erro = {"tipo": type(e).__name__, "codigo": e.code, "mensagem": str(e)}
            if e.code == REQUEST_TIMEOUT:
                resultado = "timeout"
            elif len(transporte.cortes) > n_cortes:
                resultado = "ligacao"
                detalhe = transporte.cortes[-1]
                erro["corte"] = detalhe
            else:
                resultado = f"erro_protocolo({e.code})"
                detalhe = str(e)
        else:
            resposta = r.model_dump(mode="json", by_alias=True, exclude_none=True)
            if r.is_error:
                resultado = "erro_ferramenta"
            else:
                resultado = "ok"
                replica = r.structured_content["replica"]
                replicas.append(replica)
                detalhe = f"charge_id={r.structured_content['charge_id']} replica={replica}"
        concluido_em = agora()

        # Cada tentativa tem de corresponder a exatamente um POST tools/call novo.
        novos = registo.ids_tools_call[n_ids:]
        if len(novos) != 1 or len(registo.trocas) - n_trocas != 1:
            raise RuntimeError(f"pedido {request_no} tentativa {tentativa}: esperava 1 tools/call, vi {novos}")
        ids.append(novos[0])
        resultados.append(resultado)

        # Uma linha JSONL por tentativa.
        troca = registo.trocas[-1]
        trace.write(json.dumps({
            "run_id": args.run_id,
            "request_no": request_no,
            "tentativa": tentativa,
            **troca,
            "concluido_em": concluido_em,
            "duracao_ms": round((time.monotonic() - t0) * 1000, 3),
            "resultado": resultado,
            "resposta": resposta,
            "erro": erro,
            "replica": replica,
        }, ensure_ascii=False) + "\n")
        trace.flush()
        log.info(
            "%s pedido %d tentativa %d/%d jsonrpc_id=%s -> %s (%.3f s)%s",
            args.run_id, request_no, tentativa, args.tentativas, novos[0], resultado,
            time.monotonic() - t0, f" [{detalhe}]" if detalhe else "",
        )
        if resultado not in REPETIVEIS:
            break

    # Garantia pedida: cada repetição levou um id JSON-RPC diferente.
    if len(set(ids)) != len(ids):
        raise RuntimeError(f"pedido {request_no}: ids JSON-RPC repetidos {ids}")

    ultimo = resultados[-1]
    resultado_final = "esgotado" if ultimo in REPETIVEIS else ultimo
    return {
        "run_id": args.run_id,
        "request_no": request_no,
        "tentativas": len(resultados),
        "resultado_final": resultado_final,
        "replicas_que_responderam": ";".join(replicas),
        "jsonrpc_ids": ";".join(str(i) for i in ids),
        "resultados_tentativas": ";".join(resultados),
        "duracao_ms": round((time.monotonic() - inicio) * 1000),
    }


async def executar(args: argparse.Namespace) -> None:
    transporte = TransporteComCortes()
    registo = RegistoPedidos()
    linhas: list[dict[str, str | int]] = []

    # Os timeouts do httpx2 são os que o SDK usa por omissão; o timeout do ensaio
    # é o read_timeout_seconds de cada call_tool.
    with open(args.trace, "a", encoding="utf-8") as trace:
        async with httpx2.AsyncClient(
            transport=transporte,
            timeout=httpx2.Timeout(30.0, read=300.0),
            event_hooks={"request": [registo.on_request], "response": [registo.on_response]},
        ) as http:
            async with Client(streamable_http_client(args.url, http_client=http), mode="2026-07-28") as client:
                await aquecer(client)
                cortes_aquecimento = len(transporte.cortes)
                outros_antes = len(registo.outros)
                for request_no in range(1, args.pedidos + 1):
                    linhas.append(await pedido_logico(client, transporte, registo, args, request_no, trace))
                extra = registo.outros[outros_antes:]

    if extra:
        log.warning("%s: POSTs que não são tools/call durante os pedidos: %s", args.run_id, extra)
    if len(set(registo.ids_tools_call)) != len(registo.ids_tools_call):
        raise RuntimeError(f"{args.run_id}: ids JSON-RPC repetidos na repetição")

    novo = not os.path.exists(args.csv) or os.path.getsize(args.csv) == 0
    with open(args.csv, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=CAMPOS_CSV)
        if novo:
            w.writeheader()
        w.writerows(linhas)

    tentativas = sum(int(l["tentativas"]) for l in linhas)
    finais: dict[str, int] = {}
    for l in linhas:
        finais[str(l["resultado_final"])] = finais.get(str(l["resultado_final"]), 0) + 1
    log.info(
        "%s: %d pedidos lógicos, %d tentativas (tools/call), resultados finais %s, "
        "cortes de ligação %d (+%d no aquecimento), POSTs extra %d -> %s",
        args.run_id, len(linhas), tentativas, finais, len(transporte.cortes) - cortes_aquecimento,
        cortes_aquecimento, len(extra), args.csv,
    )


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--run-id", required=True, help="identificador da repetição, por exemplo C-atraso-07")
    p.add_argument("--csv", required=True, help="ficheiro CSV onde acrescentar as linhas")
    p.add_argument("--url", default="http://toxiproxy:8666/mcp")
    p.add_argument("--pedidos", type=int, default=20, help="pedidos lógicos por repetição")
    p.add_argument("--timeout", type=float, default=2.0, help="timeout de cliente por tentativa, em segundos")
    p.add_argument("--tentativas", type=int, default=3, help="máximo de tentativas por pedido lógico (total)")
    p.add_argument("--montante", type=int, default=1000, help="amount_cents de cada cobrança")
    p.add_argument("--trace", help="registo JSONL, uma linha por tentativa "
                                   "(por omissão, o --csv com _trace.jsonl em vez de .csv)")
    args = p.parse_args()
    if not args.trace:
        args.trace = args.csv.removesuffix(".csv") + "_trace.jsonl"

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", stream=sys.stdout)
    logging.getLogger("httpx2").setLevel(logging.WARNING)
    anyio.run(executar, args)


if __name__ == "__main__":
    main()
