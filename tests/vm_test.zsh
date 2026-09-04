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
# 夹具创建失败立即终止：绝不退回 PATH 继续找真实 vmrun，保证不碰真实虚拟机。
die() { print -u2 -- "夹具创建失败: $1"; exit 1; }
mkdir -p "$T/vms/Kali Linux.vmwarevm" "$T/vms/WinSer2019.vmwarevm" \
         "$T/vms/50%off.vmwarevm" "$T/vms/中文虚拟机.vmwarevm" \
         "$T/other/Debian.vmwarevm" \
         "$T/other2/Debian.vmwarevm" "$T/emptydir" || die mkdir
touch "$T/vms/Kali Linux.vmwarevm/Kali Linux.vmx" \
      "$T/vms/WinSer2019.vmwarevm/Win.vmx" \
      "$T/vms/50%off.vmwarevm/50%off.vmx" \
      "$T/vms/中文虚拟机.vmwarevm/中文虚拟机.vmx" \
      "$T/other/Debian.vmwarevm/Debian.vmx" \
      "$T/other2/Debian.vmwarevm/Debian.vmx" || die touch

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
vmlist5.config = "$T/vms/中文虚拟机.vmwarevm/中文虚拟机.vmx"
vmlist5.DisplayName = "中文虚拟机 甲"
vmlist5.State = "normal"
INV

write_vmrun() {
  # 环境开关（需 export）：FAKE_IP / FAKE_IP_ERR / FAKE_SNAP_FAIL / FAKE_STOP_FAIL
  # 每次调用把 argv 逐参数记进 calls.log（| 分隔）供契约断言
  cat > "$T/vmrun" <<FAKE
#!/bin/zsh
{ print -rn -- "vmrun"; local _a; for _a in "\$@"; do print -rn -- "|\$_a"; done; print; } >> "$T/calls.log"
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
  snapshot|deleteSnapshot|revertToSnapshot)
    if [[ -n "\$FAKE_SNAP_FAIL" ]]; then echo "Error: snapshot op failed"; exit 1; fi
    echo "fake vmrun: \$sub" ;;
  stop)
    if [[ -n "\$FAKE_STOP_FAIL" ]]; then echo "Error: VMware Tools are not running in this VM"; exit 1; fi
    echo "fake vmrun: stop" ;;
  start|suspend|pause|unpause|reset) echo "fake vmrun: \$sub" ;;
  deleteVM) rm -f "\$4"; echo "fake vmrun: deleteVM" ;;
  clone)
    if [[ -n "\$FAKE_CLONE_FAIL" ]]; then echo "Error: clone failed"; exit 1; fi
    : > "\$5"; echo "fake vmrun: clone" ;;
  *) print -u2 "fake vmrun: 未实现的子命令 \$sub"; exit 1 ;;
esac
FAKE
  chmod +x "$T/vmrun"
}
write_vmrun

export PATH="$T:$PATH" VM_DIR="$T/vms" VM_INVENTORY="$T/inventory"
source "$VM_ZSH"

fail=0
chk() {  # chk <描述> <期望包含的子串>，被检内容在 $out（描述里的 % 需转义防 print -P 吃掉）
  if [[ "$out" == *"$2"* ]]; then
    _vm_p -P "  %F{green}PASS%f: ${1//\%/%%}"
  else
    _vm_p -P "  %F{red}FAIL%f: ${1//\%/%%}"; print "    期望含: $2"; print "    实际: $out"; fail=1
  fi
}
eq() {  # eq <描述> <期望值> <实际值>
  if [[ "$3" == "$2" ]]; then
    _vm_p -P "  %F{green}PASS%f: ${1//\%/%%}"
  else
    _vm_p -P "  %F{red}FAIL%f: ${1//\%/%%}"; print "    期望: $2"; print "    实际: $3"; fail=1
  fi
}
ok() {  # ok <描述>，检查紧邻上一条命令的退出码
  if (( $? == 0 )); then
    _vm_p -P "  %F{green}PASS%f: ${1//\%/%%}"
  else
    _vm_p -P "  %F{red}FAIL%f: ${1//\%/%%}"; fail=1
  fi
}

