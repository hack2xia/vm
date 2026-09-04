#!/usr/bin/env zsh
# vm.zsh — VMware Fusion 虚拟机管理（headless / CLI 版）
#
# 由 ~/.zshrc 通过 `[ -f ~/.config/vm/vm.zsh ] && source ~/.config/vm/vm.zsh` 引入。
#
# 定位：轻量级「VM 生命周期管理」工具——发现/状态、电源、IP、快照（含备注）、
#       克隆与删除；不是 vmrun 的全功能封装，也不追求对 vmrun 的覆盖率。
# 明确不做：ssh 包装、客户机内命令执行/文件操作（仅保留 IP 与 Tools 状态等
#       只读查询）、网络适配器与主机虚拟网络配置——这些交给原生工具更稳妥。
# 安全性优先：同名冲突的短名拒绝一切状态变更命令；vm delete 需显式确认，
# 且运行判定按文件身份（设备+inode）而非路径字符串，路径别名不致误判。
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
# 环境变量覆盖时可能是相对路径：扫描会把该形态直接写进缓存，cd 之后失效。
# source 时统一规范化为绝对路径（:A 消解 .. 与符号链接，容忍目录尚不存在）。
VM_DIR="${VM_DIR:A}"
VM_INVENTORY="${VM_INVENTORY:A}"

# 颜色策略（在 _vm_p() 里按每次调用的实际 stdout 判定，而非 source 时定死）：
# 设了 NO_COLOR，或 stdout 不是终端（管道/重定向/命令替换）时剥离 %F{…}/%f。

typeset -A VM_VMX=()      # 短名 → .vmx 绝对路径（真实大小写）
typeset -A VM_DISPLAY=()  # 短名 → Fusion 显示名
typeset -A VM_STATE=()    # 短名 → 清单记录的状态（normal / paused …）
typeset -A VM_LC=()       # 小写短名 → 短名，供大小写不敏感解析
typeset -A VM_CONFLICT=() # 短名 → 1：同名但路径不同的多台 VM 无法区分，破坏性命令拒绝

