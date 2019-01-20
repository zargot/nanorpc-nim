{.this: self.}

import httpclient except request
import json
import macros
import sequtils

type
    Account = object
        frontier, openBlock, repBlock, balance, modTime, blockCount: string

    Block = object
        kind, prev, dst, balance, work, sig: string

    NanoRPC* = ref object
        client: HttpClient

    Balance* = tuple
        balance, pending: string

const
    url = "http://[::1]:7076"

template getProcName(): string =
    $getFrame().procname

template printErr(msg) =
    echo "RPC error: ", msg

proc newNanoRPC(): NanoRPC =
    result.new()
    result.client = newHttpClient()
    result.client.headers = newHttpHeaders({ "Content-Type": "application/json" })

proc rpcImpl(self: NanoRPC, body: JsonNode): (bool, JsonNode) =
    try:
        let res = httpclient.request(client, url, HttpPost, $body)
        if res.code != 200.HttpCode:
            printErr res.repr
            return
        let data = res.body.parseJson
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

template rpc(args: varargs[string]): (bool, JsonNode) =
    let action = getProcName()
    var body = %*{ "action": action }
    buildBody body, args
    echo $body
    self.rpcImpl body

proc initBalance(data: JsonNode): Balance =
    (data["balance"].getStr, data["pending"].getStr)

proc account_balance*(self: NanoRPC, account: string): (bool, Balance) =
    let (ok, data) = rpc(account)
    if not ok:
        return
    (true, initBalance(data))

proc account_create*(self: NanoRPC, wallet: string): (bool, string) =
    let (ok, data) = rpc(wallet)
    if not ok:
        return
    (true, data["account"].getStr)

proc account_list*(self: NanoRPC, wallet: string): (bool, seq[string])
                  {.raises: [].} =
    let (ok, data) = rpc(wallet)
    if not ok:
        return

    var accounts: seq[string]
    try:
        accounts = data["accounts"].getElems.mapIt(it.getStr)
    except:
        return

    assert accounts != nil
    assert accounts.len == 0 or accounts[0] != nil
    (true, accounts)

proc account_remove*(self: NanoRPC, wallet, account: string): bool =
    let (ok, data) = rpc(wallet, account)
    if not ok:
        return
    data["removed"].getStr == "1"

proc account_representative_set*(self: NanoRPC, wallet, account,
                                 representative: string): bool =
    rpc(wallet, account, representative)[0]

proc send*(self: NanoRPC, wallet, source, destination,
           amount: string): (bool, string) =
    let (ok, data) = rpc(wallet, source, destination, amount)
    if not ok:
        return
    let blockId = data["block"].getStr
    (ok, blockId)

proc wallet_balances*(self: NanoRPC, wallet: string):
                              (bool, seq[(string, Balance)]) =
    let (ok, data) = rpc(wallet)
    if not ok:
        return
    result[0] = true
    result[1] = @[]
    for acc, balance in data["balances"]:
        result[1].add (acc, initBalance(balance))

when defined testing:
    import unittest
    import os

    suite "tests":
        let
            config = parseFile "config.json"
            wallet = config["wallet"].getStr
            nano = newNanoRPC()
        echo wallet

        var
            ok: bool
            acc: string
            accounts: seq[string]
            balance: Balance

        when false and defined control:
            test "account create/remove":
                (ok, acc) = nano.account_create(wallet)
                assert ok

                ok = nano.account_remove(wallet, acc)
                assert ok, "OBS: remove account manually:\n" & acc

        test "account list":
            (ok, accounts) = nano.account_list(wallet)
            assert ok
            echo accounts
            assert accounts.len > 0, "no accounts present"
            acc = accounts[0]

        test "account balance":
            (ok, balance) = nano.account_balance(acc)
            assert ok
            echo balance

        test "wallet balances":
            let (ok, balances) = nano.wallet_balances(wallet)
            assert ok
            for pair in balances:
                echo pair[0], ": ", pair[1].balance, " (", pair[1].pending ,")"

        when defined control:
            test "account repr set":
                ok = nano.account_representative_set(wallet, acc, acc)
                assert ok
