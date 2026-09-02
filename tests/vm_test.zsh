#!/bin/zsh
# vm.zsh 沙盒回归测试：用假 vmrun/ssh 隔离，不会碰真实虚拟机。
# 假 vmrun/ssh 逐参数记录 argv（contract test），而非只拼 $*：
# 这样才能断言 ssh 选项位于 destination 之前、clone 的目标路径正确等真实语义。
# 注：夹具里清单与磁盘的 .vmx 路径大小写保持一致——测试卷可能是大小写敏感的，
#     「清单大小写与磁盘不一致」的合并逻辑依赖大小写不敏感卷上的 -f 判定，
#     在敏感卷上会正确地走「路径失效保留磁盘结果」分支，无法在此仿真。
# 用法: zsh tests/vm_test.zsh   （全部通过退出 0，否则退出 1）
emulate -L zsh

VM_ZSH="${0:A:h}/../vm.zsh"
T="${0:A:h}/.sandbox.$$"
trap 'rm -rf "$T"' EXIT

# ── 夹具 ─────────────────────────────────────────────────────────
# vmlist3/vmlist4 是两台不同路径但 bundle 同名（Debian）的 VM，覆盖短名冲突。
mkdir -p "$T/vms/Kali Linux.vmwarevm" "$T/vms/WinSer2019.vmwarevm" \
         "$T/vms/50%off.vmwarevm" "$T/other/Debian.vmwarevm" \
         "$T/other2/Debian.vmwarevm" "$T/emptydir"
touch "$T/vms/Kali Linux.vmwarevm/Kali Linux.vmx" \
      "$T/vms/WinSer2019.vmwarevm/Win.vmx" \
      "$T/vms/50%off.vmwarevm/50%off.vmx" \
      "$T/other/Debian.vmwarevm/Debian.vmx" \
      "$T/other2/Debian.vmwarevm/Debian.vmx"

cat > "$T/inventory" <<INV
.encoding = "UTF-8"
vmlist1.config = "$T/vms/Kali Linux.vmwarevm/Kali Linux.vmx"
vmlist1.DisplayName = "Kali Linux 2024"
vmlist1.State = "normal"
vmlist2.config = "$T/vms/WinSer2019.vmwarevm/Win.vmx"
vmlist2.DisplayName = "Windows Server 2019"
vmlist2.State = "paused"
vmlist3.config = "$T/other/Debian.vmwarevm/Debian.vmx"
vmlist3.DisplayName = "Debian 12"
vmlist3.State = ""
vmlist4.config = "$T/other2/Debian.vmwarevm/Debian.vmx"
vmlist4.DisplayName = "Debian 12 mirror"
vmlist4.State = ""
INV

write_vmrun() {
  # 环境开关（需 export）：FAKE_IP / FAKE_IP_ERR / FAKE_SNAP_FAIL / FAKE_STOP_FAIL
  # 每次调用把完整 argv 记进 calls.log 供契约断言
  cat > "$T/vmrun" <<FAKE
#!/bin/zsh
print -r -- "vmrun \$*" >> "$T/calls.log"
sub="\$3"
case "\$sub" in
  list)
    echo "Total running VMs: 1"
    echo "$T/vms/Kali Linux.vmwarevm/Kali Linux.vmx" ;;
  checkToolsState) echo "installed" ;;
  getGuestIPAddress)
    if [[ -n "\$FAKE_IP_ERR" ]]; then
      echo "Error: The VMware Tools are not running (10.0.0.1)"; exit 1
    elif [[ -n "\$FAKE_IP" ]]; then echo "\$FAKE_IP"
    else echo "Error: The VMware Tools are not running in the virtual machine"; exit 1; fi ;;
  listSnapshots)
    if [[ -n "\$FAKE_SNAP_FAIL" ]]; then echo "Error: snapshot list failed"; exit 1; fi
    echo "Total snapshots: 2"; echo "base"; echo "after-setup" ;;
  stop)
    if [[ -n "\$FAKE_STOP_FAIL" ]]; then echo "Error: VMware Tools are not running in this VM"; exit 1; fi
    echo "fake vmrun: stop" ;;
  clone) : > "\$5"; echo "fake vmrun: clone" ;;
  *) echo "fake vmrun: \$sub" ;;
esac
FAKE
  chmod +x "$T/vmrun"
}
write_vmrun

