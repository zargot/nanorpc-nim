{.this: self.}

import httpclient, json

type
    Account = object
        frontier, openBlock, repBlock, balance, modTime, blockCount: string

    Block = object
        kind, prev, dst, balance, work, sig: string

    Result* = tuple
        success: bool
        value: string

    NanoRPC* = ref object
        client: HttpClient

const
    url = "http://[::1]:7076"

converter toResult(res: Response): Result =
    (res.code == 200.HttpCode, res.body)

converter toString(n: JsonNode): string =
    assert n.kind == JString
    ($n)[1..^2]

proc newNanoRPC(): NanoRPC =
    result.new()
    result.client = newHttpClient()
    result.client.headers = newHttpHeaders({ "Content-Type": "application/json" })

template defAccountAction(action, argName): untyped =
    proc action*(self: NanoRPC, arg: string): Result =
        assert arg.len == 64
        let
            action = $getFrame().procname
            body = $(%*{ "action": action, argName: arg })
        echo body
        client.request url, HttpPost, body

template defAccountAction(action, argName1, argName2, argName3): untyped =
    proc action*(self: NanoRPC, arg1, arg2, arg3: string): Result =
        assert arg1.len == 64
        assert arg2.len == 64
        assert arg3.len == 64
        let
            action = $getFrame().procname
            body = $(%*{
                "action": action,
                argName1: arg1,
                argName2: arg2,
                argName3: arg3,
            })
        echo body
        client.request url, HttpPost, body

defAccountAction account_balance, "account"
defAccountAction account_create, "wallet"
defAccountAction account_list, "wallet"
defAccountAction account_representative_set, "wallet", "account", "representative"

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
            var res: Result
            res = nano.account_list(wallet)
            assert res.success

            let acc: string = res.value.parseJson()["accounts"][0]
            echo acc
            res = nano.account_balance(acc)
            assert res.success
            echo res.value
