# iPhone Inspector 简洁诊断界面 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不改变采集、协议和既有分析算法的前提下，新增默认“诊断”页面并完整保留“详细数据”。

**Architecture:** `PerformanceMonitorStore` 继续拥有唯一会话状态，`PerformanceInsightAnalyzer` 继续计算真实趋势和 lag summary。新增 Core presentation 类型把既有结果映射为可测试的克制中文，新 SwiftUI 诊断页只渲染这些结果并调用现有 Store 动作。

**Tech Stack:** Swift 5 language mode、SwiftPM、SwiftUI、Apple Charts、XCTest、Python 3.13 Helper tests。

## Global Constraints

- macOS 最低版本保持 13；不新增依赖。
- CPU raw 不添加百分号；VM page count 不换算 MiB/GB；电池温度不显示摄氏度；Energy 不显示 W/J。
- 不修改 P90、卡顿前 30 秒/后 10 秒窗口、Top 3 排序、PID reuse、observer overhead、Provider、protocol v2 或 Helper。
- 顶层切换不得重启或重置 Store/Helper/RSD/Provider/会话/marker/时间线/搜索/时间范围。
- 阶段 C/D/E 默认只读；不执行大规模清理、重构或优化。

---

### Task 1: 可测试的诊断 presentation

**Files:**
- Create: `Tests/iPhoneMonitorCoreTests/PerformanceDiagnosticPresentationTests.swift`
- Create: `Sources/iPhoneMonitorCore/Performance/PerformanceDiagnosticPresentation.swift`

**Interfaces:**
- Consumes: `PerformanceTimelineFrame`, `PerformanceInsightAnalyzer.trend`, `PerformanceLagSummary`。
- Produces: `PerformanceDiagnosticSnapshot`, `PerformanceLagDiagnosticPresentation`, `PerformanceDiagnosticPresenter.liveSnapshot(...)`, `PerformanceDiagnosticPresenter.lagPresentation(...)`。

- [ ] **Step 1: 写实时状态和卡顿概览的失败测试**

测试覆盖以下真实行为：

```swift
func testLiveSnapshotUsesTrendsWithoutRawUnits() {
    let snapshot = PerformanceDiagnosticPresenter.liveSnapshot(
        frame: risingFrame,
        streamGapCount: 0,
        providerErrorCount: 0,
        droppedCount: 0
    )
    XCTAssertEqual(snapshot.processor, "正在升高")
    XCTAssertEqual(snapshot.memory, "内存使用正在变重")
    XCTAssertEqual(snapshot.batteryTemperature, "正在升温")
    XCTAssertEqual(snapshot.energy, "正在升高")
    XCTAssertEqual(snapshot.dataQuality, "良好")
    XCTAssertFalse(snapshot.allText.contains("%"))
    XCTAssertFalse(snapshot.allText.contains("℃"))
}

func testIncompleteLagOverviewLeadsWithLimitedReference() {
    let presentation = PerformanceDiagnosticPresenter.lagPresentation(
        summary: incompleteSummary,
        processDisplayNames: ["微信", "SpringBoard（系统界面）"]
    )
    XCTAssertTrue(presentation.overview.hasPrefix("卡顿附近存在数据中断或采集异常"))
    XCTAssertEqual(presentation.dataIntegrity, "不完整")
}
```

另覆盖：中性卡顿、数据不足、Top 2 名称组合、内存/温度/能耗现象，以及所有输出不含“根因就是”“一定是”“确定由”“硬件故障”。

- [ ] **Step 2: 运行测试并确认因类型不存在而失败**

Run: `swift test --filter PerformanceDiagnosticPresentationTests`

Expected: 编译失败，错误指出 `PerformanceDiagnosticPresenter`/输出类型不存在。

- [ ] **Step 3: 最小实现 presentation 类型**

采用以下稳定接口：

