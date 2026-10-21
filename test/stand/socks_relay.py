"""SOCKS5-релей, играющий роль узла входа на стенде автопереключения (Д2-18).

Релей нужен, чтобы узел можно было выводить из строя по команде, не трогая
боевые серверы. Режимы отказа повторяют три сценария из замера 21.10:

  ok        — нормальная пересылка
  refuse    — соединение закрывается сразу (отклонено)
  blackhole — TCP принимается, ответ SOCKS не отправляется (зависание;
              основной блокировочный сценарий по карточке)
  drop      — порт не слушается вовсе (пакеты молча теряются)

Режим меняется на лету: достаточно записать имя режима в файл --flag.
Запуск:  python3 socks_relay.py --port 19091 --flag mode_A.txt
"""

import argparse
import socket
import struct
import threading

DEFAULT_MODE = "ok"


def read_mode(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            m = f.read().strip()
        return m or DEFAULT_MODE
    except OSError:
        return DEFAULT_MODE


def pipe(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            s.close()


def handle(client, flag_path):
    mode = read_mode(flag_path)
    if mode == "refuse":
        client.close()
        return
    if mode == "blackhole":
        # Принимаем TCP и молчим: ядро висит на рукопожатии SOCKS.
        try:
            client.recv(2)
        except OSError:
            pass
        return

    try:
        greeting = client.recv(2)
        if len(greeting) < 2 or greeting[0] != 0x05:
            client.close()
            return
        nmethods = greeting[1]
        client.recv(max(1, nmethods))
        client.sendall(b"\x05\x00")

        req = client.recv(4)
        if len(req) < 4 or req[0] != 0x05 or req[1] != 0x01:
            client.close()
            return
        atyp = req[3]
        if atyp == 0x01:
            host = socket.inet_ntoa(client.recv(4))
        elif atyp == 0x03:
            length = client.recv(1)[0]
            host = client.recv(length).decode()
        elif atyp == 0x04:
            host = socket.inet_ntop(socket.AF_INET6, client.recv(16))
        else:
            client.close()
            return
        port = struct.unpack("!H", client.recv(2))[0]

        # Режим drop после рукопожатия: upstream не поднимается.
        if read_mode(flag_path) == "drop":
            client.close()
            return

        upstream = socket.create_connection((host, port), timeout=10)
        client.sendall(b"\x05\x00\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0))
        threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
        threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()
    except OSError:
        try:
            client.close()
        except OSError:
            pass


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--flag", required=True, help="файл с текущим режимом отказа")
    a = p.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", a.port))
    srv.listen(64)
    print(f"relay :{a.port} flag={a.flag} mode={read_mode(a.flag)}", flush=True)
    while True:
        client, _ = srv.accept()
        # drop: порт слушается, но соединение сбрасывается до рукопожатия
        if read_mode(a.flag) == "drop":
            client.close()
            continue
        threading.Thread(target=handle, args=(client, a.flag), daemon=True).start()


if __name__ == "__main__":
    main()
