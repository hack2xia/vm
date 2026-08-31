#!/usr/bin/env zsh
# vm.zsh — VMware Fusion 虚拟机管理（headless / CLI 版）
#
# 由 ~/.zshrc 通过 `[ -f ~/.config/vm/vm.zsh ] && source ~/.config/vm/vm.zsh` 引入。
#
# 设计要点：
#   * 不提供任何短别名（kali-up 等一律不要），统一走 `vm` 命令。
#   * 每次执行前回显原始 `vmrun` 命令，防止忘记原用法。
#   * 虚拟机发现采用「手动扫描」：source 时扫一次 + `vm scan` 手动刷新。
#     `vm()` 自身不重复扫描，直接复用 VM_VMX（短名 → .vmx 绝对路径）。
#   * PATH 由本文件自管（.zshrc 里原有 vmrun PATH 导出已被删除）。

# ── 1. 保证 vmrun 可用（自管 PATH）──────────────────────────────
export PATH="$PATH:/Applications/VMware Fusion.app/Contents/Public"

# ── 2. 路径与状态 ───────────────────────────────────────────────
VM_DIR="$HOME/Virtual Machines.localized"
typeset -A VM_VMX=()

# ── 3. 手动扫描：仅 source 末尾与 `vm scan` 时调用 ───────────────
vm_scan() {
  local d name vmx
  local -a _vmx_hits
  VM_VMX=()
  for d in "$VM_DIR"/*.vmwarevm(N/); do
    name="${d:t:r}"                       # 目录名去 .vmwarevm
    vmx="$d/$name.vmx"
    if [[ ! -f "$vmx" ]]; then
      # 注意：zsh 标量赋值不会展开 glob，必须用数组接收后再取首个
      _vmx_hits=("$d"/*.vmx(N[1]))       # 同名优先，缺失则取目录内首个 .vmx
      [[ -n "${_vmx_hits[1]}" ]] && vmx="${_vmx_hits[1]}"
    fi
    [[ -n "$vmx" && -f "$vmx" ]] && VM_VMX[$name]="$vmx"
  done
}

# ── 4. 辅助：回显 + 解析 ────────────────────────────────────────
_vm_echo() { print -P "%F{cyan}➤ vmrun -T fusion $*%f"; }

_vm_resolve() {
  # $1 = 短名；命中则向 stdout 输出 .vmx 路径并返回 0，否则报错返回 1
  local name="$1" vmx="${VM_VMX[$1]}"
  if [[ -z "$vmx" ]]; then
    print -P "%F{red}✗ 未知虚拟机: $name%f" >&2
    if (( ${#VM_VMX} )); then
      print -P "%F{yellow}  可用: ${(k)VM_VMX}%f" >&2
    else
      print -P "%F{yellow}  当前未发现任何虚拟机，先执行: vm scan%f" >&2
    fi
    return 1
  fi
  echo "$vmx"
  return 0
}

# ── 5. 帮助 ────────────────────────────────────────────────────
vm_help() {
  cat <<'EOF'
vm — VMware Fusion (headless) 管理

虚拟机发现（手动扫描）:
  vm scan            重新扫描 ~/Virtual Machines.localized/*.vmwarevm
  vm vms            列出已发现的虚拟机（短名 + .vmx 路径）
  vm list           列出正在运行的虚拟机（vmrun list）

电源 / 状态:
  vm up <name>      启动（start nogui）
  vm down <name>    关机（stop soft）
  vm kill <name>    强制断电（stop hard）
  vm suspend <name> 挂起（suspend）
  vm pause <name>   暂停（pause）
  vm unpause <name> 恢复（unpause）
  vm reset <name>   复位（reset soft）

快照:
  vm snap list <name>               列出快照（listSnapshots）
  vm snap create <name> <snap>      创建快照（snapshot）
  vm snap delete <name> <snap>      删除快照（deleteSnapshot）
  vm snap revert <name> <snap>      回滚到快照（revertToSnapshot）

网络:
  vm ip <name>       获取客户机 IP（getGuestIPAddress -wait），便于 SSH

克隆:
  vm clone <src> <新名> [full|linked]   从现有 VM 克隆（完成后自动纳入管理）

帮助:
  vm help           显示本帮助
EOF
}

# ── 6. 主函数 ───────────────────────────────────────────────────
vm() {
  local cmd="$1"
  shift 2>/dev/null

  # 无参数 / help
  [[ -z "$cmd" || "$cmd" == "help" ]] && { vm_help; return 0; }

  case "$cmd" in
    up)
      local vmx; vmx=$(_vm_resolve "$1") || return 1
      _vm_echo start "$vmx" nogui
      vmrun -T fusion start "$vmx" nogui
      ;;
    down)
      local vmx; vmx=$(_vm_resolve "$1") || return 1
      _vm_echo stop "$vmx" soft
      vmrun -T fusion stop "$vmx" soft
      ;;
    kill)
      local vmx; vmx=$(_vm_resolve "$1") || return 1
      _vm_echo stop "$vmx" hard
      vmrun -T fusion stop "$vmx" hard
      ;;
    suspend)
      local vmx; vmx=$(_vm_resolve "$1") || return 1
      _vm_echo suspend "$vmx"
      vmrun -T fusion suspend "$vmx"
      ;;
    pause)
      local vmx; vmx=$(_vm_resolve "$1") || return 1
      _vm_echo pause "$vmx"
      vmrun -T fusion pause "$vmx"
      ;;
    unpause)
      local vmx; vmx=$(_vm_resolve "$1") || return 1
      _vm_echo unpause "$vmx"
      vmrun -T fusion unpause "$vmx"
      ;;
    reset)
      local vmx; vmx=$(_vm_resolve "$1") || return 1
      _vm_echo reset "$vmx" soft
      vmrun -T fusion reset "$vmx" soft
      ;;
    ip)
      local vmx; vmx=$(_vm_resolve "$1") || return 1
      _vm_echo getGuestIPAddress "$vmx" -wait
      vmrun -T fusion getGuestIPAddress "$vmx" -wait
      ;;

    snap)
      local sub="$1"; shift 2>/dev/null
      case "$sub" in
        list)
          local vmx; vmx=$(_vm_resolve "$1") || return 1
          _vm_echo listSnapshots "$vmx"
          vmrun -T fusion listSnapshots "$vmx"
          # vmrun 官方无法输出快照备注，这里额外解析同目录 .vmsd 补充显示
          local vmsd="${vmx:r}.vmsd" total i sname sdesc
          if [[ -f "$vmsd" ]]; then
            total=$(grep -E "^snapshot\.numSnapshots" "$vmsd" | grep -oE "[0-9]+")
            [[ -z "$total" ]] && total=0
            if (( total > 0 )); then
              print -P "%F{green}— 快照备注（.vmsd）—%f"
              for (( i=0; i<total; i++ )); do
                sname=$(grep -E "^snapshot$i\.displayName" "$vmsd" | sed -E 's/.*= *"(.*)"/\1/')
                sdesc=$(grep -E "^snapshot$i\.description"  "$vmsd" | sed -E 's/.*= *"(.*)"/\1/')
                print -P "  %F{cyan}${sname:-<未命名>}%f  %F{yellow}备注:%f ${sdesc:-<无>}"
              done
            fi
          else
            print -P "%F{yellow}（未找到 .vmsd，无法读取备注）%f"
          fi
          ;;
        create|delete|revert)
          local vmx; vmx=$(_vm_resolve "$1") || return 1
          local snap="$2"
          if [[ -z "$snap" ]]; then
            print -P "%F{red}✗ 用法: vm snap $sub <name> <snap>%f" >&2
            return 1
          fi
          case "$sub" in
            create) _vm_echo snapshot "$vmx" "$snap";        vmrun -T fusion snapshot "$vmx" "$snap" ;;
            delete) _vm_echo deleteSnapshot "$vmx" "$snap";  vmrun -T fusion deleteSnapshot "$vmx" "$snap" ;;
            revert) _vm_echo revertToSnapshot "$vmx" "$snap"; vmrun -T fusion revertToSnapshot "$vmx" "$snap" ;;
          esac
          ;;
        *)
          print -P "%F{red}✗ 未知快照子命令: $sub（可选 list/create/delete/revert）%f" >&2
          return 1
          ;;
      esac
      ;;

    clone)
      local src="$1" newname="$2" mode="${3:-full}"
      if [[ -z "$src" || -z "$newname" ]]; then
        print -P "%F{red}✗ 用法: vm clone <src> <新名> [full|linked]%f" >&2
        return 1
      fi
      if [[ "$mode" != "full" && "$mode" != "linked" ]]; then
        print -P "%F{red}✗ 克隆类型必须是 full 或 linked，收到: $mode%f" >&2
        return 1
      fi
      local svxm; svxm=$(_vm_resolve "$src") || return 1
      local dst="$VM_DIR/$newname.vmwarevm/$newname.vmx"
      _vm_echo clone "$svxm" "$dst" "$mode" -cloneName="$newname"
      vmrun -T fusion clone "$svxm" "$dst" "$mode" -cloneName="$newname"
      local rc=$?
      if (( rc == 0 )); then
        print -P "%F{green}✓ 克隆完成，重新扫描以纳入管理…%f"
        vm_scan
        vm vms
      fi
      return $rc
      ;;

    list)
      _vm_echo list
      vmrun -T fusion list
      ;;
    vms)
      if (( ! ${#VM_VMX} )); then
        print -P "%F{yellow}未发现任何虚拟机，执行: vm scan%f"
        return 0
      fi
      print -P "%F{green}已发现 ${#VM_VMX} 台虚拟机：%f"
      local n p
      for n in ${(k)VM_VMX}; do
        p="${VM_VMX[$n]}"
        print -P "  %F{cyan}$n%f  ->  $p"
      done
      ;;
    scan)
      vm_scan
      print -P "%F{green}✓ 扫描完成，共发现 ${#VM_VMX} 台虚拟机%f"
      ;;
    *)
      print -P "%F{red}✗ 未知子命令: $cmd%f" >&2
      vm_help
      return 1
      ;;
  esac
}

# ── 7. source 时初始化扫描一次 ─────────────────────────────────
vm_scan
