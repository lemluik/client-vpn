"""Стенд автопереключения входов (Д2-18).

Два «узла» — локальные SOCKS-релеи, которые можно выводить из строя по команде;
цель наблюдателя — локальный HTTP-счётчик. Стенд отвечает на два вопроса,
которые `xray run -test` ответить не может:

  1. Обращается ли ядро к цели наблюдателя вообще (счётчик hits).
  2. Переходит ли трафик на второй узел после отказа первого и за сколько.

Порты стенда — 190xx: они не пересекаются с 180xx живого клиента и с другими
прогонами на этой машине. Боевые узлы и ключи не задействованы.

Пример:
  python3 run_stand.py --variant current   --fail-mode drop --duration 90
  python3 run_stand.py --variant fixed     --fail-mode drop --duration 90
  python3 run_stand.py --variant fixed     --fail-mode blackhole --duration 120
"""

import argparse
import json
import os
import re
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
RUN = HERE / "run"

HTTP_PORT = 19080
SOCKS_PORT = 19081
RELAY_A = 19091
RELAY_B = 19092
PROBE_PORT = 19098
TAG_A = "cvpn-proxy"
TAG_B = "cvpn-proxy-2"
LB_TAG = "cvpn-lb"
XRAY = os.environ.get("XRAY_BIN", str(HERE.parents[1] / "assets" / "xray" / "xray.exe"))

# Формы блока наблюдателя. `current` — то, что клиент строит сегодня
# (lib/failover.dart), остальные — кандидаты на замену.
# Цель наблюдателя и пользовательский трафик разведены по путям: иначе счётчик
# обращений к цели не отличает пробы ядра от проб стенда.
PROBE_LOCAL = f"http://127.0.0.1:{PROBE_PORT}/observatory"
TRAFFIC_PATH = "/traffic"


def observatory_current(endpoint, interval=None):
    return {"observatory": {"target": endpoint}}


def observatory_fixed(endpoint, interval="10s"):
    return {
        "observatory": {
            "subjectSelector": [TAG_A, TAG_B],
            "probeURL": endpoint,
            "probeInterval": interval,
            "enableConcurrency": True,
        }
    }


def observatory_no_subjects(endpoint, interval="10s"):
    """Только цель и интервал: проверяет, обязан ли список субъектов быть явным."""
    return {"observatory": {"probeURL": endpoint, "probeInterval": interval}}


def observatory_prefix(endpoint, interval="10s"):
    """Один префикс на все узлы: `cvpn-proxy` должен накрыть и `cvpn-proxy-2`."""
    return {
        "observatory": {
            "subjectSelector": [TAG_A],
            "probeURL": endpoint,
            "probeInterval": interval,
            "enableConcurrency": True,
        }
    }


def observatory_serial(endpoint, interval="10s"):
    """То же, что `fixed`, но без параллельных проб."""
    return {
        "observatory": {
            "subjectSelector": [TAG_A, TAG_B],
            "probeURL": endpoint,
            "probeInterval": interval,
        }
    }


def observatory_minimal(endpoint, interval=None):
    """Минимальная рабочая форма: субъекты и цель, интервал из значений ядра."""
    return {
        "observatory": {
            "subjectSelector": [TAG_A, TAG_B],
            "probeURL": endpoint,
        }
    }


def burst_current(endpoint, interval=None):
    return {"burstObservatory": {"pingConfig": {"targets": [endpoint]}}}


def burst_fixed(endpoint, interval="10s", timeout="5s"):
    return {
        "burstObservatory": {
            "subjectSelector": [TAG_A, TAG_B],
            "pingConfig": {
                "destination": endpoint,
                "interval": interval,
                "timeout": timeout,
                "httpMethod": "GET",
            },
        }
    }


VARIANTS = {
    "current": observatory_current,
    "fixed": observatory_fixed,
    "no_subjects": observatory_no_subjects,
    "minimal": observatory_minimal,
    "prefix": observatory_prefix,
    "serial": observatory_serial,
    "burst_current": burst_current,
    "burst_fixed": burst_fixed,
}


