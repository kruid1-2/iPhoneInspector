# Storage Capacity Semantics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve the USB hard-free storage reading while preventing it from being presented or analyzed as the iPhone Settings user-available capacity.

**Architecture:** Add a dedicated `hardFreeBytes` value to the core storage model and route `AmountDataAvailable` into it at every parser boundary. Keep `availableBytes` reserved for a verified user-available capacity, so existing usage and risk calculations become unavailable instead of producing a false low-storage warning. Update SwiftUI presentation to show the retained raw value with an explicit label and preserve legacy persisted records with custom decoding.

**Tech Stack:** Swift 6 toolchain, Swift 5 language mode, Swift Package Manager, XCTest, SwiftUI, libimobiledevice plist/text fixtures.

## Global Constraints

- macOS deployment target remains 13.0.
- Do not estimate iPhone Settings capacity from `AmountRestoreAvailable`, `TotalDataAvailable`, or undocumented field arithmetic.
- `AmountDataAvailable` remains visible only as “当前硬空闲空间（不含可回收空间）”.
- Hard-free capacity never participates in used-capacity percentage or low-storage risk rules.
- Existing persisted diagnostics that lack `hardFreeBytes` must continue to decode.
- Do not modify battery or performance-monitoring semantics.
- Do not add any iPhone mutation, cleanup, or deletion behavior.

---

### Task 1: Add a backward-compatible hard-free storage value

**Files:**
- Modify: `Sources/iPhoneMonitorCore/Models/StorageInformation.swift`
- Test: `Tests/iPhoneMonitorCoreTests/CapacityAndModelTests.swift`
- Test: `Tests/iPhoneMonitorCoreTests/RiskAnalysisServiceTests.swift`

**Interfaces:**
- Consumes: existing `DataValue<Int64>`, `StorageInformation.markedStale()`, and synthesized Codable payloads.
- Produces: `StorageInformation.hardFreeBytes: DataValue<Int64>` with default `.missing(.notReturned)` and backward-compatible Codable behavior.

- [ ] **Step 1: Write failing model and compatibility tests**

Add tests that reference the not-yet-existing property and remove its JSON key before decoding:

```swift
func testStorageHardFreeValueBecomesStale() {
    let storage = StorageInformation(
        hardFreeBytes: .available(
            3_700_000_000,
            source: "libimobiledevice",
            rawFieldName: "AmountDataAvailable"
        )
    )

    XCTAssertEqual(storage.markedStale().hardFreeBytes.availability, .stale)
    XCTAssertTrue(storage.hasAnyValue)
}

func testStorageDecodesLegacyJSONWithoutHardFreeValue() throws {
    let original = StorageInformation(
        totalBytes: .available(128_000_000_000, source: "legacy")
    )
    let encoded = try JSONEncoder().encode(original)
    var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "hardFreeBytes")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(
        StorageInformation.self,
        from: legacyData
    )

    XCTAssertNil(decoded.hardFreeBytes.value)
    XCTAssertEqual(decoded.hardFreeBytes.availability, .notReturned)
}

func testHardFreeStorageAloneDoesNotCreateLowStorageRisk() {
    let storage = StorageInformation(
        totalBytes: .available(120_092_147_712, source: "USB"),
        hardFreeBytes: .available(
            3_714_256_896,
            source: "USB",
            rawFieldName: "AmountDataAvailable"
        )
    )

    XCTAssertEqual(service.storageRiskLevel(storage), .insufficient)
    let findings = service.analyze(
        device: nil,
        battery: BatteryInformation(),
        storage: storage,
        records: []
    )
    XCTAssertNil(findings.first { $0.id == "storage-low" })
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter CapacityAndModelTests
swift test --filter RiskAnalysisServiceTests/testHardFreeStorageAloneDoesNotCreateLowStorageRisk
```

Expected: compilation fails because `StorageInformation` has no `hardFreeBytes` member or initializer parameter.

- [ ] **Step 3: Implement the model and custom Codable compatibility**

Add the property and initializer parameter, include it in `markedStale()` and `hasAnyValue`, and replace synthesized decoding with explicit keys:

