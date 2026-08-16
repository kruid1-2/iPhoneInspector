# 存储容量口径修正设计

日期：2026-08-16

## 背景与问题

当前应用把 `com.apple.disk_usage` 返回的 `AmountDataAvailable` 写入
`StorageInformation.availableBytes`，随后用它计算已使用容量、使用比例和低存储风险。
实机上该字段约为 3.46 GiB，而 iPhone“设置 → 通用 → iPhone 储存空间”显示仍有
20 多 GB。另一条 AFC 文件系统读取也只返回约 3.74 GiB，说明 USB 字段反映的是较严格
的当前硬空闲空间，不能直接等同于 iOS 设置中包含系统可回收内容的用户可用空间。

因此，现有数据解析虽然保留了真实原始值，但字段命名、界面表达和风险判断使用了错误
语义，可能误导用户清理数据并错误归因卡顿。

## 目标

- 保留 `AmountDataAvailable` 这一真实原始读数。
- 将它明确建模和显示为“当前硬空闲空间（不含可回收空间）”。
- 不再把硬空闲空间显示成设置口径的“可用存储”。
- 不使用硬空闲空间单独计算已用比例或触发低存储风险。
- 读不到设置口径的用户可用空间时明确显示信息不足，不估算或拼凑数值。
- 保持已保存诊断记录的解码兼容性。

## 不在本次范围内

- 不尝试复刻 iOS“设置”内部的存储计算算法。
- 不把 `AmountRestoreAvailable`、`TotalDataAvailable` 或其他未公开字段相加来估算
  设置中的可用空间。
- 不改动电池或性能监控，也不重构与本次存储口径无关的稳定接口。
- 不加入自动清理、删除文件或修改 iPhone 数据的功能。

## 方案选择

采用独立字段方案：为 `StorageInformation` 增加 `hardFreeBytes`，专门保存严格的当前
硬空闲读数。`availableBytes` 继续表示能够与用户可用空间语义一致的容量；提供器不能
返回这种口径时保持不可用。

不采用以下方案：

- 仅修改界面文案：内部仍会把原始值当成可用空间，风险服务和未来调用方可能继续误用。
- 组合多个私有字段估算：缺少 Apple 公开、稳定的换算规则，结果仍不可验证。
- 完全隐藏原始值：会丢失可用于诊断写入压力和设备工具差异的真实证据。

## 数据模型与兼容性

`StorageInformation` 增加：

```swift
public var hardFreeBytes: DataValue<Int64>
```

字段默认状态为 `.missing(.notReturned)`。编码时写入新字段；解码旧记录时，如果键缺失，
恢复为默认缺失值，不能导致整个旧记录解码失败。`markedStale()` 和 `hasAnyValue` 同步
包含该字段。

`usageFraction` 的定义保持严格：只有 `totalBytes`、`availableBytes` 和 `usedBytes` 均为
同一可信口径并满足算术关系时才返回比例。`hardFreeBytes` 永不参与该计算。

## 解析与数据流

### 实时设备读取

对于 `com.apple.disk_usage`：

- `TotalDataCapacity` 继续作为数据分区总容量证据。
- `AmountDataAvailable` 写入 `hardFreeBytes`，保留原始字段名和来源。
- `availableBytes` 标记为未返回，并说明该工具没有提供与 iPhone 设置一致的用户可用
  空间口径。
- 因缺少同口径的用户可用空间，`usedBytes` 不计算，`usageFraction` 返回 `nil`。
- `AmountRestoreAvailable` 和 `TotalDataAvailable` 暂不映射为可清理或用户可用空间。

若其他提供器明确返回成对、同域且语义可验证的总容量与用户可用容量，现有
`availableBytes`、`usedBytes` 和比例计算仍可使用。

### 导入诊断日志

日志中的 `AmountDataAvailable` 采用与实时读取相同的映射：进入 `hardFreeBytes`，不进入
`availableBytes`。只有明确匹配用户可用空间语义的字段才能填充 `availableBytes`。

### 合并与过期状态

设备刷新、实时与日志结果合并、断开后的过期标记都独立处理 `hardFreeBytes`。新一次读取
没有返回设置口径可用空间时，不得用旧的硬空闲值补入 `availableBytes`。

## 界面设计

### 概览页

现有“可用存储”卡片改为“存储空间”：

- 主值：若存在可信的 `availableBytes`，显示该值；否则显示“请在 iPhone 设置中查看”。
- 详情：若存在 `hardFreeBytes`，显示“当前硬空闲 X（不含可回收空间）”；否则显示数据
  可用状态。
- 不展示由硬空闲空间推导出的已使用百分比。

### 存储页

容量概览按语义分别显示：

- 总容量
- 设置口径可用空间
- 当前硬空闲空间（不含可回收空间）
- 已使用容量
- 可清理空间

当设置口径不可读取时，字段说明明确提示“请以 iPhone 设置 → 通用 → iPhone 储存
空间为准”。进度条只在 `usageFraction` 有效时显示。

风险规则区域注明：阈值只应用于可信的用户可用空间，不应用于硬空闲读数。

## 风险分析

`RiskAnalysisService` 继续只根据 `availableBytes` 和有效的 `usageFraction` 判断存储风险。
仅存在 `hardFreeBytes` 时返回 `.insufficient`，且不生成 `storage-low` 风险。风险提示不得
建议用户仅凭硬空闲值删除文件或清理 App。

导入日志中若出现明确的 `no space`、写入失败或其他独立证据，仍可由诊断规则单独分析；
本次修正不削弱这些证据。

## 测试策略

遵循测试先行，至少覆盖：

1. iOS 26 `com.apple.disk_usage` 样本将 `AmountDataAvailable` 解析为
   `hardFreeBytes`，而 `availableBytes`、`usedBytes` 和 `usageFraction` 均不可用。
2. 只有约 3 GiB `hardFreeBytes`、没有用户可用空间时，不生成低存储风险。
3. 具有可信同口径 `availableBytes` 的既有风险阈值测试继续通过。
4. 旧版不含 `hardFreeBytes` 的已保存 JSON 可以解码，并得到缺失状态默认值。
5. 新字段在 stale、合并和重新编码后保持来源、原始字段名与状态。
6. 完整执行 `swift test` 和 `swift build`，确认核心库与 macOS 可执行产品均通过。

## 成功标准

- 实机原始约 3 GB 仍可在存储页看到，但标签明确为硬空闲空间。
- 概览页不再把该值称作“可用存储”。
- 该值不再产生已用百分比或低存储风险。
- 界面明确引导用户以 iPhone 设置中的储存空间为准。
- 旧记录不因模型新增字段而无法读取。
- 全量测试和构建通过。
