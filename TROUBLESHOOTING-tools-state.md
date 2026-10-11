# 排查记录：`vm ip` 报 "VMware Tools are not running" / `vm status` 停在「已安装」

- 日期：2026-09-23
- 对象：alma10（AlmaLinux 10.1）
- 主机的时区为 UTC+8，文中时刻除特别标注外均为**主机本地时间**；`vmware.log` / `vmware-vix-*.log` 内部为 UTC（+8 小时即为本地）。

---

## 1. 结论摘要（TL;DR）

1. **vm.zsh 和 guest 都没有问题。** guest 侧 `vmtoolsd` 自开机约 20 秒起就 active，一路健康；故障在**主机侧 `vmrun` 看到的 Tools 状态**上。
2. 表现是 host 侧 `checkToolsState` 长时间停在 `installed`、`getGuestIPAddress` 报 `The VMware Tools are not running`。这个 `installed` 的含义是「装了，但没有确认在运行」，与 guest 里 `vmtoolsd` 是否 active **不是同一件事**。
3. 这个窗口**长度不固定，且会自发恢复**：实测两次冷启动分别约 4~7 分钟、约 22 分钟；对照机 mint 1 分钟内就正常。
4. 故障态下 **`vm ip -w` 会一直挂着不返回**（`-w` 等的是同一个信号），不要把它当万能药。
5. `suspend(hard)` → `resume` 已验证**无效**。
6. 冷启动时出现的 `LocationGetRoot: Unable to determine the product location...` / `Cannot determine message file path for locale "en"` 三行是**每次冷启动都会出现**的无害诊断输出，与本次故障无关。

---

## 2. 现象

```
$ vm up alma10
➤ 原生命令: vmrun -T fusion start .../Alma10.vmx nogui
2026-09-23T07:40:49.591| ServiceImpl_Opener: PID 2102
LocationGetRoot: Unable to determine the product location. It is likely that the product has never been run on this machine.
Cannot determine message file path for locale "en".
LocationGetRoot: Unable to determine the product location. ...
LocationGetRoot: Unable to determine the product location. ...

$ vm status alma10
  ● alma10（Alma10）
      电源:  运行中
      Tools: 已安装        ← 与下面 ip 失败看似矛盾，其实是同一件事
      .vmx:  .../Alma10.vmx

$ vm ip alma10
➤ 原生命令: vmrun -T fusion getGuestIPAddress .../Alma10.vmx
Error: The VMware Tools are not running in the virtual machine: .../Alma10.vmx
✗ 未拿到 IP：VM 可能未开机或 VMware Tools 未就绪；可加 -w 等待
```

关键误读点：`vm status` 的「已安装」= `vmrun checkToolsState` 返回的 `installed`，表示 `installed`（装了但未确认运行）；guest 内 `vmtoolsd` 正在跑时，它也可能是 `installed`。所以「已安装」和「ip 失败」不是矛盾，是同一个状态的两面。

---

## 3. 环境

| | 值 |
|---|---|
| 主机 | macOS 15.8 (24H23)，x86_64，UTC+8 |
| Fusion | 26.0.1；`vmrun` version 1.17.0 build 25689522 |
| guest alma10 | AlmaLinux 10.1 (el10)，kernel 6.12.0-124.8.1.el10_1，`open-vm-tools-13.0.10-1.el10`（13.0.10.0 build-25056151），`multi-user.target`（**无图形界面**） |
| guest 时区 | Asia/Tokyo（JST, +0900）→ 界面显示比主机快 1 小时，UTC 与主机同步 |
| guest 网络 | ens160 = 192.168.7.141/24（NAT），可达 |
| 对照机 | mint（Linux Mint 22.3），同一主机、同一 `vmrun` |

---

## 4. 排查证据

### 4.1 主机侧时间线（第一次故障，07:40 冷启动）