def build_config(variant, endpoint, strategy="leastPing", tolerance=100, probe_interval="10s"):
    obs = VARIANTS[variant](endpoint, probe_interval) if endpoint else {}
    cfg = {
        "log": {
            "loglevel": "info",
            "access": str(RUN / f"access_{variant}.log"),
            "error": str(RUN / f"xray_{variant}.log"),
        },
        "inbounds": [
            {"protocol": "http", "listen": "127.0.0.1", "port": HTTP_PORT, "tag": "cvpn-http"},
            {
                "protocol": "socks",
                "listen": "127.0.0.1",
                "port": SOCKS_PORT,
                "tag": "cvpn-socks",
                "settings": {"udp": True},
            },
        ],
        "outbounds": [
            {"protocol": "socks", "tag": TAG_A,
             "settings": {"servers": [{"address": "127.0.0.1", "port": RELAY_A}]}},
            {"protocol": "socks", "tag": TAG_B,
             "settings": {"servers": [{"address": "127.0.0.1", "port": RELAY_B}]}},
            {"protocol": "freedom", "tag": "cvpn-direct"},
        ],
        "routing": {
            "domainStrategy": "AsIs",
            "balancers": [{
                "tag": LB_TAG,
                "selector": [TAG_A, TAG_B],
                "strategy": {"type": strategy, "settings": {"tolerance": tolerance}},
            }],
            "rules": [{"type": "field", "network": "tcp,udp", "balancerTag": LB_TAG}],
        },
    }
    cfg.update(obs)
    return cfg


def write_mode(name, mode):
    RUN.joinpath(f"mode_{name}.txt").write_text(mode, encoding="utf-8")


def wait_port(port, timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        with socket.socket() as s:
            s.settimeout(0.4)
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.2)
    return False