# ── 发现 ─────────────────────────────────────────────────────────
_vm_p -P "%F{cyan}== 发现 ==%f"
out="$(vm vms 2>&1)"
chk "清单+目录共发现 5 台（冲突的镜像 Debian 不计入）" "已发现 5 台"
chk "目录外 VM 纳入" "Debian"
chk "短名取磁盘大小写（Kali Linux）" "Kali Linux"
out="$(vm scan 2>&1)"   # 冲突警告只在扫描时输出
chk "短名冲突有警告，不静默合并" "短名冲突"
chk "冲突时保留排序靠前的清单条目路径" "$T/other/Debian.vmwarevm/Debian.vmx"

# CJK 显示宽：宽字符按 2 列计
eq "_vm_dispwidth 中文按 2 列" "4" "$(_vm_dispwidth '名字')"
eq "_vm_dispwidth 混排" "3" "$(_vm_dispwidth '中a')"
# vms 每行路径列起始的显示宽度必须一致（CJK 名/显示名不把列顶偏）
out="$(vm vms 2>/dev/null)"
prefws=()
same=1
for l in ${(f)out}; do
  [[ "$l" == *"$T/"* ]] || continue
  pref="${l%%$T/*}"
  prefws+=($(_vm_dispwidth "$pref"))
done
(( ${#prefws} >= 2 )) || same=0
w0="${prefws[1]}"
for w in "${prefws[@]}"; do (( w == w0 )) || same=0; done
eq "vms 各行路径列显示宽度一致（含 CJK 行）" "1" "$same"

# ── status ───────────────────────────────────────────────────────
_vm_p -P "%F{cyan}== status ==%f"
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
_vm_p -P "%F{cyan}== ip ==%f"
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
: > "$T/calls.log"
out="$(vm ip 'kali linux' -w 2>/dev/null)"
eq "后置 -w 正常" "192.168.11.22" "$out"
grep -Fq "getGuestIPAddress|$T/vms/Kali Linux.vmwarevm/Kali Linux.vmx|-wait" "$T/calls.log"
ok "-w 透传为 vmrun -wait"
out="$(vm ip -- 'kali linux' 2>/dev/null)"
eq "-- 之后名字正常解析（-- 被消费而非透传）" "192.168.11.22" "$out"

# ── % 转义与错误路径 ─────────────────────────────────────────────
_vm_p -P "%F{cyan}== %% 转义与错误路径 ==%f"
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
_vm_p -P "%F{cyan}== 快照 ==%f"
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

# create/delete/revert 的 argv 契约与错误码（Kali 不冲突、未运行，可正常调用）
: > "$T/calls.log"
out="$(vm snap create 'kali linux' mysnap 2>&1)"
grep -Fq -- "|snapshot|$T/vms/Kali Linux.vmwarevm/Kali Linux.vmx|mysnap" "$T/calls.log"
ok "snap create argv（snapshot vmx name）"
: > "$T/calls.log"
out="$(vm snap delete 'kali linux' mysnap 2>&1)"
grep -Fq -- "|deleteSnapshot|$T/vms/Kali Linux.vmwarevm/Kali Linux.vmx|mysnap" "$T/calls.log"
ok "snap delete argv（deleteSnapshot vmx name）"
: > "$T/calls.log"
out="$(vm snap revert 'kali linux' mysnap 2>&1)"
grep -Fq -- "|revertToSnapshot|$T/vms/Kali Linux.vmwarevm/Kali Linux.vmx|mysnap" "$T/calls.log"
ok "snap revert argv（revertToSnapshot vmx name）"
FAKE_SNAP_FAIL=1
export FAKE_SNAP_FAIL
out="$(vm snap delete 'kali linux' mysnap 2>&1)"; rc=$?
unset FAKE_SNAP_FAIL
eq "snap delete 失败 rc 透传" "1" "$rc"

# ── scan ─────────────────────────────────────────────────────────
_vm_p -P "%F{cyan}== scan ==%f"
# 加一个与目录不同名的 .vmx 才会触发「多个 .vmx」警告（同名优先命中，不警告）
touch "$T/vms/WinSer2019.vmwarevm/Other.vmx"
out="$(vm scan 2>&1)"
chk "多 vmx 警告" "多个 .vmx"
rm "$T/vms/WinSer2019.vmwarevm/Other.vmx"
out="$(vm scan 2>&1)"
chk "恢复后仍 5 台" "共发现 5 台"

# ── 失效清单路径 ─────────────────────────────────────────────────
_vm_p -P "%F{cyan}== 失效清单路径 ==%f"
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
chk "失效后仍 5 台" "已发现 5 台"

# ── down / clone ─────────────────────────────────────────────────
_vm_p -P "%F{cyan}== down / clone ==%f"
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

: > "$T/calls.log"
out="$(vm clone 'kali linux' newvm full 2>&1)"
chk "clone 调用 vmrun" "fake vmrun: clone"
[[ -d "$T/vms/newvm.vmwarevm" ]] && { _vm_p -P "  %F{green}PASS%f: clone 前创建目标目录"; } \
  || { _vm_p -P "  %F{red}FAIL%f: clone 前创建目标目录"; fail=1; }
grep -Fq -- "$T/vms/newvm.vmwarevm/newvm.vmx|full|-cloneName=newvm" "$T/calls.log"
ok "clone argv 契约（目标路径 + -cloneName）"
out="$(vm clone 'kali linux' newvm full 2>&1)"; rc=$?
chk "目标已存在时拒绝" "目标已存在"
eq "目标已存在 rc=1" "1" "$rc"
out="$(vm clone 'WinSer2019' x linked 2>&1)"; rc=$?
chk "linked 无快照时拒绝并指引" "至少有一个快照"
eq "linked 无快照 rc=1" "1" "$rc"
: > "$T/calls.log"
out="$(vm clone 'kali linux' linkedvm linked base 2>&1)"
chk "linked 指定快照时克隆成功" "linkedvm"
grep -Fq -- "|linked|-cloneName=linkedvm|-snapshot=base" "$T/calls.log"
ok "linked clone argv 契约（-snapshot=base）"
out="$(vm clone 'kali linux' linkedvm2 linked nosuch 2>&1)"; rc=$?
chk "linked 指定不存在的快照时拒绝" "没有名为 nosuch 的快照"
eq "不存在快照 rc=1" "1" "$rc"

# ── 回归：失败显式化 + 同名冲突保护 ─────────────────────────────
_vm_p -P "%F{cyan}== 失败显式化与同名冲突保护 ==%f"

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
_vm_p -P "%F{cyan}== vm delete 防护 ==%f"
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

# ── 回归：冲突覆盖面 / 路径身份 / 相对路径 / % 名称 ─────────────
_vm_p -P "%F{cyan}== 冲突覆盖与路径身份 =="

# 9. 冲突短名：一切状态变更命令一律拒绝（原 bug：up/suspend/pause/unpause/
#    snap create/clone 源不在保护范围内，会把操作落在无法区分的那台上）
for c in up suspend pause unpause; do
  out="$(vm $c Debian 2>&1)"; rc=$?
  eq "冲突短名拒绝 $c" "1" "$rc"
done
before=$(wc -l < "$T/calls.log")
vm up Debian >/dev/null 2>&1
after=$(wc -l < "$T/calls.log")
eq "冲突拒绝 up 时不调用 vmrun" "$before" "$after"
out="$(vm snap create Debian s1 2>&1)"; rc=$?
eq "冲突短名拒绝 snap create" "1" "$rc"
out="$(vm clone Debian newx full 2>&1)"; rc=$?
eq "冲突短名拒绝作为 clone 源" "1" "$rc"

# 10. 默认目录内大小写同名 → 冲突（需大小写敏感卷才能仿真，否则跳过）
mkdir -p "$T/casev/Foo.vmwarevm"
: > "$T/casev/Foo.vmwarevm/Foo.vmx"
if mkdir "$T/casev/foo.vmwarevm" 2>/dev/null && [[ ! "$T/casev/Foo.vmwarevm" -ef "$T/casev/foo.vmwarevm" ]]; then
  : > "$T/casev/foo.vmwarevm/foo.vmx"
  out="$(VM_DIR="$T/casev" VM_INVENTORY="$T/no-inv" zsh -c 'source "$1" 2>/dev/null; print -rn -- "${#VM_CONFLICT}"' _ "$VM_ZSH" 2>/dev/null)"
  eq "默认目录内大小写同名进入冲突状态" "1" "$out"
  out="$(VM_DIR="$T/casev" VM_INVENTORY="$T/no-inv" zsh -c 'source "$1" 2>/dev/null; vm up Foo' _ "$VM_ZSH" 2>/dev/null)"; rc=$?
  eq "大小写同名短名拒绝 up" "1" "$rc"
  rm -rf "$T/casev"
else
  _vm_p -P "  %F{yellow}SKIP: 当前卷大小写不敏感，无法仿真大小写同名%f"
fi

# 11. 路径身份：清单存符号链接路径、vmrun list 回显真实路径 → 运行判定
#     必须仍成立（原 bug：小写字符串比对误判「未运行」，delete 运行保护被绕过）
mkdir -p "$T/real/Linked.vmwarevm" "$T/linkdir" "$T/symbin"
: > "$T/real/Linked.vmwarevm/Linked.vmx"
ln -s "$T/real/Linked.vmwarevm" "$T/linkdir/Linked.vmwarevm"
cat > "$T/syminv" <<INV
vmlist1.config = "$T/linkdir/Linked.vmwarevm/Linked.vmx"
vmlist1.DisplayName = "Linked"
vmlist1.State = "normal"
INV
REAL_VMX="$T/real/Linked.vmwarevm/Linked.vmx"
export REAL_VMX
cat > "$T/symbin/vmrun" <<'FAKE'
#!/bin/zsh
case "$3" in
  list) echo "Total running VMs: 1"; echo "$REAL_VMX" ;;
  checkToolsState) echo "installed" ;;
  deleteVM) print -u2 "BUG-DELETE-RAN"; exit 42 ;;
  *) echo "fake: $3" ;;