| 时刻 | 事件 / 证据 |
|---|---|
| 07:40:49 | `vm up alma10` 开机；同秒 Fusion 把 Services 落盘到 `/Library/Application Support/VMware/VMware Fusion/` |
| 07:40:49+ | `vm status` → `Tools: 已安装`（**这次是准确的**：guest 的 vmtoolsd 还没起） |
| 07:41:08 | vmx 日志：`Tools: Running status rpc handler: 0 => 1`、`Changing running status: 0 => 1`、随后 `1 => 2`、`2 => 1` |
| 07:41:08 | vmx 日志：`TOOLS Received tools.set.versiontype rpc call, version = 13322, type = 4` |
| 07:41 | `vm ip alma10` → `Tools not running` 失败 |
| 07:44:41 | 复测 `checkToolsState` 仍是 `installed`；`getGuestIPAddress` 失败；`listProcessesInGuest` **挂死 2 分 19 秒**（手动杀掉） |
| 07:47:22 | 对照机 mint（07:46:08 开机）`checkToolsState` = `running`，取 IP 正常 |
| 07:47:42 | alma10 `checkToolsState` 变为 `running`；随后 `vm ip alma10` → 192.168.7.141 |

### 4.2 复现（第二次冷启动，07:57）

用脚本做受控复现（软关机 → 开机 → 每 10 秒采样 `checkToolsState` + `getGuestIPAddress`）：

- 07:57:09 开机，07:57:17 ~ 08:05:37 共 **48 次采样全部** `state=installed` + `Tools not running`（518 秒），08:07 复测仍 `installed`。
- 08:11:53 `vmrun suspend ... hard`，08:11:58 resume；08:11:53 ~ 08:16:18 共 **100 次采样仍全部** `installed`。
- 08:19:29 突然取到 IP；08:19:32 `checkToolsState` = `running`。此后一直正常。

### 4.3 核心判据：vmx 的 tools 存活信号

vmx 日志里有两个心跳字段，直接对应故障与否：

| 开机 | `[RunningStatus]` | `[AppStatus]` | `vmrun` 结果 |
|---|---|---|---|
| alma10 07:40 | `Last heartbeat value 1 (last received 0s ago)` + `Running status rpc handler: 0 => 1` | 1 | 4~7 分钟后变 `running` |
| alma10 07:57 | **`Last heartbeat value 0 (never received)`** | **`never received`** | 卡 `installed` 约 22 分钟 |
| mint 07:46 | `value 1` + `Running status rpc handler: 0 => 1`（开机 +9s） | 1 | 1 分钟内 `running` |

三次开机里 guest 都完成了 `tools.set.versiontype`（说明工具在跑、RPC 通道能通），但**只有 vmx 收到 heartbeat 的那两次**，`checkToolsState`/`getGuestIPAddress` 才可用。

相关依据（来自 `vmware-vmx` 二进制字符串）：vmx 侧存在 `backdoorToolsRunningStatus`、`backdoorToolsHeartbeat`、`backdoorLastHeartbeat`、`backdoorSeenToolsActivity`、`tools.heartbeatFrequency`、`tools.ping.interval`、`tools.ping.timeout`、`tools.runningStatus` —— 即这套存活判定走的是 **backdoor 路径，且不写 `vmware.log`**，这解释了为什么"状态翻转时刻日志里什么都没有"。

> 补充：guest 的 `open-vm-tools 13.0.10` 里**不存在** `runningStatus` 字符串；用 guest 内自带的 `vmware-rpctool "tools.runningStatus"` 发送会被 vmx 回 `Unknown command`（`tools.*` 类 RPC 只接受注册为 tools 通道的应用调用），因此这个信号无法从外部伪造，只能由 guest 侧 `vmtoolsd` 自己发出。

### 4.4 suspend → resume 无效

resume 后 vmx 只多了两行：

```
Tools: sending 'OS_Resume' (state = 4) state change request
Tools: Delaying state change request to state 4.
```

vmx 认为 tools 没在跑，就把 state change 挂起等 guest；而 guest 并没有被重启（进程未变），没机会重新上报 → 互相等，状态不会变。`[RunningStatus]` 在挂起时还被置成 `1 => 0`，busy 等也没有恢复。

### 4.5 guest 侧检查清单（全部正常）

