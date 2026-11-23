# K40 多虚拟屏并发工具包

用 scrcpy 的 **虚拟显示（virtual display）** 功能，在一台 Redmi K40 上同时开出多个互相独立的“手机屏幕”窗口；
每个窗口是 Android 系统里一个真实的独立 Display，可以各自用 adb 启动 App、点击、截图。

```
┌──────────┐ ┌──────────┐ ┌──────────┐
│ display 9│ │display 10│ │display 11│   ← 3 个 scrcpy 窗口
│ Settings │ │  Chrome  │ │ Contacts │   ← 每个窗口一个虚拟屏
└──────────┘ └──────────┘ └──────────┘
       同一台 K40（同一个 adb 连接）
```

> **本机已验证**：Redmi K40（alioth，M2012K11AC）+ LineageOS 24.0（Android 17 / SDK 37）+ scrcpy 5.0.1，
> 3 屏并发（display id 每次启动都会变，示例 75/76/77），指定屏 `am start --display N` 启动 App、
> 指定屏 `input -d N` 点击/滑动均已实测通过。效果截图：`run\demo-3screens.png`；并发上限见文末实测。

## 原理与硬性要求

- `scrcpy --new-display=720x1600/320` 会让手机创建一个**公共虚拟显示**，窗口关闭时该显示销毁。
- 每个虚拟屏对应一个独立的 scrcpy 进程，进程之间互不影响；同一个 adb 连接可以并发跑多个 scrcpy。
- **必须 Android 12（SDK 31）及以上**：LineageOS 19+、MIUI 13/14、原生 Android 12+ 都可以；
  Android 11 及以下没有创建公共虚拟屏的权限，`--new-display` 会直接失败。
- 工具包自带 scrcpy 5.0.1（含配套 adb 37.0.1），无需另外安装。

## 一、手机端一次性准备（LineageOS）

1. 设置 → 关于手机 → 连续点「版本号」7 次，打开开发者选项（LineageOS 在 设置 → 系统 → 开发者选项）。
2. 开发者选项里打开 **USB 调试**（LineageOS 没有 MIUI 那个「USB 调试（安全设置）」的限制）。
3. 用**能传数据的 USB 线**连接电脑，手机弹窗「允许 USB 调试吗？」点允许，勾选「一律允许」。

> 如果手机是 MIUI/HyperOS：路径是 设置 → 我的设备 → 全部参数 → 连点 MIUI 版本，然后在 更多设置 → 开发者选项
> 里同时打开「USB 调试」和「USB 调试（安全设置）」，否则 adb 的 `input` 点击会被拒绝。

验证：

```powershell
cd C:\Users\ac\Downloads\arf
.\scripts\Test-Environment.ps1
```

看到 `android : 13 (SDK 33)` 之类的输出即可继续。

### USB 一直连不上？改用无线调试

Android 11+（含 LineageOS）都支持无线调试，不插线也能跑 scrcpy：

1. 手机：开发者选项 → **无线调试** → 打开 → 点「使用配对码配对设备」，记下弹窗里的 `IP:端口` 和 6 位配对码。
2. 电脑：

```powershell
.\scripts\Connect-Wireless.ps1 -PairAddress 192.168.31.50:37123 -PairCode 123456
```

脚本会 `adb pair`，然后自动从 mDNS 找到 `_adb-tls-connect._tcp` 的地址并 `adb connect` 完成连接。
无线模式下建议加 `-Fps 24`，并让手机插着充电器。

## 二、同时开多个虚拟屏

```powershell
cd C:\Users\ac\Downloads\arf
.\scripts\Start-MultiScreens.ps1 -Count 3 -Apps com.android.settings,com.tencent.mm,com.taobao.taobao
```

- `-Count 3`：开 3 个窗口（1~9）。
- `-Apps`：依次在每个虚拟屏启动的包名，可省略；省略时屏幕是空的（或显示系统启动器）。
- 窗口会自动按 3 列平铺，每个窗口标题 `K40-S1`、`K40-S2`……
- 启动完成后会生成 `run\screens.json`，记录“第几屏 → displayId → 进程 PID”。

