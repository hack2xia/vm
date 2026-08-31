#!/usr/bin/env zsh
# vm.zsh — VMware Fusion 虚拟机管理（headless / CLI 版）
#
# 由 ~/.zshrc 通过 `[ -f ~/.config/vm/vm.zsh ] && source ~/.config/vm/vm.zsh` 引入。
#
# 设计要点：
#   * 不提供任何短别名（kali-up 等一律不要），统一走 `vm` 命令。
#   * 每次执行前回显原始 `vmrun` 命令，防止忘记原用法。
#     回显内容先把 `%` 转义再做 prompt 展开，保证「看到的就是执行的」。
#   * 虚拟机发现采用「手动扫描」：source 时扫一次 + `vm scan` 手动刷新。
#     主来源是 Fusion 的 vmInventory（.vmx 路径大小写正确、不受默认目录限制），
#     默认目录下的 .vmwarevm 仅作兜底（例如刚 clone 出来还没进清单的）。
#   * 默认不加 -wait：拿不到 IP 立即失败，需要等就显式加 -w。
#   * PATH 由本文件自管（.zshrc 里原有 vmrun PATH 导出已被删除）。
#
# 可用环境变量覆盖：VM_DIR（默认扫描目录）、VM_INVENTORY（清单文件路径）。

# ── 1. 保证 vmrun 可用（自管 PATH，重复 source 不追加重复项）────
_vm_fusion_bindir="/Applications/VMware Fusion.app/Contents/Public"
if [[ -d "$_vm_fusion_bindir" && ":$PATH:" != *":$_vm_fusion_bindir:"* ]]; then
  export PATH="$PATH:$_vm_fusion_bindir"
fi

# ── 2. 路径与状态 ───────────────────────────────────────────────
VM_DIR="${VM_DIR:-$HOME/Virtual Machines.localized}"
VM_INVENTORY="${VM_INVENTORY:-$HOME/Library/Application Support/VMware Fusion/vmInventory}"
typeset -A VM_VMX=()      # 短名 → .vmx 绝对路径（真实大小写）
typeset -A VM_DISPLAY=()  # 短名 → Fusion 显示名
typeset -A VM_STATE=()    # 短名 → 清单记录的状态（normal / paused …）
typeset -A VM_LC=()       # 小写短名 → 短名，供大小写不敏感解析

# ── 3. 扫描：仅 source 末尾与 `vm scan` 时调用 ──────────────────
vm_scan() {
  emulate -L zsh
  local d f name invname id line key val chosen
  local -a hits
  local -A cfg=() disp=() st=() seen=() filled=()

  VM_VMX=(); VM_DISPLAY=(); VM_STATE=(); VM_LC=()

  # 3a. 先扫默认目录：短名取磁盘上的真实目录名。
  #     清单里存的大小写未必和磁盘一致（本机 WinSer2019 就是），短名以磁盘为准，
  #     同一台机器才不会被认成两台。
  for d in "$VM_DIR"/*.vmwarevm(N/); do
    name="${d:t:r}"
    hits=("$d"/*.vmx(N))
    (( ${#hits} )) || continue
    # 优先与目录同名的 .vmx（忽略大小写），否则取字典序首个并提示
    chosen=""
    for f in $hits; do
      [[ "${f:t:r:l}" == "${name:l}" ]] && { chosen="$f"; break; }
    done
    if [[ -z "$chosen" ]]; then
      (( ${#hits} > 1 )) && \
        print -P "%F{yellow}! $name 下有多个 .vmx，取 ${hits[1]:t}%f" >&2
      chosen="${hits[1]}"
    fi
    if [[ -n "${seen[${name:l}]}" ]]; then
      print -P "%F{yellow}! 短名重复（忽略大小写）: $name，已跳过%f" >&2
      continue
    fi
    VM_VMX[$name]="$chosen"
    VM_DISPLAY[$name]="$name"
    VM_STATE[$name]=""
    seen[${name:l}]="$name"
  done

  # 3b. 再用 Fusion 清单补全：.vmx 路径以清单为准（macOS 卷大小写不敏感，两种写法
  #     等价），显示名与状态也以清单为准；status 与 vmrun list 的比对统一转小写，
  #     不受两边大小写差异影响。
  if [[ -f "$VM_INVENTORY" ]]; then
    while IFS= read -r line; do
      key="${line%% *}"
      val="${line#*= }"; val="${val#\"}"; val="${val%\"}"
      case "$key" in
        vmlist*.config)      id="${key%.config}";      cfg[$id]="$val" ;;
        vmlist*.DisplayName) id="${key%.DisplayName}"; disp[$id]="$val" ;;
        vmlist*.State)       id="${key%.State}";       st[$id]="$val" ;;
      esac
    done < "$VM_INVENTORY"
  fi

  for id in ${(k)cfg}; do
    [[ -n "${cfg[$id]}" ]] || continue          # 清单里已移除的占位条目
    invname="${cfg[$id]:h:t}"; invname="${invname%.vmwarevm}"
    [[ -n "$invname" ]] || continue
    name="${seen[${invname:l}]}"
    if [[ -z "$name" ]]; then
      name="$invname"                            # 不在默认目录里，仅清单可见
      seen[${name:l}]="$name"
    fi
    if [[ -n "${filled[$name]}" ]]; then
      print -P "%F{yellow}! 清单里 $name 有重复条目，保留首个%f" >&2
      continue
    fi
    VM_VMX[$name]="${cfg[$id]}"                  # 清单路径优先（大小写正确）
    VM_DISPLAY[$name]="${disp[$id]:-$name}"
    VM_STATE[$name]="${st[$id]}"
    filled[$name]=1
  done

  for name in ${(k)VM_VMX}; do
    VM_LC[${name:l}]="$name"
  done
}

# ── 4. 辅助 ────────────────────────────────────────────────────
# 动态内容先转义 `%` 再展开，避免路径里的 %x 被 print -P 当作 prompt 序列吃掉。
# 走 stderr：它是 trace 而不是结果，这样 `ip=$(vm ip kali)` 才能只拿到 IP。
_vm_echo() { print -rP "%F{cyan}➤ vmrun -T fusion ${${*//\%/%%}}%f" >&2; }

