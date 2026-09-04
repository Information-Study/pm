#!/usr/bin/env bash
cd ~/pm
export PATH="$HOME/.local/bin:$PATH"
export ANSIBLE_DEPRECATION_WARNINGS=False
# 真的執行（不是 --check）。目標是拋棄式容器，安全。
./cx --ui plain --yes deploy apply staging > /tmp/deployapply.log 2>&1
echo "exit=$?"
echo "--- PLAY RECAP ---"
grep -A5 'PLAY RECAP' /tmp/deployapply.log | tail -6
echo "--- 失敗的 task ---"
grep -B2 -A12 'fatal:\|FAILED!' /tmp/deployapply.log | head -60
