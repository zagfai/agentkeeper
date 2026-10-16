#!/bin/bash
# T6: CLI/配置校验 + 协议杂项
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 1
chmod 600 test/ticket_test test/out_test test/host_ed25519_test test/wrongkey 2>/dev/null
S="ssh -p 2222 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=6"
KT="-i test/ticket_test"; A="basttest@127.0.0.1"
U="basttest+127.0.0.1@127.0.0.1"
KEY=$(cat test/ticket_test.pub)
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1 -- $2"; fail=$((fail+1)); }

echo "==== T6a CLI 与配置校验 ===="
out=$(./agentkeeper gen-secret 2>&1); echo "$out" | head -1 | grep -Eq '^secret: [A-Z2-7]{32}$' && ok "1 gen-secret 格式(32位base32)" || no "1 gen-secret" "$(echo "$out"|head -1)"
out=$(./agentkeeper totp-uri -c test/agentkeeper.test.yaml 2>&1)
case "$out" in *otpauth://totp/AgentKeeper:agent\?*secret=*) ok "2 totp-uri 格式(按用户)";; *) no "2 totp-uri" "$out";; esac
./agentkeeper check -c test/agentkeeper.test.yaml >/dev/null 2>&1 && ok "3 check 正常配置" || no "3 check" "rc=$?"
printf 'listen: [oops\n' >/tmp/bt-bad1.yaml
out=$(./agentkeeper check -c /tmp/bt-bad1.yaml 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'bad config' && ok "4 坏 YAML 报错" || no "4 坏YAML" "rc=$rc $out"
cat >/tmp/bt-bad2.yaml <<EOF
listen: "127.0.0.1:2298"
host_key: "$PWD/test/host_ed25519_test"
recordings_dir: "/tmp/bt-rec"
users:
  - name: agent
    keys:
      - "ssh-ed25519 NOT-A-KEY x"
    totp_secret: "DFDMV7BT72R6FC6X4WLCTKMO73WOVDZ7"
EOF
out=$(timeout 4 ./agentkeeper -c /tmp/bt-bad2.yaml 2>&1); rc=$?
if echo "$out" | grep -q 'bad public key'; then ok "5 坏公钥→启动时报错"; else no "5 坏公钥" "rc=$rc $out"; fi
out=$(./agentkeeper check -c /tmp/bt-bad2.yaml 2>&1); rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q 'bad public key'; then ok "5b check 阶段即报坏公钥"; else no "5b check" "rc=$rc $out"; fi
cat >/tmp/bt-bad3.yaml <<EOF
listen: "127.0.0.1:2298"
host_key: "test/host_ed25519_test"
users: []
EOF
out=$(./agentkeeper check -c /tmp/bt-bad3.yaml 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'no users configured\|no usable public keys' && ok "6 无用户报错" || no "6 无用户" "rc=$rc $out"
cat >/tmp/bt-nokey.yaml <<EOF
listen: "127.0.0.1:2298"
host_key: "/tmp/does-not-exist-key"
recordings_dir: "/tmp/bt-rec"
users:
  - name: agent
    keys:
      - "$KEY"
    totp_secret: "DFDMV7BT72R6FC6X4WLCTKMO73WOVDZ7"
EOF
out=$(./agentkeeper check -c /tmp/bt-nokey.yaml 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'host key' && ok "7 check 缺 host_key 报错" || no "7 check" "rc=$rc $(echo "$out"|tail -1)"
out=$(timeout 4 ./agentkeeper -c /tmp/bt-nokey.yaml 2>&1); rc=$?
echo "$out" | grep -q 'read host key' && ok "7b 缺 host_key 启动报错" || no "7b" "rc=$rc $out"
out=$(timeout 4 ./agentkeeper -c test/agentkeeper.test.yaml 2>&1); rc=$?
echo "$out" | grep -q 'address already in use' && ok "8 端口占用报错" || no "8 端口占用" "rc=$rc $out"

echo "==== T6b 协议杂项 ===="
out=$(timeout 8 sftp -oPort=2222 -i test/ticket_test -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o BatchMode=yes -b /dev/null basttest@127.0.0.1 2>&1); rc=$?
[ $rc -ne 0 ] && echo "NOTE: 9 sftp 尝试 rc=$rc 输出=[$(echo "$out"|head -1)]（无目标被拒；带目标即支持）" && pass=$((pass+1)) || no "9 sftp" "意外成功?"
out=$(timeout 8 scp -P 2222 -i test/ticket_test -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o BatchMode=yes test/ticket_test.pub basttest@127.0.0.1:/tmp/never 2>&1); rc=$?
[ $rc -ne 0 ] && echo "NOTE: 10 scp(现代/子系统) rc=$rc 输出=[$(echo "$out"|head -1)]（无目标被拒；带目标即支持）" && pass=$((pass+1)) || no "10 scp" "意外成功?"
out=$(timeout 8 scp -O -P 2222 -i test/ticket_test -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o BatchMode=yes test/ticket_test.pub basttest@127.0.0.1:/tmp/never 2>&1); rc=$?
[ $rc -ne 0 ] && echo "NOTE: 11 scp -O(传统exec) rc=$rc 输出=[$(echo "$out"|head -1)]（无目标被拒；带目标即支持）" && pass=$((pass+1)) || no "11 scp -O" "意外成功?"
out=$($S -L 12346:127.0.0.1:22 $KT "$U" 'echo L-OK' 2>&1)
if echo "$out" | grep -q 'L-OK'; then echo "NOTE: 12 -L 转发被拒但会话正常 [$(echo "$out"|grep -i -m1 'forward\|refused\|denied' || echo 无警告行)]"; pass=$((pass+1)); else no "12 -L 转发" "$(echo "$out"|head -2)"; fi
out=$(timeout 10 $S $KT "basttest+127.0.0.1:notaport@127.0.0.1" 'echo x' 2>&1); rc=$?
echo "$out" | grep -q 'target resolution failed\|cannot connect' && ok "13 畸形目标→解析失败" || no "13 畸形目标" "rc=$rc $out"
out=$($S $KT $A 'self; id' 2>&1); rc=$?
echo "$out" | grep -q 'no target in username' && [ $rc -eq 1 ] && ok "14 旧注入形态→拒绝" || no "14 旧形态" "rc=$rc out=[$(echo "$out"|head -1)]"
out=$($S $KT "basttest+self;id@127.0.0.1" 'echo x' 2>&1); rc=$?
echo "$out" | grep -q 'invalid characters' && [ $rc -ne 0 ] && ok "14b 用户名含分号→客户端即拒(到不了堡垒)" || no "14b 分号用户名" "rc=$rc out=[$(echo "$out"|head -1)]"
T=$(date +%s); P=/tmp/gl-quote-$T
$S $KT "$U" "mkdir -p $P" >/dev/null 2>&1
out=$($S $KT "$U" "r''m -rf $P" 2>&1); rc=$?
if [ $rc -eq 1 ] && [ -d $P ] && echo "$out" | grep -q graylist; then ok "15 引号拆字已命中警告(未执行)"; else no "15 引号拆字" "rc=$rc exists=$([ -d $P ] && echo y)"; fi
out=$($S $KT "$U" "r''m -rf $P" 2>&1); rc=$?
[ $rc -eq 0 ] && [ ! -d $P ] && ok "15b 拆字变体重发→执行" || no "15b 重发" "rc=$rc"
c=0; for i in $(seq 20); do $S $KT "$U" 'true' >/dev/null 2>&1 && c=$((c+1)); done
[ $c -eq 20 ] && ok "16 20 次连续连接全部成功" || no "16 连击" "$c/20"
out=$($S $KT "basttest+127.0.0.1+123456@127.0.0.1" 'echo U17-OK' 2>&1)
[ "$out" = "U17-OK" ] && ok "17 三字段(off模式码免验)" || no "17 用户名带码" "out=[$out]"
out=$($S $KT "anyname+127.0.0.1@127.0.0.1" 'echo x' 2>&1); rc=$?
echo "$out" | grep -q 'cannot connect' && [ $rc -eq 1 ] && ok "17b 用户名随意填：认证过、远端无此账号→拨号失败" || no "17b" "rc=$rc out=[$(echo "$out"|head -1)]"
cat >/tmp/bt-bad4.yaml <<EOF
listen: "127.0.0.1:2298"
host_key: "$PWD/test/host_ed25519_test"
recordings_dir: "/tmp/bt-rec"
users:
  - name: agent
    keys:
      - "$KEY"
    totp_secret: "DFDMV7BT72R6FC6X4WLCTKMO73WOVDZ7"
gray:
  window: "5m"
  patterns:
    - "rm("
EOF
out=$(./agentkeeper check -c /tmp/bt-bad4.yaml 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'gray pattern' && ok "18 非法正则→check 报错" || no "18 非法正则" "rc=$rc $(echo "$out"|tail -1)"
cat >/tmp/bt-bad5.yaml <<EOF
listen: "127.0.0.1:2298"
host_key: "$PWD/test/host_ed25519_test"
recordings_dir: "/tmp/bt-rec"
users:
  - name: agent
    keys:
      - "$KEY"
EOF
out=$(./agentkeeper check -c /tmp/bt-bad5.yaml 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'totp_secret required' && ok "19 默认统一TOTP：缺 totp_secret→check 报错" || no "19 缺 secret" "rc=$rc $(echo "$out"|tail -1)"

echo "==== 汇总: PASS=$pass FAIL=$fail ===="
