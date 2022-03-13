import std/[
    asyncdispatch,
    httpclient,
    json,
    jsonutils,
    logging,
    strutils,
]
import macros except error

import ws

type
    Account = object
        frontier, openBlock, repBlock, balance, modTime, blockCount: string

    Block = object
        kind, prev, dst, balance, work, sig: string

    Balance* = tuple
        balance, pending, receivable: string

const
    hostUrl = "http://127.0.0.1:17076"

using
    client: HttpClient

template getProcName(): string =
    $getFrame().procname

template printErr(msg) =
    echo "RPC error: ", msg

proc newNanoRPC(): HttpClient =
    result = newHttpClient()
    result.headers = newHttpHeaders({ "Content-Type": "application/json" })

proc rpcImpl(client; body: JsonNode): (bool, JsonNode)
            {.raises: [].} =
    try:
        let req = $body
        debug req
        let res = client.request(hostUrl, HttpPost, req)
        if res.code != 200.HttpCode:
            printErr res.repr
            return
        let data = res.body.parseJson
        debug data
        if data.hasKey("error"):
            printErr data["error"].getStr
            return
        return (true, data)
    except:
        printErr getCurrentExceptionMsg()
        discard

macro buildBody(body: JsonNode, args: varargs[string]): untyped =
    result = newNimNode nnkStmtList
    for a in args:
        let
            key = newLit($a)
            val = newCall(ident"newJString", a)
        result.add newCall(ident"add", body, key, val)

template rpc(client; args: varargs[string]): tuple[ok: bool, data: JsonNode] =
    let action = getProcName()
    var body = %*{ "action": action }
    buildBody body, args
    rpcImpl client, body

template logValueError(code) =
    try:
        code
    except ValueError as e:
        try:
            error e.msg, e.getStackTrace()
        except:
            discard

template objResponse(rpc, T): untyped =
    var res: (bool, T)
    let (ok, data) = rpc
    if ok:
        logValueError:
            res = (true, data.jsonTo(T))
    res

{.pragma: ne, raises: [].} # No Exceptions

proc logError(msg: string) {.ne.} =
    try:
        error msg
    except:
        discard

template response(rpcResponse: (bool, JsonNode); key: string; T): untyped =
    var res: tuple[ok: bool, data: T]
    block:
        let (ok, data) = rpcResponse
        if not ok:
            break
        let val = data.getOrDefault(key)
        if val.isNil:
            logError "missing value for key '{key}'"
            break
        try:
            res.data = val.jsonTo(T)
            res.ok = true
        except ValueError as e:
            logError e.msg
            break
    res

template response(rpcResponse: (bool, JsonNode); key: string): untyped =
    response(rpcResponse, key, string)

proc account_balance*(client; account: string): (bool, Balance) {.ne.} =
    objResponse(client.rpc(account), Balance)

proc account_create*(client; wallet: string): (bool, string) {.ne.} =
    response(client.rpc(wallet), "account")

proc account_list*(client; wallet: string): (bool, seq[string]) {.ne.} =
    response(client.rpc(wallet), "accounts", seq[string])

proc account_remove*(client; wallet, account: string): bool
                  {.raises: [].} =
    let res = response(client.rpc(wallet, account), "removed")
    res.ok and res.data == "1"

proc account_representative_set*(client; wallet, account,
                                 representative: string): bool =
    var dummy: JsonNode
    (result, dummy) = client.rpc(wallet, account, representative)

proc send*(client; wallet, source, destination, amount, id: string):
          (bool, string) {.ne.} =
    response(client.rpc(wallet, source, destination, amount, id), "block")

proc wallet_balances*(client; wallet: string):
                     (bool, seq[(string, Balance)]) =
    response(client.rpc(wallet), "balances", type(result[1]))

proc genId: int =
    var id {.global.}: int
    id.inc
    id

proc subscribe(s: WebSocket; topic: string; timeout = 1000): bool =
    const baseReq = """
{
  "action": "subscribe",
  "topic": "$1",
  "ack": true,
  "id": "$2"
}
"""
    let id = $genId()
    let req = baseReq % [topic, id]
    #debug req
    waitFor ws.send(s, req)
    let futRes = s.receiveStrPacket()
    while true:
        if not waitFor withTimeout(futRes, timeout):
            return
        let res = futRes.read
        #debug res
        let idNode = res.parseJson.getOrDefault("id")
        if idNode == nil:
            continue
        if idNode.getStr == id:
            return true

import unittest

when isMainModule:
    suite "tests":
        addHandler newConsoleLogger()
        let
            config = parseFile "config.json"
            wallet = config["wallet"].getStr
            nano = newNanoRPC()

        var
            ok: bool
            acc: string
            accounts: seq[string]
            balance: Balance

        test "websocket - subscribe":
            let s = waitFor newWebSocket("ws://127.0.0.1:17078")
            let ok = s.subscribe("confirmation")
            assert ok

        when false and defined control:
            test "account create/remove":
                (ok, acc) = nano.account_create(wallet)
                assert ok

                ok = nano.account_remove(wallet, acc)
                assert ok, "OBS: remove account manually:\n" & acc

        test "account list":
            (ok, accounts) = nano.account_list(wallet)
            assert ok
            assert accounts.len > 0, "no accounts present"
            acc = accounts[0]

        test "account balance":
            (ok, balance) = nano.account_balance(acc)
            assert ok

        when false and defined control:
            test "send":
                assert accounts.len >= 2
                assert balance.balance != "0"
                let
                    src = accounts[0]
                    dst = accounts[1]
                    amount = "1"
                    (ok, blockId) = nano.send(wallet, src, dst, amount)
                assert ok
                echo "sent ", amount, " raw"

        test "wallet balances":
            let (ok, balances) = nano.wallet_balances(wallet)
            assert ok

        when defined control:
            test "account repr set":
                ok = nano.account_representative_set(wallet, acc, acc)
                assert ok