```swift
public struct PerformanceDiagnosticSnapshot: Equatable, Sendable {
    public let processor: String
    public let memory: String
    public let memoryExplanation: String
    public let batteryTemperature: String
    public let energy: String
    public let dataQuality: String
    public var allText: String { [processor, memory, memoryExplanation, batteryTemperature, energy, dataQuality].joined(separator: " ") }
}

public struct PerformanceLagDiagnosticPresentation: Equatable, Sendable {
    public let overview: String
    public let phenomena: [String]
    public let processDisplayNames: [String]
    public let dataIntegrity: String
    public let dataIntegrityDetail: String
}

public enum PerformanceDiagnosticPresenter {
    public static func liveSnapshot(
        frame: PerformanceTimelineFrame,
        streamGapCount: Int,
        providerErrorCount: Int,
        droppedCount: Int
    ) -> PerformanceDiagnosticSnapshot

    public static func lagPresentation(
        summary: PerformanceLagSummary,
        processDisplayNames: [String]
    ) -> PerformanceLagDiagnosticPresentation
}
```

实时阈值只调用现有 `PerformanceInsightAnalyzer.trend`：CPU `0.08`、VM `0.01`、电池温度 `0.005`、Energy `0.10`。卡顿 presentation 只读取 `PerformanceLagSummary` 已有枚举和字段。

- [ ] **Step 4: 运行定向测试并确认通过**

Run: `swift test --filter PerformanceDiagnosticPresentationTests`

Expected: 新测试 0 failure。

- [ ] **Step 5: 检查真实性边界**

Run:

```bash
rg -n '%|℃|瓦特|焦耳|根因就是|一定是|确定由|硬件故障' \
  Sources/iPhoneMonitorCore/Performance/PerformanceDiagnosticPresentation.swift
```

Expected: 0 个违规命中；若文案为了明确否定单位而出现术语，只允许放在详细证据页，不放入该 presentation 文件。

### Task 2: 新增诊断页面并保留详细数据状态

**Files:**
- Create: `Sources/iPhoneMonitor/Views/Performance/PerformanceDiagnosticView.swift`
- Modify: `Sources/iPhoneMonitor/Views/PerformanceMonitorView.swift`
- Modify: `Sources/iPhoneMonitor/Views/Performance/PerformanceTimelineView.swift`
- Modify: `Sources/iPhoneMonitor/Views/PerformanceProcessListView.swift`
- Modify: `Sources/iPhoneMonitor/Views/PerformanceLogView.swift`

**Interfaces:**
- Consumes: Task 1 的两个 presentation 输出、`PerformanceMonitorStore.startMonitoring/stopMonitoring/markLag`、现有 `latestLagSummary`。
- Produces: 默认“诊断 / 详细数据”切换和不含 raw 主指标的普通用户页面。

- [ ] **Step 1: 固化切换状态设计**

在 `PerformanceMonitorView` 内增加：

```swift
private enum PerformancePage: String, CaseIterable, Identifiable {
    case diagnosis
    case details
    var id: String { rawValue }
}

@State private var selectedPage: PerformancePage = .diagnosis
```

顶层只在两个 View 分支间切换；`store` 和 `deviceStore` 仍由 `ContentView` 注入，绝不在分支内创建。

- [ ] **Step 2: 保持现有详细页的局部搜索状态**

将时间线进程搜索、全部进程搜索和日志搜索改为同一 scene 内稳定的 `@SceneStorage` 字符串；时间范围继续由 Store 拥有。排序/筛选若会随 View 重建则同样以 raw value/Bool 存入 scene state。键名使用 `performance.timeline.*`、`performance.processes.*`、`performance.logs.*`，避免与其他页面碰撞。

- [ ] **Step 3: 新增原生诊断 View**

`PerformanceDiagnosticView` 接收：

```swift
struct PerformanceDiagnosticView: View {
    @ObservedObject var store: PerformanceMonitorStore
    @ObservedObject var deviceStore: DeviceStore
    let onMarkLag: () -> Void
}
```

