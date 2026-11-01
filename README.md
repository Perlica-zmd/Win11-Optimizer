# DefenderTune · Win11 优化工具

**中文** | [English](#english)

Windows Defender 性能调节小工具(控制台菜单版),适用于 Windows 10 / 11。

> **English summary** — A small console tool that makes Microsoft Defender stop competing
> with your foreground work. It does **not** disable Defender, real-time protection or
> 安全中心. It lowers scan CPU priority, moves scheduled scans to the night, turns off
> catch-up scans, and manages exclusions. Every change is snapshotted first and can be
> reverted with one menu item, and an optional scheduled task notifies you when Windows
> silently changes a setting back. Full English notes are at the [bottom](#english).

**它不关闭 Windows 安全中心,也不关闭实时防护。** 它只解决一个具体问题:
Defender 的计划扫描和实时监控抢 CPU、抢磁盘,把前台程序拖卡。

## 用法

1. 双击 `Run.cmd`(会自动请求管理员权限),或右键「以管理员身份运行」。
2. 不用特意先存快照:任何会改设置的操作(A/B/C 三档)执行前,工具都会检查快照,
   没有就自动存一份;存不下来就取消这次修改。想手动存或覆盖,用菜单 `5`。
3. 按需应用 A 档 / B 档。
4. 想撤销,选 `6` 一键还原到快照。

命令行方式:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\DefenderTune.ps1
```

## 三档设置

### A 档:低干扰预设(不影响防护强度)

| 设置 | 取值 | 作用 |
| --- | --- | --- |
| `EnableLowCpuPriority` | true | 扫描走低 CPU 优先级 |
| `ScanAvgCPULoadFactor` | 20 | 扫描 CPU 上限从默认 50% 降到 20% |
| `ScanScheduleTime` | 03:00 | 计划扫描挪到夜间 |
| `DisableCatchupQuickScan` / `DisableCatchupFullScan` | true | 关掉错过后的补扫(经常是"莫名在后台扫"的真凶) |

### B 档:排除项(效果最大)

排除目录 / 进程 / 扩展名。实时监控的开销跟受监控的文件量成正比,排除掉
`node_modules`、`build`、`.git`、虚拟机镜像、游戏目录之后,CPU 和磁盘 I/O 都会明显下降。

代价是被排除的路径不再受实时防护,所以只排除你确定安全的目录。

### C 档:会降低防护的开关

云保护、首次见到即阻止、计划扫描总开关。全部是双向开关,关掉之后可以在同一个菜单里恢复。
每一项都需要输入 `YES` 二次确认。

## 关于"内存"

说清楚一点:Defender 常驻进程 `MsMpEng.exe` 的内存占用(通常 200–500 MB)靠这些设置
基本降不下来。这个工具降低的是 **CPU 占用、磁盘 I/O 和扫描时的卡顿感**,不是内存数字。
对外宣传时建议就写"降低扫描对前台的影响",别承诺"省内存"。

## 设置漂移监控(被改回时弹通知)

Defender 的设置会被 Windows 功能更新、组策略、或别的"优化工具"改回去。这一项就是防这个:

1. 菜单 `7` → `1` 把当前状态记为期望值。
2. 菜单 `7` → `3` 安装自动监控任务(计划任务 `DefenderTune-DriftWatch`)。
3. 之后登录时 + 每 6 小时检查一次;发现被改动就弹 Windows 通知,写明哪几项、从什么变成了什么。
4. 同一个漂移 12 小时内只提醒一次,不会反复骚扰。

几个刻意的设计:

- 任务以**当前用户**身份、**Interactive** 登录类型运行。如果用 SYSTEM 或「不管用户是否登录」,
  会落到 Session 0,通知永远不可见——这是这类工具最常见的坑。
- 脚本不需要管理员权限:`Get-MpPreference` 这 9 项普通用户就能读。
- 「检测到漂移」不会让任务显示为失败:脚本正常退出 0,结果写日志。
  把漂移映射成非 0 退出码会让任务历史永远是红色,反而误导。
- 通知被系统设置屏蔽时,`DefenderTune.drift.log` 里仍然有记录。

## 可逆性

- 所有改动都是 `Set-MpPreference` 的常规设置,不碰篡改防护,不修改服务。
- 任何会改设置的操作执行前都会检查快照;没有就自动用 `DefenderTune.snapshot.json` 存一份,
  存失败则取消本次修改。快照存在时不覆盖,保留最初那份基线。
- 选 `6` 会把快照里的值逐项写回;快照之后新增的排除项会列出来,问你要不要一并删掉。
- 如果快照里没有记录某一类排除项(比如手工重建的),还原时该类保持现状,不会被清空。
- 万一快照文件丢了,`Get-MpPreference` 可以随时查当前值,手动改回默认即可
  (默认值:`ScanAvgCPULoadFactor=50`、`EnableLowCpuPriority=false`、
  `MAPSReporting=2`、`ScanScheduleDay=0`)。

## 文件

- `DefenderTune.ps1` — 主程序(菜单)
- `DefenderTune-Watch.ps1` — 漂移监控脚本(无界面,计划任务调用)
- `Run.cmd` — 双击启动器(自动提权)
- `DefenderTune.snapshot.json` — 还原用快照,首次改动时自动生成
- `DefenderTune.expected.json` — 期望值基准,漂移监控用
- `DefenderTune.drift.log` — 每次检查的日志
- `DefenderTune.drift.state` — 重复通知抑制状态

---

## English

**DefenderTune** is a small console tool for Windows 10 / 11 that stops Microsoft Defender
from competing with whatever you are doing.

It does **not** disable Defender, the Security Center, or real-time protection. It addresses
one specific problem: scheduled scans and real-time monitoring take CPU and disk time away
from foreground programs.

- **Preset A - low impact.** Low CPU priority for scans, scan CPU cap 50% -> 20%, scheduled
  scan moved to 03:00, catch-up scans disabled (a common cause of "it scanned for no reason").
- **Preset B - exclusions.** The cost of real-time protection scales with how many files are
  watched. Excluding 
ode_modules, uild, .git, VM images and game folders measurably
  reduces CPU and disk I/O. Excluded paths lose real-time protection, so only exclude what
  you trust.
- **Preset C - weakens protection.** Cloud protection, block-at-first-sight, the scheduled
  scan master switch. Every one is a toggle with a typed `YES` confirmation.

Every change is written to `DefenderTune.snapshot.json` before it is applied and reverted by
menu item `6`. An optional scheduled task (`DefenderTune-DriftWatch`) checks the settings
on logon and every 6 hours and posts a Windows notification when something changed them back.

Run it with `Run.cmd` (asks for elevation) or:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\DefenderTune.ps1
```

Honest caveat: this does not reduce `MsMpEng.exe` memory usage (200-500 MB). It reduces CPU
load, disk I/O and the stutter during scans - not the memory number.
