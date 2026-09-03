#!/bin/zsh
# vm.zsh 沙盒回归测试：用假 vmrun 隔离，不会碰真实虚拟机。
# 假 vmrun 每次调用把参数记进 calls.log 供契约断言（clone 目标路径、-cloneName 等）。
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
    if [[ -n "\$FAKE_LIST_FAIL" ]]; then echo "Error: unable to connect to the VMware server"; exit 1; fi
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
  deleteVM) rm -f "\$4"; echo "fake vmrun: deleteVM" ;;
  clone)
    if [[ -n "\$FAKE_CLONE_FAIL" ]]; then echo "Error: clone failed"; exit 1; fi
    : > "\$5"; echo "fake vmrun: clone" ;;
  *) echo "fake vmrun: \$sub" ;;
esac
FAKE
  chmod +x "$T/vmrun"
}
write_vmrun

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

# ── ip ─────────────────────────────────────────────────────────
print -P "%F{cyan}== ip ==%f"
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
out="$(vm ssh 'kali linux' root ls /tmp 2>&1)"; rc=$?
chk "ssh 子命令已移除，报未知子命令" "未知子命令"
eq "ssh 移除后 rc=1" "1" "$rc"
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

# ── 回归：失败显式化 + 同名冲突保护 ─────────────────────────────
print -P "%F{cyan}== 失败显式化与同名冲突保护 ==%f"

# 1. vmrun list 失败：status 必须报错，不能把全部 VM 标成「未运行」
FAKE_LIST_FAIL=1
export FAKE_LIST_FAIL
out="$(vm status 'kali linux' 2>&1)"; rc=$?
unset FAKE_LIST_FAIL
eq "vmrun list 失败时 status rc=1" "1" "$rc"
chk "显示查询失败而非未运行" "无法查询运行状态"

# 2. inventory-only 的失效路径不得进入管理列表
#    （注意：vm_scan 会改 VM_VMX/VM_CONFLICT 等全局数组，必须在主 shell 里跑——
#     包在 $() 里只改子 shell 副本，后续断言读不到。这里先跑 scan 再断言）
cat > "$T/inventory" <<INV
.encoding = "UTF-8"
vmlist1.config = "$T/ghost/Phantom.vmwarevm/Phantom.vmx"
vmlist1.DisplayName = "Phantom"
vmlist1.State = "normal"
INV
vm scan >"$T/scan.out" 2>"$T/scan.err"
out="$(<$T/scan.err)"
chk "inventory-only 失效路径也有警告" "路径失效"
out="$(vm vms 2>&1)"
[[ "$out" != *Phantom* ]]
ok "失效清单条目不进入管理列表"

# 3. 磁盘扫描与清单「首条」同名但不同物理文件：冲突警告 + 保留磁盘路径
#    （原 bug：磁盘结果被清单首条静默覆盖，破坏性命令可能操作错 VM）
mkdir -p "$T/vms/Debian.vmwarevm"
touch "$T/vms/Debian.vmwarevm/Debian.vmx"
cat > "$T/inventory" <<INV
.encoding = "UTF-8"
vmlist1.config = "$T/other2/Debian.vmwarevm/Debian.vmx"
vmlist1.DisplayName = "Debian mirror"
vmlist1.State = "normal"
INV
vm scan >"$T/scan.out" 2>"$T/scan.err"
out="$(<$T/scan.err)"
chk "磁盘 vs 清单首条同名触发冲突警告" "短名冲突"
out="$(vm vms 2>&1)"
chk "保留磁盘扫描的路径，不再静默覆盖" "$T/vms/Debian.vmwarevm/Debian.vmx"
out="$(vm kill Debian 2>&1)"; rc=$?
eq "冲突短名拒绝 kill" "1" "$rc"
chk "kill 拒绝有提示" "拒绝执行"
out="$(vm snap delete Debian base 2>&1)"; rc=$?
eq "冲突短名拒绝 snap delete" "1" "$rc"
before=$(wc -l < "$T/calls.log")
vm kill Debian >/dev/null 2>&1
after=$(wc -l < "$T/calls.log")
eq "冲突拒绝时不调用 vmrun" "$before" "$after"

# 4. clone：full+snapshot 显式拒绝；失败清理本次创建的目录、可立即重试
out="$(vm clone 'kali linux' fullsnap full base 2>&1)"; rc=$?
eq "full 克隆指定 snapshot 被拒绝" "1" "$rc"
chk "full+snapshot 拒绝提示" "不支持指定 snapshot"
FAKE_CLONE_FAIL=1
export FAKE_CLONE_FAIL
out="$(vm clone 'kali linux' retryvm full 2>&1)"; rc=$?
unset FAKE_CLONE_FAIL
eq "clone 失败 rc=1" "1" "$rc"
[[ ! -e "$T/vms/retryvm.vmwarevm" ]]
ok "clone 失败后清理目标目录"
out="$(vm clone 'kali linux' retryvm full 2>&1)"
chk "清理后可立即重试成功" "克隆完成"

# 5. vm delete：运行中/冲突/路径失效/非交互无 --yes 均拒绝；--yes 删除成功并重扫消失
print -P "%F{cyan}== vm delete 防护 ==%f"
# 5.1 运行中的 VM（fake vmrun list 恒报 Kali 在运行）
out="$(vm delete 'kali linux' --yes 2>&1)"; rc=$?
eq "运行中 VM 拒绝删除" "1" "$rc"
chk "提示正在运行" "正在运行"
# 5.2 冲突短名拒绝（磁盘 Debian vs 清单 other2 Debian）
out="$(vm delete Debian --yes 2>&1)"; rc=$?
eq "冲突短名拒绝 delete" "1" "$rc"
chk "提示拒绝执行" "拒绝执行"
# 5.3 扫描缓存里的路径已失效（人为塞一个 ghost 条目）
VM_VMX[ghost]="$T/ghost/Gone.vmwarevm/Gone.vmx"
VM_LC[ghost]=ghost
VM_DISPLAY[ghost]="Ghost"
out="$(vm delete ghost --yes 2>&1)"; rc=$?
eq "路径失效 VM 拒绝删除" "1" "$rc"
chk "提示路径已不存在" "已不存在"
# 5.4 非交互且未加 --yes：拒绝（stdin 指向 /dev/null，不触发交互读取）
out="$(vm delete 50%off </dev/null 2>&1)"; rc=$?
eq "非交互无 --yes 拒绝删除" "1" "$rc"
chk "提示加 --yes" "--yes"
# 5.5 --yes 成功删除（fake deleteVM 删掉 .vmx），重扫后 VM 消失
out="$(vm delete 50%off --yes 2>&1)"; rc=$?
eq "正常 VM --yes 删除 rc=0" "0" "$rc"
chk "删除成功提示" "已删除 50%off"
vm scan >/dev/null 2>&1
out="$(vm vms 2>&1)"
[[ "$out" != *50%off* ]]
ok "删除后重新扫描，VM 已不在列表"

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