esac
FAKE
chmod +x "$T/symbin/vmrun"
out="$(PATH="$T/symbin:$PATH" VM_DIR="$T/real" VM_INVENTORY="$T/syminv" zsh -c 'source "$1" 2>/dev/null; vm status Linked' _ "$VM_ZSH" 2>&1)"
chk "符号链接路径的运行中 VM 仍被识别为运行中" "运行中"
out="$(PATH="$T/symbin:$PATH" VM_DIR="$T/real" VM_INVENTORY="$T/syminv" zsh -c 'source "$1" 2>/dev/null; vm delete Linked --yes' _ "$VM_ZSH" 2>&1)"; rc=$?
eq "符号链接路径下运行保护拦截 delete" "1" "$rc"
[[ "$out" != *BUG-DELETE-RAN* ]]
ok "deleteVM 未被执行"

# 12. 相对 VM_DIR：source 时规范化为绝对路径，cd 后缓存不失效
mkdir -p "$T/relv/Sub/Alpha.vmwarevm"
: > "$T/relv/Sub/Alpha.vmwarevm/Alpha.vmx"
out="$(cd "$T/relv" && VM_DIR="Sub" VM_INVENTORY="$T/no-inv" zsh -c 'source "$1" 2>/dev/null; cd /; print -rn -- "${VM_VMX[Alpha]}"' _ "$VM_ZSH" 2>/dev/null)"
eq "相对 VM_DIR 规范化为绝对路径（cd 后仍有效）" "$T/relv/Sub/Alpha.vmwarevm/Alpha.vmx" "$out"

