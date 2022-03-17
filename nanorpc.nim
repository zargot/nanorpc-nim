import std/[
    asyncdispatch,
    httpclient,
    json,
    jsonutils,
    logging,
    oids,
    os,
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

proc newNanoRPC*(): HttpClient =
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

proc subscribe*(s: WebSocket; id, topic: string;
                accounts: openArray[string] = []) =
    let req = %*{
        "action": "subscribe",
        "topic": topic,
        "ack": true,
        "id": id,
    }
    debug req
    waitFor ws.send(s, $req)

type
    NanoEventKind* = enum
        nekAck, nekConfirmation

    Event* = object
        id*: string
        case kind*: NanoEventKind
        of nekAck:
            ack*: string
        else:
            discard

proc process*(sock: WebSocket; ev: var Event; timeout = 0): bool  =
    # TODO: remove timeout?
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
        ev = Event(kind: nekAck, ack: data["ack"].getStr, id: data["id"].getStr)
        return true

    let topic = data["topic"].getStr
    case topic
    of "confirmation":
        ev = Event(kind: nekConfirmation, id: data["message"]["hash"].getStr)
        return true

proc processAck*(s: WebSocket; id: string): bool =
    var ev: Event
    s.process(ev) and ev.kind == nekAck and ev.id == id

import unittest

template send =
    assert accounts.len >= 2
    let
        b0 = balances[0].balance
        b1 = balances[1].balance
    assert b0 != "0" or b1 != "0"
    var
        src = accounts[0]
        dst = accounts[1]
    if b0 == "0":
        swap src, dst
    let
        amount = "1"
        id = $genOid()
    (ok, blockId) = nano.send(wallet, src, dst, amount, id)
    assert ok

when isMainModule:
    suite "tests":
        addHandler newConsoleLogger(lvlInfo)
        let
            config = parseFile "config.json"
            wallet = config["wallet"].getStr
            nano = newNanoRPC()
            sock = waitFor newWebSocket("ws://127.0.0.1:17078")

        var
            ok: bool
            accounts: seq[string]
            balances: seq[Balance]
            blockId: string

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
            let id = $genOid()
            sock.subscribe(id, "confirmation", [])#accounts)
            assert ok
            var ev: Event
            ok = sock.process(ev)
            assert ok
            check ev.id == id

        when true:#false and defined control:
            test "send":
                send()

        test "confirm block":
            var ev: Event
            check sock.process(ev)
            check ev.kind == nekConfirmation
            check ev.id == blockId

        test "wallet balances":
            let (ok, _) = nano.wallet_balances(wallet)
            assert ok

        when false and defined control:
            test "account repr set":
                let acc = accounts[0]
                ok = nano.account_representative_set(wallet, acc, acc)
                assert ok

