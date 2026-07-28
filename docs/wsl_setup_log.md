# WSL2 环境搭建日志 — SoloCo 受支持平台测试

**目的**：SoloCo 官方不支持 Windows 原生，需在 WSL2 (Ubuntu) 上重建一套干净的测试环境。
本文件记录搭建全过程的每一个报错、根因判断、解法与耗时，作为后续测试的环境基线与素材。

**记录人**：刘逸
**开始日期**：2026-07-28

---

## 0. 宿主机基线

| 项 | 值 |
|---|---|
| OS | Windows 10 Pro 22H2，Build 19045.2006 |
| CPU | 13th Gen Intel Core i5-13500H |
| RAM | 15.6 GB |
| C: 可用空间 | 168.9 GB |
| 当前用户 | `<user>`（属于本地 Administrators 组，可 UAC 提权） |
| 系统代理 | Clash Verge — `verge-mihomo` 监听 `127.0.0.1:7897` |
| WinINET 代理 | ProxyEnable=1, ProxyServer=127.0.0.1:7897 |

### 虚拟化前置条件核查

| 检查项 | 结果 | 判断 |
|---|---|---|
| CPU `VirtualizationFirmwareEnabled` | True | BIOS 里 VT-x 已开，无需进 BIOS |
| CPU `SecondLevelAddressTranslation` | True | 支持 SLAT，满足 WSL2 要求 |
| `HypervisorPresent` | **False** | 当前没有 hypervisor 在跑，符合"功能未启用"的预期 |
| Build ≥ 18362 | 19045 ✓ | 满足 WSL2 最低版本 |

---

## 1. 问题 #1：`wsl.exe` 存在但只是存根

### 现象

首次诊断执行 `wsl --status` 与 `wsl --list --verbose`，两条命令都以 **exit code 1** 失败，
并且只回吐了一份极短的帮助文本：

```
用法: wsl.exe [参数]
参数：
        --install <选项>
        --list, -l [选项]
        --help
```

### 根因判断

正常安装完成的 WSL，`wsl --help` 会列出 `--set-default-version` / `--shutdown` /
`--set-version` / `--unregister` 等几十个参数。这里只有 3 个，说明：

`C:\Windows\System32\wsl.exe` 是 Windows 10 自带的**引导存根（stub）**，
它的唯一作用是在 WSL 可选功能未启用时提供 `--install` 入口。
即：**WSL 根本没装**，而不是"装了但坏了"。

`wsl --status` 报错不是 bug，是这个参数在存根里压根不存在。

> 教训：不能只看 `wsl.exe` 存不存在就判定 WSL 已安装。
> 判据应该是**可选功能的 InstallState**，不是可执行文件是否存在。

### 验证

```powershell
Get-WmiObject Win32_OptionalFeature -Filter "Name='Microsoft-Windows-Subsystem-Linux' or Name='VirtualMachinePlatform' or Name='HypervisorPlatform'"
```

| Feature | InstallState |
|---|---|
| Microsoft-Windows-Subsystem-Linux | 2 (Disabled) |
| VirtualMachinePlatform | 2 (Disabled) |
| HypervisorPlatform | 2 (Disabled) |

三项全部 Disabled，确认根因。

### 解法

用 DISM 显式启用两个功能。**没有用 `wsl --install` 一键装**，理由：
一键命令把"启用功能 / 装内核 / 装发行版"三件事糅在一起，任何一步失败都只回一个笼统错误，
不利于定位。分步做每一步都有独立的退出码可查。

需要管理员权限（当前 Claude Code 进程非提权），通过 `Start-Process -Verb RunAs` 触发 UAC。

```powershell
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
```

`/norestart` 是刻意加的 —— 不让 DISM 自己重启机器，把重启时机留给自己控制。

### 结果

```
操作成功完成。
=== DISM_EXIT_WSL=3010 ===
操作成功完成。
=== DISM_EXIT_VMP=3010 ===
--- post state ---
Microsoft-Windows-Subsystem-Linux = 1
VirtualMachinePlatform = 1
```

**退出码 3010 不是失败**，它是 `ERROR_SUCCESS_REBOOT_REQUIRED`：操作成功，但需重启生效。
如果脚本里简单地用 `if ($LASTEXITCODE -ne 0) { throw }` 判断，会误报为失败 —— 这是自动化装机脚本里
一个很典型的坑，值得记下来。

