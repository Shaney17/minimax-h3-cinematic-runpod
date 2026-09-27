"""Local Runpod request UI for the MiniMax H3 Cinematic endpoint.

The server only listens on localhost. It forwards requests to one fixed Runpod
endpoint and never writes the API key, uploaded images, or job output to disk.
"""

from __future__ import annotations

import argparse
import json
import re
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ENDPOINT_ID = "xjh0wwhkto13ky"
RUNPOD_BASE = "https://api.runpod.ai/v2"
MAX_REQUEST_BYTES = 9_500_000
WEB_DIR = Path(__file__).resolve().parent / "web"
STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
}
UI_WORKFLOW = Path(__file__).resolve().parent / "workflow" / "cinematic_ui.json"
API_WORKFLOW = Path(__file__).resolve().parent / "workflow" / "cinematic_api.json"
JOB_ID = re.compile(r"^[A-Za-z0-9_-]{1,120}$")


class RequestHandler(BaseHTTPRequestHandler):
    server_version = "MiniMaxH3LocalUI/1.0"

    def _send(self, status: int, payload: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'self'; img-src 'self' blob: data:; media-src 'self' blob: https:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'")
        self.end_headers()
        self.wfile.write(payload)

    def _json(self, status: int, value: dict) -> None:
        self._send(status, json.dumps(value, ensure_ascii=False).encode(), "application/json; charset=utf-8")

    def _origin_ok(self) -> bool:
        origin = self.headers.get("Origin")
        if not origin:
            return True
        return origin in {f"http://127.0.0.1:{self.server.server_port}", f"http://localhost:{self.server.server_port}"}

    def _key(self) -> str | None:
        key = self.headers.get("X-Runpod-Key", "").strip()
        if not key or any(c in key for c in "\r\n"):
            self._json(401, {"error": "Nhập Runpod API key trước khi gửi."})
            return None
        return key

    def _forward(self, method: str, path: str, key: str, body: bytes | None = None) -> None:
        url = f"{RUNPOD_BASE}/{ENDPOINT_ID}{path}"
        headers = {"Authorization": f"Bearer {key}", "Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                data = response.read()
                status = response.status
        except urllib.error.HTTPError as exc:
            data = exc.read()
            status = exc.code
        except (urllib.error.URLError, TimeoutError) as exc:
            self._json(502, {"error": f"Không kết nối được Runpod: {exc.reason if hasattr(exc, 'reason') else exc}"})
            return
        self._send(status, data, "application/json; charset=utf-8")

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if path in STATIC_FILES:
            name, content_type = STATIC_FILES[path]
            self._send(200, (WEB_DIR / name).read_bytes(), content_type)
            return
        if not self._origin_ok():
            self._json(403, {"error": "Nguồn yêu cầu không hợp lệ."})
            return
        if path == "/api/default-prompt":
            try:
                graph = json.loads(UI_WORKFLOW.read_text(encoding="utf-8"))
                prompt_node = next(node for node in graph["nodes"] if node["id"] == 190)
                prompt = prompt_node["widgets_values"][0]
                if not isinstance(prompt, str):
                    raise ValueError("Prompt gốc không phải chuỗi.")
            except (OSError, ValueError, KeyError, IndexError, StopIteration) as exc:
                self._json(500, {"error": f"Không đọc được prompt gốc: {exc}"})
                return
            self._json(200, {"prompt": prompt})
            return
        if path == "/api/workflow":
            try:
                graph = json.loads(API_WORKFLOW.read_text(encoding="utf-8"))
                if not isinstance(graph, dict) or graph.get("121", {}).get("class_type") != "MiniMaxH3ReferenceToVideo":
                    raise ValueError("Workflow API mặc định không hợp lệ.")
            except (OSError, ValueError, KeyError) as exc:
                self._json(500, {"error": f"Không đọc được workflow API: {exc}"})
                return
            self._json(200, graph)
            return
        if path == "/api/health":
            key = self._key()
            if key:
                self._forward("GET", "/health", key)
            return
        if path.startswith("/api/status/"):
            job_id = path.removeprefix("/api/status/")
            if not JOB_ID.fullmatch(job_id):
                self._json(400, {"error": "Job ID không hợp lệ."})
                return
            key = self._key()
            if key:
                self._forward("GET", f"/status/{job_id}", key)
            return
        self._json(404, {"error": "Không tìm thấy đường dẫn."})

    def do_POST(self) -> None:
        if self.path != "/api/run":
            self._json(404, {"error": "Không tìm thấy đường dẫn."})
            return
        if not self._origin_ok():
            self._json(403, {"error": "Nguồn yêu cầu không hợp lệ."})
            return
        key = self._key()
        if not key:
            return
        if self.headers.get("Content-Type", "").split(";", 1)[0].strip() != "application/json":
            self._json(415, {"error": "Request body phải là JSON."})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_REQUEST_BYTES:
            self._json(413, {"error": "Request vượt giới hạn 9,5 MB. Hãy giảm kích thước ảnh."})
            return
        body = self.rfile.read(length)
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self._json(400, {"error": "Request body không phải JSON hợp lệ."})
            return
        job_input = payload.get("input") if isinstance(payload, dict) else None
        if not isinstance(job_input, dict) or not isinstance(job_input.get("workflow"), dict) or not isinstance(job_input.get("images"), list):
            self._json(400, {"error": "Thiếu input.workflow hoặc input.images."})
            return
        self._forward("POST", "/run", key, body)


def main() -> None:
    parser = argparse.ArgumentParser(description="MiniMax H3 local Runpod request UI")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    with ThreadingHTTPServer(("127.0.0.1", args.port), RequestHandler) as server:
        print(f"Mở giao diện: http://127.0.0.1:{args.port}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
