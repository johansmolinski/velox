#!/usr/bin/env python3
"""Deterministic HTTP test server for the Velox emulator tests.

usage: server.py PORT [DOCROOT] [TLSPORT CERT KEY]

Fixed routes are below; anything else is served from DOCROOT (test/www).
"""
import http.server
import os
import sys
import time

BIG = bytes((i * 7 + 13) % 251 for i in range(100000))
HELLO = b"Hello from the Velox test server\n"
SLOW_HITS = {}                  # requests for each /slow/ image
LM_HITS = {}                    # requests for each file?lm
CACHED = {"v": 1, "200": 0, "304": 0}  # /cached: version, replies
DOCROOT = sys.argv[2] if len(sys.argv) > 2 else "test/www"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("server: [%d] %s\n" % (self.client_address[1], fmt % args))

    def send(self, code, body, ctype="text/plain", headers=()):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = self.path
        if p.startswith("/hello-close"):
            # a new connection each time (TLS: a session resumed)
            self.send(200, b"<title>Hello</title>" + HELLO, "text/html",
                      headers=[("Connection", "close")])
        elif p == "/hello":
            self.send(200, HELLO)
        elif p == "/chunked":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for part in (b"chunk one, ", b"chunk two, ", b"chunk three\n"):
                self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part))
            self.wfile.write(b"0\r\n\r\n")
        elif p == "/setcookie":
            self.send(302, b"", headers=[("Location", "/echo/cookie"),
                                         ("Set-Cookie", "test=42; Path=/"),
                                         ("Set-Cookie", "other=x; Path=/nowhere")])
        elif p == "/setcookie2":
            self.send(302, b"", headers=[("Location", "/echo/cookie"),
                                         ("Set-Cookie", "sess=2; Path=/"),
                                         ("Set-Cookie", "keep=1; Max-Age=86400; Path=/"),
                                         ("Set-Cookie", "far=3; Expires=Mon, 01 Jan 2060 00:00:00 GMT; Path=/")])
        elif p == "/auth":
            if self.headers.get("Authorization") == "Basic dXNlcjpwdw==":
                self.send(200, b"auth ok\n")
            else:
                self.send(401, b"<title>Login</title><p>Who are you?",
                          "text/html", headers=[("WWW-Authenticate", 'Basic realm="test"')])
        elif p.startswith("/slowcount/"):
            # requests for /slow/ images whose names start with this
            n = p[len("/slowcount/"):]
            self.send(200, b"%d" % sum(v for k, v in SLOW_HITS.items() if k.startswith(n)))
        elif p.startswith("/hugepage"):
            # a page whose layout takes seconds even on a fast CPU
            n = int(p.split("?")[1].split("&")[0]) if "?" in p else 3000
            css = "".join(".c%d p a { color: #%06x } div.r.c%d > p { margin: 2px %dpx }\n"
                          % (i, i * 2654435 & 0xffffff, i, i % 9) for i in range(60))
            # (selectors no index rules out: each <b> and <i> tries them all)
            css += "".join('div p[lang|="z%d"] b, div p[lang|="z%d"] i { color: #%06x }\n'
                           % (i, i, i * 40503 & 0xffffff) for i in range(150))
            rows = []
            for i in range(n):
                rows.append('<div class="r c%d"><p>Row %d: lorem <a href="#r%d">ipsum</a> '
                            '<b>dolor</b> sit amet, <i>consectetur</i> adipiscing elit, sed do '
                            'eiusmod tempor incididunt ut labore et dolore magna aliqua.</p></div>'
                            % (i % 60, i, i))
                if i % 100 == 99:     # (nested tables: laid out more than once)
                    inner = "<table border=1>" + "".join(
                        "<tr>" + "".join("<td>in %d.%d</td>" % (r, c) for c in range(3)) + "</tr>"
                        for r in range(3)) + "</table>"
                    rows.append("<table border=1>" + "".join(
                        "<tr>" + "".join("<td>cell %d.%d %s</td>" % (r, c, inner) for c in range(4)) + "</tr>"
                        for r in range(4)) + "</table>")
            body = ("<title>Huge</title><style>%s</style><body><h1>Huge</h1>%s<p id=end>End</p>"
                    % (css, "".join(rows))).encode()
            self.send(200, body, "text/html")
        elif p.startswith("/lmhits/"):
            self.send(200, b"%d" % LM_HITS.get(p[len("/lmhits/"):], 0))
        elif p == "/cached":
            # a page with a validator: 304 when the browser has it
            tag = '"v%d"' % CACHED["v"]
            if self.headers.get("If-None-Match") == tag:
                CACHED["304"] += 1
                self.send_response(304)
                self.send_header("ETag", tag)
                self.end_headers()
            else:
                CACHED["200"] += 1
                self.send(200, b"<title>Cached v%d</title><p>Version %d of the page." % (CACHED["v"], CACHED["v"]),
                          "text/html", headers=[("ETag", tag)])
        elif p == "/cached-bump":
            CACHED["v"] += 1
            self.send(200, b"%d" % CACHED["v"])
        elif p == "/cached-count":
            self.send(200, b"200:%d 304:%d" % (CACHED["200"], CACHED["304"]))
        elif p == "/bigslow":
            # big.html in four parts, 2 s apart: laid out again as it comes
            with open(os.path.join(DOCROOT, "big.html"), "rb") as f:
                data = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            q = len(data) // 4
            for i in range(4):
                part = data[i * q:] if i == 3 else data[i * q:(i + 1) * q]
                if i:
                    time.sleep(2)
                self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
        elif p.split("?")[0] == "/trickle":
            # a page in three parts, 5 s apart (chunked): shown as it
            # comes; its style sheet is fetched in the middle of it
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            para = "".join("<p>Paragraph %d of the page that trickles in, with a few words.</p>\n" % i for i in range(60))
            parts = ['<html><head><title>Trickle</title><link rel="stylesheet" href="css/trickle.css"></head>'
                     '<body><p><a href="#late">To the late part</a></p>\n' + para,
                     "<h2>Second part</h2>\n" + para,
                     '<h2 id="late">The late part</h2>\n' + para + "</body></html>"]
            for i, part in enumerate(parts):
                if i:
                    time.sleep(5)
                data = part.encode()
                self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
        elif p == "/latecss":
            # a page whose style sheet comes late: shown before it
            self.send(200, b'<html><head><title>Late CSS</title>'
                      b'<link rel="stylesheet" href="/slowcss"></head><body>'
                      b'<p>Shown before its style sheet comes.</p>'
                      b'<p class="late">Moved down by it.</p></body></html>',
                      "text/html")
        elif p == "/slowcss":
            time.sleep(6)
            self.send(200, b".late { margin-top: 600px }", "text/css")
        elif p == "/slowpage":
            time.sleep(12)
            self.send(200, b"<title>Slow</title><p>A slow page.", "text/html")
        elif p.startswith("/slow/"):
            # a slow image: the browser must stay usable meanwhile
            SLOW_HITS[p[6:]] = SLOW_HITS.get(p[6:], 0) + 1
            time.sleep(8)
            with open(os.path.join(DOCROOT, "test.iff"), "rb") as f:
                self.send(200, f.read(), "image/x-ilbm")
        elif p == "/redirect":
            self.send(302, b"", headers=[("Location", "/hello")])
        elif p == "/redirect-rel":
            self.send(301, b"moved", headers=[("Location", "sub/../hello")])
        elif p == "/loop":
            self.send(302, b"", headers=[("Location", "/loop")])
        elif p == "/big":
            self.send(200, BIG, "application/octet-stream")
        elif p.startswith("/echo"):
            # body = request line + headers as received
            lines = [self.requestline] + [f"{k}: {v}" for k, v in self.headers.items()]
            self.send(200, ("\n".join(lines) + "\n").encode("latin-1"))
        else:
            path = os.path.normpath(p.split("?")[0]).lstrip("/")
            full = os.path.join(DOCROOT, path)
            if os.path.isdir(full):
                full = os.path.join(full, "index.html")
            if os.path.isfile(full) and os.path.realpath(full).startswith(os.path.realpath(DOCROOT)):
                ctype = ("text/html; charset=utf-8" if full.endswith(".html") else
                         "text/css" if full.endswith(".css") else
                         "image/svg+xml" if full.endswith(".svg") else "application/octet-stream")
                hdrs = []
                if p.endswith("?nostore"):  # (never kept: a forum's pages)
                    hdrs = [("Cache-Control", "no-store")]
                if p.endswith("?lm"):
                    # unchanged for long, no max-age: fresh for a while
                    # (heuristic freshness); its requests are counted
                    LM_HITS[path] = LM_HITS.get(path, 0) + 1
                    hdrs = [("Last-Modified", "Mon, 01 Jan 2024 00:00:00 GMT")]
                with open(full, "rb") as f:
                    self.send(200, f.read(), ctype, headers=hdrs)
            else:
                self.send(404, b"not found\n")


    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        if self.path.startswith("/upload"):
            # multipart/form-data: each part logged (a file: its name,
            # type, size and MD5), not the bytes
            import hashlib
            ctype = self.headers.get("Content-Type", "")
            sys.stderr.write("server: POST %s %s\n" % (self.path, ctype))
            b = ctype.split("boundary=", 1)[-1].encode("latin-1")
            for part in body.split(b"--" + b)[1:]:
                if part.startswith(b"--"):
                    break
                head, _, data = part[2:].partition(b"\r\n\r\n")
                data = data[:-2] if data.endswith(b"\r\n") else data
                h = head.decode("latin-1")
                name = h.split('name="', 1)[1].split('"', 1)[0]
                if 'filename="' in h:
                    fn = h.split('filename="', 1)[1].split('"', 1)[0]
                    ct = h.split("Content-Type: ", 1)[1].split("\r", 1)[0] \
                        if "Content-Type: " in h else "-"
                    sys.stderr.write("server: UPLOAD %s file=%s type=%s size=%d md5=%s\n" % (
                        name, fn, ct, len(data), hashlib.md5(data).hexdigest()))
                else:
                    sys.stderr.write("server: UPLOAD %s=%s\n" % (
                        name, data.decode("utf-8", "replace")))
            self.send(200, b"<title>Uploaded</title><p>Thank you.", "text/html")
            return
        sys.stderr.write("server: POST %s body=%s\n" % (self.path, body.decode("latin-1")))
        if self.path.startswith("/echo"):
            text = "%s\n%s\n" % (self.requestline, body.decode("latin-1"))
            self.send(200, text.encode("latin-1"))
        else:
            self.send(404, b"not found\n")


if __name__ == "__main__":
    import ssl
    import threading
    port = int(sys.argv[1])
    if len(sys.argv) > 5:  # the same site over TLS as well; also on
        # 127.0.0.2, which the certificate does not name
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(sys.argv[4], sys.argv[5])
        # the client's cipher order, as most servers do (nginx, Apache
        # defaults; Cloudflare for ChaCha20)
        ctx.options &= ~ssl.OP_CIPHER_SERVER_PREFERENCE
        for addr in ("127.0.0.1", "127.0.0.2"):
            tls = http.server.ThreadingHTTPServer((addr, int(sys.argv[3])), Handler)
            tls.socket = ctx.wrap_socket(tls.socket, server_side=True)
            threading.Thread(target=tls.serve_forever, daemon=True).start()
        # and a server that speaks only TLS 1.3, on the next port
        ctx13 = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx13.load_cert_chain(sys.argv[4], sys.argv[5])
        ctx13.minimum_version = ssl.TLSVersion.TLSv1_3
        tls = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[3]) + 1), Handler)
        tls.socket = ctx13.wrap_socket(tls.socket, server_side=True)
        threading.Thread(target=tls.serve_forever, daemon=True).start()
    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
