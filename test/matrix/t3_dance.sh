#!/bin/bash
# 一次性：T3a(all) / T3b(patterns) / T6 的模式切换与回归
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 1
chmod 600 test/ticket_test test/out_test test/host_ed25519_test test/wrongkey 2>/dev/null
C="test/agentkeeper.test.yaml"
pkill -f '[a]gentkeeper -c test/agentkeeper.test'; sleep 0.5
sed -i 's/mode: "off"/mode: "all"/' $C
./agentkeeper -c $C >>/tmp/agentkeeper.log 2>&1 &
BP=$!; sleep 0.8
echo "######## T3a (mode=all) ########"; bash test/matrix/t3a.sh 2>&1 | tail -16
kill $BP 2>/dev/null; sleep 0.4
sed -i 's/mode: "all"/mode: "patterns"/' $C
./agentkeeper -c $C >>/tmp/agentkeeper.log 2>&1 &
BP=$!; sleep 0.8
echo "######## T3b (mode=patterns) ########"; bash test/matrix/t3b.sh 2>&1 | tail -9
kill $BP 2>/dev/null; sleep 0.4
sed -i 's/mode: "patterns"/mode: "off"/' $C
./agentkeeper -c $C >>/tmp/agentkeeper.log 2>&1 &
BP=$!; sleep 0.8
echo "######## T6 (mode=off) ########"; bash test/matrix/t6.sh 2>&1 | tail -15
kill $BP 2>/dev/null; sleep 0.4
sed -i 's/mode: "all"/mode: "off"/; s/mode: "patterns"/mode: "off"/' $C
grep -E 'mode:|patterns:' $C | head -2
echo "DANCE-DONE"