# 13. 名字含 %F{…} 等 prompt 序列：无色输出原样保留
#     （原 bug：%% 转义与颜色剥除相互作用，名字被 print -P 吃得只剩 oo）
mkdir -p "$T/pctdir/%F{red}foo.vmwarevm"
: > "$T/pctdir/%F{red}foo.vmwarevm/%F{red}foo.vmx"
out="$(VM_DIR="$T/pctdir" VM_INVENTORY="$T/no-inv" zsh -c 'source "$1" 2>/dev/null; vm vms' _ "$VM_ZSH" 2>&1)"
chk "名字含 %F{...} 时无色输出原样保留" "%F{red}foo"

# 14. clone 新名禁止 - 开头；delete 支持 -- 透传，磁盘上已有的 - 名 VM 仍可管理
out="$(vm clone 'kali linux' --foo full 2>&1)"; rc=$?
eq "clone 拒绝以 - 开头的新名" "1" "$rc"
mkdir -p "$T/vms/--weird.vmwarevm"
: > "$T/vms/--weird.vmwarevm/--weird.vmx"
vm scan >/dev/null 2>&1
out="$(vm delete -- --weird </dev/null 2>&1)"; rc=$?
eq "delete -- 透传：--weird 被视为名字并因缺 --yes 拒绝" "1" "$rc"
chk "走到 --yes 检查而非未知选项" "非交互环境请显式加 --yes"
rm -rf "$T/vms/--weird.vmwarevm"
vm scan >/dev/null 2>&1

