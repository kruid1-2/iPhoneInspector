# iPhone Inspector 简洁诊断界面设计

## 目标

在现有“性能监控”功能上增加默认展示的“诊断”界面，让普通用户先看到处理器、系统内存、电池温度、能耗和数据质量的中文状态，并在点击“刚刚发生卡顿”后看到一条克制的中文概览。现有专业性能面板作为“详细数据”完整保留。

## 不变边界

- `PerformanceMonitorStore`、`PerformanceInsightAnalyzer` 和当前 Helper 是唯一数据与分析来源。
- 顶层切换只改变 SwiftUI 展示，不启动或停止 Helper、RSD、Provider，也不清除会话、marker、时间线、搜索或时间范围。
- CPU 保持 raw 相对比较，不显示百分比；VM page count 不换算容量；电池温度不显示摄氏度；Energy 不显示功率或能量单位。
- 不改变 P90、卡顿分析窗口、Top 3 排序、PID reuse、observer overhead 排除、网络归属或协议。
- 不新增 Provider、依赖、数据库、Thermal State、AI 或持久化。

## 采用方案

在 `PerformanceMonitorView` 内增加默认选择“诊断”的顶层 segmented Picker，并将现有 `VSplitView` 原样保留为“详细数据”。新增一个只读的 `PerformanceDiagnosticView`，通过同一个 `PerformanceMonitorStore` 获取实时数据和最近一次 `PerformanceLagSummary`。

新增 Core 层 presentation 类型，将已有趋势和 lag summary 组合成受约束的中文状态。它只做展示映射，不采样、不缓存、不改变分析算法。与数据真实性有关的文案逻辑使用单元测试覆盖；SwiftUI 组合通过编译、App 启动和实机交互验证。

没有采用以下方案：

- 将所有中文判断直接写在 View 中：改动看似更少，但会继续复制趋势判断，且无法可靠单测。
- 新增独立诊断 Store：会长期保存同一事实的第二份状态，并扩大生命周期风险。

## 组件

### `PerformanceDiagnosticPresenter`

输入当前 `PerformanceTimelineFrame`、stream gap/provider error/dropped 计数，输出五项不含 raw 数值的实时状态：

- 处理器：较平稳、正在升高、正在降低、数据不足。
- 内存：基本稳定、内存使用正在变重、压缩正在增加、空闲空间正在减少、数据不足。
- 电池温度：稳定、正在升温、正在降温、数据不足。
- 能耗：平稳、正在升高、正在降低、数据不足。
- 数据质量：良好、不完整。

输入现有 `PerformanceLagSummary` 和已经本地化的进程显示名，输出：

- 一句话概览；
- 主要现象列表；
- 数据完整性说明。

所有结论使用“观察到”“可能相关”“值得继续观察”等措辞，不输出根因断言。

### `PerformanceDiagnosticView`

页面顺序：

1. 页面标题和当前会话状态；
2. 醒目的“刚刚发生卡顿”按钮，以及开始/停止监控入口；
3. “刚才发生了什么”：等待分析、概览、主要现象、可能相关进程、数据完整性；
4. “手机现在怎么样”：五项简洁状态卡；
5. 当前错误（存在时）。

诊断页不显示 CPU raw、VM page count、电池温度 raw 或 Energy raw；这些证据只保留在“详细数据”。

### `PerformanceMonitorView`

负责顶层“诊断 / 详细数据”选择和现有 marker 备注 sheet。现有详细数据页的 `VSplitView`、时间线、全部进程、实时日志和事件保持原结构。

详细页内部的搜索/范围等状态使用稳定的 scene/view 状态；顶层切换不触发 Store 重建。时间线可见性仍准确通知 Store，隐藏诊断页时不额外启动采集。

## 数据流

```text
Helper JSONL
  -> PerformanceMonitorService
  -> PerformanceMonitorStore（唯一会话状态）
      -> PerformanceInsightAnalyzer（现有趋势与 lag 分析）
      -> PerformanceDiagnosticPresenter（新增中文展示映射）
          -> PerformanceDiagnosticView
      -> 现有详细数据 VSplitView
```

点击“刚刚发生卡顿”仍调用 `PerformanceMonitorStore.markLag(note:)`，经现有 protocol v2 产生 marker；Store 收到 marker 后按现有窗口和算法生成 `latestLagSummary`。诊断页只观察 pending/summary 状态。

## 错误与不足数据

- 没有足够样本时明确显示“数据不足”，不从单点推断趋势。
- 任一 gap、Provider error 或 dropped count 使数据质量显示“不完整”，卡顿概览优先提示参考有限。
- Helper/Provider 错误沿用 Store 的 `lastError`；新增界面不吞掉或改写底层错误。
- 没有相关进程时显示“进程数据不足”，不生成虚构 App 名称。

## 验证

1. 先为实时状态组合、完整/不完整数据、卡顿高负载概览、中性概览和禁用单位/断言词编写失败测试。
2. 最小实现 presentation 类型并跑定向测试。
3. 增加 SwiftUI 页面和顶层切换，增量 `swift build`。
4. 完整执行 `swift build`、`swift test`、Helper tests、`./script/build_and_run.sh --verify`。
5. 设备可用时验证实时更新、往返切换状态保持、marker 摘要、停止与 Helper cleanup。

## 范围确认

本设计只覆盖阶段 A 的 UI/presentation 实现。阶段 C 的代码体检、阶段 D 的 Profiling 和阶段 E 的稳定性验证只产生证据与报告，除非遇到明确的严重数据或安全 Bug，否则不修改代码。