布局使用 `ScrollView`、`PageHeader`、`SectionCard`、`Label`、semantic foreground styles 和最多两列的 adaptive grid。按钮直接调用现有 `markLag(note: "")` 路径；pending 时显示正在收集后 10 秒数据。最近摘要按“刚才发生了什么 → 一句话概览 → 主要现象 → 可能相关进程 → 数据完整性”展示。

- [ ] **Step 4: 将现有专业面板包在“详细数据”分支**

保持原有 `VSplitView`、下方 segmented Picker 和四个详细内容分支。顶层 Picker 位于外层 `VStack`，不使用 `.tabItem`。时间线 `onVisibilityChange` 同时考虑顶层是否处于 details，以免诊断页额外触发 timeline build。

- [ ] **Step 5: 增量编译**

Run: `swift build`

Expected: exit 0；如失败，只修第一个编译错误并重跑。

- [ ] **Step 6: 回归定向测试**

Run: `swift test --filter 'PerformanceInsightsTests|PerformanceDiagnosticPresentationTests|PerformanceTimelineTests'`

Expected: 相关分析、presentation、timeline 测试全部 0 failure。

### Task 3: 阶段 B 完整验证

**Files:**
- No source changes unless a Task 1/2 regression is reproduced.

**Interfaces:**
- Consumes: 已实现 App、Python Helper、现有 build/run 脚本。
- Produces: 完整构建/测试/启动/实机与 cleanup 证据。

- [ ] **Step 1: 完整 SwiftPM 构建与测试**

Run: `swift build && swift test`

Record: exit code、executed/skipped/failure 总数；显式 USB 测试按仓库命令单独运行。

- [ ] **Step 2: Helper tests**

使用 `.performance-tools/venv313/bin/python` 和仓库现有测试入口运行完整 Helper suite，记录总数。

- [ ] **Step 3: App bundle 验证**

Run: `./script/build_and_run.sh --verify`

Expected: `dist/iPhone Inspector.app` 被重新构建并以完整可执行路径确认进程存在。

- [ ] **Step 4: 设备可用时完成短实机会话**

验证 start、diagnosis/details 往返、实时更新、时间线范围与搜索保持、mark lag、summary、stop、`session_ended`、`helper_shutdown`、exit 0。若设备不可用，明确记录未执行，不用 Mac 数据替代。

- [ ] **Step 5: 检查残留**

只读检查 App 自己启动的 Helper、`pymobiledevice3`、`tunneld` 和 userspace tunnel；不得使用 `pkill python` 或 `killall`。

### Task 4: 阶段 C/D/E 只读审计与最终报告

**Files:**
- No source changes by default.

**Interfaces:**
- Consumes: 当前代码调用图、构建/运行日志、进程采样。
- Produces: 用户要求的 A–H 最终交接报告。

- [ ] **Step 1: 阶段 C 代码体检**

逐项检查 dead code、旧 UI、重复逻辑/状态、workaround、日志、大型 View/Store 和无效抽象。每个候选记录文件、位置、调用证据、风险和建议，不删除代码。

- [ ] **Step 2: 阶段 D Profiling**

记录 idle/monitoring/stopped 的 App/Helper CPU 与 RSS、30 秒和约 3 分钟样本、helper_ready/session_started 时序、bounded cache 实际容量、主线程候选。把实测与静态怀疑分开。

- [ ] **Step 3: 阶段 E 生命周期快测**

设备仍可用且阶段 B 正常时执行 3–5 轮 `Start → sample → Stop → cleanup`，逐轮记录 helper_ready/session_started/session_ended/helper_shutdown/exit 0 与残留；失败时保存日志，不猜根因。

- [ ] **Step 4: 完成前重新验证工作树和关键命令**

Run: `git diff --check && swift build && swift test`

Expected: diff 无空白错误，构建 exit 0，测试 0 failure。

- [ ] **Step 5: 输出 A–H 报告**

严格区分已实现、实测、静态怀疑、无法复现和尚未执行；下一步仅列 3–5 项并按收益/风险/优先级排序。