InstallState 已从 `2 (Disabled)` 变为 `1 (Enabled)`，但**重启前 WSL 仍不可用**
（内核驱动 `lxss` 尚未加载）。

**耗时**：提权 DISM 全程 10.9 秒。

### 状态：✅ 已解决（重启后生效）

重启后复验：

| 检查项 | 重启前 | 重启后 |
|---|---|---|
| `HypervisorPresent` | False | **True** |
| `LxssManager` 服务 | 不存在 | **Running** |
| `wsl --help` 参数数量 | 3 个（存根） | 完整参数表 |

---

## 2. 问题 #2：`wsl.exe` 输出全是乱码

### 现象

```
؞��Hr,g�2
 �(u�N  L i n u x   �v  W i n d o w s   P[�|�~�Q8h�S�NO(u...
```

### 根因判断

`wsl.exe` 的输出编码是 **UTF-16LE**，而 PowerShell 按当前 `[Console]::OutputEncoding`
（中文系统默认 GBK/936）去解码，于是每个 UTF-16 字符被拆成两个字节乱解释。
字母之间夹空格（`L i n u x`）是 UTF-16LE 被当单字节编码读的典型特征 —— ASCII 字符的高位字节 0x00
被当成了空格/空字符。

### 走过的弯路

1. 设 `$env:WSL_UTF8=1` —— **无效**。这个环境变量是较新版本 WSL 才支持的，
   Win10 内置的这版不认。
2. 设 `[Console]::OutputEncoding = [Text.Encoding]::Unicode` —— **反而更糟**。
   它确实让 PowerShell 正确解码了 `wsl.exe`，但同时也让 PowerShell **自己的**输出变成 UTF-16，
   外层再按 UTF-8 读又乱一次。改了一个环节，破坏了另一个环节。

### 解法

不在管道里解码，改成**重定向到文件再按指定编码读**，两个环节解耦：

```powershell
cmd /c "wsl --status > out.txt 2>&1"
Get-Content out.txt -Encoding Unicode
```

后续所有 `wsl.exe` 输出的采集都走这个方式。

> 这条对测试岗有实际意义：如果测试脚本要抓 `wsl.exe` 的输出做断言，
> 直接管道拿到的是乱码，字符串匹配会静默失配。

---

## 3. 问题 #3：`wsl --update` 秒失败 —— 根因是 Windows Update 被策略封死

### 现象

`wsl --status` 正常读出后：

```
默认版本：2

适用于 Linux 的 Windows 子系统内核可以使用"wsl --update"手动更新，但由于你的系统设置，无法进行自动更新。
 若要接收自动内核更新，请启用 Windows 更新设置:"在更新 Windows 时接收其他 Microsoft 产品的更新"。
 有关详细信息，请访问 https://aka.ms/wsl2kernel。

找不到 WSL 2 内核文件。要更新或还原内核，请运行 'wsl.exe --update'。
```

于是提权执行 `wsl --update`：

```
正在检查更新...

无法启动服务，原因可能是已被禁用或与其相关联的设备没有启动。

=== WSL_UPDATE_EXIT=-1 elapsed=0.1s ===
```

### 根因判断

**关键线索是耗时 0.1 秒**。如果是代理/网络问题，必然要等到 TCP 或 TLS 超时，
至少几秒到几十秒。0.1 秒说明**根本没发起网络请求**就失败了。
所以第一直觉「是不是 Clash 代理的问题」可以直接排除 —— 这个判断省掉了一整轮无用的代理排查。

报错文本对应 Win32 错误码 **1058 `ERROR_SERVICE_DISABLED`**。查服务状态：

| 服务 | Status | StartMode |
|---|---|---|
| `wuauserv`（Windows Update） | Stopped | **Disabled** |
| `DoSvc`（传递优化） | Stopped | **Disabled** |
| `BITS` | Stopped | Manual |
| `UsoSvc` | Running | Auto |

`wsl --update` 在 Win10 上是**通过 Windows Update 通道**拉取内核的，`wuauserv` 被禁用 → 直接 1058。

继续查组策略 `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`：

