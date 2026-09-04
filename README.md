# vm.zsh

VMware Fusion 的 headless 命令行管理工具（zsh 函数），基于 `vmrun`。无 GUI、无短别名，统一走 `vm` 命令。

## 项目定位

> **面向 VMware Fusion 的轻量级虚拟机生命周期管理工具，而不是 `vmrun` 的全功能封装。**

是否覆盖全部 `vmrun` 命令并不是质量标准。项目追求的是「所实现功能的可靠性与安全性」，而不是对 `vmrun` 的覆盖率。

| 提供 | 说明 |
|---|---|
| VM 发现 / 列表 / 状态 | 短名解析、`vmrun list` 比对、Tools/清单状态 |
| 电源管理 | up / down / kill / suspend / pause / unpause / reset |
| IP 查询 | 只读、stdout 纯净可 `$( )` 捕获 |
| 快照管理 | 增删改查 + `.vmsd` 备注展示 |
| 克隆 VM | full / linked，成功后自动纳入管理 |
| 安全删除 | `vm delete`，多重防护 + 显式确认 |
| zsh 补全 | 子命令 / 短名 / 快照名 |

| 明确不做 | 理由 |
|---|---|
| `ssh` 包装 | 原生 SSH 已足够，包装引入参数解析复杂度与静默语义风险 |
| 客户机内命令执行 / 文件复制 / 进程管理 | 涉及凭据与注入风险，会把工具变成另一类东西；仅保留 IP、Tools 状态等只读查询 |
| 网络适配器 / 主机虚拟网络配置 | 低频、配置差异大、误操作风险高 |

## 安装

```zsh
git clone https://github.com/hack2xia/vm.git ~/.config/vm   # 或把 vm.zsh 放到任意位置
# .zshrc 里加一行：
[ -f ~/.config/vm/vm.zsh ] && source ~/.config/vm/vm.zsh
```

依赖 `/Applications/VMware Fusion.app`（`vmrun` 默认解析为其中的绝对路径执行，也可用 `VMRUN_BIN` 显式指定；脚本另会把 Fusion 的 `Contents/Public` 追加到 PATH 供手动使用）。`ip`/`down` 等依赖客户机 VMware Tools。

- **环境要求**：macOS、zsh 5.x+、VMware Fusion（含 `vmrun`）。脚本不做重依赖，其余命令均为 macOS 自带工具。
- **安装后验证**：新开一个 zsh 终端执行 `vm doctor`，各项 ✓ 即环境完整（它会真正探活 `vmrun list`，比 `vm vms` 更能证明安装成功）；看不到虚拟机先 `vm scan`。
- **更新**：`git -C ~/.config/vm pull` 后重开终端（或重新 `source ~/.config/vm/vm.zsh`）。
- **卸载**：删除 `.zshrc` 里的 source 行，再 `rm -rf ~/.config/vm`。脚本不写持久业务状态（inventory 只读、缓存仅在内存）；注意 source 会修改当前 shell 的 `PATH`/`fpath`/函数/变量，已打开的 shell 需重启或手动 unset 才完全还原。
- 版本记录见 [CHANGELOG.md](CHANGELOG.md)。

## 命令一览

```
vm scan / vms / list / status [name]     发现与状态
vm doctor                                环境体检：vmrun/路径/探活（只读诊断）
vm up / down / kill / suspend / pause / unpause / reset <name>   电源
vm ip [-w] <name>                        获取客户机 IP（stdout 纯净，可 $( ) 捕获）
vm snap list|create|delete|revert ...    快照（备注从 .vmsd 解析）
vm clone <src> <新名> [full|linked] [snapshot]
                                         克隆（linked 需源机有快照；snapshot 仅对
                                         linked 生效，基于该快照，缺省用 vmrun 默认
                                         行为；新名不能以 - 开头）
vm delete <name> [--yes] [--allow-external]
                                         永久删除（vmrun deleteVM，不可恢复；
                                         运行中或短名冲突拒绝；交互需输入短名确认，
                                         自动化脚本必须显式加 --yes；VM_DIR 之外的
                                         VM 还须加 --allow-external；-- 之后的名字
                                         按位置解析）
vm help                                  完整帮助
vm version                               显示版本（stdout 纯净可捕获）
```

zsh 补全（子命令 / VM 短名 / 快照名）对两种加载顺序都能注册：`compinit` 先于本文件执行时直接 `compdef` 注册；否则 vm.zsh 会把自身目录加入 `fpath`，其中带 `#compdef` 头的 `_vm` 文件由之后的 `compinit` 扫描注册。

## 设计要点