```swift
public var hardFreeBytes: DataValue<Int64>

private enum CodingKeys: String, CodingKey {
    case totalBytes
    case availableBytes
    case usedBytes
    case reclaimableBytes
    case hardFreeBytes
    case updatedAt
}

public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
        totalBytes: try container.decodeIfPresent(
            DataValue<Int64>.self,
            forKey: .totalBytes
        ) ?? .missing(.notReturned),
        availableBytes: try container.decodeIfPresent(
            DataValue<Int64>.self,
            forKey: .availableBytes
        ) ?? .missing(.notReturned),
        usedBytes: try container.decodeIfPresent(
            DataValue<Int64>.self,
            forKey: .usedBytes
        ) ?? .missing(.notReturned),
        reclaimableBytes: try container.decodeIfPresent(
            DataValue<Int64>.self,
            forKey: .reclaimableBytes
        ) ?? .missing(.notSupported),
        hardFreeBytes: try container.decodeIfPresent(
            DataValue<Int64>.self,
            forKey: .hardFreeBytes
        ) ?? .missing(.notReturned),
        updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    )
}
```

Implement `encode(to:)` with the same six keys so new persisted records retain all values.

```swift
public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(totalBytes, forKey: .totalBytes)
    try container.encode(availableBytes, forKey: .availableBytes)
    try container.encode(usedBytes, forKey: .usedBytes)
    try container.encode(reclaimableBytes, forKey: .reclaimableBytes)
    try container.encode(hardFreeBytes, forKey: .hardFreeBytes)
    try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
}
```

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run:

```bash
swift test --filter CapacityAndModelTests
swift test --filter RiskAnalysisServiceTests/testHardFreeStorageAloneDoesNotCreateLowStorageRisk
```

Expected: all `CapacityAndModelTests` pass.

- [ ] **Step 5: Commit the model change**

```bash
git add Sources/iPhoneMonitorCore/Models/StorageInformation.swift Tests/iPhoneMonitorCoreTests/CapacityAndModelTests.swift Tests/iPhoneMonitorCoreTests/RiskAnalysisServiceTests.swift
git commit -m "fix: separate hard-free storage value"
```

### Task 2: Route live `AmountDataAvailable` into the hard-free field

**Files:**
- Modify: `Sources/iPhoneMonitorCore/Services/DeviceDetailOutputParser.swift`
- Modify: `Sources/iPhoneMonitorCore/Services/DeviceInformationService.swift`
- Test: `Tests/iPhoneMonitorCoreTests/LiveDeviceDetailParserTests.swift`
- Test: `Tests/iPhoneMonitorCoreTests/DeviceProviderParserTests.swift`

**Interfaces:**
- Consumes: `StorageInformation.hardFreeBytes` from Task 1 and live plist/key-value device output.
- Produces: live `StorageInformation` where `AmountDataAvailable` populates only `hardFreeBytes`; `availableBytes`, `usedBytes`, and `usageFraction` remain unavailable for that input.

- [ ] **Step 1: Change live parser expectations to the corrected semantics**

For both XML and legacy key-value fixtures containing `TotalDataCapacity` plus `AmountDataAvailable`, assert:

```swift
XCTAssertEqual(storage.totalBytes.value, 120_092_147_712)
XCTAssertNil(storage.availableBytes.value)
XCTAssertEqual(storage.availableBytes.availability, .notReturned)
XCTAssertEqual(storage.hardFreeBytes.value, 18_514_563_072)
XCTAssertEqual(storage.hardFreeBytes.rawFieldName, "AmountDataAvailable")
XCTAssertNil(storage.usedBytes.value)
XCTAssertNil(storage.usageFraction)
```

Update the merge test so a `devicectl` total-capacity result combined with a libimobiledevice hard-free result preserves both values without creating a usage fraction.

- [ ] **Step 2: Run live parser tests and verify RED**

Run:

```bash
swift test --filter LiveDeviceDetailParserTests
swift test --filter DeviceProviderParserTests/testDeviceDetailStorageParser
```

Expected: assertions fail because `AmountDataAvailable` still populates `availableBytes` and `usedBytes`.

- [ ] **Step 3: Implement separate live field matching**

Remove `AmountDataAvailable` from the user-available aliases and collect it independently:

```swift
private static let hardFreeStorageKeys = [
    "AmountDataAvailable"
]

private struct StorageMatches {
    let total: LocatedValue?
    let available: LocatedValue?
    let hardFree: LocatedValue?
}
```

Pass the three matches into the storage builder. Convert `hardFree` with `capacityField`, store it in `hardFreeBytes`, and calculate `usedBytes` only from a verified `availableBytes` pair. When only `AmountDataAvailable` is present, set the user-available detail to:

```text
当前工具只返回硬空闲空间，未返回与 iPhone 设置一致的用户可用空间
```

Update `missingStorage` to propagate failure status into `hardFreeBytes`. Include `hardFreeBytes` in `DeviceDetailOutputParser.mergeStorage` and `DeviceInformationService.storageScore` so the richer libimobiledevice result wins without awarding the valid-usage bonus.

- [ ] **Step 4: Run live parser tests and verify GREEN**

Run:

```bash
swift test --filter LiveDeviceDetailParserTests
swift test --filter DeviceProviderParserTests
```

Expected: all selected tests pass; the iOS 26 fixture retains its hard-free value and has no calculated used percentage.

- [ ] **Step 5: Commit live parser changes**

```bash
git add Sources/iPhoneMonitorCore/Services/DeviceDetailOutputParser.swift Sources/iPhoneMonitorCore/Services/DeviceInformationService.swift Tests/iPhoneMonitorCoreTests/LiveDeviceDetailParserTests.swift Tests/iPhoneMonitorCoreTests/DeviceProviderParserTests.swift
git commit -m "fix: classify device hard-free storage"
```

### Task 3: Keep the corrected semantic through diagnostic and store merges

**Files:**
- Modify: `Sources/iPhoneMonitorCore/Services/DiagnosticParser.swift`
- Modify: `Sources/iPhoneMonitorCore/Services/DiagnosticImportService.swift`
- Modify: `Sources/iPhoneMonitor/Stores/AppStore.swift`
- Modify: `Sources/iPhoneMonitor/Stores/DeviceStore.swift`
- Test: `Tests/iPhoneMonitorCoreTests/DiagnosticParserCoverageTests.swift`

**Interfaces:**
- Consumes: `StorageInformation.hardFreeBytes` and diagnostic text containing `AmountDataAvailable`.
- Produces: diagnostic and in-memory merges that retain hard-free source metadata without copying it into `availableBytes`.

- [ ] **Step 1: Add a failing diagnostic parser regression test**

```swift
func testAmountDataAvailableIsParsedAsHardFreeStorage() {
    let parsed = parser.parse(
        text: """
        TotalDataCapacity: 120092147712
        AmountDataAvailable: 3714256896
        """,
        fileName: "disk-usage.log"
    )

    XCTAssertEqual(parsed.storage.totalBytes.value, 120_092_147_712)
    XCTAssertEqual(parsed.storage.hardFreeBytes.value, 3_714_256_896)
    XCTAssertEqual(
        parsed.storage.hardFreeBytes.rawFieldName,
        "AmountDataAvailable"
    )
    XCTAssertNil(parsed.storage.availableBytes.value)
    XCTAssertNil(parsed.storage.usedBytes.value)
    XCTAssertNil(parsed.storage.usageFraction)
}
```

- [ ] **Step 2: Run the diagnostic test and verify RED**

Run:

```bash
swift test --filter DiagnosticParserCoverageTests/testAmountDataAvailableIsParsedAsHardFreeStorage
```

Expected: the parser puts the value in `availableBytes` and computes `usedBytes`.

- [ ] **Step 3: Implement diagnostic mapping and all merge propagation**

In `DiagnosticParser.parseStorage`, keep `FreeStorageGB` as a user-available summary, but map `AmountDataAvailable` separately. Use explicit locals so the two values cannot alias:

```swift
let summaryAvailable = DiagnosticTextParser.freeStorageGB(from: text).map {
    Int64($0 * 1_024 * 1_024 * 1_024)
}
let hardFree: Int64?
let available: Int64?

if dataTotal != nil || dataAvailable != nil {
    hardFree = dataAvailable
    available = nil
} else {
    hardFree = nil
    available = diskAvailable ?? summaryAvailable
}
```

