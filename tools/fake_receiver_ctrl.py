# -*- coding: utf-8 -*-
"""假接收端：监听 9000，等安卓发射端连入；收到握手后发反向控制消息。"""
import socket, struct, threading, sys, time

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", 9000))
srv.listen(1)
print("等待安卓发射端连入 :9000 ...")
conn, addr = srv.accept()
print("已连接:", addr)
conn.settimeout(5)

def recvn(n):
    buf = b""
    while len(buf) < n:
        try:
            c = conn.recv(n - len(buf))
        except socket.timeout:
            return None
        if not c:
            return None
        buf += c
    return buf

# 读握手
hs = recvn(16)
if not hs:
    print("握手读取失败")
    sys.exit(1)
w = struct.unpack(">HH", hs[11:15])
print("握手 OK: %dx%d@%d" % (w[0], w[1], hs[15]))

# 读若干帧（吃掉 config/帧），然后发控制
t0 = time.time()
frames = 0
while time.time() - t0 < 8:
    h = recvn(5)
    if h is None:
        break
    ln = struct.unpack(">I", h[:4])[0]
    typ = h[4]
    if ln > 0:
        p = recvn(ln)
        if p is None:
            break
    if typ == 1 or typ == 2:
        frames += 1
print("收到帧:", frames)

def send_ctrl(typ, payload):
    conn.sendall(struct.pack(">I", len(payload)) + bytes([typ]) + payload)

# 1) 点击：tap 屏幕中心（x=500,y=900 相对 0-1000）
print("发送 MOUSE down@500,900")
send_ctrl(4, struct.pack(">BHHh", 1, 500, 900, 0))
time.sleep(0.2)
print("发送 MOUSE up@500,900")
send_ctrl(4, struct.pack(">BHHh", 2, 500, 900, 0))
time.sleep(1.5)

# 2) 滑动：从 (500,800) 滑到 (500,300)（相当于下方向上滑）
print("发送 MOUSE down@500,800")
send_ctrl(4, struct.pack(">BHHh", 1, 500, 800, 0))
time.sleep(0.2)
print("发送 MOUSE up@500,300")
send_ctrl(4, struct.pack(">BHHh", 2, 500, 300, 0))
time.sleep(1.0)

# 3) 键盘：发送 'A'（android keyCode 29）
print("发送 KEY down code=29('A')")
send_ctrl(5, struct.pack(">BI", 0, 29))
time.sleep(0.3)
send_ctrl(5, struct.pack(">BI", 1, 29))

print("控制消息已全部发送，保持 3 秒观察...")
time.sleep(3)
conn.close()
srv.close()
print("完成")