| 检查 | 结果 |
|---|---|
| `systemctl is-active vmtoolsd vgauthd` | `active` / `active` |
| `systemctl show vmtoolsd -p MainPID,NRestarts,ActiveEnterTimestamp` | PID 未变、`NRestarts=0`、时间戳=开机时刻（**全程没有重启过**） |
| `systemd-analyze` | 总 9.99s（kernel 1.9 + initrd 3.0 + userspace 5.1） |
| `rpm -V open-vm-tools` | 无差异 |
| `/etc/vmware-tools/` | 无自定义 `scripts/`、无 `tools.conf`（默认） |
| `journalctl -u vmtoolsd` | 只有一条 `Started vmtoolsd.service`，无报错 |
| 时钟 | guest UTC 与 host UTC 差 <1s |
| 网络 | `ens160 192.168.7.141/24`，`ping` 通，ARP 中 MAC 与 vmx 的 `00:0c:29:f6:72:13` 一致 |
| `vmware-rpctool "info-get guestinfo.ip"` | 返回 `192.168.7.141`（backdoor RPC 正常） |
| initrd 内的 vmware 组件 | 无（`lsinitrd` 无 vmware/vmtools 条目，也没有 dracut vmware 模块） |
| 图形会话 | 无（`multi-user.target`、无 Xorg/gdm，因此不存在 vmusr 实例） |

### 4.6 vmx 配置差异（alma10 vs mint）

差异都能解释为**结果而非原因**；`tools.*` 三项（`syncTime`、`upgrade.policy`、`capability.verifiedSamlToken`）两台完全一致。

| 键 | alma10 | mint |
|---|---|---|
| `softPowerOff` | FALSE | TRUE |
| `cleanShutdown` | FALSE | TRUE |
| `ethernet0.virtualDev` | vmxnet3 | e1000 |
| `mks.enable3d` / `svga.graphicsMemoryKB` | TRUE / 8G | FALSE / 256M |
| `ide1:0` | 仍挂着 AlmaLinux 安装 ISO | 无 |

其中 `softPowerOff=FALSE` 正是"这台 guest 的 tools 没走完握手"留下的痕迹（Fusion 据此判定 guest 不支持软关机），与 `vm status` 报 `installed` 是同一件事。

---

## 5. 排查中修正过的错误判断（避免以后重踩）

| 一开始的判断 | 实际情况 |
|---|---|
| 那三行 `LocationGetRoot` / `messages/en` 是"首次运行的一次性告警" | **每次冷启动（vmrun 需要拉起 vmx 时）都会出现**。之前误判是因为用"已在运行的 VM 再 start"验证，那条路径不拉起 vmx |
| `LocationGetRoot` 是 Services 目录尚未落盘导致 | 不成立——Services 已存在时告警照旧。**能确证的只有 locale 那条**：VIX 日志明写 `DictionaryLoad: Cannot open file ".../Contents/Library/messages/en/vmware.vmsg": No such file or directory`（`messages/` 只有 `es fr ja`，英文是编译内置兜底）。`LocationGetRoot` 只能确认是服务自举期的诊断输出，无实际影响 |
| Tools 没就绪「等一会儿就好，用 `-w` 兜」 | 部分错。故障窗口可达 20 分钟以上，且 `-w` 等的是同一个信号，**会一直挂着不返回** |
| 是 guest 启动慢导致 | 不成立。guest 是 10 秒级启动，`vmtoolsd` 在开机 +20 秒就 active，全程健康 |

---

## 6. 下次遇到怎么办

**判据**：`vm status` 显示 `Tools: 已安装`，但 ssh 进 guest 后 `systemctl is-active vmtoolsd` 是 `active` → 就是这个 host 侧状态脱节的问题，**不是 Tools 未安装**。

处理顺序（前两条已实测）：

1. **等**：host 侧会自发恢复，窗口 4~22 分钟不等（无法预测）。
2. **不要用 `vm ip -w`**：故障态下会一直挂着。
3. 在 guest 内 `sudo systemctl restart vmtoolsd`，或重启 guest —— **是否立刻生效尚未验证**（本次故障是自发恢复的，没测到）。
4. `suspend`/`resume`、反复查询都不能促使它恢复（已实测）。

