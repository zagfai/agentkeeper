#!/bin/bash
# T4: 录制/审计矩阵
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 1
chmod 600 test/ticket_test test/out_test test/host_ed25519_test test/wrongkey 2>/dev/null
S="ssh -p 2222 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=6"
KT="-i test/ticket_test"; A="basttest@127.0.0.1"
U="basttest+127.0.0.1@127.0.0.1"
REC=test/rec/$(date +%F)
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1 -- $2"; fail=$((fail+1)); }

echo "==== T4 录制与审计 ===="
# 1 大输出会话：200k 行，录后精确对比
$S $KT "$U" 'seq 1 200000' > /tmp/t4-direct.out 2>/dev/null
LATEST=$(ls -t $REC/*.cast | head -1)
python3 - /tmp/t4-direct.out "$LATEST" >/tmp/t4r 2>&1 <<'PY'
import json,sys
direct=open(sys.argv[1],'rb').read()
out=b''
for ln in open(sys.argv[2],'rb'):
    ev=json.loads(ln)
    if isinstance(ev,list) and len(ev)==3 and ev[1]=='o': out+=ev[2].encode()
print("OK" if out==direct else "MISMATCH direct=%d cast=%d"%(len(direct),len(out)))
PY
grep -q '^OK' /tmp/t4r && ok "1 大输出(200k行 ~1.4MB)录用精确一致" || no "1 大输出" "$(cat /tmp/t4r)"
# 2 四件套 + 权限
M=$(ls -t $REC/*.meta.json | head -1); D=${M%.meta.json}
if [ -f "$D.cast" ] && [ -f "$D.in.raw" ] && [ -f "$D.cmd.log" ] && [ -f "$M" ]; then ok "2 四件套齐全"; else no "2 四件套" "$D"; fi
pm=$(stat -c %a "$D.in.raw"); [ "$pm" = "600" ] && ok "3 in.raw 权限 600" || no "3 权限" "$pm"
python3 - "$M" >/tmp/t4m 2>&1 <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))
ks=('user','target','peer','started','duration_s','exit','bytes_in','bytes_out','events')
print("OK" if all(k in m for k in ks) else "BAD")
PY
grep -q '^OK' /tmp/t4m && ok "4 meta 字段完整" || no "4 meta" "$(cat /tmp/t4m)"
# 5 cmd.log 记录命令
$S $KT "$U" 'echo CMDLOG-CHK' >/dev/null 2>&1
M=$(ls -t $REC/*.meta.json | head -1); D=${M%.meta.json}
grep -q 'echo CMDLOG-CHK' "$D.cmd.log" && ok "5 cmd.log 记录命令时间线" || no "5 cmd.log" "$(head -2 "$D.cmd.log")"
# 6 in.raw 内容 = stdin 字节
echo -n 'RAWPAYLOAD' | $S $KT "$U" 'cat' >/tmp/t4-cat.out 2>/dev/null
M=$(ls -t $REC/*.meta.json | head -1); D=${M%.meta.json}
if [ "$(cat /tmp/t4-cat.out)" = "RAWPAYLOAD" ] && grep -q 'RAWPAYLOAD' "$D.in.raw"; then ok "6 in.raw=原始输入"; else no "6 in.raw" "raw=[$(cat "$D.in.raw")]"; fi
# 7 索引追加合法
tail -1 test/rec/sessions.jsonl | python3 -c 'import json,sys; m=json.loads(sys.stdin.read()); assert m["user"]=="basttest" and "target" in m; print("OK")' >/tmp/t4i 2>&1
grep -q '^OK' /tmp/t4i && ok "7 sessions.jsonl 索引合法" || no "7 索引" "$(cat /tmp/t4i)"
# 8 并发 5 会话内容正确
for i in 1 2 3 4 5; do ( $S $KT "$U" "echo CONC-$i; sleep 0.2" >/tmp/t4c-$i.out 2>&1 ) & done; wait
cn=0; for i in 1 2 3 4 5; do [ "$(cat /tmp/t4c-$i.out 2>/dev/null)" = "CONC-$i" ] && cn=$((cn+1)); done
[ "$cn" = "5" ] && ok "8 并发5会话输出正确" || no "8 并发" "$cn/5"
# 9 并发录像不串（近 90s 内：5 个 CONC 标记各在其自己的 cast 里，且无 cast 混入多个）
python3 - >/tmp/t4p 2>&1 <<'PY'
import glob,os,json,time
def scan():
    now=time.time()
    recent=[c for c in glob.glob('test/rec/*/*.cast') if now-os.path.getmtime(c)<90]
    seen=set(); bad=[]
    for c in recent:
        s=''
        for l in open(c):
            if not l.strip(): continue
            ev=json.loads(l)
            if isinstance(ev,list) and len(ev)==3 and ev[1]=='o': s+=ev[2]
        ms=[m for m in ['CONC-1','CONC-2','CONC-3','CONC-4','CONC-5'] if m in s]
        if len(ms)==1: seen.add(ms[0])
        elif len(ms)>1: bad.append((os.path.basename(c),ms))
    return seen,bad
ok=False
for _ in range(20):
    seen,bad=scan()
    if len(seen)==5 and not bad: ok=True; break
    time.sleep(1)
print("OK" if ok else "BAD seen=%s bad=%s"%(sorted(seen),bad))
PY
grep -q '^OK' /tmp/t4p && ok "9 并发录像无串流" || no "9 并发录像" "$(cat /tmp/t4p)"
# 10 客户端中途断开：录制仍完整（远端继续跑完）
timeout 2 $S $KT "$U" 'sleep 4; echo LATE-DONE' >/dev/null 2>&1
sleep 5
M=$(ls -t $REC/*.meta.json | head -1); D=${M%.meta.json}
if grep -q 'LATE-DONE' "$D.cast"; then
  dur=$(python3 -c "import json;print('%.1f'%json.load(open('$M'))['duration_s'])")
  ok "10 断线后录制完整(duration=${dur}s)"
else no "10 断线录制" "LATE-DONE 不在 cast"; fi

echo "==== 汇总: PASS=$pass FAIL=$fail ===="
