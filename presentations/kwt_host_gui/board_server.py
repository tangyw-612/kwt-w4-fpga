"""供上位机调用的本机 J8 网关。"""

import argparse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path, PurePosixPath
import sys
from threading import Lock
from urllib.parse import unquote, urlsplit


WORKSPACE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(WORKSPACE / "FPGA_DATA" / "keyword_acc" / "host"))
from mac_uart_protocol import BAUD, CASES, CLOCK_HZ, identify, open_board, run_sample
import keyword_uart_protocol as keyword


GUI = "/presentations/kwt_host_gui/"
ASSETS = {GUI + name for name in ("", "index.html", "console.css", "console.js", "replay.js", "board.js")}
ASSETS.update({"/presentations/an970_gui/dataset.js", "/presentations/an970_gui/competition-background.png"})
AUDIO = "/research/20261110_official600_eval_01/audio/"
SERIAL_LOCK = Lock()


class BoardRequest(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WORKSPACE), **kwargs)

    def path_name(self):
        return unquote(urlsplit(self.path).path)

    def static_allowed(self):
        path = self.path_name()
        return (self.headers.get("Host") == self.server.host_header and ".." not in PurePosixPath(path).parts
                and "\\" not in path and (path in ASSETS or (path.startswith(AUDIO) and path.endswith(".wav"))))

    def do_GET(self):
        if self.static_allowed():
            super().do_GET()
        else:
            self.send_error(404)

    def do_HEAD(self):
        if self.static_allowed():
            super().do_HEAD()
        else:
            self.send_error(404)

    def send_json(self, status, value):
        payload = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

    def do_POST(self):
        if (self.headers.get("Host") != self.server.host_header
                or self.headers.get("Origin") != f"http://{self.server.host_header}"):
            self.send_json(403, {"error": "J8 网关只接受本机上位机页面的请求"})
            return
        path = self.path_name()
        if path not in {"/api/board/connect", "/api/board/run"}:
            self.send_json(404, {"error": "未知的 J8 接口"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 128 or self.headers.get_content_type() != "application/json":
                raise ValueError("请求格式不正确")
            data = json.loads(self.rfile.read(length))
            sample = data.get("sample_id") if isinstance(data, dict) else None
            if path.endswith("/run") and (type(sample) is not int or not 0 <= sample <= 599):
                raise ValueError("样本编号范围为 000–599")
        except (ValueError, UnicodeDecodeError) as error:
            self.send_json(400, {"error": str(error)})
            return

        try:
            with SERIAL_LOCK, open_board(self.server.serial_port) as serial_port:
                full = keyword.probe(serial_port)
                if not full:
                    identify(serial_port)
                if path.endswith("/run"):
                    result = keyword.run_sample(serial_port, sample) if full else run_sample(serial_port, sample)
                else:
                    result = {"port": self.server.serial_port, "baud": BAUD, "clock_hz": CLOCK_HZ,
                              "mode": "keyword" if full else "mac"}
                    if not full:
                        result["samples"] = sorted(CASES.values())
        except (OSError, ValueError, RuntimeError, ImportError) as error:
            self.send_json(503, {"error": f"J8 {self.server.serial_port}：{error}"})
            return
        self.send_json(200, result)


def main():
    parser = argparse.ArgumentParser(description="KWT-STAR 上位机 J8 网关")
    parser.add_argument("--port", default="COM7", help="开发板 J8 对应的串口")
    parser.add_argument("--listen", type=int, default=8771, help="本机网页端口")
    args = parser.parse_args()
    with ThreadingHTTPServer(("127.0.0.1", args.listen), BoardRequest) as server:
        server.host_header = f"127.0.0.1:{server.server_port}"
        server.serial_port = args.port
        print(f"http://{server.host_header}{GUI}?board=1", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
