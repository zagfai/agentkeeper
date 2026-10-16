#!/usr/bin/env python3
# 测试用：生成当前 TOTP 码。用法: python3 totp.py <base32-secret>
import base64, hashlib, hmac, struct, sys, time

secret = sys.argv[1]
offset = int(sys.argv[2]) if len(sys.argv) > 2 else 0
key = base64.b32decode(secret + "=" * (-len(secret) % 8))
step = (int(time.time()) + offset) // 30
digest = hmac.new(key, struct.pack(">Q", step), hashlib.sha1).digest()
off = digest[-1] % 16
code = struct.unpack(">I", digest[off:off + 4])[0] % 0x80000000
print("%06d" % (code % 1000000))
