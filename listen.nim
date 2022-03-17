import asyncdispatch, oids

import ws

import nanorpc

proc main =
    let sock = waitFor newWebSocket("ws://127.0.0.1:17078")
    let id = $genOid()
    var ev: Event
    sock.subscribe(id, "confirmation")
    doAssert sock.process(ev) and ev.kind == nekAck and ev.id == id and ev.ack == "subscribe"
    while true:
        if not sock.process(ev):
            quit 1
main()
