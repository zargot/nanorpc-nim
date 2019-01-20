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

converter toString(n: JsonNode): string =
    assert n.kind == JString
    ($n)[1..^2]

template getProcName(): string =
    $getFrame().procname

proc newNanoRPC(): NanoRPC =
    result.new()
    result.client = newHttpClient()
    result.client.headers = newHttpHeaders({ "Content-Type": "application/json" })

proc request(self: NanoRPC, body: JsonNode): (bool, JsonNode) =
    try:
        let res = httpclient.request(client, url, HttpPost, $body)
        if res.code != 200.HttpCode:
            return
        let data = res.body.parseJson
        if data.hasKey("error"):
            return
        return (true, data)
    except:
        discard

proc account_balance*(self: NanoRPC, acc: string): (bool, Balance) =
    assert acc.len == 64
    let
        body = %*{ "action": getProcName(), "account": acc }
        (success, data) = request(body)
    if not success:
        return
    (true, (data["balance"].string, data["pending"].string))

proc account_create*(self: NanoRPC, wallet: string): (bool, string) =
    assert wallet.len == 64
    let
        body = %*{ "action": getProcName(), "wallet": wallet }
        (success, data) = request(body)
    if not success:
        return
    (true, data["account"].string)

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
        accounts = data["accounts"].getElems.mapIt(it.toString)
    except:
        return

    assert accounts != nil
    assert accounts.len > 0 and accounts[0] != nil
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
        (result, data) = request(body)

when defined testing:
    import unittest
    import os

    suite "tests":
        var nano: NanoRPC
        var wallet: string

        setup:
            let config = parseFile "config.json"
            wallet = config["wallet"]
            nano = newNanoRPC()
            echo wallet
        
        test "account":
            var
                ok: bool
                accounts: seq[string]
                balance: Balance

            (ok, accounts) = nano.account_list(wallet)
            assert ok
            echo accounts

            (ok, balance) = nano.account_balance(accounts[0])
            assert ok
            echo balance
