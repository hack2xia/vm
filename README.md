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
git clone <本仓库> ~/.config/vm   # 或把 vm.zsh 放到任意位置
# .zshrc 里加一行：
[ -f ~/.config/vm/vm.zsh ] && source ~/.config/vm/vm.zsh
```

依赖 `/Applications/VMware Fusion.app`（脚本自管 PATH，把其 `Contents/Public` 追加进来）。`ip`/`down` 等依赖客户机 VMware Tools。

## 命令一览

```
vm scan / vms / list / status [name]     发现与状态
vm up / down / kill / suspend / pause / unpause / reset <name>   电源
vm ip [-w] <name>                        获取客户机 IP（stdout 纯净，可 $( ) 捕获）
vm snap list|create|delete|revert ...    快照（备注从 .vmsd 解析）
vm clone <src> <新名> [full|linked] [snapshot]
                                         克隆（linked 需源机有快照；snapshot 仅对
                                         linked 生效，基于该快照，缺省用 vmrun 默认行为）
vm delete <name> [--yes]                 永久删除（vmrun deleteVM，不可恢复；
                                         运行中或短名冲突拒绝；交互需输入短名确认，
                                         自动化脚本必须显式加 --yes）
vm help                                  完整帮助
```

zsh 补全（子命令 / VM 短名 / 快照名）对两种加载顺序都能注册：`compinit` 先于本文件执行时直接 `compdef` 注册；否则 vm.zsh 会把自身目录加入 `fpath`，其中带 `#compdef` 头的 `_vm` 文件由之后的 `compinit` 扫描注册。

## 设计要点

- **trace 与结果分离**：回显的 `vmrun` 命令、警告全走 stderr，`vm ip` 的 stdout 只有 IP，可以直接 `ip=$(vm ip kali)`；失败时退出码可信，可脚本化判断。
- **发现双来源**：Fusion 的 `vmInventory` 为主（路径大小写正确、覆盖默认目录之外的 VM），`VM_DIR` 下的 `.vmwarevm` 兜底；短名取磁盘真实目录名。同名合并按文件身份（设备+inode）判断：同一台（大小写/软链差异）用清单路径刷新；不同物理文件的同名 VM 只保留一台、警告冲突，且该短名的破坏性命令（`kill`/`reset`/`down`/`snap delete`/`snap revert`/`delete`）会被拒绝执行。`status` 与 `vmrun list` 的比对统一转小写，不受两边大小写差异影响。
- **删除安全**：`vm delete` 在运行中、短名冲突、`.vmx` 已失效时一律拒绝；交互式必须输入短名确认，位于 `VM_DIR` 之外的 inventory-only VM 还要二次确认；自动化必须显式 `--yes`。
- **`%` 转义**：所有动态内容回显前先转义 `%`，路径里的 `%x` 不会被 `print -P` 当成 prompt 序列吃掉。
- **回显原始命令**：每次执行前打印实际调用的 `vmrun` 命令，防止忘记原用法。
- 手动扫描模型：source 时扫一次，`vm scan` 手动刷新。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `VM_DIR` | `~/Virtual Machines.localized` | 兜底扫描目录 |
| `VM_INVENTORY` | `~/Library/Application Support/VMware Fusion/vmInventory` | Fusion 清单 |

## 测试

```zsh
zsh tests/vm_test.zsh
```

沙盒回归测试：用假 `vmrun` 隔离，并逐参数记录 argv 做契约断言（覆盖 clone 目标路径、路径穿越、短名冲突与破坏性拒绝、失效清单、错误码透传、删除防护等），不会碰真实虚拟机。
