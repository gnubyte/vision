#!/usr/bin/env python3
"""A stand-in for a vision model server, for the iPhone app's live check.

It speaks the part of the OpenAI chat-completions API the app uses and, like vLLM with
`--limit-mm-per-prompt`, refuses any request that carries more than LIMIT pictures with vLLM's own
wording. Otherwise it streams a reply that says what it was sent, so a test can tell what arrived:

    saw <N> picture(s); pdf text: <yes|no>; model <id>

    python3 fake-model-server.py <port> <picture limit>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
LIMIT = int(sys.argv[2]) if len(sys.argv) > 2 else 2


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("model-server: " + fmt % args + "\n")

    def _send(self, code, body, content_type="application/json"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            return self._send(200, json.dumps({"data": [{"id": "stand-in", "max_model_len": 262144}]}))
        self._send(404, json.dumps({"error": {"message": "not found"}}))

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            request = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self._send(400, json.dumps({"error": {"message": "bad JSON"}}))
        if not self.path.rstrip("/").endswith("/chat/completions"):
            return self._send(404, json.dumps({"error": {"message": "not found"}}))
        pictures, text = 0, []
        for message in request.get("messages", []):
            content = message.get("content")
            if isinstance(content, str):
                text.append(content)
            for part in content if isinstance(content, list) else []:
                if part.get("type") == "image_url":
                    pictures += 1
                elif part.get("type") == "text":
                    text.append(part.get("text", ""))
                elif part.get("type") == "file":
                    return self._send(400, json.dumps({"error": {"message": "Unknown part type: file"}}))
        sys.stderr.write(f"model-server: {pictures} picture(s) in the request\n")
        if pictures > LIMIT:
            return self._send(400, json.dumps({"error": {
                "message": f"At most {LIMIT} image(s) may be provided in one request.",
                "type": "BadRequestError", "code": 400}}))
        has_pdf = "yes" if "Attached PDF" in "\n".join(text) else "no"
        reply = f"saw {pictures} picture(s); pdf text: {has_pdf}; model {request.get('model')}"
        chunks = "".join(
            "data: " + json.dumps({"choices": [{"delta": {"content": word + " "}}]}) + "\n\n"
            for word in reply.split(" "))
        chunks += 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n'
        self._send(200, chunks, "text/event-stream")


if __name__ == "__main__":
    print(f"stand-in model server on http://127.0.0.1:{PORT}/v1 (takes {LIMIT} pictures per request)", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
