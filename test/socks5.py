#!/usr/bin/env python3
# 测试用极简 SOCKS5 服务器：仅 CONNECT、无认证；每连接向日志追加一行 "CONNECT host:port"
import socket, struct, sys, threading


def recv_exact(c, n):
    buf = b""
    while len(buf) < n:
        d = c.recv(n - len(buf))
        if not d:
            raise OSError("eof")
        buf += d
    return buf


def pump(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    try:
        b.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def handle(c, logpath):
    up = None
    try:
        hdr = recv_exact(c, 2)
        if hdr[0] != 5:
            return
        _ = recv_exact(c, hdr[1])
        c.sendall(b"\x05\x00")  # 选择"无认证"
        head = recv_exact(c, 4)
        if head[0] != 5 or head[1] != 1:
            return
        atyp = head[3]
        if atyp == 1:
            host = socket.inet_ntoa(recv_exact(c, 4))
        elif atyp == 3:
            host = recv_exact(c, recv_exact(c, 1)[0]).decode()
        elif atyp == 4:
            host = socket.inet_ntop(socket.AF_INET6, recv_exact(c, 16))
        else:
            return
        port = struct.unpack(">H", recv_exact(c, 2))[0]
        with open(logpath, "a") as f:
            f.write("CONNECT %s:%d\n" % (host, port))
        try:
            up = socket.create_connection((host, port), 10)
        except OSError:
            c.sendall(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
            return
        c.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        threading.Thread(target=pump, args=(c, up), daemon=True).start()
        pump(up, c)
    finally:
        for s in (c, up):
            if s:
                try:
                    s.close()
                except OSError:
                    pass


def main():
    host, port, logpath = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((host, port))
    s.listen(16)
    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c, logpath), daemon=True).start()


main()