对 vm.zsh 的影响：**无 bug，无需改动**。`vm status` 的 Tools 列语义如上；`vm ip` 的失败提示里"VM 可能未开机或 VMware Tools 未就绪"这句话在这个场景下是准确的，只是「未就绪」的含义是 host 侧没拿到心跳。

---

## 7. 尚未查清的部分（供后续）

1. **触发条件未知**：3 次 alma10 冷启动里 2 次故障（长短不一）、mint 完全正常；两台 VM 的 `tools.*` 配置一致。差异点在网络设备型号、3D/显存、是否挂了安装 ISO、`softPowerOff`/`cleanShutdown` 的持久化值等，但目前都只能是"结果"而非"原因"。
2. **为什么会脱节**：vmx 判定需要 guest 侧的 tools 存活信号（backdoor 路径的 heartbeat），而该 guest 的 `vmtoolsd` 有时不发。这个信号既不打日志、也无法从外部伪造，难以进一步定位；`open-vm-tools 13.0.10` 与 Fusion 26 的组合是否相关尚无证据。
3. **自发恢复的触发者**：08:19:29 前后主机侧没有任何 Tools 日志，guest 侧只有 `dnf-makecache.timer` 在约 1 分钟前跑过（无法证明因果）；guest 侧 `vmtoolsd` 也没有重启。唯一的已知事实是"它会自己好"。
4. **restart vmtoolsd 的有效性**：需要在故障态下才能验证，属于下一次复现时该做的实验。

---

## 8. 附录

### A. 用到的命令

```bash
# 主机侧判据
vmrun="/Applications/VMware Fusion.app/Contents/Public/vmrun"
VMX=~/Virtual\ Machines.localized/alma10.vmwarevm/Alma10.vmx
"$vmrun" -T fusion checkToolsState   "$VMX"
"$vmrun" -T fusion getGuestIPAddress "$VMX"

# guest 侧（ssh victim@192.168.7.141）
systemctl is-active vmtoolsd vgauthd
systemctl show vmtoolsd -p MainPID,NRestarts,ActiveEnterTimestamp
rpm -V open-vm-tools
journalctl -b -u vmtoolsd --no-pager
vmware-toolbox-cmd -v
vmware-rpctool "info-get guestinfo.ip"      # 验证 backdoor RPC 通
```

### B. 日志位置

| 内容 | 路径 |
|---|---|
| vmx 日志（含 Tools 状态机、GuestRpc、Vix 连接） | `<VM>.vmwarevm/vmware.log`（历史轮转为 `vmware-0.log`…） |
| 每次 `vmrun` 的 VIX 客户端日志 | `~/Library/Logs/VMware/vmware-vix-<pid>.log` |
| Fusion 清单（含 `paused` 等状态） | `~/Library/Application Support/VMware Fusion/vmInventory` |
| Fusion Services（首次使用时落盘） | `/Library/Application Support/VMware/VMware Fusion/Services/` |
| 本机 NAT DHCP 租约 | `/var/db/vmware/vmnet-dhcpd-vmnet8.leases` |

### C. 关键日志行原文

```
# 故障态（07:57 冷启动）：心跳从未收到
Tools: [AppStatus] Last heartbeat value 0 (never received)
Tools: [RunningStatus] Last heartbeat value 0 (never received)
Tools: Changing running status: 0 => 2.
Tools: Changing running status: 2 => 1.

# 正常态（07:40 冷启动 / mint）：
Tools: Running status rpc handler: 0 => 1.
Tools: Changing running status: 0 => 1.
Tools: [RunningStatus] Last heartbeat value 1 (last received 0s ago)

# locale 告警的确证（vmware-vix-*.log）
Msg_SetLocaleEx: HostLocale=UTF-8 UserLocale=en
DictionaryLoad: Cannot open file "/Applications/VMware Fusion.app/Contents/Library/messages/en/vmware.vmsg": No such file or directory.
```

### D. 复现/观测脚本

临时脚本（本次使用，位于 `/tmp`，可按需重跑）：

