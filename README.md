# iPhone 诊断助手

英文名：**iPhone Inspector**

这是一个面向 macOS 的原生 SwiftUI 工具。它通过本机已有的只读设备工具检查经
USB 连接的未越狱 iPhone，并在本地分析用户主动导入的诊断日志，用于辅助排查：

- 卡顿、掉帧和应用频繁重载
- 发热与热压力记录
- 掉电快和可读取的电池信息
- 存储空间不足
- panic、watchdog 和异常重启
- Jetsam、LowMemory 和系统进程持续崩溃

所有分析都在本机完成。应用没有服务器、账户系统或遥测上传，不使用 `sudo`，
不会修改 iPhone，也不会尝试突破 iOS 权限。

## 能读取什么

连接且已解锁、已信任时，应用会根据当前电脑可用的工具尽量读取：

- 设备名称、产品类型和可识别的市场型号
- iOS 与 Build Version
- 序列号、UDID、ECID、CPU 架构（工具确实返回时）
- USB / 网络连接方式、配对状态和可读状态
- 当前电量、充电状态（工具确实返回时）
- 总容量、已用和设置口径可用存储（工具确实返回且语义可验证时）
- 当前硬空闲存储（`AmountDataAvailable` 返回时，明确标注不含可回收空间）
- 导入日志中的电池健康、循环次数、panic、Jetsam、thermal 等摘要

每个字段都显示来源和可用状态。空值不会覆盖之前成功读取的结果；连接断开后，
上次结果会标记为过期并保留最后成功读取时间。内部还会记录对应的原始字段名，
便于排查不同 iOS / 工具版本的字段变化，但界面默认不展开原始字段名。

序列号和 UDID 默认遮挡，可在设置中选择显示完整内容。

## iOS 不允许直接读取的内容

未越狱 iPhone 不向普通 macOS 应用稳定开放：

- 实时 CPU 使用率
- 芯片真实温度
- 每个 App 的实时内存占用
- 完整后台进程列表
- iPhone 内部全部受保护日志
- 系统未公开的电池底层参数

应用不会用随机数、Mac 本机指标或推测值代替这些数据。读取不到时会明确显示：

- “当前 iOS 不允许直接读取”
- “当前读取工具不支持”
- “当前 iOS 未返回此字段”
- “返回数据解析失败”
- “需要导入诊断日志”
- “当前连接方式不支持”
- “暂未获取到数据”

演示模式默认关闭。开启后，窗口顶部和字段状态会明确标注“演示数据”。

## 连接 iPhone

1. 使用数据线连接 iPhone 与 Mac。
2. 解锁 iPhone。
3. 首次连接时，在 iPhone 上点击“信任此电脑”并输入密码。
4. 保持手机亮屏。
5. 在应用中点击“刷新”，或按 `Command-R`。

没有设备时应用会保持可用，不会崩溃。连接断开后会自动切回未连接状态，并把之前
的数据标记为过期。

## 构建要求

- macOS 13 或更高版本
- Apple Swift 6 / Xcode Command Line Tools
- Intel 与 Apple Silicon 均可构建；本项目已在 Intel `x86_64` Mac 上验证
- 不要求 Homebrew

实时性能 Helper 使用 Python 3.13。当前锁定的 `cryptography 50.0.0` 在 Intel Mac
上需要从源码构建，因此自行创建 Helper 环境时还需要 Rust 工具链；Apple Silicon
若可直接取得兼容 wheel，则不需要本地编译该依赖。

Swift Package Manager 入口：

```bash
swift build
swift test
```

统一构建与启动入口：

```bash
./script/build_and_run.sh
```

构建、启动并验证进程：

```bash
./script/build_and_run.sh --verify
```

其他调试模式：

```bash
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --debug
```

脚本会停止旧进程、执行 `swift build`、创建并临时签名
`dist/iPhone Inspector.app`、生成 `Info.plist`、复制 Dock 图标，然后使用
`open -n` 启动应用。

Codex Run 按钮已通过
`.codex/environments/environment.toml` 连接到同一个脚本。

## 导入诊断日志

点击窗口顶部“导入诊断文件”，按 `Command-O`，或把文件拖到“诊断日志”页面。

支持：

- `.ips`
- `.panic`
- `.log`
- `.txt`
- `.zip`
- `.tar.gz` / `.tgz`
- 已解压的诊断文件夹

第一版优先识别：

- `panic-full`、`panic-base`
- `JetsamEvent`、`LowMemory`
- thermal / thermal pressure
- reset counter、watchdog
- crash report、SpringBoard、backboardd
- battery、storage
- PowerLog 中可理解的电池、温度、内存压力和存储摘要

导入器会限制候选文件数量、单文件大小和总解压大小，检查压缩包路径穿越，支持取消；
单个文件失败不会使整个导入崩溃。未知文本格式会保留受限长度的摘要。

默认只读分析原文件。设置中开启“保留导入文件副本”后，合理大小的单文件会复制到
应用数据目录；大型文件夹仍使用只读分析，避免无意复制完整 sysdiagnose。

## 如何生成 sysdiagnose