Only compute `usedBytes` from `total` and the verified user-available value. In `DiagnosticImportService.mergeStorage`, `AppStore.mergeStorage`, and `DeviceStore.reconciledStorage`, merge or reconcile `hardFreeBytes` independently:

```swift
if result.hardFreeBytes.value == nil,
   fallback.hardFreeBytes.value != nil {
    result.hardFreeBytes = fallback.hardFreeBytes
}
```

Include `hardFreeBytes` in stale propagation and preserve its source, raw field name, confidence, and update time.

- [ ] **Step 4: Run diagnostic and model tests and verify GREEN**

Run:

```bash
swift test --filter DiagnosticParserCoverageTests
swift test --filter CapacityAndModelTests
```

Expected: selected tests pass with hard-free metadata retained.

- [ ] **Step 5: Commit diagnostic and merge changes**

```bash
git add Sources/iPhoneMonitorCore/Services/DiagnosticParser.swift Sources/iPhoneMonitorCore/Services/DiagnosticImportService.swift Sources/iPhoneMonitor/Stores/AppStore.swift Sources/iPhoneMonitor/Stores/DeviceStore.swift Tests/iPhoneMonitorCoreTests/DiagnosticParserCoverageTests.swift
git commit -m "fix: preserve hard-free storage across merges"
```

### Task 4: Correct both storage views and document the semantic split

**Files:**
- Create: `Sources/iPhoneMonitorCore/Models/StorageOverviewPresentation.swift`
- Modify: `Sources/iPhoneMonitor/Views/OverviewView.swift`
- Modify: `Sources/iPhoneMonitor/Views/StorageView.swift`
- Modify: `Sources/iPhoneMonitorCore/Support/DemoDataFactory.swift`
- Modify: `README.md`
- Create: `Tests/iPhoneMonitorCoreTests/StorageOverviewPresentationTests.swift`

**Interfaces:**
- Consumes: semantic split from Tasks 1–3.
- Produces: a tested presentation state and UI text that distinguish Settings capacity from current hard-free capacity.

- [ ] **Step 1: Add a failing overview presentation test**

```swift
import XCTest
@testable import iPhoneMonitorCore

final class StorageOverviewPresentationTests: XCTestCase {
    func testHardFreeOnlyRequiresSettingsAndRetainsDiagnosticValue() {
    let storage = StorageInformation(
        totalBytes: .available(120_092_147_712, source: "USB"),
        hardFreeBytes: .available(
            3_714_256_896,
            source: "USB",
            rawFieldName: "AmountDataAvailable"
        )
    )

        let presentation = StorageOverviewPresentation.resolve(storage)

        XCTAssertEqual(presentation.primaryValue, .settingsRequired)
        XCTAssertEqual(presentation.hardFreeBytes, 3_714_256_896)
        XCTAssertNil(presentation.usageFraction)
    }
}
```

- [ ] **Step 2: Run the presentation test and verify RED**

Run:

```bash
swift test --filter StorageOverviewPresentationTests
```

Expected: compilation fails because `StorageOverviewPresentation` does not exist.

- [ ] **Step 3: Implement the presentation state and explanatory copy**

Create the core presentation resolver:

```swift
public struct StorageOverviewPresentation: Equatable, Sendable {
    public enum PrimaryValue: Equatable, Sendable {
        case userAvailable(Int64)
        case settingsRequired
    }

    public let primaryValue: PrimaryValue
    public let hardFreeBytes: Int64?
    public let usageFraction: Double?

    public static func resolve(_ storage: StorageInformation) -> Self {
        Self(
            primaryValue: storage.availableBytes.value.map(PrimaryValue.userAvailable)
                ?? .settingsRequired,
            hardFreeBytes: storage.hardFreeBytes.value,
            usageFraction: storage.usageFraction
        )
    }
}
```

Change the overview metric to:

```swift
MetricCard(
    title: "存储空间",
    value: appStore.effectiveStorage.availableBytes.value
        .map { AppFormatters.bytes($0) } ?? "请在 iPhone 设置中查看",
    detail: storageDetail,
    systemImage: "internaldrive",
    tint: .indigo
)
```

