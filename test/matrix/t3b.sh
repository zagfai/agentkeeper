#!/bin/bash
# T3b v2: TOTP mode=patterns ["self"]
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 1
chmod 600 test/ticket_test test/out_test test/host_ed25519_test test/wrongkey 2>/dev/null
S="ssh -p 2222 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=6"
E="ssh -p 2222 -i test/ticket_test -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR"
KT="-i test/ticket_test"
H="127.0.0.1"
SECRET=$(sed -n 's/.*secret: "\(.*\)"/\1/p' test/agentkeeper.test.yaml)
CUR=$(python3 test/totp.py $SECRET)
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1 -- $2"; fail=$((fail+1)); }

echo "==== T3b v2 TOTP mode=patterns [self] ===="
out=$($S $KT "basttest+127.0.0.1@$H" 'echo NEVER1' 2>&1); rc=$?
echo "$out" | grep -q 'TOTP required' && ! echo "$out" | grep -q NEVER1 && ok "1 命中目标要码(未执行)" || no "1 命中要码" "rc=$rc out=[$(echo "$out"|head -1)]"
out=$($S $KT "basttest+127.0.0.1+$CUR@$H" 'echo P2-OK' 2>&1)
[ "$out" = "P2-OK" ] && ok "2 命中目标+码放行" || no "2 命中+码" "out=[$out]"
out=$($S $KT "basttest+localhost@$H" 'echo P3-OK' 2>&1)
[ "$out" = "P3-OK" ] && ok "3 非命中目标免码" || no "3 免码" "out=[$out]"
rsync -a -e "$E" /tmp/rt-src/file1.txt "basttest+127.0.0.1+$CUR@$H:/tmp/t3b-rs.txt" >/dev/null 2>&1; rc=$?
out=$($S $KT "basttest+127.0.0.1+$CUR@$H" 'cat /tmp/t3b-rs.txt' 2>&1)
[ $rc -eq 0 ] && [ "$out" = "$(cat /tmp/rt-src/file1.txt)" ] && ok "4 rsync 带码传文件" || no "4 rsync 带码" "rc=$rc out=[$out]"
out=$(printf 'ls\nquit\n' | timeout 8 sftp -oPort=2222 -i test/ticket_test -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "basttest+127.0.0.1@$H" 2>&1)
echo "$out" | grep -q 'TOTP required' && ok "5 sftp 无码→拒绝" || no "5 sftp 无码" "out=[$(echo "$out"|tail -2|head -1)]"

echo "==== 汇总: PASS=$pass FAIL=$fail ===="