def socks_get(path=TRAFFIC_PATH, timeout=8):
    """Один запрос через SOCKS-вход ядра. Возвращает (код, секунды) или (None, …)."""
    started = time.time()
    try:
        with socket.create_connection(("127.0.0.1", SOCKS_PORT), timeout=timeout) as s:
            s.settimeout(timeout)
            s.sendall(b"\x05\x01\x00")
            if s.recv(2) != b"\x05\x00":
                return None, time.time() - started
            s.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", PROBE_PORT))
            if s.recv(4)[1] != 0x00:
                return None, time.time() - started
            s.recv(6)
            s.sendall(f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".encode())
            head = s.recv(64).decode(errors="replace")
        code = int(head.split(" ")[1]) if head.startswith("HTTP/") else None
        return code, time.time() - started
    except (OSError, ValueError, IndexError):
        return None, time.time() - started


def parse_tags(variant):
    """Разбирает журнал доступа ядра: [(секунды от полуночи, тег выхода)].

    Ядро пишет выбор выхода двумя формами — `[вход -> тег]` и `[вход >> тег]`;
    считать надо обе, иначе прогон выглядит как «тегов нет».
    """
    path = RUN / f"access_{variant}.log"
    out = []
    if not path.exists():
        return out
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.search(r"(?:->|>>)\s*(cvpn-proxy(?:-2)?)\]", line)
        if not m:
            continue
        # Строка журнала начинается с даты: «2026-10-21 22:16:33.550262 from …».
        t = re.search(r"\s(\d{2}):(\d{2}):(\d{2})", line)
        if not t:
            continue
        ts = int(t.group(1)) * 3600 + int(t.group(2)) * 60 + int(t.group(3))
        out.append((ts, m.group(1)))
    return out


def wall_to_day_seconds(ts):
    lt = time.localtime(ts)
    return lt.tm_hour * 3600 + lt.tm_min * 60 + lt.tm_sec


def run(args):
    RUN.mkdir(exist_ok=True)
    for f in RUN.glob("*"):
        # Журнал прошлого прогона может ещё держать процесс ядра — не роняем стенд.
        try:
            f.unlink()
        except OSError:
            pass

    write_mode("A", "ok")
    write_mode("B", "ok")
    hits = RUN / f"hits-{PROBE_PORT}.jsonl"

    procs = []
    env = dict(os.environ)
    procs.append(subprocess.Popen(
        [sys.executable, str(HERE / "probe_target.py"), "--port", str(PROBE_PORT), "--hits", str(hits)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env))
    for name, port in (("A", RELAY_A), ("B", RELAY_B)):
        procs.append(subprocess.Popen(
            [sys.executable, str(HERE / "socks_relay.py"), "--port", str(port),
             "--flag", str(RUN / f"mode_{name}.txt")],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env))

    cfg = build_config(args.variant, args.endpoint or PROBE_LOCAL, args.strategy,
                       args.tolerance, args.probe_interval)
    cfg_path = RUN / f"cfg_{args.variant}.json"
    cfg_path.write_text(json.dumps(cfg, indent=2), encoding="utf-8")

    if not all(wait_port(p) for p in (PROBE_PORT, RELAY_A, RELAY_B)):
        print("FAIL: вспомогательные порты не поднялись")
        return cleanup(procs, args)

    xray = subprocess.Popen([XRAY, "run", "-c", str(cfg_path)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    procs.append(xray)
    if not wait_port(SOCKS_PORT, timeout=25):
        print("FAIL: SOCKS-вход ядра не поднялся")
        return cleanup(procs, args)

    print(f"variant={args.variant} fail_mode={args.fail_mode} duration={args.duration}s "
          f"interval={args.interval}s fail_after={args.fail_after}s")

    timeline = []
    fail_at = None
    recover_at = None
    failb_at = None
    started = time.time()
    end = started + args.duration
    while time.time() < end:
        if fail_at is None and args.fail_after >= 0 and time.time() >= started + args.fail_after:
            write_mode("A", args.fail_mode)
            fail_at = time.time()
            print(f"[{time.strftime('%H:%M:%S')}] впрыск отказа на узле A: {args.fail_mode}")
        if (fail_at is not None and recover_at is None and args.recover_after >= 0
                and time.time() >= fail_at + args.recover_after):
            write_mode("A", "ok")
            recover_at = time.time()
            print(f"[{time.strftime('%H:%M:%S')}] узел A восстановлен")
        if (fail_at is not None and failb_at is None and args.fail_b_after >= 0
                and time.time() >= fail_at + args.fail_b_after):
            write_mode("B", args.fail_mode)
            failb_at = time.time()
            print(f"[{time.strftime('%H:%M:%S')}] впрыск отказа на узле B: {args.fail_mode}")
        code, dt = socks_get(timeout=args.timeout)
        timeline.append((time.time(), code, round(dt, 3)))
        if code is None:
            print(f"[{time.strftime('%H:%M:%S')}] проба не прошла ({dt:.1f} с)")
        time.sleep(max(0.0, args.interval - dt))

    xray.terminate()
    try:
        xray.wait(timeout=10)
    except subprocess.TimeoutExpired:
        xray.kill()

    tags = parse_tags(args.variant)
    obs_hits = traffic_hits = 0
    if hits.exists():
        for line in hits.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            path = json.loads(line).get("path", "")
            if path.startswith("/observatory"):
                obs_hits += 1
            else:
                traffic_hits += 1
    ok = sum(1 for _, c, _ in timeline if c is not None)

    print("\n=== итог ===")
    print(f"проб отправлено: {len(timeline)}, успешных: {ok}")
    print(f"обращений ядра к цели наблюдателя: {obs_hits} (трафик стенда: {traffic_hits})")
    print(f"строк в журнале с тегом выхода: {len(tags)} "
          f"(A={sum(1 for _, t in tags if t == TAG_A)}, B={sum(1 for _, t in tags if t == TAG_B)})")

    if fail_at is not None:
        fail_s = wall_to_day_seconds(fail_at)
        before = [t for ts, t in tags if ts < fail_s]
        after = [(ts, t) for ts, t in tags if ts >= fail_s]
        print(f"до впрыска: A={before.count(TAG_A)} B={before.count(TAG_B)}")
        print(f"после впрыска: A={sum(1 for _, t in after if t == TAG_A)} "
              f"B={sum(1 for _, t in after if t == TAG_B)}")
        first_b = next(((ts, t) for ts, t in after if t == TAG_B), None)
        if first_b:
            print(f"время перехода на узел B: {first_b[0] - fail_s} с "
                  f"(первая строка с тегом B в {first_b[0] - fail_s} с после впрыска)")
        else:
            print("время перехода на узел B: перехода не было")
        leak = [l for l in (RUN / f"access_{args.variant}.log").read_text(
            encoding="utf-8", errors="replace").splitlines() if "cvpn-direct" in l]
        print(f"строк с уходом напрямую (cvpn-direct): {len(leak)}")

    if recover_at is not None:
        rec_s = wall_to_day_seconds(recover_at)
        back = [t for ts, t in tags if ts >= rec_s]
        print(f"после восстановления A: A={back.count(TAG_A)} B={back.count(TAG_B)}")
    if failb_at is not None:
        fb_s = wall_to_day_seconds(failb_at)
        dead = [t for ts, t in tags if ts >= fb_s]
        tail_ok = sum(1 for ts, c, _ in timeline if wall_to_day_seconds(ts) >= fb_s and c is not None)
        print(f"после отказа обоих узлов: A={dead.count(TAG_A)} B={dead.count(TAG_B)}, "
              f"успешных проб: {tail_ok}")

    for p in procs:
        if p.poll() is None:
            p.terminate()
    return 0


def cleanup(procs, args):
    for p in procs:
        if p.poll() is None:
            p.terminate()
    return 2


def kill_by_ports():
    """Гасит процессы стенда по его портам 190xx.

    Нужен, чтобы упавший прогон не оставлял ядро и релеи с занятыми портами и
    не держал журнал доступа (иначе следующий прогон не может его удалить).
    Порты стенда зарезервированы за ним и не пересекаются с 180xx живого
    клиента, поэтому чужие процессы сюда не попадают.
    """
    script = (
        "$ports = 19080,19081,19091,19092,19098;"
        "$ids = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue"
        " | Where-Object { $ports -contains $_.LocalPort }"
        " | Select-Object -ExpandProperty OwningProcess -Unique;"
        "foreach ($i in $ids) { Stop-Process -Id $i -Force -ErrorAction SilentlyContinue }"
    )
    subprocess.run(["powershell", "-NoProfile", "-Command", script],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)


def main():
    p = argparse.ArgumentParser(description="Стенд автопереключения входов (Д2-18)")
    p.add_argument("--variant", choices=sorted(VARIANTS), default="current")
    p.add_argument("--fail-mode", choices=["drop", "blackhole", "refuse", "none"], default="drop")
    p.add_argument("--endpoint", default=None, help="цель наблюдателя (по умолчанию локальный счётчик)")
    p.add_argument("--strategy", default="leastPing")
    p.add_argument("--tolerance", type=int, default=100)
    p.add_argument("--probe-interval", default="10s", help="интервал проб наблюдателя (строка длительности)")
    p.add_argument("--duration", type=int, default=90)
    p.add_argument("--interval", type=float, default=1.0)
    p.add_argument("--fail-after", type=int, default=20, help="секунд до впрыска отказа (-1 = не впрыскивать)")
    p.add_argument("--recover-after", type=int, default=-1,
                   help="через сколько секунд после впрыска вернуть узел A в строй (-1 = не возвращать)")
    p.add_argument("--fail-b-after", type=int, default=-1,
                   help="через сколько секунд после впрыска сломать и узел B тем же режимом (-1 = не ломать)")
    p.add_argument("--timeout", type=float, default=8.0)
    a = p.parse_args()
    kill_by_ports()
    try:
        sys.exit(run(a) or 0)
    finally:
        kill_by_ports()


if __name__ == "__main__":
    main()