- **trace 与结果分离**：回显的 `vmrun` 命令、警告全走 stderr，`vm ip` 的 stdout 只有 IP，可以直接 `ip=$(vm ip kali)`；失败时退出码可信，可脚本化判断。
- **vmrun 单一入口**：所有调用统一走 `VMRUN_BIN`（默认解析为 Fusion 内的绝对路径），不依赖 PATH 优先级，避免 Homebrew/旧版本 `vmrun` 或同名函数导致「doctor 显示 A、实际执行 B」；`vm doctor` 显示的就是真正会执行的路径。
- **发现双来源**：Fusion 的 `vmInventory` 为主（路径大小写正确、覆盖默认目录之外的 VM），`VM_DIR` 下的 `.vmwarevm` 兜底；短名取磁盘真实目录名。同名合并按文件身份（设备+inode）判断：同一台（大小写/软链差异）用清单路径刷新；不同物理文件的同名 VM 只保留一台、警告冲突，且该短名的一切状态变更命令（`up`/`down`/`kill`/`reset`/`suspend`/`pause`/`unpause`/快照全部操作/`clone` 源/`delete`）都会被拒绝——拒绝时展示保留与被隐藏的全部冲突路径及解决指引，`vm vms` 在冲突短名行下追加冲突路径，`vm doctor` 列出完整冲突集合。`status`/`delete` 与 `vmrun list` 的运行比对同样按文件身份进行，清单路径是符号链接或大小写别名时不会误判运行状态。
- **删除安全**：`vm delete` 在短名冲突、`.vmx` 已失效时拒绝；运行状态在交互确认之后、执行 `deleteVM` 之前最后一刻复查（确认期间 VM 被启动也拦得住），`vmrun list` 失败视为无法确认、拒绝删除；交互式必须输入短名确认，位于 `VM_DIR` 之外的 inventory-only VM 还要二次确认；自动化必须显式 `--yes`，且删除 `VM_DIR` 之外的 VM 还须加 `--allow-external`（`--yes` 单独不足以静默删除外部 VM）；支持 `vm delete -- <name>` 管理磁盘上已有的 `-` 开头名字。
- **动态内容安全化**：所有动态内容（VM 名、路径、清单字段、外部命令输出）进入输出前统一经 `_vm_esc` 处理——`%` 转义防 prompt 展开吃掉内容，控制字符可见化（ESC→`^[`、CR→`^M`、LF→`\n`）防终端注入伪造显示；含 `%F{…}` 等序列的名字在任何输出模式下都原样可读。
- **回显可复制执行**：每次执行前打印实际调用的 `vmrun` 命令，参数按 shell quoting 逐个表示（含空格的路径也能原样复制执行），防止忘记原用法。
- 手动扫描模型：source 时扫一次，`vm scan` 手动刷新。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `VM_DIR` | `~/Virtual Machines.localized` | 兜底扫描目录（source 时规范化为绝对路径，相对路径覆盖也不会随 `cd` 失效） |
| `VM_INVENTORY` | `~/Library/Application Support/VMware Fusion/vmInventory` | Fusion 清单（同上） |
| `VMRUN_BIN` | Fusion 内 `vmrun` 的绝对路径 | 唯一实际执行的 `vmrun`；覆盖值须为绝对路径且可执行（测试用 fake 注入也走这里） |
| `NO_COLOR` | 未设置 | 设置后（任意非空值）强制关闭彩色输出 |

颜色输出按实际 stdout 判定：管道 / 重定向 / 命令替换中自动关闭，无需显式设置。

## 故障排查

**「短名 X 对应不止一台虚拟机」**
两台不同的物理 VM 映射到了同一短名（常见于不同目录下的同名 bundle，或清单与磁盘同名）。此时该短名的一切状态变更命令都会被拒绝——这是有意的，绝不猜测你想操作哪一台。解决：`vm vms` 会在冲突短名下列出保留路径与全部冲突路径（`vm doctor` 同样列出）；把其中一个 bundle 重命名，或在 Fusion 里移除清单中的陈旧条目，然后 `vm scan`。

**新建/删除的 VM 没出现或没消失**
扫描是手动模型：source 时扫一次，之后只读缓存，任何变化都需要 `vm scan` 刷新。注意 `vm status` 的「运行中」判定每次实时调 `vmrun list`，不受缓存影响；但缓存里的路径若已失效，删除命令会以「已不存在」拒绝，先 `vm scan` 即可。

**「无法查询运行状态（vmrun list 失败）」**
通常是 Fusion 未启动。状态查询失败会显式报错并透传退出码，绝不会伪装成「全部未运行」。启动 Fusion 后重试。

**「vmrun 不可用」**
默认从 `/Applications/VMware Fusion.app` 解析 `vmrun` 的绝对路径。Fusion 装在别处或使用其他构建时，用 `VMRUN_BIN=/绝对路径/vmrun` 显式指定；`vm doctor` 显示的就是实际会执行的路径。

**VMware Tools 未安装时哪些命令受影响**
- `vm ip`：立即失败；加 `-w` 会阻塞等待 Tools 就绪
- `vm down` / `vm reset`（soft）：失败，确认无未保存数据后可改 `vm kill`（hard，不需要 Tools）
- `vm status` 的 Tools 列：显示 `unknown`
- 电源、快照、克隆、删除不依赖 Tools

**删除 VM_DIR 之外的 VM**
清单里的 VM 可以位于默认目录之外（inventory-only）。这类 VM 交互式删除需要额外输入 `yes` 二次确认；自动化还必须同时加 `--allow-external`——单靠 `--yes` 永远不会静默删除外部 VM。

**报障**：附上 `vm version` 与 `vm doctor` 的完整输出。

## 测试

```zsh
zsh tests/vm_test.zsh      # 沙盒回归（CI 同款）
zsh tests/smoke_local.zsh  # 本机冒烟：真实 vmrun 只读验证，推送前跑
```

沙盒回归测试：用假 `vmrun` 隔离——经 `VMRUN_BIN` 显式注入，不依赖 PATH 优先级，绝不触达真实虚拟机；fake 对沙盒外的写入/删除路径 fail-closed（拒绝执行）；沙盒目录用 `mktemp` 随机生成，夹具创建失败立即终止，清理注册到 EXIT/INT/TERM/HUP。并逐参数记录 argv 做契约断言（覆盖 clone 目标路径、路径穿越、短名冲突与状态变更拒绝、符号链接路径身份、失效清单、错误码透传、删除防护、外部 VM 双标志、多余参数、非终端无色、控制字符可见化、回显 quoting 等）。交互删除流程用 `zpty` 真实伪终端覆盖：正确输入确认后删除、错误输入/EOF 取消、外部 VM 二次确认、运行状态最后一刻拦截，并对 TTY（有色）与非 TTY（无色）两种输出模式分别断言。

## 许可

MIT，见 [LICENSE](LICENSE)。
