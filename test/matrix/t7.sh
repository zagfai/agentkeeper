#!/bin/bash
# T7: 用户名语法（<远端用户名>[+码]+<目标>）与文件传输（totp off 前提）
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 1
chmod 600 test/ticket_test test/out_test test/host_ed25519_test test/wrongkey 2>/dev/null
S="ssh -p 2222 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=6"
E="ssh -p 2222 -i test/ticket_test -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR"
KT="-i test/ticket_test"
H="127.0.0.1"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1 -- $2"; fail=$((fail+1)); }

echo "==== T7.1 用户名语法 ===="
out=$($S $KT "basttest+127.0.0.1"@$H 'echo T7-1' 2>&1); rc=$?
[ "$out" = "T7-1" ] && ok "1 目标在用户名→命令执行" || no "1" "rc=$rc out=[$out]"
out=$($S $KT "basttest+127.0.0.1"@$H 'self pwd' 2>&1); rc=$?
echo "$out" | grep -q 'self: command not found' && [ $rc -eq 127 ] && ok "2 命令原样执行(不做首词切分)" || no "2 原样" "rc=$rc out=[$(echo "$out"|head -1)]"
o=$(printf 'echo T7-3\nexit\n' | $S -tt $KT "basttest+127.0.0.1"@$H 2>/dev/null | tr '\r' '\n' | grep -m1 '^T7-3$')
[ "$o" = "T7-3" ] && ok "3 目标在用户名→交互 shell" || no "3 交互" "out=[$o]"
out=$($S $KT "basttest+127.0.0.1"@$H 'echo "a b"; echo c' 2>&1)
[ "$out" = $'a b\nc' ] && ok "4 命令含空格/分号原样" || no "4 元字符" "out=[$out]"
out=$(printf 'ls\nquit\n' | timeout 8 sftp -oPort=2222 -i test/ticket_test -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "basttest"@$H 2>&1)
echo "$out" | grep -q 'sftp requires the target' && ok "5 sftp 无目标→明确拒绝" || no "5 sftp无目标" "out=[$(echo "$out"|tail -2|head -1)]"
out=$($S $KT basttest@$H 'echo T7-6' 2>&1); rc=$?
echo "$out" | grep -q 'no target in username' && [ $rc -eq 1 ] && ok "6 旧写法已移除（明确拒绝）" || no "6 旧写法" "rc=$rc out=[$(echo "$out"|head -1)]"

echo "==== T7.2 传输（目标随用户名）===="
rm -rf /tmp/t7-src; mkdir -p /tmp/t7-src/sub
echo t7-file1 >/tmp/t7-src/file1.txt; echo t7-file2 >/tmp/t7-src/sub/file2.txt
head -c 5242880 /dev/urandom >/tmp/t7-src/big.bin
SF="sftp -oPort=2222 -i test/ticket_test -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
$S $KT "basttest+127.0.0.1@$H" 'rm -r /tmp/t7-rs /tmp/t7-rs2' >/dev/null 2>&1
rsync -a -e "$E" /tmp/t7-src/ "basttest+127.0.0.1"@$H:/tmp/t7-rs/ >/dev/null 2>&1; rc=$?
out=$($S $KT "basttest+127.0.0.1@$H" 'cat /tmp/t7-rs/sub/file2.txt' 2>&1)
[ $rc -eq 0 ] && [ "$out" = "t7-file2" ] && ok "7 rsync 上传(无 --rsync-path)" || no "7 rsync 上传" "rc=$rc out=[$out]"
printf 'ls /tmp/t7-rs\nquit\n' | timeout 8 $SF "basttest+127.0.0.1"@$H >/tmp/t7-sf.out 2>&1
grep -q 'file1.txt' /tmp/t7-sf.out && ok "8 sftp ls" || no "8 sftp ls" "$(tail -2 /tmp/t7-sf.out|head -1)"
rm -f /tmp/t7-sfget.txt
printf 'get /tmp/t7-rs/file1.txt /tmp/t7-sfget.txt\nquit\n' | timeout 8 $SF "basttest+127.0.0.1"@$H >/dev/null 2>&1
[ "$(md5sum </tmp/t7-sfget.txt 2>/dev/null | cut -d' ' -f1)" = "$(md5sum </tmp/t7-src/file1.txt | cut -d' ' -f1)" ] && ok "9 sftp 下载 md5 一致" || no "9 sftp 下载" "mismatch"
printf 'put /tmp/t7-src/big.bin /tmp/t7-rs/big2.bin\nquit\n' | timeout 20 $SF "basttest+127.0.0.1"@$H >/dev/null 2>&1
out=$($S $KT "basttest+127.0.0.1@$H" 'md5sum /tmp/t7-rs/big2.bin' 2>&1 | cut -d' ' -f1)
[ "$out" = "$(md5sum </tmp/t7-src/big.bin | cut -d' ' -f1)" ] && ok "10 sftp 上传 5MB md5 一致" || no "10 sftp 上传" "out=[$out]"
scp -P 2222 -i test/ticket_test -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no /tmp/t7-src/file1.txt "basttest+127.0.0.1"@$H:/tmp/t7-scp-up.txt 2>/dev/null
out=$($S $KT "basttest+127.0.0.1@$H" 'cat /tmp/t7-scp-up.txt' 2>&1)
[ "$out" = "t7-file1" ] && ok "11 scp 上传(sftp通路)" || no "11 scp 上传" "out=[$out]"
rm -f /tmp/t7-scp-down.bin
scp -P 2222 -i test/ticket_test -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "basttest+127.0.0.1"@$H:/tmp/t7-rs/big2.bin /tmp/t7-scp-down.bin 2>/dev/null
[ -s /tmp/t7-scp-down.bin ] && [ "$(md5sum </tmp/t7-scp-down.bin | cut -d' ' -f1)" = "$(md5sum </tmp/t7-src/big.bin | cut -d' ' -f1)" ] && ok "12 scp 下载 5MB md5 一致" || no "12 scp 下载" "mismatch"
rm -f /tmp/t7-rs-down.bin
rsync -a -e "$E" "basttest+127.0.0.1"@$H:/tmp/t7-rs/big.bin /tmp/t7-rs-down.bin >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && [ -s /tmp/t7-rs-down.bin ] && [ "$(md5sum </tmp/t7-rs-down.bin | cut -d' ' -f1)" = "$(md5sum </tmp/t7-src/big.bin | cut -d' ' -f1)" ] && ok "13 rsync 下载 5MB md5 一致" || no "13 rsync 下载" "rc=$rc"
out=$(rsync -a -e "$E" --rsync-path='self rsync' /tmp/t7-src/ basttest@$H:/tmp/t7-rs2/ 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'no target in username' && ok "14 旧 --rsync-path 包法已移除（明确拒绝）" || no "14 旧包法" "rc=$rc"
scp -O -P 2222 -i test/ticket_test -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no /tmp/t7-src/file1.txt "basttest+127.0.0.1"@$H:/tmp/t7-scpo.txt 2>/dev/null
out=$($S $KT "basttest+127.0.0.1@$H" 'cat /tmp/t7-scpo.txt' 2>&1)
[ "$out" = "t7-file1" ] && ok "15 scp -O(传统exec通路)" || no "15 scp -O" "out=[$out]"

echo "==== 汇总: PASS=$pass FAIL=$fail ===="