# ── 回归：多余参数拒绝 + vmrun 缺失 + 非终端无色 ───────────────
_vm_p -P "%F{cyan}== 参数契约与颜色 ==%f"

# 6. 多余参数/拼写不再被静默忽略
out="$(vm up 'kali linux' typo 2>&1)"; rc=$?
eq "vm up 多余参数 rc=1" "1" "$rc"
chk "报参数过多" "参数过多"
out="$(vm ip 'kali linux' typo 2>&1)"; rc=$?
eq "vm ip 多余参数 rc=1" "1" "$rc"
out="$(vm status 'kali linux' typo 2>&1)"; rc=$?
eq "vm status 多余参数 rc=1" "1" "$rc"
out="$(vm snap list 'kali linux' typo 2>&1)"; rc=$?
eq "vm snap list 多余参数 rc=1" "1" "$rc"
out="$(vm snap create 'kali linux' s1 typo 2>&1)"; rc=$?
eq "vm snap create 多余参数 rc=1" "1" "$rc"
out="$(vm clone 'kali linux' x full base typo 2>&1)"; rc=$?
eq "vm clone 多余参数 rc=1" "1" "$rc"
out="$(vm vms typo 2>&1)"; rc=$?
eq "vm vms 多余参数 rc=1" "1" "$rc"
out="$(vm scan typo 2>&1)"; rc=$?
eq "vm scan 多余参数 rc=1" "1" "$rc"

# 7. vmrun 不可用（命令缺失/失败）：status 必须显式失败，不得当「全部未运行」。
#    用函数遮蔽 vmrun 模拟「找不到命令」，避免本机装了真实 Fusion 而测不到。
out="$(zsh -c 'vmrun() { print -u2 "vmrun: command not found"; return 127; }; source "$1" >/dev/null 2>&1; vm status "kali linux"' _ "$VM_ZSH" 2>&1)"; rc=$?
eq "vmrun 缺失时 status rc=127" "127" "$rc"
chk "缺失时提示查询失败" "无法查询运行状态"

# 8. 非终端（命令替换/管道）输出不含 ANSI 颜色转义
out="$(vm vms 2>&1)"
[[ "$out" != *$'\e['* ]]
ok "非终端输出不含 ANSI 颜色转义"

# 8b. vm doctor：完整环境 rc=0；vmrun 缺失时 rc=1 并显式指出问题
out="$(vm doctor 2>&1)"; rc=$?
eq "vm doctor 完整环境 rc=0" "0" "$rc"
chk "doctor 报告 vmrun 位置" "vmrun"
chk "doctor 真正探活（vmrun list）" "探活正常"
chk "doctor 提示冲突短名" "冲突短名"
out="$(zsh -c 'source "$1" >/dev/null 2>&1; PATH=/usr/bin:/bin; vm doctor' _ "$VM_ZSH" 2>&1)"; rc=$?
eq "vmrun 缺失时 doctor rc=1" "1" "$rc"
chk "doctor 指出 vmrun 不可用" "vmrun 不可用"
# 8c. doctor 的运行台数取自行内容而非行号（原 bug：(I) 下标取到表头行号 1，
#     显示的台数恒为 1；沙盒主夹具恰为 1 台测不出，用 3 台的专用探针区分）
mkdir -p "$T/countbin"
cat > "$T/countbin/vmrun" <<FAKE2
#!/bin/zsh
case "\$3" in
  list) echo "Total running VMs: 3"; echo one; echo two; echo three ;;