_vm_resolve() {
  emulate -L zsh
  # $1 = 短名；命中则向 stdout 输出 .vmx 路径并返回 0，否则报错返回 1
  local name="$1" vmx
  if [[ -z "$name" ]]; then
    print -P "%F{red}✗ 缺少虚拟机名，用法: vm <命令> <name>%f" >&2
    return 1
  fi
  vmx="${VM_VMX[$name]}"
  [[ -z "$vmx" ]] && vmx="${VM_VMX[${VM_LC[$name:l]}]}"   # 大小写不敏感兜底
  if [[ -z "$vmx" ]]; then
    print -P "%F{red}✗ 未知虚拟机: $name%f" >&2
    if (( ${#VM_VMX} )); then
      print -P "%F{yellow}  可用: ${${(k)VM_VMX}//\%/%%}%f" >&2
    else
      print -P "%F{yellow}  当前未发现任何虚拟机，先执行: vm scan%f" >&2
    fi
    return 1
  fi
  print -rn -- "$vmx"
  return 0
}

# 电源类子命令共用：回显 + 调用（vmx 由调用方给出，可无）
_vm_power() {
  local sub="$1"; shift
  _vm_echo "$sub" "$@"
  vmrun -T fusion "$sub" "$@"
}

# 取客户机 IP：$1 = vmx，$2 非空则带 -wait。
# 注意 vmrun 把报错也写进 stdout（但 rc != 0），所以只从输出里提 IPv4，
# 拿不到就把原始输出转给 stderr，别让调用方把报错当 IP 用。
_vm_ip() {
  local vmx="$1" flag="" out ip
  [[ -n "$2" ]] && flag="-wait"
  _vm_echo getGuestIPAddress "$vmx" $flag
  out="$(vmrun -T fusion getGuestIPAddress "$vmx" $flag)"
  ip="$(print -rn -- "$out" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)"
  if [[ -z "$ip" ]]; then
    [[ -n "$out" ]] && print -rP "%F{red}${${out//\%/%%}}%f" >&2
    return 1
  fi
  print -rn -- "$ip"
}

# 从参数里摘掉 -w/--wait，其余参数留在 reply 数组里，等待标志留在 _vm_waitflag
# （两者在 vm() 里已声明 local，不会泄漏到全局）
_vm_parse_wait() {
  _vm_waitflag=""
  local -a rest=()
  while (( $# )); do
    case "$1" in
      -w|--wait) _vm_waitflag=1 ;;
      *)         rest+=("$1") ;;
    esac
    shift
  done
  reply=("${(@)rest}")
}

# 快照备注：vmrun 官方拿不到 description，这里解析同目录 .vmsd 补充
_vm_snap_notes() {
  emulate -L zsh
  local vmsd="$1" i sname sdesc
  local -a idxs
  [[ -f "$vmsd" ]] || { print -P "%F{yellow}（未找到 .vmsd，无法读取备注）%f"; return 0; }

  # 快照编号在删过中间快照后可能不连续，所以直接枚举实际存在的编号
  idxs=(${${(f)"$(grep -oE '^snapshot[0-9]+\.displayName' "$vmsd")"}//[!0-9]/})
  (( ${#idxs} )) || { print -P "%F{yellow}（.vmsd 中无快照备注）%f"; return 0; }

  print -P "%F{green}— 快照备注（.vmsd）—%f"
  for i in ${(n)idxs}; do
    sname=$(grep -E "^snapshot${i}\.displayName" "$vmsd" \
            | sed -E 's/^[^=]*= *"//; s/[[:space:]]*"[[:space:]]*$//')
    sdesc=$(grep -E "^snapshot${i}\.description" "$vmsd" \
            | sed -E 's/^[^=]*= *"//; s/[[:space:]]*"[[:space:]]*$//')
    print -rP "  %F{cyan}${${sname:-<未命名>}//\%/%%}%f  %F{yellow}备注:%f ${${sdesc:-<无>}//\%/%%}"
  done
}

# 查询 VMware Tools 状态。checkToolsState 在关机/挂起状态下也能查，
# 但挂起（paused）时可能返回 unknown；输出只认白名单，避免把报错当状态。
_vm_tools() {
  local s
  s="$(vmrun -T fusion checkToolsState "$1" 2>/dev/null)"
  case "$s" in
    installed|notInstalled|running) print -rn -- "$s" ;;
    *)                              print -rn -- "unknown" ;;
  esac
}

# 状态表格的一行：$1 = 短名，$2 = 圆点（含颜色），$3 = 运行状态，$4 = Tools 状态
# $5/$6 = 名称列/显示名列的宽度（缺省 14）
_vm_status_line() {
  local n="$1" m="$2" s="$3" t="$4" nw="${5:-14}" dw="${6:-14}" a b c d
  a="${(r:nw:)${${n}//\%/%%}}"
  b="${(r:dw:)${${VM_DISPLAY[$n]}//\%/%%}}"
  c="${(r:8:)${VM_STATE[$n]:-未知}}"
  d="${(r:13:)${t:-unknown}}"
  print -rP -- "  $m %F{cyan}${a}%f ${b} ${c} ${d} $s"
}

# ── 5. 帮助 ────────────────────────────────────────────────────
vm_help() {
  cat <<'EOF'
vm — VMware Fusion (headless) 管理

虚拟机发现（手动扫描）:
  vm scan              重新扫描（Fusion 清单 + 默认目录兜底）
  vm vms               列出已发现的虚拟机（短名 + .vmx 路径）
  vm list              列出正在运行的虚拟机（vmrun list）
  vm status [name]     查看状态：清单状态 + 是否正在运行

电源:
  vm up <name>         启动（start nogui）
  vm down <name>       关机（stop soft，需 VMware Tools；失败可 vm kill）
  vm kill <name>       强制断电（stop hard，不需要 VMware Tools）
  vm suspend <name>    挂起（suspend）
  vm pause <name>      暂停（pause）
  vm unpause <name>    恢复（unpause）
  vm reset <name>      复位（reset soft，需 VMware Tools）

网络 / 登录:
  vm ip [-w] <name>             获取客户机 IP；-w = -wait 等待就绪（会阻塞）
  vm ssh [-w] <name> [user] [-- ssh参数...]
                                拿 IP 后直接 ssh（默认用当前用户名）；
                                -- 后的参数原样透传给 ssh，如: vm ssh kali root -- -p 2222
  ※ 两者都依赖 VMware Tools：不装 Tools 时立即失败；加 -w 则会一直阻塞等 Tools

快照:
  vm snap list <name>               列出快照（listSnapshots + .vmsd 备注）
  vm snap create <name> <snap>      创建快照（snapshot）
  vm snap delete <name> <snap>      删除快照（deleteSnapshot）
  vm snap revert <name> <snap>      回滚到快照（revertToSnapshot）

克隆:
  vm clone <src> <新名> [full|linked]   从现有 VM 克隆（linked 需源机有快照；完成后自动纳入管理）

帮助:
  vm help              显示本帮助
EOF
}

# ── 6. 主函数 ───────────────────────────────────────────────────
vm() {
  emulate -L zsh
  local cmd="${1:-}" reply _vm_waitflag
  shift 2>/dev/null

  [[ -z "$cmd" || "$cmd" == "help" ]] && { vm_help; return 0; }

  case "$cmd" in
    up)      local vmx; vmx=$(_vm_resolve "${1:-}") || return 1
             _vm_power start "$vmx" nogui ;;
    down)    local vmx; vmx=$(_vm_resolve "${1:-}") || return 1
             local rc
             _vm_power stop "$vmx" soft
             rc=$?
             (( rc != 0 )) && print -P "%F{yellow}! soft 关机失败：常见原因是未装/未启动 VMware Tools（vm status 可查）；确认无未保存数据后可改 vm kill $1 强制断电%f" >&2
             return $rc ;;
    kill)    local vmx; vmx=$(_vm_resolve "${1:-}") || return 1
             _vm_power stop "$vmx" hard ;;
    reset)   local vmx; vmx=$(_vm_resolve "${1:-}") || return 1
             local rc
             _vm_power reset "$vmx" soft
             rc=$?
             (( rc != 0 )) && print -P "%F{yellow}! soft 复位失败：常见原因是未装/未启动 VMware Tools（vm status 可查）%f" >&2
             return $rc ;;
    suspend) local vmx; vmx=$(_vm_resolve "${1:-}") || return 1
             _vm_power suspend "$vmx" ;;
    pause)   local vmx; vmx=$(_vm_resolve "${1:-}") || return 1
             _vm_power pause "$vmx" ;;
    unpause) local vmx; vmx=$(_vm_resolve "${1:-}") || return 1
             _vm_power unpause "$vmx" ;;

    ip)
      _vm_parse_wait "$@"
      set -- "${reply[@]}"
      local vmx; vmx=$(_vm_resolve "$1") || return 1
      local ip; ip=$(_vm_ip "$vmx" "$_vm_waitflag")
      if [[ -z "$ip" ]]; then
        print -P "%F{yellow}✗ 未拿到 IP：VM 可能未开机或 VMware Tools 未就绪；可加 -w 等待%f" >&2
        return 1
      fi
      print -rP -- "${ip//\%/%%}"     # stdout 只有 IP，可被 $( ) 捕获
      ;;

    ssh)
      _vm_parse_wait "$@"
      set -- "${reply[@]}"
      local vmx; vmx=$(_vm_resolve "${1:-}") || return 1
      local user="${2:-}" ip
      # 语法: vm ssh [-w] <name> [user] [-- ssh参数...]，-- 后的参数原样透传
      if [[ "$user" == "--" ]]; then
        user=""
        shift 2
      else
        if (( $# >= 2 )); then shift 2; else shift; fi
        [[ "${1:-}" == "--" ]] && shift
      fi
      ip=$(_vm_ip "$vmx" "$_vm_waitflag")
      if [[ -z "$ip" ]]; then
        print -P "%F{yellow}✗ 未拿到 IP：VM 可能未开机或 VMware Tools 未就绪；可加 -w 等待%f" >&2
        return 1
      fi
      local target="$ip"
      [[ -n "$user" ]] && target="$user@$ip"
      print -rP "%F{cyan}➤ ssh ${target//\%/%%}%f" >&2
      ssh "$target" "$@"
      ;;

    status)
      local name="${1:-}" vmx mark state n
      local -a running
      running=(${${(f)"$(vmrun -T fusion list 2>/dev/null)"}:#Total running VMs:*})
      # vmrun 回显路径的大小写可能与清单不一致，统一转小写再精确比对
      # （转小写必须单独一步：与 :# 过滤链在同一层嵌套里会丢失过滤）
      running=("${(@)running:l}")
      if [[ -n "$name" ]]; then
        vmx=$(_vm_resolve "$name") || return 1
        name="${VM_LC[${name:l}]:-$name}"
        if (( ${running[(Ie)${vmx:l}]} )); then
          mark="%F{green}●%f"; state="%F{green}运行中%f"
        else
          mark="%F{white}○%f"; state="未运行"
        fi
        _vm_status_line "$name" "$mark" "$state" "$(_vm_tools "$vmx")" "${#name}" "${#VM_DISPLAY[$name]}"
        print -rP "      .vmx: ${${VM_VMX[$name]}//\%/%%}"
      else
        (( ${#VM_VMX} )) || { print -P "%F{yellow}未发现任何虚拟机，执行: vm scan%f"; return 0; }
        # 列宽取最长名称，避免长名字被 (r:14:) 截断
        local -i nw=8 dw=8
        for n in ${(k)VM_VMX}; do
          (( ${#n} > nw )) && nw=${#n}
          (( ${#VM_DISPLAY[$n]} > dw )) && dw=${#VM_DISPLAY[$n]}
        done
        print -P "%F{green}共 ${#VM_VMX} 台虚拟机：%f"
        for name in ${(ok)VM_VMX}; do
          if (( ${running[(Ie)${${VM_VMX[$name]}:l}]} )); then
            mark="%F{green}●%f"; state="%F{green}运行中%f"
          else
            mark="%F{white}○%f"; state="未运行"
          fi
          _vm_status_line "$name" "$mark" "$state" "$(_vm_tools "${VM_VMX[$name]}")" "$nw" "$dw"
        done
      fi
      ;;

    snap)
      local sub="${1:-}"; shift 2>/dev/null
      case "$sub" in
        list)
          local vmx; vmx=$(_vm_resolve "${1:-}") || return 1
          _vm_echo listSnapshots "$vmx"
          vmrun -T fusion listSnapshots "$vmx"
          _vm_snap_notes "${vmx:r}.vmsd"
          ;;
        create|delete|revert)
          local vmx; vmx=$(_vm_resolve "${1:-}") || return 1
          local snap="${2:-}"
          if [[ -z "$snap" ]]; then
            print -P "%F{red}✗ 用法: vm snap $sub <name> <snap>%f" >&2
            return 1
          fi
          case "$sub" in
            create) _vm_power snapshot "$vmx" "$snap" ;;
            delete) _vm_power deleteSnapshot "$vmx" "$snap" ;;
            revert) _vm_power revertToSnapshot "$vmx" "$snap" ;;
          esac
          ;;
        *)
          print -P "%F{red}✗ 未知快照子命令: ${sub:-<空>}（可选 list/create/delete/revert）%f" >&2
          return 1
          ;;
      esac
      ;;

    clone)
      local src="${1:-}" newname="${2:-}" mode="${3:-full}"
      if [[ -z "$src" || -z "$newname" ]]; then
        print -P "%F{red}✗ 用法: vm clone <src> <新名> [full|linked]%f" >&2
        return 1
      fi
      if [[ "$mode" != "full" && "$mode" != "linked" ]]; then
        print -P "%F{red}✗ 克隆类型必须是 full 或 linked，收到: $mode%f" >&2
        return 1
      fi
      local svmx; svmx=$(_vm_resolve "$src") || return 1
      # 注意：zsh 的 local 同一语句里后面的赋值展开时前面变量还未生效，必须分行
      local dstdir="$VM_DIR/$newname.vmwarevm"
      local dst="$dstdir/$newname.vmx"
      if [[ -e "$dst" ]]; then
        print -P "%F{red}✗ 目标已存在: ${dst//\%/%%}%f" >&2
        return 1
      fi
      if [[ "$mode" == "linked" ]] && \
         ! grep -q '^snapshot[0-9]*\.displayName' "${svmx:r}.vmsd" 2>/dev/null; then
        print -P "%F{red}✗ linked 克隆要求源虚拟机至少有一个快照，先执行: vm snap create ${src//\%/%%} <snap>%f" >&2
        return 1
      fi
      mkdir -p "$dstdir" || return 1   # vmrun clone 不保证创建目标目录
      _vm_echo clone "$svmx" "$dst" "$mode" -cloneName="$newname"
      vmrun -T fusion clone "$svmx" "$dst" "$mode" -cloneName="$newname"
      local rc=$?
      if (( rc == 0 )); then
        print -P "%F{green}✓ 克隆完成，重新扫描以纳入管理…%f"
        vm_scan
        vm vms
      fi
      return $rc
      ;;

    list)
      _vm_power list
      ;;
    vms)
      (( ${#VM_VMX} )) || { print -P "%F{yellow}未发现任何虚拟机，执行: vm scan%f"; return 0; }
      local n p d
      local -i nw=8 dw=8
      for n in ${(k)VM_VMX}; do
        (( ${#n} > nw )) && nw=${#n}
        (( ${#VM_DISPLAY[$n]} > dw )) && dw=${#VM_DISPLAY[$n]}
      done
      print -P "%F{green}已发现 ${#VM_VMX} 台虚拟机：%f"
      for n in ${(ok)VM_VMX}; do
        p="${VM_VMX[$n]}"
        d="${${VM_DISPLAY[$n]}//\%/%%}"
        print -rP "  %F{cyan}${(r:nw:)${n//\%/%%}}%f ${(r:dw:)d} ${p//\%/%%}"
      done
      ;;
    scan)
      vm_scan
      print -P "%F{green}✓ 扫描完成，共发现 ${#VM_VMX} 台虚拟机%f"
      ;;
    *)
      print -P "%F{red}✗ 未知子命令: $cmd%f" >&2
      vm_help >&2
      return 1
      ;;
  esac
}

# ── 7. zsh 补全 ────────────────────────────────────────────────
_vm_comp() {
  local state
  local -a vms
  vms=(${(k)VM_VMX})

  _arguments -C '1: :->cmd' '*:: :->args'

  case "$state" in
    cmd)
      local -a cmds
      cmds=(
        'up:启动 (start nogui)'
        'down:关机 (stop soft)'
        'kill:强制断电 (stop hard)'
        'suspend:挂起'
        'pause:暂停'
        'unpause:恢复暂停'
        'reset:复位 (soft)'
        'status:查看状态'
        'ip:获取客户机 IP'
        'ssh:SSH 登录客户机'
        'snap:快照管理'
        'clone:克隆虚拟机'
        'list:列出运行中的 VM'
        'vms:列出已发现的 VM'
        'scan:重新扫描'
        'help:显示帮助'
      )
      _describe -t vm-cmds 'vm 子命令' cmds
      ;;
    args)
      case "$words[1]" in
        snap)
          if (( CURRENT == 2 )); then
            _values '快照子命令' 'list[列出]' 'create[创建]' 'delete[删除]' 'revert[回滚]'
          elif (( CURRENT == 3 )); then
            _wanted vms expl '虚拟机' compadd -a vms
          elif (( CURRENT == 4 )) && [[ ${words[2]} != list ]]; then
            # 快照名：从该 VM 的 .vmsd 补全
            local vmx snames=()
            vmx="${VM_VMX[${VM_LC[${words[3]:l}]}]}"
            if [[ -n "$vmx" ]]; then
              snames=(${(f)"$(grep -E '^snapshot[0-9]+\.displayName' "${vmx:r}.vmsd" 2>/dev/null | \
                      sed -E 's/^[^=]*= *"//; s/[[:space:]]*"[[:space:]]*$//')"})
            fi
            (( ${#snames} )) && _wanted snaps expl '快照名' compadd -a snames
          fi
          ;;
        clone)
          case $CURRENT in
            2) _wanted vms expl '源虚拟机' compadd -a vms ;;
            4) _values '克隆类型' 'full[完整克隆]' 'linked[链接克隆]' ;;
          esac
          ;;
        ip|ssh)
          case $CURRENT in
            2) _alternative 'vms:虚拟机:compadd -a vms' 'opts:选项:compadd -- -w --wait' ;;
            3) [[ ${words[2]} == -* ]] && _wanted vms expl '虚拟机' compadd -a vms ;;
          esac
          ;;
        up|down|kill|suspend|pause|unpause|reset|status)
          _wanted vms expl '虚拟机' compadd -a vms
          ;;
      esac
      ;;
  esac
}
# .zshrc 里 compinit 可能在本文件之后才执行，故先判断 compdef 是否可用
(( $+functions[compdef] )) && compdef _vm_comp vm

# ── 8. source 时初始化扫描一次 ─────────────────────────────────
vm_scan
