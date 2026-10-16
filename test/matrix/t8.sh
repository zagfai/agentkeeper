#!/bin/bash
# T8: SOCKS5 出口（堡垒连目标机经代理）
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 1
chmod 600 test/ticket_test test/out_test test/host_ed25519_test test/wrongkey 2>/dev/null
S="ssh -p 2222 -i test/ticket_test -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=8"
E="ssh -p 2222 -i test/ticket_test -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR"
C="test/agentkeeper.test.yaml"
LOG=/tmp/t8-socks.log
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1 -- $2"; fail=$((fail+1)); }

echo "==== T8 SOCKS5 出口 ===="
rm -f $LOG
python3 test/socks5.py 127.0.0.1 1081 $LOG >/dev/null 2>&1 &
SP=$!
sleep 0.6
sed -i 's|^proxy: .*|proxy: "socks5://127.0.0.1:1081"|' $C
pkill -f '[a]gentkeeper -c test/agentkeeper.test'; sleep 0.4
./agentkeeper -c $C >>/tmp/agentkeeper.log 2>&1 &
BP=$!
sleep 0.7

out=$($S 'basttest+127.0.0.1@127.0.0.1' 'echo VIA-SOCKS' 2>&1); rc=$?
[ "$out" = "VIA-SOCKS" ] && [ $rc -eq 0 ] && ok "1 命令模式经 socks5 连通" || no "1" "rc=$rc out=[$(echo "$out"|head -1)]"
grep -q 'CONNECT 127.0.0.1:22' $LOG && ok "2 代理日志证实流量走了代理" || no "2 代理日志" "$(cat $LOG 2>/dev/null)"

echo "t8-payload" >/tmp/t8-src.txt
rsync -a -e "$E" /tmp/t8-src.txt 'basttest+127.0.0.1@127.0.0.1:/tmp/t8-dst.txt' >/dev/null 2>&1; rc=$?
out=$($S 'basttest+127.0.0.1@127.0.0.1' 'cat /tmp/t8-dst.txt' 2>&1)
[ $rc -eq 0 ] && [ "$out" = "t8-payload" ] && ok "3 rsync 经代理上传可用" || no "3 rsync 经代理" "rc=$rc out=[$out]"
n=$(grep -c 'CONNECT 127.0.0.1:22' $LOG)
[ "$n" -ge 2 ] && ok "4 多次连接均走代理($n 次)" || no "4 计数" "$n"

kill $SP 2>/dev/null; sleep 0.4
out=$(timeout 15 $S 'basttest+127.0.0.1@127.0.0.1' 'echo x' 2>&1); rc=$?
echo "$out" | grep -q 'socks5\|cannot connect' && [ $rc -eq 1 ] && ok "5 代理不可用→拨号阶段失败" || no "5 代理故障" "rc=$rc out=[$(echo "$out"|head -1)]"

kill $BP 2>/dev/null; sleep 0.3
sed -i 's|^proxy: .*|proxy: ""|' $C
echo "==== 汇总: PASS=$pass FAIL=$fail ===="
