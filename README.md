# vm.zsh

VMware Fusion 的 headless 命令行管理工具（zsh 函数），基于 `vmrun`。无 GUI、无短别名，统一走 `vm` 命令。

## 安装

```zsh
git clone <本仓库> ~/.config/vm   # 或把 vm.zsh 放到任意位置
# .zshrc 里加一行：
[ -f ~/.config/vm/vm.zsh ] && source ~/.config/vm/vm.zsh
```

依赖 `/Applications/VMware Fusion.app`（脚本自管 PATH，把其 `Contents/Public` 追加进来）。`ip`/`ssh`/`down` 等依赖客户机 VMware Tools。

## 命令一览

```
vm scan / vms / list / status [name]     发现与状态
vm up / down / kill / suspend / pause / unpause / reset <name>   电源
vm ip [-w] <name>                        获取客户机 IP（stdout 纯净，可 $( ) 捕获）
vm ssh [-w] <name> [user] [-- ssh选项...] [远程命令...]
                                         拿 IP 后直接 ssh；-- 后的参数是 ssh 选项，
                                         自动放在目标地址之前（如: vm ssh kali root -- -p 2222）；
                                         不带 -- 时其余参数作为远程命令执行
vm snap list|create|delete|revert ...    快照（备注从 .vmsd 解析）
vm clone <src> <新名> [full|linked] [snapshot]
                                         克隆（linked 需源机有快照；指定 snapshot 时
                                         基于该快照，缺省用 vmrun 默认行为）
vm help                                  完整帮助
```

zsh 补全（子命令 / VM 短名 / 快照名）对两种加载顺序都能注册：`compinit` 先于本文件执行时直接 `compdef` 注册；否则 vm.zsh 会把自身目录加入 `fpath`，其中带 `#compdef` 头的 `_vm` 文件由之后的 `compinit` 扫描注册。

## 设计要点

- **trace 与结果分离**：回显的 `vmrun` 命令、警告全走 stderr，`vm ip` 的 stdout 只有 IP，可以直接 `ip=$(vm ip kali)`；失败时退出码可信，可脚本化判断。
- **发现双来源**：Fusion 的 `vmInventory` 为主（路径大小写正确、覆盖默认目录之外的 VM），`VM_DIR` 下的 `.vmwarevm` 兜底；短名取磁盘真实目录名。清单路径失效时保留磁盘扫描结果并警告；不同路径的同名 VM 只保留一台并警告冲突。`status` 与 `vmrun list` 的比对统一转小写，不受两边大小写差异影响。
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

沙盒回归测试：用假 `vmrun`/`ssh` 隔离，并逐参数记录 argv 做契约断言（覆盖 ssh 选项位置、clone 目标路径、路径穿越、短名冲突、失效清单、错误码透传等），不会碰真实虚拟机。
