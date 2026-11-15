"""Stand-in for the Claude API, for trying the app without an API key.

Run:   python3 tools/mock_claude.py [--host 127.0.0.1] [--port 8787] [--dump DIR] [--delay 0.03]
Point a debug build of the app at it with a launch argument (the simulator reaches the Mac as 127.0.0.1):
       xcrun simctl launch booted app.aipencil.ios -apiBase http://127.0.0.1:8787
A release build ignores the argument and only ever talks to api.anthropic.com.

It answers POST /v1/messages with a streamed reply shaped like the real API's (a thinking block, then text
with Markdown and LaTeX), and prints what the app sent. With --dump it also saves the images from each request.
"""

import argparse
import base64
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FIRST_ANSWER = """표시한 부분은 **기울기 하강법의 갱신 식**입니다. 지금 위치에서 손실이 가장 가파르게 줄어드는 방향으로 한 걸음 옮긴다는 뜻이에요.

$$\\theta_{t+1} = \\theta_t - \\eta \\, \\nabla_\\theta L(\\theta_t)$$

기호를 하나씩 보면:

- $\\theta_t$: 지금까지 학습한 **가중치**
- $\\nabla_\\theta L(\\theta_t)$: 손실 $L$이 가장 빨리 *커지는* 방향. 그래서 앞에 빼기가 붙습니다.
- $\\eta$: **학습률**. 한 번에 얼마나 크게 움직일지 정합니다.

### 문서 안에서의 맥락
2쪽에서 손실 함수를 $L(\\theta) = \\frac{1}{n}\\sum_{i=1}^{n} (y_i - \\hat{y}_i)^2$ 로 정의했고, 이 식은 그 값을 줄이는 방법으로 나옵니다.

### 짧은 예
$L(\\theta) = \\theta^2$, $\\theta_0 = 3$, $\\eta = 0.1$ 이면 기울기는 $2\\theta_0 = 6$ 이므로 $\\theta_1 = 3 - 0.1 \\times 6 = 2.4$ 입니다. 최솟값 $0$ 쪽으로 한 걸음 다가갔죠.

> 학습률이 너무 크면 최솟값을 지나쳐 발산하고, 너무 작으면 학습이 느려집니다. (이 부분은 문서에 없는 일반적인 설명입니다.)
"""

SEARCH_PARTS = [
    "찾아보니 **Adam**은 모멘텀과 RMSProp을 합친 방법으로, 기울기의 평균과 제곱 평균을 함께 써서 걸음 크기를 가중치마다 다르게 잡습니다.",
    " 문서의 기울기 하강법 식에서 학습률 $\\eta$ 를 고정값 대신 이렇게 조절한다고 보면 됩니다.",
]
SEARCH_RESULT = {"type": "web_search_result", "url": "https://example.com/adam-optimizer", "title": "Adam optimizer explained",
                 "encrypted_content": "MOCK-ENCRYPTED-CONTENT", "page_age": "April 30, 2025"}
SEARCH_CITATION = {"type": "web_search_result_location", "url": SEARCH_RESULT["url"], "title": SEARCH_RESULT["title"],
                   "encrypted_index": "MOCK-ENCRYPTED-INDEX", "cited_text": "Adam combines momentum and RMSProp."}

FOLLOW_UP_ANSWER = """산에서 **안개 속에 내려오는 상황**으로 생각하면 쉬워요.

1. 발밑의 경사를 느껴 봅니다. 이것이 기울기 $\\nabla L$ 입니다.
2. 가장 가파른 내리막 쪽으로 한 걸음 내딛습니다. 걸음 크기가 $\\eta$ 입니다.
3. 멈춰서 다시 경사를 느끼고, 같은 일을 반복합니다.

걸음이 너무 크면 골짜기를 건너뛰고, 너무 작으면 해가 지도록 못 내려옵니다.
"""


def sse(event, data):
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n".encode("utf-8")


