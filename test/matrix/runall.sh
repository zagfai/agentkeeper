#!/bin/bash
# 全矩阵一键复跑：T1–T8 全部套件（自动切换 TOTP 模式、自建/清理实例）
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 1
chmod 600 test/ticket_test test/out_test test/host_ed25519_test test/wrongkey 2>/dev/null
C="test/agentkeeper.test.yaml"
pkill -f '[a]gentkeeper -c test/agentkeeper.test'; sleep 0.5
./agentkeeper -c $C >>/tmp/agentkeeper.log 2>&1 &
BP=$!
sleep 0.7
for t in t1 t2 t4 t5 t7; do
  echo "######## ${t} ########"
  bash test/matrix/$t.sh 2>&1 | tail -1
done
kill $BP 2>/dev/null; sleep 0.4
echo "######## t3 舞（t3a/t3b/t6）########"
bash test/matrix/t3_dance.sh 2>&1 | grep -E '汇总|DANCE-DONE'
echo "######## t8（socks5）########"
bash test/matrix/t8.sh 2>&1 | tail -1
pkill -f '[a]gentkeeper -c test/agentkeeper.test'; pkill -f 'test/socks5.py'
echo "ALL-DONE"
