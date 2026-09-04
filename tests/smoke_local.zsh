#!/bin/zsh
# 本机冒烟：用【真实 vmrun】做只读验证（不碰电源/删除/克隆），推送前跑一遍。
# 存在理由：沙盒测试全绿 ≠ 正确——假 vmrun 的输出可能与 bug 行为巧合
# （实例：doctor 台数解析 bug 中「行号 1」与「台数 1」重合，145 项测试无一报警，
#  首次真实使用即出错）。凡解析外部输出的新代码，推送前必须过这里。
# 用法: zsh tests/smoke_local.zsh   （本机无 Fusion 时打印提示并退出 0）
emulate -L zsh
fail=0
chk() {  # chk <描述> <期望包含的子串>，被检内容在 $out
  if [[ "$out" == *"$2"* ]]; then
    print -r -- "PASS: $1"
  else
    print -r -- "FAIL: $1"; print -r -- "  期望含: $2"; print -r -- "  实际: $out"; fail=1
  fi
}

VM_ZSH="${0:A:h}/../vm.zsh"
vmrun_real="/Applications/VMware Fusion.app/Contents/Public/vmrun"
if [[ ! -x "$vmrun_real" ]]; then
  print -u2 "本机未找到 Fusion vmrun，冒烟不适用，跳过（CI 沙盒测试另跑）"
  exit 0
fi

# 1. doctor：环境完整 + 运行台数与真实 vmrun list 逐字一致
realn="$("${vmrun_real}" -T fusion list | head -1)"
realn="${realn//[!0-9]/}"
out="$(zsh -c 'source "$1" >/dev/null 2>&1; vm doctor' _ "$VM_ZSH" 2>&1)"
chk "doctor 环境完整" "✓ 环境完整"
chk "doctor 台数与真实 vmrun list 一致（期望 ${realn} 台）" "当前运行 ${realn} 台"

# 2. status：真实运行状态下表格可用，无 ANSI 泄漏、无「误判全未运行」
out="$(zsh -c 'source "$1" >/dev/null 2>&1; vm status' _ "$VM_ZSH" 2>&1)"
chk "status 输出表格" "台虚拟机"
if (( realn > 0 )); then
  chk "真实环境有 VM 在运行时 status 能识别（防误判未运行）" "运行中"
fi
[[ "$out" != *$'\e['* ]] || { print -r -- "FAIL: status 输出泄漏 ANSI 转义"; fail=1; }

# 3. vms：扫描缓存与真实目录存在性抽查（只读，不触发电源操作）
out="$(zsh -c 'source "$1" >/dev/null 2>&1; vm vms' _ "$VM_ZSH" 2>&1)"
chk "vms 列表非空报错路径" "虚拟机"

(( fail )) && { print -u2 "SMOKE FAILED"; exit 1 }
print -r -- "SMOKE PASS"
