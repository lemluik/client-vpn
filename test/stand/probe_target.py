"""Точка проб и origin для стенда автопереключения (Д2-18).

Один процесс играет две роли: HTTP-цель наблюдателя (считает обращения ядра) и
origin для пользовательского трафика. Счётчик — главное доказательство того,
запущен ли наблюдатель вообще: 0 строк в журнале = ядро к цели не обращалось.

Запуск:  python3 probe_target.py --port 19098
Журнал:  hits-<port>.jsonl в текущей папке (время, путь, адрес клиента)
"""

import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_HITS = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        with open(_HITS, "a", encoding="utf-8") as f:
            f.write(json.dumps({
                "t": round(time.time(), 3),
                "path": self.path,
                "peer": self.client_address[0],
            }) + "\n")
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_HEAD = do_GET

    def log_message(self, *args):
        pass


def main():
    global _HITS
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=19098)
    p.add_argument("--hits", default=None)
    a = p.parse_args()
    _HITS = a.hits or f"hits-{a.port}.jsonl"
    ThreadingHTTPServer(("127.0.0.1", a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