# ── 3. 扫描：仅 source 末尾与 `vm scan` 时调用 ──────────────────
vm_scan() {
  emulate -L zsh
  local d f name invname id line key val chosen
  local -a hits
  local -A cfg=() disp=() st=() seen=() src=()

  VM_VMX=(); VM_DISPLAY=(); VM_STATE=(); VM_LC=(); VM_CONFLICT=()

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
        _vm_p -P "%F{yellow}! $name 下有多个 .vmx，取 ${${hits[1]:t}//\%/%%}%f" >&2
      chosen="${hits[1]}"
    fi
    if [[ -n "${seen[${name:l}]}" ]]; then
      # 两个不同物理文件映射到同一大小写不敏感短名（大小写敏感卷上才会出现）：
      # 与「磁盘 vs 清单」同名同性质，必须进入冲突状态，不能只跳过了事
      _vm_p -P "%F{yellow}! 短名重复（忽略大小写）: ${name//\%/%%}，仅保留 ${${seen[${name:l}]}//\%/%%}，该短名的状态变更命令将被拒绝%f" >&2
      VM_CONFLICT[${seen[${name:l}]}]=1
      continue
    fi
    VM_VMX[$name]="$chosen"
    VM_DISPLAY[$name]="$name"
    VM_STATE[$name]=""
    seen[${name:l}]="$name"
    src[$name]=disk
  done

  # 3b. 再用 Fusion 清单补全。每条记录先统一验证路径，再做名称合并：
  #     同一物理文件（清单与磁盘大小写/符号链接不同）→ 用清单路径刷新显示名与状态；
  #     不同物理文件但短名相同 → 冲突，保留先出现的并记入 VM_CONFLICT（供破坏性命令拒绝）。
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
    # 统一先验证清单路径：绝对路径、.vmx 后缀、文件存在且可读。
    # 失效条目（含 inventory-only 的陈旧路径）一律跳过并警告，不进管理列表。
    if [[ "$invpath" != /* || "$invpath" != *.vmx || ! -f "$invpath" || ! -r "$invpath" ]]; then
      _vm_p -P "%F{yellow}! 清单里 $invname 的路径失效，跳过: ${${invpath//\%/%%}}%f" >&2
      continue
    fi
    name="${seen[${invname:l}]}"
    if [[ -z "$name" ]]; then
      name="$invname"                            # 不在默认目录里，仅清单可见
      VM_VMX[$name]="$invpath"
      VM_DISPLAY[$name]="${disp[$id]:-$name}"
      VM_STATE[$name]="${st[$id]}"
      seen[${name:l}]="$name"
      src[$name]=inv
      continue
    fi
    # 同名已存在：按文件身份（设备+inode，跟随符号链接）判断是否同一台，
    # 而不是比较路径字符串——同一文件在清单与磁盘上可能大小写/软链不同。
    if _vm_same_file "${VM_VMX[$name]}" "$invpath"; then
      if [[ "${src[$name]}" == inv ]]; then
        _vm_p -P "%F{yellow}! 清单里 ${name//\%/%%} 有重复条目，保留首个%f" >&2
        continue
      fi
      # 磁盘先发现、清单是同一台：用清单路径刷新（大小写正确），并带上清单的显示名/状态
      VM_VMX[$name]="$invpath"
      VM_DISPLAY[$name]="${disp[$id]:-$name}"
      VM_STATE[$name]="${st[$id]}"
      src[$name]=inv
    else
      # 同名但物理上是两台不同的 VM：仅靠短名无法区分 → 冲突
      _vm_p -P "%F{yellow}! 短名冲突: $name 同时对应 ${${VM_VMX[$name]}//\%/%%} 和 ${${invpath}//\%/%%}，仅保留前者；该短名的破坏性命令将被拒绝%f" >&2
      VM_CONFLICT[$name]=1
    fi
  done

  for name in ${(k)VM_VMX}; do
    VM_LC[${name:l}]="$name"
  done
}

# 两个路径是否指向同一物理文件（比较设备号+inode，跟随符号链接）。
# 判断依据必须是文件身份而非路径字符串：同一台 VM 的 .vmx 在
# 清单与磁盘上可能因大小写、符号链接而呈现不同路径。
_vm_same_file() {
  emulate -L zsh
  local a="$1" b="$2" ai bi
  ai="$(/usr/bin/stat -L -f '%d:%i' "$a" 2>/dev/null)" || return 1
  bi="$(/usr/bin/stat -L -f '%d:%i' "$b" 2>/dev/null)" || return 1
  [[ -n "$ai" && "$ai" == "$bi" ]]
}

# 运行状态判断：$1 = 待检 .vmx，其余 = vmrun list 输出的路径行。
# 必须按文件身份（设备+inode，跟随符号链接）而非路径字符串比对——
# 清单/磁盘路径可能是符号链接或大小写不同的形态，vmrun 回显的是另一种，
# 字符串比对会把运行中的 VM 误判为未运行（delete 的运行保护随之失效）。
_vm_running() {
  emulate -L zsh
  local vmx="$1" myid pid p
  shift
  myid="$(/usr/bin/stat -L -f '%d:%i' "$vmx" 2>/dev/null)" || return 1
  for p in "$@"; do
    pid="$(/usr/bin/stat -L -f '%d:%i' "$p" 2>/dev/null)"
    [[ -n "$pid" && "$pid" == "$myid" ]] && return 0
  done
  return 1
}

# 冲突短名的状态变更保护：同名但路径不同、无法确定用户指哪一台时，
# up/down/kill/reset/suspend/pause/unpause、快照全部操作、clone/delete
# 一律拒绝——启动、挂起乃至从错误的源机克隆同样是不可逆的误操作。
_vm_maybe_destroy() {
  emulate -L zsh
  local key="${VM_LC[${1:l}]:-$1}"
  if (( $+VM_CONFLICT[$key] )); then
    _vm_p -P "%F{red}✗ 短名 $key 对应不止一台虚拟机，无法确定操作对象，拒绝执行破坏性命令（vm vms 查看）%f" >&2
    return 1
  fi
  return 0
}

# 参数个数校验：$1=实际参数个数，$2=允许的最大个数，$3=用法示例。
# 拼写错误/多余参数不再被静默忽略，而是报错退出。
_vm_need() {
  emulate -L zsh
  if (( $1 > $2 )); then
    _vm_p -P "%F{red}✗ 参数过多。用法: vm $3%f" >&2
    return 1
  fi
  return 0
}

# 统一输出入口：等价 print -P，但颜色关闭时剥掉 %F{…}/%f 转义。
# 颜色关闭路径绝不能再用 print -P 渲染：数据里的 %% 转义会和颜色剥除相互
# 干扰（如数据 "%F{red}foo" 转义成 %%F{red}foo，剥掉 %F{…} 后残留 %foo，
# 再被 print -P 当作 %f 吃掉，输出只剩 oo）。改为：先保护 %%、剥掉真正的
# 颜色转义、还原 %%，最后 print -r 按字面输出，动态内容原样呈现。
_vm_p() {
  emulate -L zsh
  # 本次调用按实际 stdout 判断是否上色（管道/重定向/命令替换一律无色）
  if [[ -z "${NO_COLOR:-}" && -t 1 ]]; then
    builtin print "$@"
    return
  fi
  local -a args=("$@")
  local f="${args[$#]}"
  # 注意占位符必须经变量中转：替换串里内联 $'\x01' 会被当字面文本插入
  local esc=$'\x01'
  f="${f//\%\%/$esc}"
  f="$(builtin print -rn -- "$f" | LC_ALL=C sed -E 's/%F\{[^}]*\}//g; s/%f//g')"
  f="${f//$esc/%}"
  builtin print -r -- "$f"
}

# ── 4. 辅助 ────────────────────────────────────────────────────
# 动态内容先转义 `%` 再展开，避免路径里的 %x 被 print -P 当作 prompt 序列吃掉。
# 走 stderr：它是 trace 而不是结果，这样 `ip=$(vm ip kali)` 才能只拿到 IP。
_vm_echo() { _vm_p -rP "%F{cyan}➤ vmrun -T fusion ${${*//\%/%%}}%f" >&2; }

_vm_resolve() {
  emulate -L zsh
  # $1 = 短名；命中则向 stdout 输出 .vmx 路径并返回 0，否则报错返回 1
  local name="$1" vmx
  if [[ -z "$name" ]]; then
    _vm_p -P "%F{red}✗ 缺少虚拟机名，用法: vm <命令> <name>%f" >&2
    return 1
  fi
  vmx="${VM_VMX[$name]}"
  [[ -z "$vmx" ]] && vmx="${VM_VMX[${VM_LC[$name:l]}]}"   # 大小写不敏感兜底
  if [[ -z "$vmx" ]]; then
    _vm_p -P "%F{red}✗ 未知虚拟机: ${name//\%/%%}%f" >&2
    if (( ${#VM_VMX} )); then
      _vm_p -P "%F{yellow}  可用: ${${(k)VM_VMX}//\%/%%}%f" >&2
    else
      _vm_p -P "%F{yellow}  当前未发现任何虚拟机，先执行: vm scan%f" >&2
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
    [[ -n "$out" ]] && _vm_p -rP "%F{red}${${out//\%/%%}}%f" >&2
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
      --)        shift; rest+=("$@"); break ;;   # -- 本身消费掉，之后视为透传参数
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
  [[ -f "$vmsd" ]] || { _vm_p -P "%F{yellow}（未找到 .vmsd，无法读取备注）%f"; return 0; }

  # 快照编号在删过中间快照后可能不连续，所以直接枚举实际存在的编号
  idxs=(${${(f)"$(grep -oE '^snapshot[0-9]+\.displayName' "$vmsd")"}//[!0-9]/})
  (( ${#idxs} )) || { _vm_p -P "%F{yellow}（.vmsd 中无快照备注）%f"; return 0; }

  _vm_p -P "%F{green}— 快照备注（.vmsd）—%f"
  for i in ${(n)idxs}; do
    sname=$(grep -E "^snapshot${i}\.displayName" "$vmsd" \
            | sed -E 's/^[^=]*= *"//; s/[[:space:]]*"[[:space:]]*$//')
    sdesc=$(grep -E "^snapshot${i}\.description" "$vmsd" \
            | sed -E 's/^[^=]*= *"//; s/[[:space:]]*"[[:space:]]*$//')
    _vm_p -rP "  %F{cyan}${${sname:-<未命名>}//\%/%%}%f  %F{yellow}备注:%f ${${sdesc:-<无>}//\%/%%}"
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

# 字符串的屏幕显示宽度（CJK 等宽字符按 2 列）：用 (mr:N:) 按列补齐后反推。
# 列对齐必须按显示宽度而非字符数，否则中文名的行会把后续列顶偏。
_vm_dispwidth() {
  emulate -L zsh
  local s="$1" p="${(mr:1000:)1}"
  print -rn -- "$(( 1000 + ${#s} - ${#p} ))"
}

# 状态表格的一行：$1 = 短名，$2 = 圆点（含颜色），$3 = 运行状态，$4 = Tools 状态
# $5/$6 = 名称列/显示名列的显示宽度（缺省 14）；padding 用 (mr:) 按屏幕列宽
_vm_status_line() {
  local n="$1" m="$2" s="$3" t="$4" nw="${5:-14}" dw="${6:-14}" a b c d
  # 先按列宽补齐再转义 %：顺序反了会让含 % 的名字按转义后的长度补齐，列被顶偏
  a="${${(mr:nw:)n}//\%/%%}"
  b="${${(mr:dw:)VM_DISPLAY[$n]}//\%/%%}"
  c="${(mr:8:)${VM_STATE[$n]:-未知}}"
  d="${(mr:13:)${t:-unknown}}"
  _vm_p -rP -- "  $m %F{cyan}${a}%f ${b} ${c} ${d} $s"
}

# ── 5. 帮助 ────────────────────────────────────────────────────
vm_help() {
  cat <<'EOF'
vm — VMware Fusion (headless) 管理

虚拟机发现（手动扫描）:
  vm scan              重新扫描（Fusion 清单 + 默认目录兜底）
  vm vms               列出已发现的虚拟机（短名 + .vmx 路径）
  vm doctor            环境体检：vmrun/路径/探活（只读诊断）
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

网络 / IP:
  vm ip [-w] <name>             获取客户机 IP；-w = -wait 等待就绪（会阻塞）
  ※ 依赖 VMware Tools：不装 Tools 时立即失败；加 -w 则会一直阻塞等 Tools

快照:
  vm snap list <name>               列出快照（listSnapshots + .vmsd 备注）
  vm snap create <name> <snap>      创建快照（snapshot）
  vm snap delete <name> <snap>      删除快照（deleteSnapshot）
  vm snap revert <name> <snap>      回滚到快照（revertToSnapshot）

克隆:
  vm clone <src> <新名> [full|linked] [snapshot]
                                克隆（linked 需源机有快照；snapshot 仅对 linked 生效，
                                基于该快照克隆，缺省用 vmrun 默认行为；完成后自动纳入管理）

删除:
  vm delete <name> [--yes]     永久删除整台 VM（vmrun deleteVM，不可恢复）
                                运行中或短名冲突时拒绝；交互式需输入短名确认，
                                自动化脚本必须显式加 --yes

帮助:
  vm help              显示本帮助
EOF
}

# ── 6. 主函数 ───────────────────────────────────────────────────
vm() {
  emulate -L zsh
  local cmd="${1:-}" reply _vm_waitflag
  shift 2>/dev/null

  [[ -z "$cmd" ]] && { vm_help; return 0; }
  if [[ "$cmd" == "help" ]]; then
    _vm_need $# 0 'help' || return 1
    vm_help
    return 0
  fi

  case "$cmd" in
    up)      _vm_need $# 1 'up <name>' || return 1
             local vmx; vmx=$(_vm_resolve "${1:-}") || return 1
             _vm_maybe_destroy "$1" || return 1   # 冲突短名：不知道会启动哪一台
             _vm_power start "$vmx" nogui ;;
    down)    _vm_need $# 1 'down <name>' || return 1
             local vmx; vmx=$(_vm_resolve "${1:-}") || return 1
             _vm_maybe_destroy "$1" || return 1
             local rc
             _vm_power stop "$vmx" soft
             rc=$?
             (( rc != 0 )) && _vm_p -P "%F{yellow}! soft 关机失败：常见原因是未装/未启动 VMware Tools（vm status 可查）；确认无未保存数据后可改 vm kill ${1//\%/%%} 强制断电%f" >&2
             return $rc ;;
    kill)    _vm_need $# 1 'kill <name>' || return 1
             local vmx; vmx=$(_vm_resolve "${1:-}") || return 1
             _vm_maybe_destroy "$1" || return 1
             _vm_power stop "$vmx" hard ;;
    reset)   _vm_need $# 1 'reset <name>' || return 1
             local vmx; vmx=$(_vm_resolve "${1:-}") || return 1
             _vm_maybe_destroy "$1" || return 1
             local rc
             _vm_power reset "$vmx" soft
             rc=$?
             (( rc != 0 )) && _vm_p -P "%F{yellow}! soft 复位失败：常见原因是未装/未启动 VMware Tools（vm status 可查）%f" >&2
             return $rc ;;
    suspend) _vm_need $# 1 'suspend <name>' || return 1
             local vmx; vmx=$(_vm_resolve "${1:-}") || return 1
             _vm_maybe_destroy "$1" || return 1
             _vm_power suspend "$vmx" ;;
    pause)   _vm_need $# 1 'pause <name>' || return 1
             local vmx; vmx=$(_vm_resolve "${1:-}") || return 1
             _vm_maybe_destroy "$1" || return 1
             _vm_power pause "$vmx" ;;
    unpause) _vm_need $# 1 'unpause <name>' || return 1
             local vmx; vmx=$(_vm_resolve "${1:-}") || return 1
             _vm_maybe_destroy "$1" || return 1
             _vm_power unpause "$vmx" ;;

    ip)
      _vm_parse_wait "$@"
      set -- "${reply[@]}"
      _vm_need $# 1 'ip [-w] <name>' || return 1
      local vmx; vmx=$(_vm_resolve "$1") || return 1
      local ip; ip=$(_vm_ip "$vmx" "$_vm_waitflag")
      if [[ -z "$ip" ]]; then
        _vm_p -P "%F{yellow}✗ 未拿到 IP：VM 可能未开机或 VMware Tools 未就绪；可加 -w 等待%f" >&2
        return 1
      fi
      _vm_p -rP -- "${ip//\%/%%}"     # stdout 只有 IP，可被 $( ) 捕获
      ;;

    status)
      _vm_need $# 1 'status [name]' || return 1
      local name="${1:-}" vmx mark state n rc out
      local -a running
      out="$(vmrun -T fusion list 2>&1)"; rc=$?
      if (( rc != 0 )); then
        # 状态查询失败不能伪装成「全部未运行」：显式报错并透传退出码
        _vm_p -P "%F{red}✗ 无法查询运行状态（vmrun list 失败，Fusion 未运行？）%f" >&2
        [[ -n "$out" ]] && _vm_p -rP "  ${${out//\%/%%}}" >&2
        return $rc
      fi
      running=(${${(f)out}:#Total running VMs:*})
      # 运行比对按文件身份（设备+inode，见 _vm_running）：vmrun 回显路径的
      # 大小写/符号链接形态可能与清单不同，字符串比对会误判「未运行」
      if [[ -n "$name" ]]; then
        vmx=$(_vm_resolve "$name") || return 1
        name="${VM_LC[${name:l}]:-$name}"
        if _vm_running "$vmx" "${running[@]}"; then
          mark="%F{green}●%f"; state="%F{green}运行中%f"
        else
          mark="%F{white}○%f"; state="未运行"
        fi
        _vm_status_line "$name" "$mark" "$state" "$(_vm_tools "$vmx")" \
          "$(_vm_dispwidth "$name")" "$(_vm_dispwidth "${VM_DISPLAY[$name]}")"
        _vm_p -rP "      .vmx: ${${VM_VMX[$name]}//\%/%%}"
      else
        (( ${#VM_VMX} )) || { _vm_p -P "%F{yellow}未发现任何虚拟机，执行: vm scan%f"; return 0; }
        # 列宽取最长名称的显示宽度（宽字符按 2 列），避免长名/CJK 名顶偏后续列
        local -i nw=8 dw=8 wn wd
        for n in ${(k)VM_VMX}; do
          wn=$(_vm_dispwidth "$n"); wd=$(_vm_dispwidth "${VM_DISPLAY[$n]}")
          (( wn > nw )) && nw=wn
          (( wd > dw )) && dw=wd
        done
        _vm_p -P "%F{green}共 ${#VM_VMX} 台虚拟机：%f"
        for name in ${(ok)VM_VMX}; do
          if _vm_running "${VM_VMX[$name]}" "${running[@]}"; then
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
          _vm_need $# 1 'snap list <name>' || return 1
          local vmx rc; vmx=$(_vm_resolve "${1:-}") || return 1
          _vm_echo listSnapshots "$vmx"
          vmrun -T fusion listSnapshots "$vmx"
          rc=$?
          _vm_snap_notes "${vmx:r}.vmsd"
          return $rc   # listSnapshots 失败不能被 .vmsd 备注解析掩盖
          ;;
        create|delete|revert)
          _vm_need $# 2 "snap $sub <name> <snap>" || return 1
          local vmx; vmx=$(_vm_resolve "${1:-}") || return 1
          _vm_maybe_destroy "$1" || return 1   # create 也在内：冲突时不知道快照落在哪台上
          local snap="${2:-}"
          if [[ -z "$snap" ]]; then
            _vm_p -P "%F{red}✗ 用法: vm snap $sub <name> <snap>%f" >&2
            return 1
          fi
          case "$sub" in
            create) _vm_power snapshot "$vmx" "$snap" ;;
            delete) _vm_power deleteSnapshot "$vmx" "$snap" ;;
            revert) _vm_power revertToSnapshot "$vmx" "$snap" ;;
          esac
          ;;
        *)
          _vm_p -P "%F{red}✗ 未知快照子命令: ${${sub:-<空>}//\%/%%}（可选 list/create/delete/revert）%f" >&2
          return 1
          ;;
      esac
      ;;

    clone)
      _vm_need $# 4 'clone <src> <新名> [full|linked] [snapshot]' || return 1
      local src="${1:-}" newname="${2:-}" mode="${3:-full}" snapname="${4:-}"
      if [[ -z "$src" || -z "$newname" ]]; then
        _vm_p -P "%F{red}✗ 用法: vm clone <src> <新名> [full|linked] [snapshot]%f" >&2
        return 1
      fi
      if [[ "$mode" != "full" && "$mode" != "linked" ]]; then
        _vm_p -P "%F{red}✗ 克隆类型必须是 full 或 linked，收到: ${mode//\%/%%}%f" >&2
        return 1
      fi
      # full 克隆不支持指定 snapshot：与其静默忽略第 4 个参数，不如显式拒绝
      if [[ "$mode" == "full" && -n "$snapname" ]]; then
        _vm_p -P "%F{red}✗ full 克隆不支持指定 snapshot，请改用: vm clone $src $newname linked $snapname%f" >&2
        return 1
      fi
      # 新名必须是单个安全文件名：拒绝 / 、. 、.. 、控制字符和前导 -，
      # 否则目标路径会逃逸出 VM_DIR，或产生 delete 的选项解析无法处理的名字
      if [[ "$newname" == -* || "$newname" == */* || "$newname" == . || "$newname" == .. || \
            "$newname" == *[[:cntrl:]]* ]]; then
        _vm_p -P "%F{red}✗ 新名必须是单个文件名（不含 / 和控制字符，不能是 . 或 ..，不能以 - 开头）: ${newname//\%/%%}%f" >&2
        return 1
      fi
      local svmx; svmx=$(_vm_resolve "$src") || return 1
      _vm_maybe_destroy "$src" || return 1   # 冲突短名做源机：克隆出的可能是错的镜像
      # 短名被占用会导致克隆后两台 VM 无法区分，直接拒绝
      if [[ -n "${VM_LC[${newname:l}]}" ]]; then
        _vm_p -P "%F{red}✗ 短名已被占用: ${newname//\%/%%}（vm vms 查看）%f" >&2
        return 1
      fi
      # 注意：zsh 的 local 同一语句里后面的赋值展开时前面变量还未生效，必须分行
      local dstdir="$VM_DIR/$newname.vmwarevm"
      local dst="$dstdir/$newname.vmx"
      # 双重越界保险：VM_DIR 内有符号链接时，规范化后目标必须仍在 VM_DIR 里
      local realdir="${${VM_DIR%/}:A}" realdst="${dstdir:A}"
      if [[ "$realdst" != "$realdir"/* ]]; then
        _vm_p -P "%F{red}✗ 目标路径越界: ${dstdir//\%/%%}%f" >&2
        return 1
      fi
      # 拒绝整个目标 bundle（目录或符号链接），而不只是 .vmx
      if [[ -e "$dstdir" || -L "$dstdir" ]]; then
        _vm_p -P "%F{red}✗ 目标已存在: ${dstdir//\%/%%}%f" >&2
        return 1
      fi
      local -a cloneargs=("$svmx" "$dst" "$mode" -cloneName="$newname")
      if [[ "$mode" == "linked" ]]; then
        if [[ -n "$snapname" ]]; then
          local -a snames
          snames=("${(@f)$(_vm_snap_names "${svmx:r}.vmsd")}")
          if [[ -z "${snames[(re)$snapname]}" ]]; then
            _vm_p -P "%F{red}✗ 源虚拟机没有名为 ${snapname//\%/%%} 的快照，先执行: vm snap list ${src//\%/%%}%f" >&2
            return 1
          fi
          cloneargs+=(-snapshot="$snapname")
        elif ! grep -q '^snapshot[0-9]*\.displayName' "${svmx:r}.vmsd" 2>/dev/null; then
          _vm_p -P "%F{red}✗ linked 克隆要求源虚拟机至少有一个快照，先执行: vm snap create ${src//\%/%%} <snap>%f" >&2
          return 1
        fi
        # 不指定快照名时不传 -snapshot，交由 vmrun 默认行为
      fi
      # 原子占位：不用 -p。检查与创建之间有竞态窗口，若并发进程抢先创建了
      # 目标，无 -p 的 mkdir 立即失败，失败清理就绝不会误删他物
      local created_by_us=0
      if ! mkdir "$dstdir" 2>/dev/null; then
        _vm_p -P "%F{red}✗ 无法创建目标目录（不存在、被并发创建或 VM_DIR 缺失）: ${dstdir//\%/%%}%f" >&2
        return 1
      fi
      created_by_us=1
      _vm_echo clone "${(@)cloneargs}"
      vmrun -T fusion clone "${(@)cloneargs}"
      local rc=$?
      if (( rc == 0 )); then
        _vm_p -P "%F{green}✓ 克隆完成，重新扫描以纳入管理…%f"
        vm_scan
        vm vms
      elif (( created_by_us )); then
        # 目录确系本命令创建（mkdir 占位成功）；失败时清掉残留，
        # 否则下次重试会被「目标已存在」挡住
        _vm_p -P "%F{red}✗ 克隆失败，清理本次创建的目标目录%f" >&2
        rm -rf -- "$dstdir"
      fi
      return $rc
      ;;

    delete)
      # 永久删除：破坏性命令，多重防护（冲突/运行中/路径失效拒绝，交互确认）
      local yesflag=0 nopts=0 name arg
      local -a pos=()
      for arg in "$@"; do
        if (( nopts )); then pos+=("$arg"); continue; fi   # -- 之后全是位置参数
        case "$arg" in
          --)        nopts=1 ;;   # 支持以 - 开头的 VM 名（磁盘上手工建的仍可能出现）
          --yes|-y)  yesflag=1 ;;
          --*) _vm_p -P "%F{red}✗ 未知选项: ${arg//\%/%%}（删除支持 --yes）%f" >&2; return 1 ;;
          *) pos+=("$arg") ;;
        esac
      done
      if (( ${#pos} > 1 )); then
        _vm_p -P "%F{red}✗ 多余参数: ${pos[2]//\%/%%}，用法: vm delete <name> [--yes]%f" >&2
        return 1
      fi
      name="${pos[1]:-}"
      [[ -n "$name" ]] || { _vm_p -P "%F{red}✗ 用法: vm delete <name> [--yes]%f" >&2; return 1; }
      local key="${VM_LC[${name:l}]:-$name}"
      local vmx; vmx=$(_vm_resolve "$name") || return 1
      _vm_maybe_destroy "$name" || return 1       # 同名冲突的短名：拒绝，绝不二义删除
      # 不信任扫描缓存：删除前此刻重新验证 .vmx 真实存在
      if [[ ! -f "$vmx" ]]; then
        _vm_p -P "%F{red}✗ $vmx 已不存在（扫描缓存过期），先 vm scan 刷新再试%f" >&2
        return 1
      fi
      # 位于默认目录之外（inventory-only / 外部路径）→ 需要额外确认
      local realdir="${${VM_DIR%/}:A}" realvmx="${vmx:A}" external=0
      if [[ "$realvmx" != "$realdir"/* ]]; then external=1; fi
      local dname="${VM_DISPLAY[$key]:-$name}"
      _vm_p -P "%F{red}⚠ 即将永久删除（vmrun deleteVM，不可恢复）:%f" >&2
      _vm_p -P "  %F{cyan}${name//\%/%%}%f（${${dname//\%/%%}}）" >&2
      _vm_p -P "  ${vmx//\%/%%}" >&2
      (( external )) && _vm_p -P "%F{yellow}  ⚠ 该 VM 不在 ${${VM_DIR//\%/%%}} 内（清单/inventory-only 路径）%f" >&2
      if (( ! yesflag )); then
        # 非交互环境必须显式 --yes，不能默认跳过确认
        if [[ ! -t 0 ]]; then
          _vm_p -P "%F{yellow}✗ 非交互环境请显式加 --yes 确认删除%f" >&2
          return 1
        fi
        local typed
        print -rn "  输入短名 ${name} 以确认删除: " >&2
        read -r typed
        typed="${typed%$'\r'}"      # 某些终端/伪终端会带回车符
        if [[ "${typed:l}" != "${name:l}" ]]; then
          _vm_p -P "%F{yellow}输入不匹配，已取消%f" >&2
          return 1
        fi
        if (( external )); then
          print -rn "  该 VM 在 $VM_DIR 之外，再输入 yes 确认: " >&2
          read -r typed
          typed="${typed%$'\r'}"
          if [[ "${typed:l}" != "yes" ]]; then
            _vm_p -P "%F{yellow}未确认，已取消%f" >&2
            return 1
          fi
        fi
      fi
      # 最后一刻重查运行状态（vmrun list 失败视为无法确认，拒绝删除）：
      # 交互确认期间 VM 可能被启动；比对按文件身份，路径别名不致漏判
      local listout rc
      listout="$(vmrun -T fusion list 2>&1)"; rc=$?
      if (( rc != 0 )); then
        _vm_p -P "%F{red}✗ 无法确认 VM 是否在运行（vmrun list 失败），拒绝删除%f" >&2
        return $rc
      fi
      local -a running
      running=(${${(f)listout}:#Total running VMs:*})
      if _vm_running "$vmx" "${running[@]}"; then
        _vm_p -P "%F{red}✗ ${name//\%/%%} 正在运行，拒绝删除；先 vm down（软）或 vm kill（强制）%f" >&2
        return 1
      fi
      _vm_echo deleteVM "$vmx"
      vmrun -T fusion deleteVM "$vmx"
      rc=$?
      if (( rc == 0 )); then
        _vm_p -P "%F{green}✓ 已删除 ${name//\%/%%}，重新扫描…%f"
        vm_scan
        vm vms
      fi
      return $rc
      ;;

    list)
      _vm_need $# 0 'list' || return 1
      _vm_power list
      ;;
    vms)
      _vm_need $# 0 'vms' || return 1
      (( ${#VM_VMX} )) || { _vm_p -P "%F{yellow}未发现任何虚拟机，执行: vm scan%f"; return 0; }
      local n p d
      local -i nw=8 dw=8 wn wd
      for n in ${(k)VM_VMX}; do
        wn=$(_vm_dispwidth "$n"); wd=$(_vm_dispwidth "${VM_DISPLAY[$n]}")
        (( wn > nw )) && nw=wn
        (( wd > dw )) && dw=wd
      done
      _vm_p -P "%F{green}已发现 ${#VM_VMX} 台虚拟机：%f"
      for n in ${(ok)VM_VMX}; do
        p="${VM_VMX[$n]}"
        d="${${(mr:dw:)VM_DISPLAY[$n]}//\%/%%}"   # 先补齐再转义 %
        _vm_p -rP "  %F{cyan}${${(mr:nw:)n}//\%/%%}%f ${d} ${p//\%/%%}"
      done
      ;;
    scan)
      _vm_need $# 0 'scan' || return 1
      vm_scan
      _vm_p -P "%F{green}✓ 扫描完成，共发现 ${#VM_VMX} 台虚拟机%f"
      ;;
    doctor)
      # 只读体检：不改动任何状态，装完/升级后一次看清环境是否完整。
      # ✗ 计入失败（退出码 1），! 仅提示（环境仍可用）。
      _vm_need $# 0 'doctor' || return 1
      local ok=1 fver probeout proberc n
      _vm_p -P "%F{cyan}== vm doctor ==%f"
      if (( $+commands[vmrun] )); then
        _vm_p -P "%F{green}✓ vmrun%f ${commands[vmrun]}"
      else
        ok=0
        _vm_p -P "%F{red}✗ vmrun 不可用%f（未找到 VMware Fusion，默认路径: ${_vm_fusion_bindir//\%/%%}）"
      fi
      if [[ -d "/Applications/VMware Fusion.app" ]]; then
        fver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
                "/Applications/VMware Fusion.app/Contents/Info.plist" 2>/dev/null)"
        _vm_p -P "%F{green}✓ Fusion%f /Applications/VMware Fusion.app（版本 ${fver:-未知}）"
      else
        _vm_p -P "%F{yellow}! 未找到 /Applications/VMware Fusion.app（vmrun 来自其他位置也可用）%f"
      fi
      # 路径变量：绝对且目录存在才有意义（source 时已规范化，这里兜底验证）
      if [[ "$VM_DIR" == /* && -d "$VM_DIR" ]]; then
        _vm_p -P "%F{green}✓ VM_DIR%f ${VM_DIR//\%/%%}"
      elif [[ "$VM_DIR" != /* ]]; then
        ok=0
        _vm_p -P "%F{red}✗ VM_DIR 不是绝对路径: ${VM_DIR//\%/%%}%f"
      else
        _vm_p -P "%F{yellow}! VM_DIR 不存在: ${VM_DIR//\%/%%}（仅清单里的 VM 可见，属正常可用）%f"
      fi
      if [[ -f "$VM_INVENTORY" ]]; then
        _vm_p -P "%F{green}✓ VM_INVENTORY%f ${VM_INVENTORY//\%/%%}"
      else
        _vm_p -P "%F{yellow}! VM_INVENTORY 不存在: ${VM_INVENTORY//\%/%%}（Fusion 首次启动前属正常）%f"
      fi
      # 探活：vmrun list 真正跑一次，这才是「环境完整」的硬证据
      probeout="$(vmrun -T fusion list 2>&1)"; proberc=$?
      if (( proberc == 0 )); then
        n="${${(f)probeout}[(I)Total running VMs:*]}"
        n="${n//[!0-9]/}"
        _vm_p -P "%F{green}✓ vmrun list%f 探活正常，当前运行 ${n:-0} 台"
      else
        ok=0
        _vm_p -P "%F{red}✗ vmrun list 探活失败（rc=$proberc，Fusion 未启动？）%f"
        [[ -n "$probeout" ]] && _vm_p -rP "  ${${probeout//\%/%%}}" >&2
      fi
      # 扫描缓存与冲突
      _vm_p -P "  已发现 ${#VM_VMX} 台虚拟机（${${(j:、:)${(ok)VM_VMX}}:-无}；vm scan 刷新）"
      if (( ${#VM_CONFLICT} )); then
        _vm_p -P "%F{yellow}! 存在冲突短名（同名不同机，状态变更命令被拒）: ${${(j:、:)${(ok)VM_CONFLICT}}//\%/%%}%f"
      fi
      (( ok )) && _vm_p -P "%F{green}✓ 环境完整%f" || _vm_p -P "%F{red}✗ 环境存在问题，见上方 ✗ 项%f"
      return $(( 1 - ok ))
      ;;
    *)
      _vm_p -P "%F{red}✗ 未知子命令: ${cmd//\%/%%}%f" >&2
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
        'snap:快照管理'
        'clone:克隆虚拟机'
        'delete:永久删除（需确认）'
        'list:列出运行中的 VM'
        'vms:列出已发现的 VM'
        'scan:重新扫描'
        'doctor:环境体检（只读诊断）'
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
              # linked 克隆可指定基于哪个快照；full 不支持
              local vmx snames=()
              if [[ "${words[4]}" == linked ]]; then
                vmx="${VM_VMX[${VM_LC[${words[2]:l}]}]}"
                if [[ -n "$vmx" ]]; then
                  snames=("${(@f)$(_vm_snap_names "${vmx:r}.vmsd")}")
                fi
                (( ${#snames} )) && _wanted snaps expl '快照名' compadd -a snames
              fi
              ;;
          esac
          ;;
        ip)
          case $CURRENT in
            2) _alternative 'vms:虚拟机:compadd -a vms' 'opts:选项:compadd -- -w --wait' ;;
            3) [[ ${words[2]} == -* ]] && _wanted vms expl '虚拟机' compadd -a vms ;;
          esac
          ;;
        up|down|kill|suspend|pause|unpause|reset|status|delete)
          # 这些命令只收一个 VM 名（多余参数会被 _vm_need 拒绝），只在第一位补全
          (( CURRENT == 2 )) && _wanted vms expl '虚拟机' compadd -a vms
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
