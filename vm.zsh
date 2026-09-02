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
  #     按 id 排序遍历，保证「保留首个」的结果稳定可复现。
  local invpath
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

  for id in ${(ok)cfg}; do
    [[ -n "${cfg[$id]}" ]] || continue          # 清单里已移除的占位条目
    invpath="${cfg[$id]}"
    invname="${invpath:h:t}"; invname="${invname%.vmwarevm}"
    [[ -n "$invname" ]] || continue
    name="${seen[${invname:l}]}"
    if [[ -z "$name" ]]; then
      name="$invname"                            # 不在默认目录里，仅清单可见
      seen[${name:l}]="$name"
    elif [[ -n "${filled[$name]}" ]]; then
      # 同名条目已处理过：路径相同算重复；路径不同是两台不同的 VM，
      # 仅靠短名无法区分，保留首个并警告，不静默合并
      if [[ "${VM_VMX[$name]:A}" == "${invpath:A}" ]]; then
        print -P "%F{yellow}! 清单里 $name 有重复条目，保留首个%f" >&2
      else
        print -P "%F{yellow}! 短名冲突: $name 同时对应 ${VM_VMX[$name]} 和 ${invpath}，仅保留前者%f" >&2
      fi
      continue
    elif [[ ! -f "$invpath" ]]; then
      # 磁盘扫描已找到同名 VM，而清单路径已失效：保留磁盘结果
      print -P "%F{yellow}! 清单里 $name 的路径失效，保留磁盘扫描的: ${VM_VMX[$name]}%f" >&2
      continue
    fi
    VM_VMX[$name]="$invpath"                     # 清单路径优先（大小写正确）
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
# 注意 vmrun 把报错也写进 stdout（但 rc != 0），所以先要求 rc == 0，
# 再从输出里提 IPv4 且四段 octet 都 ≤255，避免把错误文本里的数字串当 IP；
# 拿不到就把原始输出转给 stderr，别让调用方把报错当 IP 用。
_vm_ip() {
  local vmx="$1" flag="" out ip rc o
  [[ -n "$2" ]] && flag="-wait"
  _vm_echo getGuestIPAddress "$vmx" $flag
  out="$(vmrun -T fusion getGuestIPAddress "$vmx" $flag)"
  rc=$?
  if (( rc == 0 )); then
    ip="$(print -rn -- "$out" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)"
    for o in ${(s:.:)ip}; do
      (( 10#$o <= 255 )) || { ip=""; break }
    done
  fi
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
      --)        rest+=("$@"); break ;;   # -- 之后是透传参数（如 ssh 选项），不再解析
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

# 从 .vmsd 提取快照名（解析规则与 _vm_snap_notes 一致），一行一个
_vm_snap_names() {
  [[ -f "$1" ]] || return 0
  grep -E '^snapshot[0-9]+\.displayName' "$1" 2>/dev/null | \
    sed -E 's/^[^=]*= *"//; s/[[:space:]]*"[[:space:]]*$//'
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
  vm ssh [-w] <name> [user] [-- ssh选项...] [远程命令...]
                                拿 IP 后直接 ssh（默认用当前用户名）；
                                -- 后的参数作为 ssh 选项放在目标地址之前，
                                如: vm ssh kali root -- -p 2222
                                不带 -- 时其余参数作为远程命令执行
  ※ 两者都依赖 VMware Tools：不装 Tools 时立即失败；加 -w 则会一直阻塞等 Tools

快照:
  vm snap list <name>               列出快照（listSnapshots + .vmsd 备注）
  vm snap create <name> <snap>      创建快照（snapshot）
  vm snap delete <name> <snap>      删除快照（deleteSnapshot）
  vm snap revert <name> <snap>      回滚到快照（revertToSnapshot）

克隆:
  vm clone <src> <新名> [full|linked] [snapshot]
                                克隆（linked 需源机有快照；指定 snapshot 时基于该
                                快照克隆，缺省用 vmrun 默认行为；完成后自动纳入管理）

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
      shift
      local user="" ip
      local -a pre=() post=()
      if (( $# )) && [[ "$1" != "--" ]]; then
        user="$1"; shift
      fi
      if (( $# )) && [[ "$1" == "--" ]]; then
        shift
        pre=("$@")     # -- 后全是 ssh 选项：OpenSSH 要求选项在 destination 之前
      else
        post=("$@")    # 不带 --：其余参数作为远程命令，放 destination 之后
      fi
      ip=$(_vm_ip "$vmx" "$_vm_waitflag")
      if [[ -z "$ip" ]]; then
        print -P "%F{yellow}✗ 未拿到 IP：VM 可能未开机或 VMware Tools 未就绪；可加 -w 等待%f" >&2
        return 1
      fi
      local target="$ip"
      [[ -n "$user" ]] && target="$user@$ip"
      print -rP "%F{cyan}➤ ssh ${target//\%/%%}%f" >&2
      ssh "${(@)pre}" "$target" "${(@)post}"
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
          local vmx rc; vmx=$(_vm_resolve "${1:-}") || return 1
          _vm_echo listSnapshots "$vmx"
          vmrun -T fusion listSnapshots "$vmx"
          rc=$?
          _vm_snap_notes "${vmx:r}.vmsd"
          return $rc   # listSnapshots 失败不能被 .vmsd 备注解析掩盖
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
      local src="${1:-}" newname="${2:-}" mode="${3:-full}" snapname="${4:-}"
      if [[ -z "$src" || -z "$newname" ]]; then
        print -P "%F{red}✗ 用法: vm clone <src> <新名> [full|linked] [snapshot]%f" >&2
        return 1
      fi
      if [[ "$mode" != "full" && "$mode" != "linked" ]]; then
        print -P "%F{red}✗ 克隆类型必须是 full 或 linked，收到: $mode%f" >&2
        return 1
      fi
      # 新名必须是单个安全文件名：拒绝 / 、. 、.. 和控制字符，
      # 否则目标路径会逃逸出 VM_DIR（路径穿越）
      if [[ "$newname" == */* || "$newname" == . || "$newname" == .. || \
            "$newname" == *[[:cntrl:]]* ]]; then
        print -P "%F{red}✗ 新名必须是单个文件名（不含 / 和控制字符，不能是 . 或 ..）: ${newname//\%/%%}%f" >&2
        return 1
      fi
      local svmx; svmx=$(_vm_resolve "$src") || return 1
      # 短名被占用会导致克隆后两台 VM 无法区分，直接拒绝
      if [[ -n "${VM_LC[${newname:l}]}" ]]; then
        print -P "%F{red}✗ 短名已被占用: ${newname//\%/%%}（vm vms 查看）%f" >&2
        return 1
      fi
      # 注意：zsh 的 local 同一语句里后面的赋值展开时前面变量还未生效，必须分行
      local dstdir="$VM_DIR/$newname.vmwarevm"
      local dst="$dstdir/$newname.vmx"
      # 双重越界保险：VM_DIR 内有符号链接时，规范化后目标必须仍在 VM_DIR 里
      local realdir="${${VM_DIR%/}:A}" realdst="${dstdir:A}"
      if [[ "$realdst" != "$realdir"/* ]]; then
        print -P "%F{red}✗ 目标路径越界: ${dstdir//\%/%%}%f" >&2
        return 1
      fi
      # 拒绝整个目标 bundle（目录或符号链接），而不只是 .vmx
      if [[ -e "$dstdir" || -L "$dstdir" ]]; then
        print -P "%F{red}✗ 目标已存在: ${dstdir//\%/%%}%f" >&2
        return 1
      fi
      local -a cloneargs=("$svmx" "$dst" "$mode" -cloneName="$newname")
      if [[ "$mode" == "linked" ]]; then
        if [[ -n "$snapname" ]]; then
          local -a snames
          snames=("${(@f)$(_vm_snap_names "${svmx:r}.vmsd")}")
          if [[ -z "${snames[(re)$snapname]}" ]]; then
            print -P "%F{red}✗ 源虚拟机没有名为 ${snapname//\%/%%} 的快照，先执行: vm snap list ${src//\%/%%}%f" >&2
            return 1
          fi
          cloneargs+=(-snapshot="$snapname")
        elif ! grep -q '^snapshot[0-9]*\.displayName' "${svmx:r}.vmsd" 2>/dev/null; then
          print -P "%F{red}✗ linked 克隆要求源虚拟机至少有一个快照，先执行: vm snap create ${src//\%/%%} <snap>%f" >&2
          return 1
        fi
        # 不指定快照名时不传 -snapshot，交由 vmrun 默认行为
      fi
      mkdir -p "$dstdir" || return 1   # vmrun clone 不保证创建目标目录
      _vm_echo clone "${(@)cloneargs}"
      vmrun -T fusion clone "${(@)cloneargs}"
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
            5)
              # linked 克隆可指定基于哪个快照
              local vmx snames=()
              vmx="${VM_VMX[${VM_LC[${words[2]:l}]}]}"
              if [[ -n "$vmx" ]]; then
                snames=("${(@f)$(_vm_snap_names "${vmx:r}.vmsd")}")
              fi
              (( ${#snames} )) && _wanted snaps expl '快照名' compadd -a snames
              ;;
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
# 补全注册双保险，覆盖两种 compinit 时序：
#   1) compinit 已在本文件之前执行 → compdef 可用，直接注册；
#   2) compinit 尚未执行 → 把本文件所在目录加入 fpath，目录里的 _vm 文件
#      带 #compdef 头，之后 compinit 扫描 fpath 时自动注册。
_vm_compfile="${(%):-%x}"        # 本文件路径（source 场景下由 %x 取得）
_vm_compdir="${_vm_compfile:A:h}" # 规范化（消解 .. 与符号链接）后取目录
# 注意不能用 [[ ":$fpath:" == ... ]] 判断：$fpath 标量展开是空格连接，冒号比对必失效
(( $+functions[compdef] )) && compdef _vm_comp vm
(( ${fpath[(Ie)$_vm_compdir]} )) || fpath=("$_vm_compdir" "$fpath[@]")

# ── 8. source 时初始化扫描一次 ─────────────────────────────────
vm_scan
