"""Стенд фрагментации рукопожатия (Д2-20).

Отвечает на два вопроса, которых `xray run -test` не касается:

  1. Принимает ли живое ядро (assets/xray/xray.exe, сборка 26.3.27) конфиг
     с блоком finalmask.tcp/fragment — ядро должно поднять SOCKS-вход и
     выдать ClientHello наружу, а не молча проигнорировать блок.
  2. Режет ли блок ClientHello на части: стенки замеряет локальный
     слушатель — размеры сегментов и интервалы между их приходом.

Узлы боевой выдачи не задействованы: «сервер» — слушатель на 127.0.0.1,
идентификатор vless — фиктивная константа. Порты стенда 191xx, не
пересекаются с 1908x/1909x стенда Д2-18 и с входами клиента 10808/10809.

Форма блока — подтверждённая замерами 22.10.2026 (интервал называется
`delay`; тегов `handshake` и `interval` в сборке нет). Стартовые значения
100-200 / 10-20 / 2-8 — гипотеза, подбирается полем; здесь стенд проверяет,
что фактическая нарезка соответствует заданному диапазону.

Пример:
  python3 fragment_measure.py                 # прогон выкл+вкл, 12 проб
  python3 fragment_measure.py --length 50-100 --delay 5-10 --max-split 4-16
"""

import argparse
import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
RUN = HERE / "run"

SOCKS_PORT = 19111   # локальный SOCKS-вход ядра
CAPTURE_PORT = 19110  # «узел»: слушает приходящий ClientHello
PROXY_TAG = "fm-proxy"

# фиктивный идентификатор: ядро проверяет только формат uuid,
# настоящий ключ не нужен — рукопожатие обрывается на слушателе
FAKE_ID = "00000000-0000-4000-8000-000000000001"

XRAY = os.environ.get("XRAY_BIN", str(HERE.parents[1] / "assets" / "xray" / "xray.exe"))


def parse_range(text, default_lo, default_hi):
    if "-" in text:
        lo, hi = text.split("-", 1)
        return int(lo), int(hi)
    value = int(text)
    return value, value


def build_config(frag, args):
    stream = {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
            "serverName": "example.org",
            "fingerprint": "chrome",
            "alpn": ["h2", "http/1.1"],
        },
    }
    if frag:
        stream["finalmask"] = {
            "tcp": [
                {
                    "type": "fragment",
                    "settings": {
                        "packets": args.packets,
                        "length": args.length,
                        "delay": args.delay,
                        "maxSplit": args.max_split,
                    },
                }
            ]
        }
    return {
        "log": {
            "loglevel": "warning",
            "error": str(RUN / f"xray_{'on' if frag else 'off'}.log"),
        },
        "inbounds": [
            {
                "protocol": "socks",
                "listen": "127.0.0.1",
                "port": SOCKS_PORT,
                "tag": "fm-socks",
                "settings": {"udp": False},
            }
        ],
        "outbounds": [
            {
                "protocol": "vless",
                "tag": PROXY_TAG,
                "settings": {
                    "vnext": [
                        {
                            "address": "127.0.0.1",
                            "port": CAPTURE_PORT,
                            "users": [{"id": FAKE_ID, "encryption": "none"}],
                        }
                    ]
                },
                "streamSettings": stream,
            }
        ],
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [
                {"type": "field", "network": "tcp,udp", "outboundTag": PROXY_TAG}
            ],
        },
    }


class Listener:
    """Сырой TCP-слушатель: пишет (размер куска, время прихода) на соединение."""

    def __init__(self, port):
        self.port = port
        self.connections = []  # [[(байт, монотонное_время), ...], ...]
        self._stop = threading.Event()
        self._sock = socket.socket()
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("127.0.0.1", port))
        self._sock.listen(8)
        self._sock.settimeout(0.5)
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        while not self._stop.is_set():
            try:
                conn, _ = self._sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self._capture, args=(conn,), daemon=True).start()

    def _capture(self, conn):
        conn.settimeout(5)
        chunks = []
        try:
            while True:
                started = time.perf_counter()
                data = conn.recv(65536)
                if not data:
                    break
                chunks.append((len(data), started))
        except (OSError, socket.timeout):
            pass
        finally:
            conn.close()
        if chunks:
            self.connections.append(chunks)

    def stop(self):
        self._stop.set()
        try:
            self._sock.close()
        except OSError:
            pass


def wait_port(port, timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        with socket.socket() as s:
            s.settimeout(0.4)
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.2)
    return False


def socks_touch(timeout=6):
    """Один запрос через SOCKS-вход: ядро идёт к «узлу» и шлёт ClientHello.

    Назначение в SOCKS-запросе — адрес из документации (RFC 5737), он не
    резолвится и не используется: правило маршрута отправляет весь tcp-трафик
    на единственный выход, а тот стучится в локальный слушатель.
    """
    try:
        with socket.create_connection(("127.0.0.1", SOCKS_PORT), timeout=timeout) as s:
            s.settimeout(timeout)
            s.sendall(b"\x05\x01\x00")
            if s.recv(2) != b"\x05\x00":
                return False
            s.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("198.51.100.20")
                      + struct.pack("!H", 80))
            if s.recv(4)[1] != 0x00:
                return False
            s.sendall(b"GET / HTTP/1.1\r\nHost: example.org\r\n\r\n")
            s.recv(64)
        return True
    except OSError:
        return False


