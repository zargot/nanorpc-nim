{.this: self.}

import sequtils
import httpclient except request
import json

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

template error(msg) =
    echo "RPC error: ", msg

proc newNanoRPC(): NanoRPC =
    result.new()
    result.client = newHttpClient()
    result.client.headers = newHttpHeaders({ "Content-Type": "application/json" })

proc request(self: NanoRPC, body: JsonNode): (bool, JsonNode) =
    try:
        let res = httpclient.request(client, url, HttpPost, $body)
        if res.code != 200.HttpCode:
            error res.repr
            return
        let data = res.body.parseJson
        if data.hasKey("error"):
            error data["error"].getStr
            return
        return (true, data)
    except:
        error getCurrentExceptionMsg()
        discard

proc account_balance*(self: NanoRPC, acc: string): (bool, Balance) =
    assert acc.len == 64
    let
        body = %*{ "action": getProcName(), "account": acc }
        (ok, data) = request(body)
    if not ok:
        return
    (true, (data["balance"].getStr, data["pending"].getStr))

proc account_create*(self: NanoRPC, wallet: string): (bool, string) =
    assert wallet.len == 64
    let
        body = %*{ "action": getProcName(), "wallet": wallet }
        (ok, data) = request(body)
    if not ok:
        return
    (true, data["account"].getStr)

proc account_remove*(self: NanoRPC, wallet, acc: string): bool =
    assert wallet.len == 64
    assert acc.len == 64
    let
        body = %*{ "action": getProcName(), "wallet": wallet, "account": acc }
        (ok, data) = request(body)
    if not ok:
        return
    data["removed"].getStr == "1"

proc account_list*(self: NanoRPC, wallet: string): (bool, seq[string])
                  {.raises: [].} =
    assert wallet.len == 64
    let
        body = %*{ "action": getProcName(), "wallet": wallet }
        (ok, data) = request(body)
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

proc account_representative_set*(self: NanoRPC, wallet, acc, rep: string): bool =
    assert wallet.len == 64
    assert acc.len == 64
    assert rep.len == 64
    let
        body = %*{
            "action": getProcName(),
            "wallet": wallet,
            "account": acc,
            "representative": rep
        }
        (ok, _) = request(body)
    ok

when defined testing:
    import unittest
    import os

    suite "tests":
        var nano: NanoRPC
        var wallet: string

        let config = parseFile "config.json"
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

        when defined control:
            test "account repr set":
                    ok = nano.account_representative_set(wallet, acc, acc)
                    assert ok