```
DisableWindowsUpdateAccess                   : 1
DoNotConnectToWindowsUpdateInternetLocations : 1
WUServer                                     : <一个不可达的内网主机名>
AU\NoAutoUpdate                              : 1
AU\UseWUServer                               : 1
```

本机被配置为**只从一台内网 WSUS 服务器取更新**（`UseWUServer=1` + `WUServer`），
而该主机名在当前网络里解析不到；同时 `DoNotConnectToWindowsUpdateInternetLocations=1`
禁止回退到微软的公网更新源。两者叠加，更新通道完全断开。

结合 `wuauserv` 被设为 Disabled，`wsl --update` 无路可走。

> 这类配置在受管终端上很常见。对测试工作的意义是：
> **不能假设目标机器能访问 Windows Update**，凡是依赖该通道的安装步骤都需要准备离线/直连的替代路径。

### 影响面（不止 WSL 内核）

这套策略同时会影响 **Microsoft Store**，而 `wsl --install -d Ubuntu` 默认走 Store 分发。
所以这个坑很可能在下一步「装 Ubuntu 发行版」时**再次撞上**，需要提前准备绕过方案。

### 候选解法

| 方案 | 做法 | 代价 |
|---|---|---|
| A. 绕过 WU | 直接从微软官方 Azure Blob 下载 `wsl_update_x64.msi`（16.31 MB），`msiexec` 安装 | 不动系统任何配置；只解决内核，Store 问题仍需另解 |
| B. 恢复 WU | 临时启用 `wuauserv`、临时改 WSUS 策略，跑 `wsl --update`，事后还原 | 改动系统更新配置；可能触发大量积压更新；但能一并解决 Store |

已验证方案 A 的下载源可达：

```
https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi
status=200   size=17104896 bytes (16.31 MB)
```

### 采用方案 A

下载并校验：

```
期望 SHA256: 2a790896740b14d637dbdc583cce1ba081ac53b9e9cdb46dc09a2f73abbd9934
实际 SHA256: 2a790896740b14d637dbdc583cce1ba081ac53b9e9cdb46dc09a2f73abbd9934
校验: 一致
Authenticode Status : Valid
SignerCN            : CN=Microsoft Corporation, ...
```

> 证书 `NotAfter` 是 2021-12-03（已过期）但 Status 仍为 Valid —— 因为有时间戳反签名，
> 签名时刻证书有效即可。不懂这点容易误判成"签名失效"。

`msiexec /i ... /qn /norestart` → `MSIEXEC_EXIT=0`，2.1 秒。
内核落地 `C:\Windows\System32\lxss\tools\kernel`（70.7 MB）。

复验 `wsl --status`：**默认版本 2 / 内核版本 5.10.16 / 退出码 0**。

### 状态：✅ 已解决

**耗时**：诊断 + 下载 + 安装约 4 分钟。

---

## 4. 问题 #4：`wsl --install -d Ubuntu` 失败 `0x80072efd`

### 现象

```
正在下载: Ubuntu
安装过程中出现错误。分发名称: 'Ubuntu' 错误代码: 0x80072efd
elapsed=2.6s
```

`0x80072efd` = `ERROR_INTERNET_CANNOT_CONNECT`。

### 排查过程（对照实验）

这次耗时 2.6 秒，符合网络失败特征，所以确实要查网络。但**不能想当然认为是代理**，
做了个对照实验，用 .NET `HttpWebRequest` 分别强制直连和强制走 Clash：

| 路径 | 结果 |
|---|---|
| 不走代理（直连） | OK 200，1.43s |
| 走 Clash 7897 | OK 200，1.12s |

**两条路都通**。所以微软的 blob 存储不是问题所在。

### 根因判断

Ubuntu 发行版**不是**从 `wslstorestorage.blob` 拉的，它走 Microsoft Store 的分发通道
（`*.delivery.mp.microsoft.com`）。而问题 #3 里发现的那套策略
（`DoNotConnectToWindowsUpdateInternetLocations=1` + `DoSvc` 被禁用）正好把这条通道掐断。
探测 `tlu.dl.delivery.mp.microsoft.com` 也确实失败（SSL/TLS 通道无法建立）。

即：**问题 #3 和 #4 是同一个根因的两次发作**，正如当时预判的那样。