# 假 ssh：逐参数回显 argv（argc=N |arg1 |arg2 ...），验证顺序而非仅拼接
cat > "$T/ssh" <<'FAKE'
#!/bin/zsh
print -rn -- "argc=$#"
local a
for a in "$@"; do print -rn -- " |$a"; done
print
FAKE
chmod +x "$T/ssh"

export PATH="$T:$PATH" VM_DIR="$T/vms" VM_INVENTORY="$T/inventory"
source "$VM_ZSH"

fail=0
chk() {  # chk <描述> <期望包含的子串>，被检内容在 $out
  if [[ "$out" == *"$2"* ]]; then
    print -P "  %F{green}PASS%f: $1"
  else
    print -P "  %F{red}FAIL%f: $1"; print "    期望含: $2"; print "    实际: $out"; fail=1
  fi
}
eq() {  # eq <描述> <期望值> <实际值>
  if [[ "$3" == "$2" ]]; then
    print -P "  %F{green}PASS%f: $1"
  else
    print -P "  %F{red}FAIL%f: $1"; print "    期望: $2"; print "    实际: $3"; fail=1
  fi
}
ok() {  # ok <描述>，检查紧邻上一条命令的退出码
  if (( $? == 0 )); then
    print -P "  %F{green}PASS%f: $1"
  else
    print -P "  %F{red}FAIL%f: $1"; fail=1
  fi
}

# ── 发现 ─────────────────────────────────────────────────────────
print -P "%F{cyan}== 发现 ==%f"
out="$(vm vms 2>&1)"
chk "清单+目录共发现 4 台（冲突的镜像 Debian 不计入）" "已发现 4 台"
chk "目录外 VM 纳入" "Debian"
chk "短名取磁盘大小写（Kali Linux）" "Kali Linux"
out="$(vm scan 2>&1)"   # 冲突警告只在扫描时输出
chk "短名冲突有警告，不静默合并" "短名冲突"
chk "冲突时保留排序靠前的清单条目路径" "$T/other/Debian.vmwarevm/Debian.vmx"

# ── status ───────────────────────────────────────────────────────
print -P "%F{cyan}== status ==%f"
out="$(vm status 2>&1)"
chk "运行中（vmrun 回显与清单路径匹配）" "运行中"
chk "paused 状态透出" "paused"
chk "Tools 状态列" "installed"
out="$(vm status 'KALI LINUX' 2>&1)"
chk "单台大小写不敏感" "Kali Linux 2024"
chk "显示名不被列宽截断" "Kali Linux 2024 "
out="$(vm status 'KALI LINUX' 2>/dev/null)"
chk "stdout 不含 trace" ".vmx:"

# ── ip / ssh ─────────────────────────────────────────────────────
print -P "%F{cyan}== ip / ssh ==%f"
FAKE_IP=""
out="$(vm ip 'kali linux' 2>&1)"
chk "未拿到 IP 提示" "未拿到 IP"
FAKE_IP="999.999.999.999"
export FAKE_IP
out="$(vm ip 'kali linux' 2>/dev/null)"; rc=$?
eq "octet>255 的假 IP 拒绝" "1" "$rc"
FAKE_IP="192.168.11.22"
FAKE_IP_ERR=1
export FAKE_IP_ERR
out="$(vm ip 'kali linux' 2>/dev/null)"; rc=$?
unset FAKE_IP_ERR
eq "vmrun 非零退出时输出含 IP 也不采信" "1" "$rc"
out="$(vm ip 'kali linux' 2>/dev/null)"
eq "stdout 仅 IP（可被 \$() 捕获）" "192.168.11.22" "$out"
out="$(vm ip 'kali linux' -w 2>/dev/null)"
eq "后置 -w 正常" "192.168.11.22" "$out"
grep -q "getGuestIPAddress .* -wait" "$T/calls.log"
ok "-w 透传为 vmrun -wait"

out="$(vm ssh 'kali linux' root -- -p 2222 2>/dev/null)"
eq "ssh 选项位于 destination 之前" "argc=3 |-p |2222 |root@192.168.11.22" "$out"
out="$(vm ssh 'kali linux' -- -4 2>/dev/null)"
eq "无用户名时选项同样前置" "argc=2 |-4 |192.168.11.22" "$out"
out="$(vm ssh 'kali linux' 2>/dev/null)"
eq "默认用当前用户（不拼 user@）" "argc=1 |192.168.11.22" "$out"
out="$(vm ssh 'kali linux' root ls /tmp 2>/dev/null)"
eq "不带 -- 时参数作为远程命令在 destination 之后" \
  "argc=3 |root@192.168.11.22 |ls |/tmp" "$out"