常用参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Width/-Height` | 720x1600 | 虚拟屏分辨率（不是窗口大小，是 Android 里真实的 display 尺寸） |
| `-Dpi` | 320 | 虚拟屏密度；320 时 App 认为是 360dp 宽的标准手机 |
| `-Fps` | 30 | 每屏帧率上限；3 屏并发建议 30，性能吃紧可降到 24 |
| `-WindowWidth/-WindowHeight` | 自动 | 窗口像素大小，0 表示按屏幕高度自动算 |
| `-Audio` | 关 | 只让第 1 屏转发声音（多屏同时采音在多数机型上会冲突） |
| `-KeepActive` | 关 | 阻止手机息屏 |
| `-KeepApps` | 关 | 关窗口时把 App 移到主屏而不是杀掉（`--no-vd-destroy-content`） |
| `-NoDecorations` | 关 | 虚拟屏不显示状态栏等系统装饰 |
| `-Serial` | 自动 | 多台设备时指定序列号 |
| `-DryRun` | 关 | 只打印将要执行的 scrcpy 命令，不启动 |

## 三、在指定虚拟屏上操作 App

查看当前所有 display 和本次会话的映射：

```powershell
.\scripts\Show-Displays.ps1
```

输出里 `Type=VIRTUAL` 的就是 scrcpy 开的虚拟屏，`Id` 即 displayId。

在某个虚拟屏启动 App（推荐，脚本会自动从 `run\screens.json` 查 displayId）：

```powershell
.\scripts\Start-App.ps1 -Screen 2 -Package com.ss.android.ugc.aweme
.\scripts\Start-App.ps1 -Screen 3 -Package com.tencent.mm -Activity .ui.LauncherUI -Wait
```

直接用 adb（等价写法，可写进你自己的批处理/自动化）：

```powershell
$adb = ".\tools\scrcpy-win64-v5.0.1\adb.exe"
$serial = "你的序列号"     # 用 $adb devices 查看

# 在 display 3 上启动微信
& $adb -s $serial shell am start --display 3 -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p com.tencent.mm

# 在 display 3 上点击坐标 (360, 800)
& $adb -s $serial shell input -d 3 tap 360 800

# 在 display 3 上输入文字
& $adb -s $serial shell input -d 3 text "hello"

