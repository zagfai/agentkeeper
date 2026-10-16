#!/bin/bash
# T3a v2: TOTP（用户名带码）mode=all
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 1
chmod 600 test/ticket_test test/out_test test/host_ed25519_test test/wrongkey 2>/dev/null
S="ssh -p 2222 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=6"
KT="-i test/ticket_test"
H="127.0.0.1"
SECRET=$(sed -n 's/.*secret: "\(.*\)"/\1/p' test/agentkeeper.test.yaml)
CUR=$(python3 test/totp.py $SECRET); B3=$(python3 test/totp.py $SECRET -90); B11=$(python3 test/totp.py $SECRET -330); FWD=$(python3 test/totp.py $SECRET 30)
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1 -- $2"; fail=$((fail+1)); }

echo "==== T3a v2 TOTP mode=all（用户名带码）===="
out=$($S $KT "basttest+127.0.0.1+$CUR@$H" 'echo T1-OK' 2>&1); rc=$?
if [ "$out" = "T1-OK" ] && [ $rc -eq 0 ]; then ok "1 码+目标在用户名→纯净输出"; else no "1 纯净" "rc=$rc out=[$out]"; fi
out=$($S $KT "basttest+$CUR+127.0.0.1@$H" 'echo NEVER2' 2>&1); rc=$?
echo "$out" | grep -q 'invalid TOTP code' && ! echo "$out" | grep -q NEVER2 && ok "2 旧顺序(码在目标前)→拒绝" || no "2 旧顺序" "rc=$rc out=[$(echo "$out"|head -1)]"
out=$($S $KT "basttest+127.0.0.1@$H" 'echo NEVER3' 2>&1); rc=$?
echo "$out" | grep -q 'TOTP required' && ! echo "$out" | grep -q 'NEVER3' && ok "3 无码→拒绝(未执行)" || no "3 无码" "rc=$rc out=[$(echo "$out"|head -1)]"
out=$($S $KT "basttest+127.0.0.1+000000@$H" 'echo NEVER4' 2>&1); rc=$?
echo "$out" | grep -q 'invalid TOTP code' && ! echo "$out" | grep -q 'NEVER4' && ok "4 错码→拒绝(未执行)" || no "4 错码" "rc=$rc out=[$(echo "$out"|head -1)]"
out=$($S $KT "basttest+127.0.0.1+$B3@$H" 'echo T5-OK' 2>&1)
[ "$out" = "T5-OK" ] && ok "5 往前3窗(-90s)码接受" || no "5 -90s" "out=[$out]"
out=$($S $KT "basttest+127.0.0.1+$B11@$H" 'echo NEVER6' 2>&1)
echo "$out" | grep -q 'invalid TOTP code' && ! echo "$out" | grep -q NEVER6 && ok "6 往前11窗(-330s)拒绝" || no "6 -330s" "out=[$(echo "$out"|head -1)]"
out=$($S $KT "basttest+127.0.0.1+$FWD@$H" 'echo T7-OK' 2>&1)
[ "$out" = "T7-OK" ] && ok "7 时钟超前1窗(+30s)接受" || no "7 +30s" "out=[$out]"
o=$(printf 'echo IT8-OK\nexit\n' | $S -tt $KT "basttest+127.0.0.1+$CUR@$H" 2>/dev/null | tr '\r' '\n' | grep -m1 '^IT8-OK$')
[ "$o" = "IT8-OK" ] && ok "8 交互模式带码" || no "8 交互" "out=[$o]"
o=$(timeout 8 $S -tt $KT "basttest+127.0.0.1@$H" </dev/null 2>&1 | tr '\r' '\n')
echo "$o" | grep -q 'TOTP required' && ok "9 交互无码→拒绝" || no "9 交互无码" "尾=[$(echo "$o"|tail -1)]"
MKO=$(grep -cE 'user=basttest\+127\.0\.0\.1\+\*\*\*' /tmp/agentkeeper.log 2>/dev/null || true)
RAW=$(grep -cF "user=basttest+127.0.0.1+$CUR" /tmp/agentkeeper.log 2>/dev/null || true)
RAW2=$(grep -cF "user=basttest+$CUR+" /tmp/agentkeeper.log 2>/dev/null || true)
[ "${MKO:-0}" -gt 0 ] && [ "${RAW:-0}" = "0" ] && [ "${RAW2:-0}" = "0" ] && ok "10 日志脱敏(码以***落日志，裸码未现)" || no "10 日志" "masked=${MKO:-0} raw=${RAW:-0}/${RAW2:-0}"
MF=$(ls -t test/rec/*/*.meta.json 2>/dev/null | head -30 | xargs grep -l '"kind": "totp"' 2>/dev/null | head -1)
[ -n "$MF" ] && ok "11 meta 记录 totp 事件" || no "11 meta" "未见"
MG=$(ls -t test/rec/*/*.meta.json 2>/dev/null | head -30 | xargs grep -l '"detail": "fail"' 2>/dev/null | head -1)
[ -n "$MG" ] && grep -q '"kind": "totp"' "$MG" && ok "12 失败也记档(totp fail)" || no "12 fail 档" "未见"

echo "— 传输在统一 TOTP 下（全部带码）—"
E13="ssh -p 2222 -i test/ticket_test -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR"
TR="t3a-tr-$$"; echo "tr-content-$TR" >/tmp/t3a-src.txt
rsync -a -e "$E13" /tmp/t3a-src.txt "basttest+127.0.0.1+$CUR@$H:/tmp/$TR.txt" >/dev/null 2>&1; rc=$?
out=$($S $KT "basttest+127.0.0.1+$CUR@$H" "cat /tmp/$TR.txt" 2>&1)
[ $rc -eq 0 ] && [ "$out" = "tr-content-$TR" ] && ok "13 rsync 带码上传（文件传输同样要码）" || no "13 rsync 带码" "rc=$rc out=[$out]"
out=$(printf 'ls /tmp\nquit\n' | timeout 8 sftp -oPort=2222 -i test/ticket_test -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "basttest+127.0.0.1+$CUR@$H" 2>&1)
echo "$out" | grep -q "$TR.txt" && ok "14 sftp 带码可用" || no "14 sftp 带码" "out=[$(echo "$out"|tail -2|head -1)]"
scp -P 2222 -i test/ticket_test -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR /tmp/t3a-src.txt "basttest+127.0.0.1+$CUR@$H:/tmp/$TR-scp.txt" >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && ok "15 scp 带码上传" || no "15 scp 带码" "rc=$rc"
rsync -a -e "$E13" /tmp/t3a-src.txt "basttest+127.0.0.1@$H:/tmp/$TR-no.txt" >/dev/null 2>&1; rc=$?
out=$($S $KT "basttest+127.0.0.1+$CUR@$H" "ls /tmp/$TR-no.txt 2>/dev/null || echo ABSENT" 2>&1)
[ $rc -ne 0 ] && [ "$out" = "ABSENT" ] && ok "16 rsync 无码→拒绝且未落地" || no "16 rsync 无码" "rc=$rc out=[$out]"

echo "==== 汇总: PASS=$pass FAIL=$fail ===="
