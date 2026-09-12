# Python Performance Helper

这是 iPhone Inspector 的只读性能采集辅助进程。它使用项目本地 Python 3.13 环境和
`pymobiledevice3 10.2.3`，通过一个长生命周期 userspace RSD tunnel 复用设备连接。高流量
提供器各自保留一条长生命周期 DVT 连接，避免 oslog 阻塞 sysmontap；不会在每个采样周期
重新启动 CLI、tunnel 或开发者服务。

依赖版本记录在 `requirements-lock.txt`。Intel Mac 上的 `cryptography 50.0.0` 需要
Rust 工具链从源码构建；安装时应先单独升级到锁定的 pip 版本，再安装其余依赖，避免
在同一次 pip 进程中升级 pip 自身。

## 协议

- stdin：一行一个 JSON 控制消息。
- stdout：只允许 JSON Lines 协议事件。
- stderr：脱敏后的内部错误摘要。
- Helper 不保存完整 syslog、oslog、网络地址、数据包或设备标识。
- 当前协议版本：`2`。每条事件包含严格递增的 `sequence`、UTC 时间、单调时钟和会话 ID。
- 输出使用容量为 256 的有界队列。慢消费者出现时只丢弃非关键采样，`heartbeat` 与
  `session_ended` 会报告最高占用和 `dropped_count`；控制、生命周期和错误事件受到保护。

主要事件为 `session_started`、`system_sample`、`process_batch`、`battery_sample`、
`energy_sample`、`log_event`、`log_summary`、`network_summary`、`heartbeat`、
`stream_gap`、`lag_marker`、`provider_error` 和 `session_ended`。

支持的控制消息：

```json
{"type":"start_session","config":{}}
{"type":"mark_lag","note":"切换 App 时卡顿"}
{"type":"stop_session"}
{"type":"shutdown"}
```

运行真实设备 Helper：

```bash
.performance-tools/helper/run_helper.sh
```

运行明确标注的固定样例模式（不连接设备）：

```bash
.performance-tools/helper/run_helper.sh --fixture-mode
```

稳定性测试专用模式（同样不连接设备）：

```bash
.performance-tools/helper/run_helper.sh --backpressure-test-mode
.performance-tools/helper/run_helper.sh --provider-failure-test-mode
```

运行测试：

```bash
.performance-tools/helper/test_helper.sh
```

限制：系统 CPU、Energy、电池温度/电流/电压等字段按 DVT 或 diagnostics 的原始值输出；
单位未由当前返回明确确认时保持 `null`，不会猜测换算。NetworkMonitor 只输出汇总，永不输出
端点地址或载荷。DVT oslog 默认只输出关键词命中结构和统计，不输出完整消息正文。

`Sysmontap` 的 DVT 输出刷新频率会与请求的采样间隔对齐，避免 1 ms 无效刷新占满 CPU。
当前实机上 ActivityTraceTap/oslog 的解码仍然消耗接近一个 Mac CPU 核心；正式 UI 应把
实时 oslog 作为明确可关闭的高开销选项，并在关闭时保留 sysmon、电池、Energy 和网络汇总。