Apple 在开发者视频中说明：在 iPhone 上同时按住两个音量键和侧边键数秒，然后松开，
系统稍后会在“设置 → 隐私与安全性 → 分析与改进 → 分析数据”中提供 sysdiagnose。
按键组合可能触发截图或关机界面，操作时不要继续长按到紧急 SOS；不同设备和 iOS
版本可能略有差异，请以 Apple 针对相应日志配置提供的说明为准。

参考：[Apple Developer - Optimize your use of Core Data and CloudKit](https://developer.apple.com/videos/play/wwdc2022/10119/?time=438)

也可以从“设置 → 隐私与安全性 → 分析与改进 → 分析数据”分享单个 `.ips` 日志。
越接近问题发生时间的日志越有价值。

## 风险分析

`RiskAnalysisService` 集中处理规则，当前包括：

- 可信的设置口径可用空间低于总容量 15%、8% 或低于 5 GB
- 短期多次 panic
- 多次 watchdog
- 多次 Jetsam / 内存压力
- 同一进程持续崩溃
- thermal pressure
- 电池字段缺失或明显偏低
- 更新、恢复或照片同步后可能存在的索引任务
- 数据不足或字段相互矛盾

风险提示不是硬件诊断结论。应用不会仅凭日志缺失就断言第三方电池是假货，也不会
轻易断言主板损坏、系统必然有 Bug，或默认建议刷机、抹掉手机。

## 当前数据提供器

应用逐个检查工具是否存在，再决定是否调用：

1. `xcrun devicectl`
2. 已安装的 `idevice_id` / `ideviceinfo`
3. `xcrun xcdevice`
4. `system_profiler` USB 信息

`system_profiler` 是重量级后备提供器，只用于确认 USB 设备，不会把 Mac 的电池、
存储或温度当作 iPhone 数据。定时检测只运行轻量提供器；详细信息在首次连接或手动
刷新时读取。

如果电脑没有 `libimobiledevice`，应用仍可启动和使用 Apple 自带工具，不要求用户
安装 Homebrew，也不会自动安装 Homebrew、`libimobiledevice` 或其他软件。

手动详细刷新时，`devicectl device info details` 使用单独的受保护系统临时目录，
原始 JSON 解析完成后立即删除。若电脑已经存在 `ideviceinfo`，应用会只读执行：

```text
ideviceinfo -u <UDID> -x
ideviceinfo -u <UDID> -q com.apple.mobile.battery -x
ideviceinfo -u <UDID> -q com.apple.disk_usage -x
```

完整 XML 不会写入项目或长期保存；命令日志只记录脱敏命令标签、退出码、耗时和脱敏
错误摘要，不记录完整 UDID、序列号或 XML 内容。

`devicectl` 可能只返回硬件总容量（例如 `internalStorageCapacity`），而不返回可用容量
或电池字段。应用会显示确实返回的总容量；只有总容量和可用容量来自同一数据域、单位
可确认且满足“总容量 ≥ 可用容量”时，才计算已使用容量和使用比例。

`com.apple.disk_usage` 的 `AmountDataAvailable` 表示较严格的当前硬空闲空间，可能明显
低于“设置 → 通用 → iPhone 储存空间”中包含系统可回收内容的用户可用空间。应用会保留
这个原始值，但不会把它称作设置口径可用空间，也不会仅凭该值计算使用比例或触发低
存储风险。读取不到设置口径时，界面会提示以 iPhone 设置为准，不会组合其他未公开字段
估算。

## 第三方电池说明

更换第三方电池后，iOS 或设备工具可能不返回健康度、循环次数、容量、序列或验证状态，
返回值也可能可信度较低。应用会按实际失败原因标记为“工具不支持”“iOS 未返回”、
“解析失败”或低可信度，
不会仅凭字段缺失判定电池损坏或非正品。

## 本地数据与清除

诊断摘要和可选导入副本保存在：

```text
~/Library/Application Support/iPhoneInspector/
```

在设置中可以：

- 设置日志摘要保留天数
- 打开应用数据目录
- 二次确认后清除本地诊断记录和受控副本

清除应用数据不会删除用户选择的原始诊断文件。

## App Sandbox

当前开发版暂不启用 App Sandbox，因为应用需要：

- 调用本地只读设备命令
- 访问用户通过文件选择器授权的诊断文件和文件夹
- 处理 USB 设备发现

这不改变隐私原则：不使用 `sudo`、不修改设备、不上传数据。正式分发前需要根据签名、
沙箱与设备工具可用性重新评估权限方案。

## 已知限制

- 没有真实 iPhone 连接时，只能验证未连接流程和日志导入。
- `devicectl` 的字段会随 Xcode / CoreDevice 版本变化，解析器采用容错字段查找。
- 并非所有 iOS 版本都会向 `devicectl` 或 `ideviceinfo` 返回电池和存储域；
  Apple 自带工具通常不保证提供实时电量或可用容量。
- USB 工具返回的硬空闲空间不等同于 iPhone 设置中的用户可用空间。
- 第一版不会完整解析 sysdiagnose 中的所有数据库。
- App 存储分类、实时 CPU、实时温度和完整进程列表不可用时不会猜测。
- 开发构建使用临时签名，不等同于公证发行版本。

## 许可证

本项目采用 [MIT License](LICENSE)。
