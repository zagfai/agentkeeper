#!/bin/bash
# T1: 认证与命令模式边界测试矩阵
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 1
chmod 600 test/ticket_test test/out_test test/host_ed25519_test test/wrongkey 2>/dev/null
S="ssh -p 2222 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=6"
KT="-i test/ticket_test"
A="basttest@127.0.0.1"
U="basttest+127.0.0.1@127.0.0.1"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1 -- $2"; fail=$((fail+1)); }
chk(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "want[$3] got[$2]"; }

echo "==== T1.1 认证边界 ===="
out=$($S $KT "$U" 'echo AUTH-OK' 2>&1); chk "1 正确票→可用" "$out" "AUTH-OK"
out=$($S -o BatchMode=yes -o PreferredAuthentications=publickey "$U" 'echo x' 2>&1 | tail -1)
case "$out" in *"Permission denied"*) ok "2 无票被拒";; *) no "2 无票被拒" "$out";; esac
[ -f test/wrongkey ] || ssh-keygen -q -t ed25519 -N '' -f test/wrongkey
out=$($S -i test/wrongkey -o BatchMode=yes -o PreferredAuthentications=publickey "$U" 'echo x' 2>&1 | tail -1)
case "$out" in *"Permission denied"*) ok "3 错票被拒";; *) no "3 错票被拒" "$out";; esac
out=$($S $KT ops@127.0.0.1 'echo x' 2>&1); rc=$?
case "$out" in *"no target in username"*) ok "4 用户名不参与认证（任意名+有效票→过认证，因无目标被拒）";; *) no "4" "rc=$rc out=[$(echo "$out"|head -1)]";; esac
# known_hosts 正向
ssh-keyscan -p 2222 127.0.0.1 >test/kh_scan 2>/dev/null
out=$($S -o UserKnownHostsFile=test/kh_scan -o StrictHostKeyChecking=yes $KT "$U" 'echo KH-OK' 2>&1); chk "5 known_hosts 指纹吻合→连" "$out" "KH-OK"
# known_hosts 负向：放一枚不匹配的假指纹
ssh-keygen -q -t ed25519 -N '' -f /tmp/khw_fake
printf '[127.0.0.1]:2222 %s\n' "$(cat /tmp/khw_fake.pub)" >test/kh_wrong
rm -f /tmp/khw_fake /tmp/khw_fake.pub
out=$(ssh -p 2222 -o UserKnownHostsFile=test/kh_wrong -o StrictHostKeyChecking=yes -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=6 -i test/ticket_test 'basttest+127.0.0.1'@127.0.0.1 'echo x' 2>&1 | tail -1)
case "$out" in *"Host key verification failed"*) ok "6 指纹不符→拒连";; *) no "6 指纹不符→拒连" "$out";; esac

echo "==== T1.2 命令模式边界 ===="
$S $KT "$U" 'exit 42' >/dev/null 2>&1; chk "7 exit 42 传播" "$?" "42"
o=$($S $KT "$U" 'sh -c "echo OUT; echo ERR 1>&2"' 2>/dev/null); chk "8 stdout 分离" "$o" "OUT"
e=$($S $KT "$U" 'sh -c "echo OUT; echo ERR 1>&2"' 2>&1 >/dev/null); chk "9 stderr 分离" "$e" "ERR"
o=$(echo hello-pipe | $S $KT "$U" 'cat' 2>&1); chk "10 stdin 管道透传" "$o" "hello-pipe"
head -c 1048576 /dev/urandom >/tmp/t2bin1
$S $KT "$U" 'cat' </tmp/t2bin1 >/tmp/t2bin2 2>/dev/null
chk "11 二进制 1MB 往返" "$(md5sum </tmp/t2bin1 | cut -d' ' -f1)" "$(md5sum </tmp/t2bin2 | cut -d' ' -f1)"
BIG=$(python3 -c "print('x'*40000)")
o=$($S $KT "$U" "echo $BIG" 2>&1 | wc -c); chk "12 超长命令 40KB" "$o" "40001"
o=$($S $KT "$U" 'printf "中文🎉-OK\n"' 2>&1); chk "13 UTF-8 输出" "$o" "中文🎉-OK"
o=$($S $KT "$U" $'echo lineA\necho lineB' 2>&1); chk "14 多行命令" "$o" $'lineA\nlineB'
o=$($S $KT "$U" 'echo "x; y | z"' 2>&1); chk "15 元字符原样送达" "$o" "x; y | z"
out=$(timeout 15 $S $KT "basttest+nosuchalias@127.0.0.1" 'echo x' 2>&1); rc=$?
case "$out" in *"target resolution failed"*|*"cannot connect"*) chk "16 未知目标(连不通)→报错+exit1" "$rc" "1";; *) no "16 未知目标" "$out";; esac
out=$(timeout 20 $S $KT "basttest+10.99.99.99:22@127.0.0.1" 'echo x' 2>&1); rc=$?
if [ $rc -ne 124 ] && [ -n "$out" ]; then ok "17 目标不可达→报错返回(rc=$rc)"; else no "17 目标不可达" "rc=$rc out=[$out]"; fi
out=$($S $KT $A 'self echo x' 2>&1); rc=$?
case "$out" in *"no target in username"*) chk "18a 旧写法(命令首词)→拒绝+exit1" "$rc" "1";; *) no "18a 旧写法" "rc=$rc out=[$out]";; esac
out=$(timeout 8 $S -T $KT $A </dev/null 2>&1); rc=$?
case "$out" in *"no target in username"*) chk "18b 无目标(无pty)→拒绝+exit1" "$rc" "1";; *) no "18b" "rc=$rc out=[$out]";; esac
out=$(printf '\n' | timeout 8 $S -tt $KT $A 2>&1); rc=$?
case "$out" in *"no target in username"*) ok "19 交互无目标→拒绝(无提示)";; *) no "19 无目标" "rc=$rc out=[$(echo "$out"|tail -1)]";; esac

echo "==== 汇总: PASS=$pass FAIL=$fail ===="
