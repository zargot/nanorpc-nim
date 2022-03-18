import json, strformat, logging, oids

import nanocurrency

proc main =
    addHandler newConsoleLogger()
    var
        ok: bool
        accounts: seq[string]
        balances: seq[Balance]
    let
        config = parseFile "config.json"
        wallet = config["wallet"].getStr
        nano = newNanoRPC()
    (ok, accounts) = nano.account_list(wallet)
    assert ok
    balances.setLen accounts.len
    for i, acc in accounts:
        (ok, balances[i]) = nano.account_balance(acc)
        assert ok

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
    var blockId: string
    (ok, blockId) = nano.send(wallet, src, dst, amount, id)
    assert ok
    echo &"balance0: {balances[0]}"
    echo &"balance1: {balances[1]}"
    echo &"sent {amount} raw, blockid {blockId}"
main()