out="$(vm ssh -w 'kali linux' -- -w 2>/dev/null)"
eq "-- 后的 -w 原样透传，不被解析为等待标志" "argc=2 |-w |192.168.11.22" "$out"
grep -q "getGuestIPAddress .* -wait" "$T/calls.log"
ok "前置 -w 仍生效为等待标志"

# ── % 转义与错误路径 ─────────────────────────────────────────────
print -P "%F{cyan}== % 转义与错误路径 ==%f"
out="$(vm up 50%off 2>&1)"
chk "回显路径完整（% 不被 prompt 展开吃掉）" "50%off.vmwarevm/50%off.vmx"
out="$(vm up nope 2>&1)"; rc=$?
chk "未知 VM 列出可用列表" "可用"
chk "可用列表中 % 名字原样显示" "50%off"
eq "未知 VM rc=1" "1" "$rc"
out="$(vm bogus 2>&1)"; rc=$?
eq "未知子命令 rc=1" "1" "$rc"
out="$(vm up 2>&1)"; rc=$?
chk "缺参数给用法提示" "缺少虚拟机名"
eq "缺参数 rc=1" "1" "$rc"

# ── 快照 ─────────────────────────────────────────────────────────
print -P "%F{cyan}== 快照 ==%f"
out="$(vm snap list 'kali linux' 2>&1)"
chk "listSnapshots 输出" "after-setup"
# .vmsd 放在 .vmx 旁（${vmx:r}.vmsd = Kali Linux.vmsd）
cat > "$T/vms/Kali Linux.vmwarevm/Kali Linux.vmsd" <<'VMSD'
snapshot0.displayName = "base"
snapshot0.description = "初始状态"
snapshot1.displayName = "after-setup"
snapshot1.description = "装完 Tools"
VMSD
out="$(vm snap list 'kali linux' 2>&1)"
chk ".vmsd 备注解析" "初始状态"
chk "多条备注" "装完 Tools"
FAKE_SNAP_FAIL=1
export FAKE_SNAP_FAIL
out="$(vm snap list 'kali linux' 2>/dev/null)"; rc=$?
unset FAKE_SNAP_FAIL
eq "listSnapshots 失败 rc 透传（不被备注解析掩盖）" "1" "$rc"

# ── scan ─────────────────────────────────────────────────────────
print -P "%F{cyan}== scan ==%f"
# 加一个与目录不同名的 .vmx 才会触发「多个 .vmx」警告（同名优先命中，不警告）
touch "$T/vms/WinSer2019.vmwarevm/Other.vmx"
out="$(vm scan 2>&1)"
chk "多 vmx 警告" "多个 .vmx"
rm "$T/vms/WinSer2019.vmwarevm/Other.vmx"
out="$(vm scan 2>&1)"
chk "恢复后仍 4 台" "共发现 4 台"

# ── 失效清单路径 ─────────────────────────────────────────────────
print -P "%F{cyan}== 失效清单路径 ==%f"
# bundle 名与磁盘一致（Kali Linux）但 .vmx 不存在 → 不能覆盖磁盘扫描结果
cat > "$T/inventory" <<INV
.encoding = "UTF-8"
vmlist1.config = "$T/vms/Kali Linux.vmwarevm/GONE.vmx"
vmlist1.DisplayName = "Kali Linux 2024"
vmlist1.State = "normal"
vmlist2.config = "$T/vms/WinSer2019.vmwarevm/Win.vmx"
vmlist2.DisplayName = "Windows Server 2019"
vmlist2.State = "paused"
vmlist3.config = "$T/other/Debian.vmwarevm/Debian.vmx"
vmlist3.DisplayName = "Debian 12"
vmlist3.State = ""
INV
out="$(vm scan 2>&1)"
chk "清单路径失效有警告" "路径失效"
out="$(vm vms 2>&1)"
chk "失效后保留磁盘扫描的路径" "$T/vms/Kali Linux.vmwarevm/Kali Linux.vmx"
chk "失效后仍 4 台" "已发现 4 台"

# ── down / clone ─────────────────────────────────────────────────
print -P "%F{cyan}== down / clone ==%f"
FAKE_STOP_FAIL=1
export FAKE_STOP_FAIL
out="$(vm down 'kali linux' 2>&1)"; rc=$?
unset FAKE_STOP_FAIL
chk "soft 关机失败指引 vm kill" "可改 vm kill"
eq "down rc 透传" "1" "$rc"

