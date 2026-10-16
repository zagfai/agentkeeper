#!/bin/bash
# T2: 交互模式 + 灰名单矩阵
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

echo "==== T2.1 交互模式 ===="
o=$($S -t $KT "$U" 'hostname' 2>/dev/null | tr '\r' '\n' | grep -m1 '^ops$'); chk "1 pty+命令→执行" "$o" "ops"
printf 'exit 7\n' | $S -tt $KT "$U" >/dev/null 2>&1; chk "2 交互 exit 7 传播" "$?" "7"
o=$({ printf 'sleep 30\n'; sleep 1.2; printf '\003'; sleep 0.8; printf 'echo AFTER-INT\n'; sleep 0.4; printf 'exit\n'; } | $S -tt $KT "$U" 2>/dev/null | tr -d '\r')
case "$o" in *AFTER-INT*) ok "3 Ctrl-C 后可继续输入";; *) no "3 Ctrl-C 中断" "$(echo "$o" | tail -2 | head -1)";; esac
o=$(printf 'echo 你好🎉\nexit\n' | $S -tt $KT "$U" 2>/dev/null | tr '\r' '\n' | grep -m1 '^你好🎉$'); chk "4 交互 UTF-8" "$o" "你好🎉"
o=$({ printf 'stty size\n'; sleep 1.0; printf 'exit\n'; } | $S -tt $KT "$U" 2>/dev/null | tr '\r' '\n' | grep -m1 -E '^[0-9]+ [0-9]+$'); chk "5 pty 窗口尺寸回落 80x24" "$o" "24 80"

echo "==== T2.2 灰名单 ===="
T=$(date +%s); GA=/tmp/gl-a-$T; GB=/tmp/gl-b-$T; GB2=/tmp/gl-b2-$T; GI=/tmp/gl-i-$T
rm -rf $GA $GB; $S $KT "$U" "mkdir -p $GA"; $S $KT "$U" "mkdir -p $GB"
out=$($S $KT "$U" "rm -rf $GA" 2>&1); rc=$?
if [ $rc -eq 1 ] && [ -d $GA ] && echo "$out" | grep -q '\[graylist\]'; then ok "6 命中→警告+不执行+exit1"; else no "6 命中拦截" "rc=$rc exists=$([ -d $GA ] && echo y)"; fi
out=$($S $KT "$U" "rm -rf $GA" 2>&1); rc=$?
if [ $rc -eq 0 ] && [ ! -d $GA ]; then ok "7 同命令重发→执行"; else no "7 重发执行" "rc=$rc exists=$([ -d $GA ] && echo y)"; fi
out=$($S $KT "$U" "rm -rf $GB" 2>&1); rc=$?
if [ $rc -eq 1 ] && [ -d $GB ]; then ok "8 不同路径需各自确认"; else no "8 不同路径" "rc=$rc"; fi
out=$($S $KT "$U" "rm -rf $GB" 2>&1); rc=$?
if [ $rc -eq 0 ] && [ ! -d $GB ]; then ok "9 第二条重发→执行"; else no "9 第二条重发" "rc=$rc"; fi
out=$($S $KT "$U" 'echo CLEAN-CMD' 2>&1); rc=$?
if [ $rc -eq 0 ] && [ "$out" = "CLEAN-CMD" ]; then ok "10 非命中命令直通"; else no "10 直通" "rc=$rc out=$out"; fi
out=$($S $KT "$U" 'RM -RF /tmp/xyz' 2>&1); rc=$?
if [ $rc -eq 127 ] && ! echo "$out" | grep -q graylist; then ok "11 大小写变体不命中(设计如此)"; else no "11 大小写变体" "rc=$rc"; fi
so=$($S $KT "$U" "rm -rf $GB2" 2>/dev/null); rc=$?
if [ $rc -eq 1 ] && [ -z "$so" ]; then ok "12 警告走 stderr、stdout 干净"; else no "12 流分离" "rc=$rc stdout=[$so]"; fi
o=$({ printf "mkdir -p $GI\n"; sleep 0.5; printf "rm -rf $GI\n"; sleep 1.4; printf "rm -rf $GI\n"; sleep 0.9; printf "echo GONE-CHK; ls -d $GI 2>/dev/null || echo GONE-I\n"; sleep 0.5; printf 'exit\n'; } | $S -tt $KT "$U" 2>/dev/null | tr -d '\r')
case "$o" in *GONE-I*) ok "13 交互命中:警告→重发→执行";; *) no "13 交互命中" "$(echo "$o" | tail -2 | head -1)";; esac
case "$o" in *"[graylist]"*) ok "14 交互警告框可见";; *) no "14 交互警告框" "not found";; esac
PD=/tmp/gl-regex-$T; $S $KT "$U" "mkdir -p $PD" >/dev/null 2>&1
out=$($S $KT "$U" "chmod -R 770 $PD" 2>&1); rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q '\[graylist\]'; then ok "15 正则模式命中((chmod|chown)\\s+-R)"; else no "15 正则" "rc=$rc out=[$(echo "$out"|head -1)]"; fi
out=$($S $KT "$U" "dd if=/dev/zero of=/dev/loop-none-$T bs=1 count=1" 2>&1); rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q '\[graylist\]'; then ok "16 磁盘写命令命中(dd of=/dev/)"; else no "16 dd" "rc=$rc out=[$(echo "$out"|head -1)]"; fi

echo "==== 汇总: PASS=$pass FAIL=$fail ===="
