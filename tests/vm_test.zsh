#!/bin/zsh
# vm.zsh 沙盒回归测试：用假 vmrun/ssh 隔离，不会碰真实虚拟机。
# 用法: zsh tests/vm_test.zsh   （全部通过退出 0，否则退出 1）
emulate -L zsh

VM_ZSH="${0:A:h}/../vm.zsh"
T="${0:A:h}/.sandbox.$$"
trap 'rm -rf "$T"' EXIT

# ── 夹具 ─────────────────────────────────────────────────────────
# 清单里 Kali 的路径大小写故意与磁盘不一致，覆盖「磁盘短名 + 清单路径」组合
mkdir -p "$T/vms/Kali Linux.vmwarevm" "$T/vms/WinSer2019.vmwarevm" \
         "$T/vms/50%off.vmwarevm" "$T/other/Debian.vmwarevm"
touch "$T/vms/Kali Linux.vmwarevm/Kali Linux.vmx" \
      "$T/vms/WinSer2019.vmwarevm/Win.vmx" \
      "$T/vms/50%off.vmwarevm/50%off.vmx" \
      "$T/other/Debian.vmwarevm/Debian.vmx"

cat > "$T/inventory" <<INV
.encoding = "UTF-8"
vmlist1.config = "$T/vms/kali LINUX.vmwarevm/KALI.vmx"
vmlist1.DisplayName = "Kali Linux 2024"
vmlist1.State = "normal"
vmlist2.config = "$T/vms/WinSer2019.vmwarevm/Win.vmx"
vmlist2.DisplayName = "Windows Server 2019"
vmlist2.State = "paused"
vmlist3.config = "$T/other/Debian.vmwarevm/Debian.vmx"
vmlist3.DisplayName = "Debian 12"
vmlist3.State = ""
INV

write_vmrun() {
  cat > "$T/vmrun" <<FAKE
#!/bin/zsh
sub="\$3"
case "\$sub" in
  list)
    echo "Total running VMs: 1"
    echo "$T/vms/kali LINUX.vmwarevm/KALI.vmx" ;;
  checkToolsState) echo "installed" ;;
  getGuestIPAddress)
    if [[ -n "\$FAKE_IP" ]]; then echo "\$FAKE_IP"
    else echo "Error: The VMware Tools are not running in the virtual machine"; exit 1; fi ;;
  listSnapshots)
    echo "Total snapshots: 2"; echo "base"; echo "after-setup" ;;
  *) echo "fake vmrun: \$sub" ;;
esac
FAKE
  chmod +x "$T/vmrun"
}
write_vmrun

# 假 ssh：回显收到的参数，验证透传
cat > "$T/ssh" <<'FAKE'
#!/bin/zsh
echo "fake ssh: $*"
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

# ── 发现 ─────────────────────────────────────────────────────────
print -P "%F{cyan}== 发现 ==%f"
out="$(vm vms 2>&1)"
chk "清单+目录共发现 4 台" "已发现 4 台"
chk "目录外 VM 纳入" "Debian"
chk "短名取磁盘大小写（Kali Linux）" "Kali Linux"

# ── status ───────────────────────────────────────────────────────
print -P "%F{cyan}== status ==%f"
out="$(vm status 2>&1)"
chk "运行中（vmrun 回显大小写与清单不一致也能匹配）" "运行中"
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
FAKE_IP="192.168.11.22"
export FAKE_IP
out="$(vm ip 'kali linux' 2>/dev/null)"
eq "stdout 仅 IP（可被 \$() 捕获）" "192.168.11.22" "$out"
out="$(vm ip 'kali linux' -w 2>/dev/null)"
eq "后置 -w 正常" "192.168.11.22" "$out"
out="$(vm ssh 'kali linux' root -- -p 2222 2>/dev/null)"
chk "ssh 用户名 + 透传参数" "root@192.168.11.22 -p 2222"
out="$(vm ssh 'kali linux' -- -4 2>/dev/null)"
chk "无用户名直接透传" "fake ssh: 192.168.11.22 -4"
out="$(vm ssh 'kali linux' 2>/dev/null)"
eq "默认用当前用户（不拼 user@）" "fake ssh: 192.168.11.22" "$out"

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
# .vmsd 放在清单解析出的路径旁（${vmx:r}.vmsd = KALI.vmsd）
cat > "$T/vms/Kali Linux.vmwarevm/KALI.vmsd" <<'VMSD'
snapshot0.displayName = "base"
snapshot0.description = "初始状态"
snapshot1.displayName = "after-setup"
snapshot1.description = "装完 Tools"
VMSD
out="$(vm snap list 'kali linux' 2>&1)"
chk ".vmsd 备注解析" "初始状态"
chk "多条备注" "装完 Tools"

# ── scan ─────────────────────────────────────────────────────────
print -P "%F{cyan}== scan ==%f"
# 加一个与目录不同名的 .vmx 才会触发「多个 .vmx」警告（同名优先命中，不警告）
touch "$T/vms/WinSer2019.vmwarevm/Other.vmx"
out="$(vm scan 2>&1)"
chk "多 vmx 警告" "多个 .vmx"
rm "$T/vms/WinSer2019.vmwarevm/Other.vmx"
out="$(vm scan 2>&1)"
chk "恢复后仍 4 台" "共发现 4 台"

# ── down / clone ─────────────────────────────────────────────────
print -P "%F{cyan}== down / clone ==%f"
cat > "$T/vmrun" <<'FAKE'
#!/bin/zsh
if [[ "$3" == "stop" ]]; then echo "Error: VMware Tools are not running in this VM"; exit 1; fi
if [[ "$3" == "clone" ]]; then : > "$5"; echo "fake vmrun: clone"; exit 0; fi
echo "fake vmrun: $3"
FAKE
chmod +x "$T/vmrun"
out="$(vm down 'kali linux' 2>&1)"; rc=$?
chk "soft 关机失败指引 vm kill" "可改 vm kill"
eq "down rc 透传" "1" "$rc"

out="$(vm clone 'kali linux' newvm full 2>&1)"
chk "clone 调用 vmrun" "fake vmrun: clone"
[[ -d "$T/vms/newvm.vmwarevm" ]] && { print -P "  %F{green}PASS%f: clone 前创建目标目录"; } \
  || { print -P "  %F{red}FAIL%f: clone 前创建目标目录"; fail=1; }
out="$(vm clone 'kali linux' newvm full 2>&1)"; rc=$?
chk "目标已存在时拒绝" "目标已存在"
eq "目标已存在 rc=1" "1" "$rc"
out="$(vm clone 'Debian' x linked 2>&1)"; rc=$?
chk "linked 无快照时拒绝并指引" "至少有一个快照"
eq "linked 无快照 rc=1" "1" "$rc"

print ""
if (( fail )); then
  print -P "%F{red}HAS FAILURES%f"
  exit 1
else
  print -P "%F{green}ALL PASS%f"
fi