esac
FAKE2
chmod +x "$T/countbin/vmrun"
out="$(PATH="$T/countbin:$PATH" VM_DIR="$T/no-such-dir" VM_INVENTORY="$T/no-inv" zsh -c 'source "$1" 2>/dev/null; vm doctor' _ "$VM_ZSH" 2>&1)"
chk "doctor 运行台数解析（行内容而非行号）" "当前运行 3 台"

# ── 补全注册时序 ─────────────────────────────────────────────────
_vm_p -P "%F{cyan}== 补全注册时序 ==%f"
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

# ── 补全行为 ─────────────────────────────────────────────────
_vm_p -P "%F{cyan}== 补全行为 ==%f"
# 桩：_arguments 按 CURRENT 分流 state；_describe/_values/_alternative 记录实参；
# _wanted 透传执行内部命令；compadd 展开 -a <数组名>（动态作用域可见 _vm_comp 的局部数组）。
typeset -a _comp_out=()
_arguments()   { (( ${CURRENT:-1} == 1 )) && state=cmd || state=args }
_describe()    { _comp_out+=("describe:${(j: :)${(P@)4}}") }
_values()      { _comp_out+=("values:$*") }
_alternative() { _comp_out+=("alternative:$*") }
_wanted()      { shift 3; "$@" }
compadd() {
  local -a out=()
  while (( $# )); do
    case "$1" in
      -a) shift; out+=("${(P@)1}"); shift ;;
      --) shift; out+=("$@"); break ;;
      -*) shift ;;
      *)  out+=("$1"); shift ;;
    esac
  done
  _comp_out+=("compadd:${(j: :)out}")
}
# $1=CURRENT，其余=words（已去掉 vm 本身，words[1] 为子命令）
_vm_comp_probe() {
  local CURRENT="$1" state=""
  local -a words=("${@[2,-1]}")
  _comp_out=()
  _vm_comp
  print -rl -- "${_comp_out[@]}"
}

out="$(_vm_comp_probe 1 '')"
chk "补全子命令列表" "up:启动"
chk "补全含 delete" "delete:永久删除"
out="$(_vm_comp_probe 2 snap '')"
chk "snap 补子命令" "list[列出]"
out="$(_vm_comp_probe 3 snap create '')"
chk "snap create 第三参补 VM 名" "Kali Linux"
out="$(_vm_comp_probe 4 snap create 'Kali Linux' '')"
chk "snap create 第四参从 .vmsd 补快照名" "base"
chk "快照名含 after-setup" "after-setup"
out="$(_vm_comp_probe 4 snap list 'Kali Linux' '')"
[[ "$out" != *base* ]]
ok "snap list 第四参不补快照名"
out="$(_vm_comp_probe 2 up '')"
chk "up 第一参补 VM 名" "Kali Linux"
out="$(_vm_comp_probe 3 up 'Kali Linux' '')"
eq "up 只收一个参数，第二位不再补 VM 名" "" "$out"
out="$(_vm_comp_probe 4 clone 'Kali Linux' newvm '')"
chk "clone 第四参补 full/linked" "full[完整克隆]"
out="$(_vm_comp_probe 5 clone 'Kali Linux' newvm linked '')"
chk "clone linked 第五参补快照名" "after-setup"
out="$(_vm_comp_probe 5 clone 'Kali Linux' newvm full '')"
eq "clone full 第五参不补快照名" "" "$out"
out="$(_vm_comp_probe 2 ip '')"
chk "ip 第一参补 VM 名与 -w" "-w"
out="$(_vm_comp_probe 3 ip -w '')"
chk "ip -w 之后补 VM 名" "Kali Linux"

print ""
if (( fail )); then
  _vm_p -P "%F{red}HAS FAILURES%f"
  exit 1
else
  _vm_p -P "%F{green}ALL PASS%f"
fi