### 解法：改用 `wsl --import` + 官方 rootfs

完全绕开 Store / Delivery Optimization / Windows Update 三条通道。
这是锁定环境（企业内网、策略受限机器）里的标准做法。

找源的过程有波折 —— 先猜的四个 URL 全是 404，改为直接抓目录索引才定位到：

```
https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-24.04lts.rootfs.tar.gz
```

对比另一条可行路径 `aka.ms/wslubuntu2204`（→ `Ubuntu2204-221101.AppxBundle`，**1065 MB**），
rootfs 只有 **340 MB**，且 Canonical 提供 `SHA256SUMS` 可校验，选它。

```
下载: 340.2 MB  耗时 5.7s  均速 59.58 MB/s
SHA256 校验: 一致
wsl --import Ubuntu-24.04 C:\WSL\Ubuntu-24.04 <tar> --version 2   →  exit=0, 11.1s
```

首次启动 **0.6 秒**：

```
Linux <hostname> 5.10.16.3-microsoft-standard-WSL2 #1 SMP Fri Apr 2 22:23:49 UTC 2021 x86_64
PRETTY_NAME="Ubuntu 24.04 LTS"
16 CPU / 12 GiB 可用内存
```

### 状态：✅ 已解决

---

## 5. 预判落空：Clash 代理并没有挡路

### 原始预判

> WSL2 是独立虚拟网卡，不走 Windows 系统代理，`curl`/`npm` 很可能超时。

### 实测结果

WSL 内部对五个关键端点做直连 / 直连-IPv4 / 走宿主机代理三组对照：

| 端点 | 直连 | 走 `172.28.32.1:7897` |
|---|---|---|
| archive.ubuntu.com | 200 / 2.6s | 200 / 0.5s |
| registry.npmjs.org | 200 / 2.0s | 200 / 0.5s |
| raw.githubusercontent.com | 200 / 1.3s | 200 / 0.5s |
| nodejs.org | 200 / 3.2s | 200 / 0.9s |
| api.anthropic.com | 403 / 0.6s | 404 / 0.7s |

**两条路都通。** 预判不成立。

### 为什么不成立

最初诊断用的是 `Get-NetTCPConnection -State Listen -LocalPort 7897`，它只回了一行
`LocalAddress = 127.0.0.1`，据此判断 mihomo 只绑回环。改用 `netstat -ano` 看到的是全貌：

```
TCP    0.0.0.0:7897    0.0.0.0:0    LISTENING    15828
TCP    [::]:7897       [::]:0       LISTENING    15828
```

mihomo 实际监听 **`0.0.0.0`** —— Clash Verge 的「允许局域网连接」是开着的，
所以 WSL 能通过宿主机 IP 够到它。

> 教训：`Get-NetTCPConnection` 在多地址绑定场景下给出的视图不完整，
> 判断监听范围应以 `netstat -ano` 为准。一个不完整的观测直接导致了一个错误的预判。

另外确认宿主机**没有 TUN 网卡**（只有 Realtek / WLAN / 蓝牙 / vEthernet(WSL)），
Clash 处于系统代理模式而非 TUN 模式。

### 应对

虽然直连可用，但走代理快 4–5 倍。写了 `/etc/profile.d/wsl-proxy.sh`，提供
`proxy_on` / `proxy_off` 两个命令，要点：

* **宿主机 IP 动态取**（`ip route` 解析），因为 WSL2 每次重启宿主机 IP 都会变，写死必然失效
* **先探测端口可达再导出变量**，避免 Clash 关闭时代理变量残留导致全网瘫痪

---

## 6. 问题 #6：自己写的脚本踩 bash 坑（记录下来避免再犯）

```
/etc/profile.d/wsl-proxy.sh: line 10: no_proxy: unbound variable
```

原写法：

```bash
export no_proxy="localhost,127.0.0.1,::1" NO_PROXY="$no_proxy"
```

bash 对**同一条命令**的所有参数先做词展开、再做赋值，所以 `$NO_PROXY` 取 `$no_proxy` 时
它还没被赋值。平时无害，配上调用方的 `set -u` 就直接报错退出。

拆成两条 `export` 即可。修完用 `bash -n` 做语法检查、再在 `set -u` 下复验通过。

---

