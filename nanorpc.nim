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

proc subscribe(s: WebSocket; id, topic: string;
               accounts: openArray[string] = []) =
    let req = %*{
        "action": "subscribe",
        "topic": topic,
        "ack": true,
        "id": id,
        "options": {
            "accounts": accounts,
        }
    }
    debug req
    waitFor ws.send(s, $req)

type
    NanoEventKind = enum
        nekAck, nekConfirmation

    Event = object
        id: string
        case kind: NanoEventKind
        of nekAck:
            topic: string
        else:
            discard

proc process(sock: WebSocket; timeout = 0): Event  =
    let futRes = sock.receiveStrPacket()
    var res: string
    block:
        if timeout > 0:
            if not waitFor withTimeout(futRes, timeout):
                return
            res = futRes.read
        else:
            res = waitFor futRes

    let data = res.parseJson
    if data.hasKey("ack"):
        return Event(kind: nekAck, topic: data["ack"].getStr, id: data["id"].getStr)

    let topic = data["topic"].getStr
    case topic
    of "confirmation":
        return Event(kind: nekConfirmation, id: data["hash"].getStr)

import unittest

when isMainModule:
    suite "tests":
        addHandler newConsoleLogger()
        let
            config = parseFile "config.json"
            wallet = config["wallet"].getStr
            nano = newNanoRPC()
            sock = waitFor newWebSocket("ws://127.0.0.1:17078")

        var
            ok: bool
            accounts: seq[string]
            balances: seq[Balance]
            ev: Event

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

        test "account balance":
            balances.setLen accounts.len
            for i, acc in accounts:
                (ok, balances[i]) = nano.account_balance(acc)
                assert ok

        test "subscribe to confirmations":
            let id = $genId()
            sock.subscribe(id, "confirmation", accounts)
            assert ok
            ev = sock.process()
            check ev.id == id

        when false and defined control:
            test "send":
                assert accounts.len >= 2
                assert balances[0] > 0 or balance[1] > 0
                var
                    src = accounts[0]
                    dst = accounts[1]
                if balances[0].parseInt < balances[1].parseInt:
                    swap src, dst
                let amount = balances[0]
                (ok, blockId) = nano.send(wallet, src, dst, amount)
                assert ok
                echo "sent ", amount, " raw"

        test "confirm block":
            discard

        test "wallet balances":
            let (ok, balances) = nano.wallet_balances(wallet)
            assert ok

        when false and defined control:
            test "account repr set":
                let acc = accounts[0]
                ok = nano.account_representative_set(wallet, acc, acc)
                assert ok

