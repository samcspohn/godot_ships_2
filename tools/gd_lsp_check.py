import json, os, socket, sys, time, pathlib

ROOT = pathlib.Path(sys.argv[1]).resolve()
files = [pathlib.Path(p).resolve() for p in sys.argv[2:]] or sorted(
    p for p in ROOT.rglob("*.gd") if not {".godot", "addons", "godot-cpp"} & set(p.parts))

s = socket.create_connection(("127.0.0.1", 6005), timeout=30)
buf = b""

def send(msg):
    b = json.dumps(msg).encode()
    s.sendall(b"Content-Length: %d\r\n\r\n" % len(b) + b)

def recv(timeout):
    global buf
    s.settimeout(timeout)
    while True:
        h = buf.find(b"\r\n\r\n")
        if h >= 0:
            n = int([l for l in buf[:h].split(b"\r\n") if l.lower().startswith(b"content-length")][0].split(b":")[1])
            if len(buf) >= h + 4 + n:
                m = json.loads(buf[h + 4:h + 4 + n]); buf = buf[h + 4 + n:]
                return m
        try:
            c = s.recv(1 << 20)
        except socket.timeout:
            return None
        if not c:
            return None
        buf += c

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"processId": os.getpid(), "rootUri": ROOT.as_uri(), "capabilities": {}}})
while (m := recv(10)) and m.get("id") != 1:
    pass
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

diags = {}
for f in files:
    uri = f.as_uri()
    send({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {
        "uri": uri, "languageId": "gdscript", "version": 1, "text": f.read_text(errors="replace")}}})
    deadline = time.time() + 5
    while time.time() < deadline:
        m = recv(max(0.05, deadline - time.time()))
        if m is None:
            break
        if m.get("method") == "textDocument/publishDiagnostics":
            diags[m["params"]["uri"]] = m["params"]["diagnostics"]
            if m["params"]["uri"] == uri:
                break
    send({"jsonrpc": "2.0", "method": "textDocument/didClose", "params": {"textDocument": {"uri": uri}}})

sev = {1: "ERROR", 2: "WARN", 3: "INFO", 4: "HINT"}
want = int(os.environ.get("MAXSEV", "1"))
count = 0
for uri, ds in sorted(diags.items()):
    rel = os.path.relpath(uri.removeprefix("file://"), ROOT)
    for d in ds:
        if d.get("severity", 1) <= want:
            count += 1
            print(f"{rel}:{d['range']['start']['line'] + 1}: {sev.get(d.get('severity', 1))}: {d['message']}")
print(f"-- {len(files)} files checked, {count} diagnostics", file=sys.stderr)