## 7. 问题 #7：Windows 侧残留污染 WSL 的 PATH ⚠️ 最重要的一个

### 现象

安装完成后执行 `soloco start --help`：

```
/mnt/c/Users/<user>/AppData/Roaming/npm/soloco: 15: exec: node: not found
```

`soloco` 没解析到刚装的 Linux 版本，而是解析到了 **Windows 侧的 shim**。

### 根因

`/etc/wsl.conf` 的 `interop.appendWindowsPath=true`（默认值）会把 Windows 的整个 PATH
注入 WSL。本机 PATH 里包含 `/mnt/c/Users/<user>/AppData/Roaming/npm`，
而该目录里有上一轮 Windows 安装留下的：

```
claude   claude.cmd   claude.ps1
soloco   soloco.cmd   soloco.ps1
node_modules/
```

npm 生成的 `soloco`（无扩展名那个）是 **POSIX sh 脚本**（本意是给 Cygwin/MSYS 用的），
WSL 会毫不犹豫地执行它，内容是：

```sh
exec node --disable-warning=ExperimentalWarning "$basedir/node_modules/@soloco/client/bin.mjs" "$@"
```

即：**在 WSL 里执行 Windows 那一份 SoloCo 的代码**。

### 为什么这个必须解决

* 登录 shell 里 nvm 会把自己的 bin 排在前面，看起来一切正常
* 但**非登录、非交互 shell**（`wsl -d X -- cmd`、cron、CI、测试脚本）不加载 nvm，
  于是 PATH 里第一个 `soloco` 就是 Windows 那份
* 测试脚本恰恰运行在这种 shell 里 —— 这会造成**静默的、看起来正常的错误结果**

对方明确要求 WSL 这轮是「在受支持平台上的全新测试」。如果测试脚本悄悄跑到了 Windows 那份
代码上，整轮结论作废且极难发现。这属于必须消除的环境污染。

### 解法

1. `/etc/wsl.conf` 设 `appendWindowsPath=false`，彻底断开宿主机 PATH 注入
   （`interop.enabled` 保持 `true`，仍可用完整路径调用 Windows 程序）
2. 新增 `/etc/profile.d/nvm.sh`，登录 shell 自动加载 nvm
3. 把工具链软链到 `/usr/local/bin`，使**非登录 shell 也能稳定解析**，且必然指向 Linux 二进制
4. 附带 `/usr/local/sbin/relink-node-tools`，将来 nvm 换版本后重建软链

**没有删除** Windows 侧那些残留文件 —— 那是宿主机上的东西，只做记录不动它。

### 复验

| Shell 类型 | 处理前 | 处理后 |
|---|---|---|
| 登录 (`bash -l`) | Linux 版（侥幸正确） | Linux 版 |
| 非登录 (`bash -c`) | **Windows 版** ❌ | Linux 版 ✅ |
| PATH 中 `/mnt/*` 条目 | 21 条 | **0 条** |

```
node     /usr/local/bin/node     v24.18.0
npm      /usr/local/bin/npm      11.16.0
soloco   /usr/local/bin/soloco   0.2.1
claude   /usr/local/bin/claude   2.1.220
```

### 状态：✅ 已解决

---

## 8. 观察：npm 11 默认拦截 postinstall 脚本

安装时 npm 给出：

```
npm warn allow-scripts 1 package has install scripts not yet covered by allowScripts:
npm warn allow-scripts   @anthropic-ai/claude-code@2.1.220 (postinstall: node install.cjs)
npm warn allow-scripts   @soloco/client@0.2.1 (postinstall: node postinstall.mjs)
```

npm 11 起默认不执行依赖的安装脚本（供应链安全加固）。
两个包的 `postinstall` **都没有运行**。

实测影响：**目前没有可观察到的功能异常** —— `soloco --version`、`soloco doctor`、
`soloco start`、`claude --version` 均正常。但这是环境基线的一部分，
如果后续出现"官方文档说应该有但实际没有"的行为，这里是第一个要回查的点。

> 顺带核实：`claude` 软链最终指向 `.../bin/claude.exe`，文件名有误导性。
> `file(1)` 确认它是 **ELF 64-bit LSB executable, x86-64, for GNU/Linux** —— 是正常的
> Linux 原生二进制，不是被 Windows 的 exe 串了。