def chunks(text, size=6):
    for i in range(0, len(text), size):
        yield text[i:i + size]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    counter = 0

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path.startswith("/v1/models/"):
            model = self.path.rsplit("/", 1)[-1]
            body = json.dumps({"id": model, "type": "model", "display_name": model, "created_at": "2026-01-01T00:00:00Z"}).encode()
            auth = "x-api-key" if self.headers.get("x-api-key") else "bearer" if self.headers.get("authorization") else "none"
            print(f"[models] lookup {model} auth={auth}", flush=True)
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        req = json.loads(self.rfile.read(length) or b"{}")
        Handler.counter += 1
        n = Handler.counter
        messages = req.get("messages", [])
        images = []
        for m in messages:
            if isinstance(m.get("content"), list):
                images += [b for b in m["content"] if b.get("type") == "image"]
        system = req.get("system", [])
        system_info = [
            f"{len(b.get('text', ''))}자" + (f" cache={b['cache_control'].get('ttl', '5m')}" if b.get("cache_control") else "")
            for b in system
        ] if isinstance(system, list) else [f"{len(system)}자"]
        print(
            f"[#{n}] model={req.get('model')} effort={req.get('output_config', {}).get('effort')} speed={req.get('speed')} "
            f"stream={req.get('stream')} messages={len(messages)} images={len(images)} system={system_info} "
            f"thinking={req.get('thinking')} fallbacks={req.get('fallbacks')} beta={self.headers.get('anthropic-beta')} "
            f"auth={'x-api-key' if self.headers.get('x-api-key') else 'bearer' if self.headers.get('authorization') else 'none'} "
            f"version={self.headers.get('anthropic-version')} max_tokens={req.get('max_tokens')} cache={req.get('cache_control')}",
            flush=True,
        )
        # What came back of earlier answers: each block's kind, and whether a thinking block kept its signature.
        for i, m in enumerate(messages):
            if m.get("role") == "assistant" and isinstance(m.get("content"), list):
                kinds = [b.get("type", "?") + (f"(signature={b.get('signature')})" if b.get("type") == "thinking" else "") for b in m["content"]]
                print(f"      answer sent back as message {i}: {kinds}", flush=True)
            elif m.get("role") == "user" and isinstance(m.get("content"), list):
                texts = [b.get("text", "") for b in m["content"] if b.get("type") == "text"]
                print(f"      message {i} texts: {texts}", flush=True)
        last_user = messages[-1].get("content") if messages else None
        if isinstance(last_user, str):
            print(f"      follow-up: {last_user}", flush=True)
        tools = req.get("tools") or []
        if tools:
            print(f"      tools: {[(t.get('type'), t.get('max_uses')) for t in tools]}", flush=True)
        # What came back of an earlier answer that searched: the sealed parts have to be as they were sent.
        for i, m in enumerate(messages):
            if m.get("role") != "assistant" or not isinstance(m.get("content"), list):
                continue
            kinds = [b.get("type") for b in m["content"]]
            if "server_tool_use" not in kinds:
                continue
            query = next((b.get("input", {}).get("query") for b in m["content"] if b.get("type") == "server_tool_use"), None)
            sealed = next((r.get("encrypted_content") for b in m["content"] if b.get("type") == "web_search_tool_result" for r in b.get("content", [])), None)
            index = next((c.get("encrypted_index") for b in m["content"] if b.get("type") == "text" for c in (b.get("citations") or [])), None)
            intact = query is not None and sealed == SEARCH_RESULT["encrypted_content"] and index == SEARCH_CITATION["encrypted_index"]
            print(f"      searched answer sent back as message {i}: {kinds} query={query!r} sealed parts intact={intact}", flush=True)
        searching = bool(tools) and isinstance(last_user, str) and any(word in last_user.lower() for word in ("검색", "웹", "search"))
        dump = self.server.dump
        if dump:
            os.makedirs(dump, exist_ok=True)
            for i, img in enumerate(images):
                path = os.path.join(dump, f"req{n}_image{i}.jpg")
                with open(path, "wb") as f:
                    f.write(base64.b64decode(img["source"]["data"]))
            with open(os.path.join(dump, f"req{n}_system.txt"), "w", encoding="utf-8") as f:
                f.write("\n\n-----\n\n".join(b.get("text", "") for b in system) if isinstance(system, list) else str(system))

        answer = FOLLOW_UP_ANSWER if len(messages) > 1 else FIRST_ANSWER
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        try:
            out = self.wfile
            out.write(sse("message_start", {"type": "message_start", "message": {
                "id": f"msg_mock_{n}", "type": "message", "role": "assistant", "model": req.get("model", "mock"),
                "content": [], "stop_reason": None, "stop_sequence": None,
                "usage": {"input_tokens": 1200, "output_tokens": 1}}}))
            out.write(sse("content_block_start", {"type": "content_block_start", "index": 0,
                                                    "content_block": {"type": "thinking", "thinking": "", "signature": ""}}))
            out.flush()
            time.sleep(self.server.think)
            out.write(sse("content_block_delta", {"type": "content_block_delta", "index": 0,
                                                    "delta": {"type": "signature_delta", "signature": f"mock-signature-{n}"}}))
            out.write(sse("content_block_stop", {"type": "content_block_stop", "index": 0}))
            if searching:
                # A search, as the API streams one: the call (its input in pieces), the result, then words that cite it.
                answer = "".join(SEARCH_PARTS)
                out.write(sse("content_block_start", {"type": "content_block_start", "index": 1, "content_block": {
                    "type": "server_tool_use", "id": f"srvtoolu_mock_{n}", "name": "web_search", "input": {}}}))
                for piece in ('{"query":', ' "Adam optimizer', ' explained"}'):
                    out.write(sse("content_block_delta", {"type": "content_block_delta", "index": 1,
                                                            "delta": {"type": "input_json_delta", "partial_json": piece}}))
                out.write(sse("content_block_stop", {"type": "content_block_stop", "index": 1}))
                out.flush()
                time.sleep(self.server.search)
                out.write(sse("content_block_start", {"type": "content_block_start", "index": 2, "content_block": {
                    "type": "web_search_tool_result", "tool_use_id": f"srvtoolu_mock_{n}", "content": [SEARCH_RESULT]}}))
                out.write(sse("content_block_stop", {"type": "content_block_stop", "index": 2}))
                for at, part in enumerate(SEARCH_PARTS):
                    index = 3 + at
                    block = {"type": "text", "text": ""}
                    if at == 0:
                        block["citations"] = []
                    out.write(sse("content_block_start", {"type": "content_block_start", "index": index, "content_block": block}))
                    if at == 0:
                        out.write(sse("content_block_delta", {"type": "content_block_delta", "index": index,
                                                                "delta": {"type": "citations_delta", "citation": SEARCH_CITATION}}))
                    for piece in chunks(part):
                        out.write(sse("content_block_delta", {"type": "content_block_delta", "index": index,
                                                                "delta": {"type": "text_delta", "text": piece}}))
                        out.flush()
                        time.sleep(self.server.delay)
                    out.write(sse("content_block_stop", {"type": "content_block_stop", "index": index}))
            else:
                out.write(sse("content_block_start", {"type": "content_block_start", "index": 1,
                                                        "content_block": {"type": "text", "text": ""}}))
                for piece in chunks(answer):
                    out.write(sse("content_block_delta", {"type": "content_block_delta", "index": 1,
                                                            "delta": {"type": "text_delta", "text": piece}}))
                    out.flush()
                    time.sleep(self.server.delay)
                out.write(sse("content_block_stop", {"type": "content_block_stop", "index": 1}))
            out.write(sse("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                                              "usage": {"output_tokens": len(answer) // 2}}))
            out.write(sse("message_stop", {"type": "message_stop"}))
            out.flush()
            print(f"[#{n}] answer sent ({len(answer)}자)", flush=True)
        except (BrokenPipeError, ConnectionError):
            print(f"[#{n}] the app closed the connection before the answer finished", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0", help="address to listen on; 127.0.0.1 keeps it to this machine")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--dump", help="folder to save the images and system prompt of each request")
    ap.add_argument("--delay", type=float, default=0.03, help="seconds between streamed pieces")
    ap.add_argument("--think", type=float, default=0.6, help="seconds of silence before the first words")
    ap.add_argument("--search", type=float, default=1.5, help="seconds a web search takes")
    args = ap.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.dump, server.delay, server.think, server.search = args.dump, args.delay, args.think, args.search
    print(f"mock Claude listening on port {args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