def run_variant(frag, args):
    tag = "on" if frag else "off"
    cfg = build_config(frag, args)
    cfg_path = RUN / f"cfg_frag_{tag}.json"
    cfg_path.write_text(json.dumps(cfg, indent=2), encoding="utf-8")

    listener = Listener(CAPTURE_PORT)
    proc = subprocess.Popen([XRAY, "run", "-c", str(cfg_path)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        if not wait_port(SOCKS_PORT, timeout=25):
            print(f"FAIL[{tag}]: SOCKS-вход ядра не поднялся — ядро не приняло конфиг")
            return None
        print(f"[{tag}] ядро поднялось, конфиг принят живьём (не `-test`)")
        for _ in range(args.probes):
            socks_touch()
            time.sleep(args.pause)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        listener.stop()

    conns = [c for c in listener.connections if sum(n for n, _ in c) >= 200]
    RUN.joinpath(f"segments_{tag}.json").write_text(
        json.dumps([[[n, round(t, 6)] for n, t in c] for c in listener.connections],
                   indent=1), encoding="utf-8")
    return analyze(tag, conns, args)


def analyze(tag, conns, args):
    if not conns:
        print(f"[{tag}] ClientHello не дошёл ни разу (соединений с >=200 байт: 0)")
        return None
    lo_len, hi_len = parse_range(args.length, 100, 200)
    lo_delay, hi_delay = parse_range(args.delay, 10, 20)
    sizes = []  # все сегменты кроме последних в соединении
    gaps = []   # интервалы м/у приходом следующего сегмента
    per_conn = []
    for c in conns:
        per_conn.append([n for n, _ in c])
        for idx in range(len(c) - 1):
            sizes.append(c[idx][0])
            gaps.append((c[idx + 1][1] - c[idx][1]) * 1000.0)
    print(f"[{tag}] соединений: {len(conns)}; нарезка по соединениям: {per_conn}")
    if sizes:
        in_len = sum(1 for n in sizes if lo_len <= n <= hi_len)
        print(f"[{tag}] не последних сегментов: {len(sizes)}, в диапазоне "
              f"length {lo_len}-{hi_len}: {in_len}")
    head = [g for g in gaps if 0 < g < 1000]  # паузы м/у попытками не считаем
    if head:
        print(f"[{tag}] интервалы м/у сегментами, мс: мин {min(head):.1f}, "
              f"медиана {sorted(head)[len(head) // 2]:.1f}, макс {max(head):.1f}; "
              f"в диапазоне delay {lo_delay}-{hi_delay}: "
              f"{sum(1 for g in head if lo_delay <= g <= hi_delay)} из {len(head)}")
    return {"connections": per_conn, "sizes": sizes, "gaps_ms": gaps}


def kill_by_ports():
    """Гасит процессы стенда по его портам 191xx; чужие процессы не задевает."""
    script = (
        "$ports = 19110,19111;"
        "$ids = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue"
        " | Where-Object { $ports -contains $_.LocalPort }"
        " | Select-Object -ExpandProperty OwningProcess -Unique;"
        "foreach ($i in $ids) { Stop-Process -Id $i -Force -ErrorAction SilentlyContinue }"
    )
    subprocess.run(["powershell", "-NoProfile", "-Command", script],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)


def main():
    p = argparse.ArgumentParser(description="Стенд фрагментации рукопожатия (Д2-20)")
    p.add_argument("--probes", type=int, default=12, help="число попыток на вариант")
    p.add_argument("--pause", type=float, default=1.5, help="пауза между попытками, с")
    p.add_argument("--packets", default="tlshello")
    p.add_argument("--length", default="100-200")
    p.add_argument("--delay", default="10-20")
    p.add_argument("--max-split", default="2-8")
    p.add_argument("--only", choices=["on", "off", "both"], default="both")
    a = p.parse_args()

    RUN.mkdir(exist_ok=True)
    kill_by_ports()
    try:
        base = run_variant(False, a) if a.only in ("both", "off") else {}
        frag = run_variant(True, a) if a.only in ("both", "on") else {}
        if a.only != "both":
            return 0
        if not base or not frag:
            print("ИТОГ: один из вариантов не отработал")
            return 2
        off_multi = sum(1 for c in base["connections"] if len(c) > 1)
        on_multi = sum(1 for c in frag["connections"] if len(c) > 1)
        print(f"\n=== итог ===\nвыкл: соединений с >1 сегментом: {off_multi} "
              f"(ожидаем 0 — целый ClientHello)\nвкл: соединений с >1 сегментом: "
              f"{on_multi} из {len(frag['connections'])} (ожидаем все)")
        return 0 if off_multi == 0 and on_multi == len(frag["connections"]) else 1
    finally:
        kill_by_ports()


if __name__ == "__main__":
    sys.exit(main())
