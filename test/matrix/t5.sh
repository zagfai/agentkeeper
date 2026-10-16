#!/bin/bash
# T5: rsync 深测
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 1
chmod 600 test/ticket_test test/out_test test/host_ed25519_test test/wrongkey 2>/dev/null
E="ssh -p 2222 -i test/ticket_test -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR"
R() { rsync "$@"; }
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1 -- $2"; fail=$((fail+1)); }

SRC=/tmp/rt5-src; DST=/tmp/rt5-dst; BAK=/tmp/rt5-bak
rm -rf $SRC $BAK; mkdir -p $SRC/sub/deep/a/b $SRC/emptydir $BAK
$E "basttest+127.0.0.1@127.0.0.1" "rm -r $DST" >/dev/null 2>&1
echo hello5 >$SRC/f1.txt
printf 'bin\0data\x01\x02' >"$SRC/bin file.bin"
echo "中文内容" >"$SRC/中文 文件名.txt"
echo quo >"$SRC/quo'te.txt"
ln -s f1.txt $SRC/link-f1
head -c 20971520 /dev/urandom >$SRC/big.bin

echo "==== T5 rsync 深测 ===="
t0=$(date +%s.%N)
R -a -e "$E" $SRC/ "basttest+127.0.0.1@127.0.0.1:$DST/" >/tmp/t5-up.log 2>&1; rc=$?
t1=$(date +%s.%N)
[ $rc -eq 0 ] && ok "1 多文件+嵌套上传 rc=0（20MB 用时 $(echo "$t1 $t0" | awk '{printf "%.1f", $1-$2}')s）" || { no "1 上传" "$(tail -3 /tmp/t5-up.log)"; }
python3 - $SRC $DST >/tmp/t5cmp 2>&1 <<'PY'
import os,sys,hashlib
a,b=sys.argv[1],sys.argv[2]
def snap(root):
    files,links,dirs={},{},set()
    for dp,dn,fn in os.walk(root):
        dirs.add(os.path.relpath(dp,root))
        for n in fn:
            p=os.path.join(dp,n); r=os.path.relpath(p,root)
            if os.path.islink(p): links[r]=os.readlink(p)
            else: files[r]=hashlib.md5(open(p,'rb').read()).hexdigest()
    return files,links,dirs
fa,la,da=snap(a); fb,lb,db=snap(b)
if fa==fb:
    print("FILES OK")
else:
    print("FILES DIFF")
    print(" only-src:", sorted(set(fa)-set(fb)))
    print(" only-dst:", sorted(set(fb)-set(fa)))
    for k in sorted(set(fa)&set(fb)):
        if fa[k]!=fb[k]:
            print(" content-diff:", repr(k), fa[k][:8], fb[k][:8])
print("LINKS", "OK" if la==lb else "DIFF")
print("DIRS",  "OK" if da==db else "DIFF")
PY
if grep -q 'FILES OK' /tmp/t5cmp && grep -q 'LINKS OK' /tmp/t5cmp && grep -q 'DIRS OK' /tmp/t5cmp; then ok "2 内容/含空格/中文/引号/二进制/符号链接/空目录 全部一致"; else no "2 一致性" "$(cat /tmp/t5cmp)"; fi
own=$(stat -c '%U' $DST/f1.txt); [ "$own" = "basttest" ] && ok "3 目标侧属主 basttest" || no "3 属主" "$own"
echo changed >>$SRC/f1.txt
R -v -a -e "$E" $SRC/ "basttest+127.0.0.1@127.0.0.1:$DST/" >/tmp/t5-inc.log 2>&1
if grep -q 'f1.txt' /tmp/t5-inc.log && ! grep -q 'big.bin' /tmp/t5-inc.log; then ok "4 增量：只传变化文件"; else no "4 增量" "$(grep -c . /tmp/t5-inc.log)行: $(tail -4 /tmp/t5-inc.log|tr '\n' '|')"; fi
rm $SRC/f1.txt
R -a --delete -e "$E" $SRC/ "basttest+127.0.0.1@127.0.0.1:$DST/" >/dev/null 2>&1
[ ! -f $DST/f1.txt ] && ok "5 --delete 同步删除" || no "5 --delete" "f1 还在"
echo hello5 >$SRC/f1.txt
R -a -e "$E" $SRC/ "basttest+127.0.0.1@127.0.0.1:$DST/" >/dev/null 2>&1
out=$($E 'basttest+127.0.0.1@127.0.0.1' 'hostname' 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$out" = "ops" ] && ok "6 直连形态 host(ssh)" || no "6 直连" "rc=$rc out=[$out]"
out=$($E 'basttest+127.0.0.1:22@127.0.0.1' 'hostname' 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$out" = "ops" ] && ok "7 直连形态 host:port(ssh)" || no "7 直连" "rc=$rc out=[$out]"
t0=$(date +%s.%N)
R -a -e "$E" "basttest+127.0.0.1@127.0.0.1:$DST/big.bin" $BAK/big.bin >/tmp/t5-down.log 2>&1; rc=$?
t1=$(date +%s.%N)
m1=$(md5sum $SRC/big.bin | cut -d' ' -f1); m2=$(md5sum $BAK/big.bin | cut -d' ' -f1)
if [ $rc -eq 0 ] && [ "$m1" = "$m2" ]; then ok "8 下载 20MB md5 一致（用时 $(echo "$t1 $t0" | awk '{printf "%.1f", $1-$2}')s）"; else no "8 下载" "rc=$rc m1=$m1 m2=$m2"; fi

echo "==== 汇总: PASS=$pass FAIL=$fail ===="