# 看 display 3 当前是哪个 Activity
& $adb -s $serial shell dumpsys activity activities | Select-String "displayId=3"
```

> 截图注意：Android 15+（本机是 Android 17）的 `screencap -d` 只认 SurfaceFlinger 的物理 display id，
> 不再认逻辑 displayId，所以 `screencap -d 3` 会报 “Display Id '3' is not valid”。
> 虚拟屏要看画面直接看 scrcpy 窗口即可；需要录屏时给 scrcpy 加 `--record=run\screen1.mp4`。
>
> `am start -p <包名>` 对个别 App 会解析不到启动入口（本机计算器就是），改用
> `am start --display N -n 包名/.Activity` 即可；`Start-App.ps1` 会自动解析启动 Activity。

关闭全部窗口（虚拟屏随之销毁）：

```powershell
.\scripts\Stop-MultiScreens.ps1
```

## 四、必须知道的限制

- **同一个 Android 用户、同一份 App 数据。** 多个虚拟屏只是“多块屏”，不是多开/分身：
  同一个 App 在不同屏上是同一个账号、同一份数据。要不同账号需要工作资料/手机分身/应用双开，那属于另一套方案。
- `am force-stop` 会杀掉该包在**所有**屏上的实例，`Start-App.ps1 -ForceStop` 慎用。
- 银行、DRM 视频等安全窗口在虚拟屏上可能黑屏（系统禁止安全图层被虚拟显示捕获）。
- 部分 App 在非默认 display 上会以“平板/桌面模式”布局，必要时调 `-Width/-Height/-Dpi` 模拟手机比例（如 720x1600/320）。
- 关闭窗口默认销毁虚拟屏及其中的 App；要保留用 `-KeepApps`。
- 声音默认全部静音；`-Audio` 只给第 1 屏。多实例同时采集音频在多数机型上会失败。

## 五、常见问题

**`No adb device found`**
- 数据线是否支持传输；换线/换 USB 口。
- 开发者选项里 USB 调试是否打开；弹窗是否点了“允许”。
- 执行 `.\tools\scrcpy-win64-v5.0.1\adb.exe kill-server` 后重插。
- 若之前拒绝过授权：开发者选项 → 撤销 USB 调试授权，再重插。

**`Device is unauthorized`**
- 解锁手机，在“允许 USB 调试吗？”弹窗点允许并勾选“一律允许”。

**scrcpy 启动后立刻退出**
- 看 `run\logs\screenN.err.log`（脚本会打印末尾 30 行）。
- 最常见：Android < 12、端口被占用（换 `-BasePort`）、USB 调试被撤销。

**窗口开了但里面全黑 / 没有内容**
- 没有启动 App 且系统没有可用启动器时，虚拟屏没有内容。加 `-Apps` 或在窗口里用 `Start-App.ps1` 启动。
- 安全类 App 本身禁止虚拟屏显示。

**虚拟屏画面冻结，`Show-Displays.ps1` 里 State 变成 `OFF`**
- 手机锁屏/息屏后，所有 display 都会进 OFF。启动时加 `-KeepActive`，并执行一次
  `adb shell svc power stayon true`（充电时常亮），或让手机保持插电。

**adb 能连，但 `input` 报权限错误**
- MIUI 需要打开“USB 调试（安全设置）”。

**窗口太小或互相重叠**
- 脚本已按物理像素平铺，并自动处理 Windows 缩放（本机 150% / 144 DPI）。
- 远程桌面或特殊分辨率下仍不对，用 `-WindowWidth/-WindowHeight` 手动指定像素。

## 六、目录结构

```
arf\
  README.md
  scripts\
    common.ps1              公共函数（找 adb/scrcpy、设备、display 解析、DPI/窗口摆放）
    Test-Environment.ps1    环境自检
    Start-MultiScreens.ps1  启动 N 个虚拟屏并平铺
    Test-Capacity.ps1       并发上限测试（逐屏加压，每屏不同 App）
    Show-Displays.ps1       列出 display 与会话映射
    Start-App.ps1           在指定虚拟屏启动 App
    Stop-MultiScreens.ps1   关闭所有窗口
    Connect-Wireless.ps1    无线调试配对并连接
  tools\
    scrcpy-win64-v5.0.1\    scrcpy 5.0.1 + 配套 adb
  run\                      运行时生成：screens.json、logs\、capacity.json、demo-3screens.png
```

## 附：并发上限实测（K40 / LineageOS 24 / 720x1600@320dpi@30fps）

```powershell
.\scripts\Test-Capacity.ps1 -Max 16          # 逐屏加压，每屏一个不同 App，失败即停
.\scripts\Test-Capacity.ps1 -Max 10 -LeaveOpen
```

实测结果（每屏独立 App，`--new-display` 实际编码推流，测试期间 `--keep-active` 保持常亮）：

| 屏数 | 结果 | 启动后 CPU | 剩余内存 | 备注 |
|---|---|---|---|---|
| 10 | 全部正常 | ~33% | 4.8 GB | 窗口 221×492 |
| 15 | 全部正常 | 稳态 37.8% | 3.0 GB | 15 个 scrcpy 进程 / 15 个 VIRTUAL display |
| 16 | **第 16 屏失败** | — | 3.4 GB | `MediaCodec.start` → `CodecException` |

结论：**这台 K40 的硬上限是 15 路并发 720p 编码**。第 16 路不是内存不足（当时还剩 3.4GB），
而是 Adreno 编码器的并发会话耗尽；失败后其余 15 路继续正常推流。

实用建议：
- 15 是“能开”的上限，不是“好用”的上限；1080p 桌面上 3 列最舒服（约 446×992 一个窗口），6 屏开始窗口明显变小。
- 每屏都会独立编码，CPU 主要花在编码上；减少屏数比降分辨率更有效。
- 结果明细在 `run\capacity.json`；15 屏和 16 屏失败的截图只在本地 `run\` 下生成（含 App 内容，未上传仓库）。