---

## 9. Node 安装

刻意**不用 apt**（源里的 Node 版本远低于 SoloCo 要求的 22.5），改用 nvm：

```
nvm install --lts   →  Node v24.18.0, npm 11.16.0
checksum 校验: Checksums matched!
版本检查: PASS  (>= 22.5 要求满足)
which -a node → 只有 /home/liuyi/.nvm/... 一个，未被 Windows 侧 node.exe 抢占
```

---

## 10. SoloCo 包的选择（有坑）

npm 上有两个都注册了 `soloco` 命令名的包：

| 包 | latest | `engines.node` | 最近发布 | 说明 |
|---|---|---|---|---|
| `@soloco/cli` | 0.3.1-canary.0 | `>=20` | 2026-06-20 | 依赖 embedded-postgres / drizzle，偏服务端 |
| **`@soloco/client`** | **0.2.1** | **`>=22.5.0`** | **2026-07-27** | 本地客户端 daemon，命令入口 `soloco` |

判定依据：作业里说的「SoloCo 要求 ≥22.5」与 `@soloco/client` 的 `engines.node` **精确吻合**，
且 0.2.1 正是要测的版本号。选 `@soloco/client@0.2.1`。

⚠️ **两个包都会安装名为 `soloco` 的命令，同时全局安装会互相覆盖。** 环境里只装了 `@soloco/client`。

另注：`@soloco/cli` 的 `latest` 标签指向 `0.3.1-canary.0`，但 `canary` 标签已到
`0.3.2-canary.5` —— 全部版本都是 canary 预发布，没有正式版本。

---

## 11. 当前环境状态

### 版本基线

| 组件 | 版本 |
|---|---|
| WSL | 内置版（Win10 19045 自带），内核 5.10.16.3-microsoft-standard-WSL2 |
| 发行版 | Ubuntu 24.04 LTS (noble)，WSL VERSION 2 |
| 安装位置 | `C:\WSL\Ubuntu-24.04` |
| Node | v24.18.0 (nvm) |
| npm | 11.16.0 |
| Claude Code | 2.1.220 |
| SoloCo | `@soloco/client` 0.2.1 |
| 默认用户 | `liuyi`（sudo 组，当前配置为免密 sudo） |

### `soloco doctor` 结果

```
Soloco doctor
CLI version: 0.2.1
PASS  Node v24.18.0 satisfies >=22.5.0
PASS  daemon is running at http://localhost:8751 (version 0.2.1)
PASS  local UI is served by the daemon
FAIL  runtime unavailable: codex (spawn codex ENOENT)
FAIL  runtime login required: claude. Log in to that runtime, then run soloco doctor again.
```

### runtime 矩阵

```
RUNTIME   AVAILABLE  VERSION                LOGIN     REASON
codex     no         -                      -         spawn codex ENOENT
claude    yes        2.1.220 (Claude Code)  required  -
kimi      no         -                      -         not registered — adapter not yet wired
qwen      no         -                      -         not registered — adapter not yet wired
opencode  no         -                      -         not registered — adapter not yet wired
```

### 附带验证

* daemon 监听 WSL 内 `127.0.0.1:8751`
* WSL 内访问本地 UI：**HTTP 200，5 ms**
* **从 Windows 浏览器访问 `http://localhost:8751`：HTTP 200，1166 bytes**
  —— WSL2 的 localhost 自动转发工作正常，宿主机上可以直接开 UI

### 剩余两项 FAIL 的性质

两项都**不是环境搭建问题**，都需要账号凭据：

1. `claude` runtime 需要交互式登录（浏览器 OAuth）—— 必须本人操作
2. `codex` runtime 需要另外安装 OpenAI Codex CLI，且同样需要 OpenAI 账号

---

## 附：待办 / 未决项

* [ ] Claude Code 登录（本人操作）
* [ ] 决定是否安装 codex runtime
* [ ] 免密 sudo 目前是打开的（`/etc/sudoers.d/90-liuyi`）。如需改为密码保护：
      `wsl -d Ubuntu-24.04 -u root passwd liuyi` 设密码后删除该文件
* [ ] Windows 侧 `AppData\Roaming\npm\` 中的 soloco/claude 残留未清理（只记录未删除）