Make `storageDetail` prefer:

```swift
if let hardFree = appStore.effectiveStorage.hardFreeBytes.value {
    return "当前硬空闲 \(AppFormatters.bytes(hardFree))（不含可回收空间）"
}
```

On `StorageView`, rename the user-facing row to “设置口径可用空间”, add a row named
“当前硬空闲空间（不含可回收空间）”, and show the Settings guidance in the unavailable field detail. Keep the progress bar conditional on `usageFraction` and change the rules note to say that thresholds apply only to verified user-available capacity.

Keep the existing verified demo `availableBytes` and add an explicit demo `hardFreeBytes` value of 8 GiB so both UI states remain visibly marked as demo data.

Update README storage claims and known limitations to document both capacities and state that `AmountDataAvailable` is not the Settings value.

- [ ] **Step 4: Run risk tests and compile the SwiftUI executable**

Run:

```bash
swift test --filter StorageOverviewPresentationTests
swift test --filter RiskAnalysisServiceTests
swift build --product iPhoneInspector
```

Expected: risk tests pass and the executable builds without SwiftUI type errors.

- [ ] **Step 5: Commit UI, risk, and documentation changes**

```bash
git add Sources/iPhoneMonitorCore/Models/StorageOverviewPresentation.swift Sources/iPhoneMonitor/Views/OverviewView.swift Sources/iPhoneMonitor/Views/StorageView.swift Sources/iPhoneMonitorCore/Support/DemoDataFactory.swift Tests/iPhoneMonitorCoreTests/StorageOverviewPresentationTests.swift README.md
git commit -m "fix: present storage capacity without false risk"
```

### Task 5: Run full verification, package, install, and check the real device UI

**Files:**
- Verify: all Swift sources and tests
- Build artifact: `dist/iPhone Inspector.app`
- Installed artifact: `/Applications/iPhone Inspector.app`

**Interfaces:**
- Consumes: completed Tasks 1–4.
- Produces: tested, signed, installed, and launched macOS app with the corrected storage display.

- [ ] **Step 1: Run the complete test and build gates**

Run:

```bash
swift test
swift build --product iPhoneInspector
git diff --check
```

Expected: zero test failures, successful build, and no whitespace errors.

- [ ] **Step 2: Build and launch the signed app bundle**

Run:

```bash
./script/build_and_run.sh --verify
```

Expected: `dist/iPhone Inspector.app` passes strict code-signature verification and the exact dist executable remains running.

- [ ] **Step 3: Install the verified bundle with a recoverable backup**

Stop only the exact app process, move the existing installed bundle to a uniquely named item under `/Users/a66/.Trash`, copy the verified dist bundle into `/Applications`, and launch it:

```bash
pkill -x iPhoneInspector || true
backup_dir=$(mktemp -d "/Users/a66/.Trash/iPhone-Inspector-backup.XXXXXX")
mv "/Applications/iPhone Inspector.app" "$backup_dir/iPhone Inspector.app"
ditto --norsrc "dist/iPhone Inspector.app" "/Applications/iPhone Inspector.app"
open -n -a "/Applications/iPhone Inspector.app"
```

Expected: the previous installed bundle remains recoverable in Trash and the new installed bundle launches.

- [ ] **Step 4: Verify installation identity, signature, and storage semantics**

Run:

```bash
codesign --verify --deep --strict "/Applications/iPhone Inspector.app"
pgrep -f -x "/Applications/iPhone Inspector.app/Contents/MacOS/iPhoneInspector"
```

With the connected iPhone unlocked, refresh once and inspect the overview and storage pages. Expected:

- Overview does not label approximately 3 GB as “可用存储”.
- Storage page retains approximately 3 GB as “当前硬空闲空间（不含可回收空间）”.
- No used percentage or low-storage risk is derived from that hard-free value.
- The UI instructs the user to check iPhone Settings for user-available capacity.

- [ ] **Step 5: Review final repository state**

Run:

```bash
git status --short --branch
git log -6 --oneline --decorate
```

Expected: no unintended uncommitted files; commits correspond only to the approved storage semantic correction and its documentation.