- `/tmp/alma_boot_probe.sh` → 软关机 + 开机 + 每 10s 采样，日志 `/tmp/alma_boot_probe.log`
- `/tmp/alma_resume_probe.sh` → suspend(hard) + resume + 每 2s 采样，日志 `/tmp/alma_resume_probe.log`
- `/tmp/alma_vmtools_watch.sh` → 每 2s 采样、检测到翻转即退出，日志 `/tmp/alma_vmtools_restart.log`

---

## 9. 附：2026-10-10 winser2019——Tools 未安装是同一症状的另一根因

alma10 之外，`vm ip` 拿不到 IP 还有另一种完全不同的病因：**guest 里从来没装过 VMware Tools**。现象与本文档第 2 节几乎一样，容易误判成 host 侧卡住；本次实例记录如下，供下次先做区分。

**现象**：`vm up` 成功，但 `vm ip` 失败、`vm ip -w` 永久挂起、`vm down`（stop soft）干等（vmware.log 里每分钟一次 `GuestRpcSendTimedOut`）。
**与 alma 故障的区分**：`vm status` 的 Tools 列是 **`未知`**（alma 是 `已安装`）；`checkToolsState` 返回 `unknown`（rc=254）。

**host 侧判据（分钟级）**：
- vmx 日志自报 `VMXVmdb_SetToolsVersionStatus: 'noTools'`，且全程没有 `tools.set.versiontype`、没有 heartbeat（alma 故障至少收到过 heartbeat）
- guest 网络侧证据：ARP 表里有 guest（静态 IP，所以 DHCP 租约文件里反而查不到）、ping 通、SMB/WinRM/RPC 端口开——**guest 本身健康，只是没有 Tools**；CPU/磁盘高是 Defender 首扫，与故障无关
- vmx 里 `softPowerOff=FALSE`/`cleanShutdown=FALSE`：Tools 握手从未完成的结果，非原因

**guest 侧判据（一句话实锤）**：ssh 进 guest（本例 `administrator@192.168.7.148`，静态 IP）后无 VMTools 服务、无 VMware 卸载项、`C:\Program Files\VMware\VMware Tools\vmtoolsd.exe` 不存在。

**处置**：`vmrun -T fusion installTools <vmx>` 挂载 Tools ISO（headless 不会自启安装器，guest 里看到 D: 有介质但无进程），再经 ssh 在 guest 内跑 `D:\setup.exe /S /v"/qn REBOOT=R"` 静默安装（约 1 分钟；安装器退出码 194 但实际成功，以文件和服务为准）。服务起来后 host 侧数秒内 `checkToolsState=running`，`vm ip` 恢复。不需要 Tools 的干净关机路径：ssh 进 guest 执行 `shutdown /s /t 0`。

**对 vm.zsh 的影响**：0.1.8 起 `vm ip` 失败提示区分 notInstalled/unknown（不再无脑建议 `-w`）；`vm down` 在 VM 运行而 Tools 未安装/状态未知（`notInstalled`/`unknown`）时快速失败（预检 `checkToolsState`），不再陪 vmrun 干等。0.1.9 修正：`installed` 不拦——查询卡在 `installed` 但 guest 内心跳正常的实例（见下）soft 关机很可能可用，拦截是 regression。

**第三种状态：查询卡在 `installed`，但 guest 内 Tools 心跳正常（2026-10-11 kali）**
kali 冷启动 13 分钟后 `checkToolsState` 仍是 `installed`，但 vmx 日志里 `tools.set.versiontype` 照收、`[RunningStatus] Last heartbeat value 1`、无 heartbeat timeout——即 alma 文档 4.3 的判据（收到心跳）成立而查询依旧不翻 `running`。这修正了 alma 文档「只有 vmx 收到 heartbeat，checkToolsState 才可用」的模型：**心跳正常也可能查询卡死**。因此 `installed` 不能当作「soft 关机/-w 一定不可用」的判据，只能当作「未确认」；vm.zsh 的 `vm down` 预检据此只拦 `notInstalled`/`unknown`。**闭环实测（2026-10-11）**：该状态下 `vmrun stop soft` 成功（rc=0，kali 干净关机）——放行是对的。
