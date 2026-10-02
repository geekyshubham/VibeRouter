"""Local AWS event-stream fixtures; no credentials or remote traffic."""
import http.server
import json
import struct
import time


def frame(kind, payload, exception=False):
    def header(name, value):
        name, value = name.encode(), value.encode()
        return bytes([len(name)]) + name + b"\x07" + struct.pack(">H", len(value)) + value
    headers = header(":exception-type" if exception else ":event-type", kind)
    body = json.dumps(payload).encode()
    return struct.pack(">III", len(headers) + len(body) + 16, len(headers), 0) + headers + body + b"\0" * 4


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(200)
        self.send_header("Content-Type", "application/vnd.amazon.eventstream")
        self.send_header("Connection", "close")
        self.end_headers()
        if self.path == "/exception":
            self.wfile.write(frame("ValidationException", {"reason": "CONTENT_LENGTH_EXCEEDS_THRESHOLD"}, True))
            return
        if self.path == "/tool":
            self.wfile.write(frame("toolUseEvent", {"toolUseId": "t1", "name": "Bash", "input": '{"command":', "stop": True}))
            return
        if self.path in ["/empty-tool", "/unfinished-tool"]:
            self.wfile.write(frame("toolUseEvent", {"toolUseId": "t1", "name": "TaskList",
                                                   "input": "" if self.path == "/empty-tool" else "{}",
                                                   "stop": self.path == "/empty-tool"}))
            return
        self.wfile.write(frame("assistantResponseEvent", {"content": "first "}))
        self.wfile.flush()
        if self.path == "/delayed":
            time.sleep(1.2)
        elif self.path == "/cancel":
            time.sleep(30)
        tail = frame("assistantResponseEvent", {"content": "second"}) + frame("meteringEvent", {"usage": 0.125})
        if self.path == "/truncated":
            tail = tail[:-3]
        try:
            # Deliberately split AWS prelude, header and payload across writes.
            for chunk in [tail[:1], tail[1:7], tail[7:]]:
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