# 路径穿越：newname 含 / 或 . .. 必须拒绝，且不能在 VM_DIR 外创建任何东西
out="$(vm clone 'kali linux' ../outside full 2>&1)"; rc=$?
chk "clone 拒绝 .. 穿越" "单个文件名"
eq ".. 穿越 rc=1" "1" "$rc"
[[ ! -e "$T/outside.vmwarevm" && ! -e "$T/vms/outside.vmwarevm" ]]
ok "VM_DIR 内外都未创建目录"
out="$(vm clone 'kali linux' 'a/b' full 2>&1)"; rc=$?
eq "clone 拒绝子路径 a/b" "1" "$rc"
out="$(vm clone 'kali linux' . full 2>&1)"; rc=$?
eq "clone 拒绝 ." "1" "$rc"
out="$(vm clone 'kali linux' .. full 2>&1)"; rc=$?
eq "clone 拒绝 .." "1" "$rc"
out="$(vm clone 'kali linux' $'a\nb' full 2>&1)"; rc=$?
eq "clone 拒绝含换行的名字" "1" "$rc"
out="$(vm clone 'kali linux' 'KALI LINUX' full 2>&1)"; rc=$?
chk "短名被占用时拒绝" "短名已被占用"
eq "占用短名 rc=1" "1" "$rc"
# 目标 bundle 是符号链接（指向空目录）时必须拒绝
ln -s "$T/emptydir" "$T/vms/evil.vmwarevm"
out="$(vm clone 'kali linux' evil full 2>&1)"; rc=$?
chk "目标 bundle 为符号链接时拒绝（越界检查拦截）" "目标路径越界"
eq "符号链接目标 rc=1" "1" "$rc"

out="$(vm clone 'kali linux' newvm full 2>&1)"
chk "clone 调用 vmrun" "fake vmrun: clone"
[[ -d "$T/vms/newvm.vmwarevm" ]] && { print -P "  %F{green}PASS%f: clone 前创建目标目录"; } \
  || { print -P "  %F{red}FAIL%f: clone 前创建目标目录"; fail=1; }
grep -Fq -- "$T/vms/newvm.vmwarevm/newvm.vmx full -cloneName=newvm" "$T/calls.log"
ok "clone argv 契约（目标路径 + -cloneName）"
out="$(vm clone 'kali linux' newvm full 2>&1)"; rc=$?
chk "目标已存在时拒绝" "目标已存在"
eq "目标已存在 rc=1" "1" "$rc"
out="$(vm clone 'Debian' x linked 2>&1)"; rc=$?
chk "linked 无快照时拒绝并指引" "至少有一个快照"
eq "linked 无快照 rc=1" "1" "$rc"
out="$(vm clone 'kali linux' linkedvm linked base 2>&1)"
chk "linked 指定快照时克隆成功" "linkedvm"
grep -Fq -- "linked -cloneName=linkedvm -snapshot=base" "$T/calls.log"
ok "linked clone argv 契约（-snapshot=base）"
out="$(vm clone 'kali linux' linkedvm2 linked nosuch 2>&1)"; rc=$?
chk "linked 指定不存在的快照时拒绝" "没有名为 nosuch 的快照"
eq "不存在快照 rc=1" "1" "$rc"

# ── 补全注册时序 ─────────────────────────────────────────────────
print -P "%F{cyan}== 补全注册时序 ==%f"
# 顺序一（compinit 先行）：用假 compdef 模拟 compinit 已执行，
# source 时应立刻收到 compdef _vm_comp vm 的注册调用。
# VM_DIR/VM_INVENTORY/PATH 已 export，子进程直接继承。
out="$(zsh -c 'compdef() { print -r -- "compdef $*" }; source "$0" 2>/dev/null' "$VM_ZSH")"
eq "compinit 先行时自动 compdef 注册" "compdef _vm_comp vm" "$out"
# 顺序二（compinit 后置）靠 fpath + _vm 文件，验证两条前提：
_vm_repo="${VM_ZSH:A:h}"
# 不能用 [[ ":$fpath:" == ... ]] 判断：$fpath 标量展开是空格连接，必须用 (Ie) 精确成员判断
(( ${fpath[(Ie)$_vm_repo]} ))
ok "vm.zsh 目录已加入 fpath"
[[ -f "${VM_ZSH:A:h}/_vm" ]]
ok "_vm 补全入口文件存在"

print ""
if (( fail )); then
  print -P "%F{red}HAS FAILURES%f"
  exit 1
else
  print -P "%F{green}ALL PASS%f"
fi
