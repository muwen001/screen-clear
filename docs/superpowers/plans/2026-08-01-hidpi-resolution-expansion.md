# ScreenClear HiDPI Resolution Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add upgrade-safe 1920×1080 @2x and 2560×1440 @2x override support without adding a new preset or modifying the real display configuration during automated tests.

**Architecture:** `OverrideBuilder` owns one typed catalog for all managed logical/rendered mode pairs and pure plist inspection/merge behavior. `OverrideInstaller` owns filesystem state and a tested privileged atomic-replacement command, while `AppModel` and `MenuContent` map the resulting state into explicit install/update/current/invalid UI flows and require both requested modes before reporting activation.

**Tech Stack:** Swift 6.1, SwiftUI/AppKit, Foundation property lists, CoreGraphics mode enumeration, XCTest, macOS `/usr/bin/osascript`, `/usr/bin/plutil`, `/bin/sh`, existing Bash packaging gates.

## Global Constraints

- Deployment target remains macOS 14.0; add no external package dependency.
- Target display remains vendor 1507 (`0x5e3`) and product 9360 (`0x2490`).
- Managed modes are exactly 1440×810→2880×1620, 1600×900→3200×1800, 1920×1080→3840×2160, and 2560×1440→5120×2880.
- Do not add a 2560×1440 preset; activated modes appear only in “其他可用模式”.
- Reading app state must never prompt for administrator access or write the override.
- Invalid or mismatched existing plists must not be overwritten; extra keys and extra mode entries in valid plists must survive updates.
- Automated tests, builds, packaging, and app installation must not change the real override, display mode, LinkDescription, or LaunchAgent.
- The app remains ad-hoc signed and local-only; Developer ID signing and notarization are out of scope.
- The real override update is user-triggered from the installed app and requires the user to approve the macOS administrator prompt.

## File Map

- Modify `Sources/ScreenClear/OverrideBuilder.swift` — typed mode catalog and entry encoding.
- Create `Sources/ScreenClear/OverrideConfiguration.swift` — pure plist classification, lossless merge, and activation predicate as an `OverrideBuilder` extension.
- Modify `Sources/ScreenClear/OverrideInstaller.swift` — path-level state reading, unique temp file, quoted privileged command, validated atomic replacement.
- Modify `Sources/ScreenClear/AppModel.swift` — replace the installed boolean with configuration state, install/update orchestration, exact activation polling.
- Modify `Sources/ScreenClear/MenuContent.swift` — render install/update/current/invalid actions without adding a preset.
- Modify `Sources/ScreenClear/SelfTest.swift` — exercise the complete managed catalog in memory.
- Modify `README.md` — document the two requested modes and upgrade UI.
- Modify `Tests/ScreenClearTests/OverrideBuilderTests.swift` — catalog, encoding, canonical plist, merge, invalid-input, and activation tests.
- Create `Tests/ScreenClearTests/OverrideInstallerTests.swift` — isolated file-state and atomic shell-command tests.

---

### Task 1: Central Mode Catalog and Pure Plist Upgrade Logic

**Files:**
- Modify: `Sources/ScreenClear/OverrideBuilder.swift:3-65`
- Create: `Sources/ScreenClear/OverrideConfiguration.swift`
- Modify: `Tests/ScreenClearTests/OverrideBuilderTests.swift:5-36`

**Interfaces:**
- Consumes: existing `ModeEntry` fields and the existing vendor/product constants.
- Produces: `HiDPIModeSpec`, `OverrideConfigurationState`, `OverrideBuilder.managedModes`, `OverrideBuilder.managedEntryData`, `OverrideBuilder.buildManagedPlist(existingData:)`, and `OverrideBuilder.configurationState(for:)`.

- [ ] **Step 1: Add failing catalog, encoding, canonical-plist, and merge tests**

Replace the three-entry assertion and add helpers/tests with these behaviors:

```swift
private func plistData(
    entries: [Data],
    vendorID: Int = OverrideBuilder.vendorID,
    productID: Int = OverrideBuilder.productID,
    extra: [String: Any] = [:]
) throws -> Data {
    var root = extra
    root["DisplayVendorID"] = vendorID
    root["DisplayProductID"] = productID
    root["scale-resolutions"] = entries
    return try PropertyListSerialization.data(
        fromPropertyList: root,
        format: .xml,
        options: 0
    )
}

func testManagedCatalogContainsFourLogicalAndRenderedModes() {
    XCTAssertEqual(
        OverrideBuilder.managedModes,
        [
            HiDPIModeSpec(logicalWidth: 1440, logicalHeight: 810, pixelWidth: 2880, pixelHeight: 1620),
            HiDPIModeSpec(logicalWidth: 1600, logicalHeight: 900, pixelWidth: 3200, pixelHeight: 1800),
            HiDPIModeSpec(logicalWidth: 1920, logicalHeight: 1080, pixelWidth: 3840, pixelHeight: 2160),
            HiDPIModeSpec(logicalWidth: 2560, logicalHeight: 1440, pixelWidth: 5120, pixelHeight: 2880),
        ]
    )
}

func testFiveKEntryHasKnownEncodingAndRoundTrips() {
    let entry = OverrideBuilder.scaleEntry(pixelWidth: 5120, pixelHeight: 2880)
    XCTAssertEqual(entry, "AAAUAAAAC0AA")
    XCTAssertTrue(OverrideBuilder.verifyEntry(entry, pixelWidth: 5120, pixelHeight: 2880))
}

func testManagedPlistContainsFourUniqueEntries() throws {
    let xml = try OverrideBuilder.buildManagedPlist(existingData: nil).get()
    let data = try XCTUnwrap(xml.data(using: .utf8))
    let root = try XCTUnwrap(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )
    let entries = try XCTUnwrap(root["scale-resolutions"] as? [Data])
    XCTAssertEqual(root["DisplayVendorID"] as? Int, 1507)
    XCTAssertEqual(root["DisplayProductID"] as? Int, 9360)
    XCTAssertEqual(entries.count, 4)
    XCTAssertEqual(Set(entries).count, 4)
}

func testOldTwoEntryPlistIsOutdatedAndMergePreservesExtras() throws {
    let oldEntries = [
        OverrideBuilder.scaleEntryData(pixelWidth: 2880, pixelHeight: 1620),
        OverrideBuilder.scaleEntryData(pixelWidth: 3200, pixelHeight: 1800),
    ]
    let custom = OverrideBuilder.scaleEntryData(pixelWidth: 4096, pixelHeight: 2304)
    let oldData = try plistData(
        entries: oldEntries + [custom, custom],
        extra: ["DisplayProductName": "Custom AOC", "CustomFlag": true]
    )
    XCTAssertEqual(OverrideBuilder.configurationState(for: oldData), .outdated)

    let mergedXML = try OverrideBuilder.buildManagedPlist(existingData: oldData).get()
    let mergedData = try XCTUnwrap(mergedXML.data(using: .utf8))
    let root = try XCTUnwrap(
        PropertyListSerialization.propertyList(from: mergedData, format: nil) as? [String: Any]
    )
    let entries = try XCTUnwrap(root["scale-resolutions"] as? [Data])
    XCTAssertEqual(root["DisplayProductName"] as? String, "Custom AOC")
    XCTAssertEqual(root["CustomFlag"] as? Bool, true)
    XCTAssertEqual(entries.filter { $0 == custom }.count, 1)
    XCTAssertTrue(Set(OverrideBuilder.managedEntryData).isSubset(of: Set(entries)))
}

func testCurrentAllowsExtraEntryAndInvalidInputsAreRejected() throws {
    let extra = OverrideBuilder.scaleEntryData(pixelWidth: 4096, pixelHeight: 2304)
    let current = try plistData(entries: OverrideBuilder.managedEntryData + [extra])
    XCTAssertEqual(OverrideBuilder.configurationState(for: current), .current)

    let wrongID = try plistData(entries: OverrideBuilder.managedEntryData, vendorID: 1)
    guard case .invalid = OverrideBuilder.configurationState(for: wrongID) else {
        return XCTFail("wrong vendor must be invalid")
    }
    guard case .failure = OverrideBuilder.buildManagedPlist(existingData: wrongID) else {
        return XCTFail("invalid existing data must not be overwritten")
    }
    let wrongType = try PropertyListSerialization.data(
        fromPropertyList: [
            "DisplayVendorID": OverrideBuilder.vendorID,
            "DisplayProductID": OverrideBuilder.productID,
            "scale-resolutions": ["not data"],
        ],
        format: .xml,
        options: 0
    )
    guard case .invalid = OverrideBuilder.configurationState(for: wrongType) else {
        return XCTFail("non-data scale-resolutions must be invalid")
    }
    guard case .invalid = OverrideBuilder.configurationState(for: Data("not plist".utf8)) else {
        return XCTFail("malformed plist must be invalid")
    }
}

```

- [ ] **Step 2: Run the focused tests and confirm RED**

Run:

```bash
swift test --filter OverrideBuilderTests
```

Expected: compilation fails because `HiDPIModeSpec`, `managedModes`, `scaleEntryData`, `buildManagedPlist`, and `configurationState` do not exist.

- [ ] **Step 3: Add the typed catalog and byte encoder**

Add this value type and catalog to `OverrideBuilder.swift`, retain `scaleEntry` as a compatibility wrapper, and remove call-site-owned render arrays later in Task 3:

```swift
struct HiDPIModeSpec: Hashable, Sendable {
    let logicalWidth: Int
    let logicalHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int

    func matches(_ mode: ModeEntry) -> Bool {
        mode.isHiDPI
            && mode.logicalWidth == logicalWidth
            && mode.logicalHeight == logicalHeight
            && mode.pixelWidth == pixelWidth
            && mode.pixelHeight == pixelHeight
    }
}

enum OverrideConfigurationState: Equatable, Sendable {
    case missing
    case current
    case outdated
    case invalid(String)
}

static let managedModes: [HiDPIModeSpec] = [
    .init(logicalWidth: 1440, logicalHeight: 810, pixelWidth: 2880, pixelHeight: 1620),
    .init(logicalWidth: 1600, logicalHeight: 900, pixelWidth: 3200, pixelHeight: 1800),
    .init(logicalWidth: 1920, logicalHeight: 1080, pixelWidth: 3840, pixelHeight: 2160),
    .init(logicalWidth: 2560, logicalHeight: 1440, pixelWidth: 5120, pixelHeight: 2880),
]

static func scaleEntryData(pixelWidth: Int, pixelHeight: Int) -> Data {
    var bytes: [UInt8] = [
        UInt8((pixelWidth >> 24) & 0xFF), UInt8((pixelWidth >> 16) & 0xFF),
        UInt8((pixelWidth >> 8) & 0xFF), UInt8(pixelWidth & 0xFF),
        UInt8((pixelHeight >> 24) & 0xFF), UInt8((pixelHeight >> 16) & 0xFF),
        UInt8((pixelHeight >> 8) & 0xFF), UInt8(pixelHeight & 0xFF),
        0,
    ]
    return Data(bytes)
}

static func scaleEntry(pixelWidth: Int, pixelHeight: Int) -> String {
    scaleEntryData(pixelWidth: pixelWidth, pixelHeight: pixelHeight).base64EncodedString()
}

static var managedEntryData: [Data] {
    managedModes.map {
        scaleEntryData(pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight)
    }
}
```

- [ ] **Step 4: Implement pure classification, lossless merge, and activation checks**

Create `OverrideConfiguration.swift` as an `OverrideBuilder` extension. Parse with `PropertyListSerialization`, require the exact vendor/product and `[Data]` mode array, de-duplicate existing entries in first-seen order, append missing managed entries in catalog order, and serialize XML:

```swift
extension OverrideBuilder {
    private static func parsedRoot(from data: Data) -> Result<[String: Any], String> {
        do {
            guard let root = try PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any] else {
                return .failure("override plist 根对象不是字典")
            }
            guard root["DisplayVendorID"] as? Int == vendorID,
                  root["DisplayProductID"] as? Int == productID else {
                return .failure("override 显示器标识不匹配")
            }
            guard root["scale-resolutions"] is [Data] else {
                return .failure("scale-resolutions 不是 data 数组")
            }
            return .success(root)
        } catch {
            return .failure("解析 override plist 失败：\(error.localizedDescription)")
        }
    }

    static func configurationState(for data: Data) -> OverrideConfigurationState {
        switch parsedRoot(from: data) {
        case .failure(let reason):
            return .invalid(reason)
        case .success(let root):
            guard let entries = root["scale-resolutions"] as? [Data] else {
                return .invalid("scale-resolutions 不是 data 数组")
            }
            return Set(managedEntryData).isSubset(of: Set(entries)) ? .current : .outdated
        }
    }

    static func buildManagedPlist(existingData: Data?) -> Result<String, String> {
        var root: [String: Any]
        if let existingData {
            switch parsedRoot(from: existingData) {
            case .failure(let reason): return .failure(reason)
            case .success(let parsed): root = parsed
            }
        } else {
            root = [
                "DisplayVendorID": vendorID,
                "DisplayProductID": productID,
                "scale-resolutions": [Data](),
            ]
        }
        guard let existing = root["scale-resolutions"] as? [Data] else {
            return .failure("scale-resolutions 不是 data 数组")
        }
        var seen = Set<Data>()
        var merged = existing.filter { seen.insert($0).inserted }
        for entry in managedEntryData where seen.insert(entry).inserted {
            merged.append(entry)
        }
        root["scale-resolutions"] = merged
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: root,
                format: .xml,
                options: 0
            )
            guard let xml = String(data: data, encoding: .utf8) else {
                return .failure("生成的 plist 不是 UTF-8")
            }
            return .success(xml)
        } catch {
            return .failure("生成 plist 失败：\(error.localizedDescription)")
        }
    }

}
```

Keep `parsedRoot(from:)` private to the pure configuration extension. Do not coerce or overwrite any malformed, mismatched, or incorrectly typed input.

- [ ] **Step 5: Run focused and full Swift tests and confirm GREEN**

Run:

```bash
swift test --filter OverrideBuilderTests
swift test
git diff --check
```

Expected: all catalog/configuration tests pass; the full suite reports zero failures; `git diff --check` prints nothing.

- [ ] **Step 6: Commit Task 1**

```bash
git add Sources/ScreenClear/OverrideBuilder.swift Sources/ScreenClear/OverrideConfiguration.swift Tests/ScreenClearTests/OverrideBuilderTests.swift
git commit -m "feat: centralize HiDPI override modes"
```

---

### Task 2: Read-Only State Detection and Atomic Privileged Replacement

**Files:**
- Modify: `Sources/ScreenClear/OverrideInstaller.swift:3-58`
- Create: `Tests/ScreenClearTests/OverrideInstallerTests.swift`

**Interfaces:**
- Consumes: `OverrideBuilder.configurationState(for:)`, `OverrideBuilder.targetDir`, and `OverrideBuilder.targetFile` from Task 1.
- Produces: `OverrideInstaller.configurationState(atPath:)`, `OverrideInstaller.existingData(atPath:)`, `OverrideInstaller.install(plistXML:)`, and internal testable `shellQuote(_:)` / `privilegedInstallCommand(sourcePath:targetDirectory:targetFile:token:)` helpers.

- [ ] **Step 1: Write failing isolated installer tests**

Create `OverrideInstallerTests.swift` with a unique temporary root per test and cleanup limited to that root:

```swift
final class OverrideInstallerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenclear-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempRoot)
    }

    func testPathStateDistinguishesMissingOutdatedCurrentAndInvalid() throws {
        let target = tempRoot.appendingPathComponent("DisplayProductID-2490")
        XCTAssertEqual(OverrideInstaller.configurationState(atPath: target.path), .missing)

        let oldXML = try OverrideBuilder.buildPlist(
            renderResolutions: [(2880, 1620), (3200, 1800)]
        ).get()
        try oldXML.write(to: target, atomically: true, encoding: .utf8)
        XCTAssertEqual(OverrideInstaller.configurationState(atPath: target.path), .outdated)

        let currentXML = try OverrideBuilder.buildManagedPlist(existingData: nil).get()
        try currentXML.write(to: target, atomically: true, encoding: .utf8)
        XCTAssertEqual(OverrideInstaller.configurationState(atPath: target.path), .current)

        try Data("broken".utf8).write(to: target)
        guard case .invalid = OverrideInstaller.configurationState(atPath: target.path) else {
            return XCTFail("broken plist must be invalid")
        }
    }

    func testPrivilegedCommandAtomicallyReplacesValidTargetAndQuotesSpaces() throws {
        let directory = tempRoot.appendingPathComponent("target dir's", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("DisplayProductID-2490")
        let source = tempRoot.appendingPathComponent("new config.plist")
        try Data("old".utf8).write(to: target)
        let newXML = try OverrideBuilder.buildManagedPlist(existingData: nil).get()
        try newXML.write(to: source, atomically: true, encoding: .utf8)

        let command = OverrideInstaller.privilegedInstallCommand(
            sourcePath: source.path,
            targetDirectory: directory.path,
            targetFile: target.path,
            token: "TEST"
        )
        XCTAssertEqual(try runShell(command), 0)
        XCTAssertEqual(try Data(contentsOf: target), Data(newXML.utf8))
        XCTAssertTrue(try stagedFiles(in: directory).isEmpty)
    }

    func testPrivilegedCommandKeepsOldTargetWhenValidationFails() throws {
        let directory = tempRoot.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("DisplayProductID-2490")
        let source = tempRoot.appendingPathComponent("invalid.plist")
        let old = Data("old-target".utf8)
        try old.write(to: target)
        try Data("invalid-new-plist".utf8).write(to: source)

        let command = OverrideInstaller.privilegedInstallCommand(
            sourcePath: source.path,
            targetDirectory: directory.path,
            targetFile: target.path,
            token: "FAIL"
        )
        XCTAssertNotEqual(try runShell(command), 0)
        XCTAssertEqual(try Data(contentsOf: target), old)
        XCTAssertTrue(try stagedFiles(in: directory).isEmpty)
    }
}
```

Add these test helpers so the command runs only against the test-owned directory:

```swift
private func runShell(_ command: String) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private func stagedFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.contains(".screenclear-") }
}
```

- [ ] **Step 2: Run installer tests and confirm RED**

Run:

```bash
swift test --filter OverrideInstallerTests
```

Expected: compilation fails because the state reader and command builder do not exist.

- [ ] **Step 3: Implement injected read-only state and existing-data access**

Replace `isInstalled()` with defaults that point to the real target but permit temporary-path tests:

```swift
static func configurationState(atPath path: String = OverrideBuilder.targetFile) -> OverrideConfigurationState {
    guard FileManager.default.fileExists(atPath: path) else { return .missing }
    do {
        return OverrideBuilder.configurationState(for: try Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        return .invalid("读取 override 失败：\(error.localizedDescription)")
    }
}

static func existingData(atPath path: String = OverrideBuilder.targetFile) -> Result<Data?, String> {
    guard FileManager.default.fileExists(atPath: path) else { return .success(nil) }
    do {
        return .success(try Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        return .failure("读取 override 失败：\(error.localizedDescription)")
    }
}
```

- [ ] **Step 4: Implement a quoted, validated, same-directory atomic replacement**

`shellQuote(_:)` must single-quote every path and replace an embedded apostrophe with `'"'"'`. `privilegedInstallCommand` must derive the stage as `targetFile + ".screenclear-" + token`, validate that exact stage with `/usr/bin/plutil -lint`, set mode `0644`, and move it over the target only after validation. An EXIT/HUP/INT/TERM trap removes only the exact stage.

Implement the builders as:

```swift
static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

static func privilegedInstallCommand(
    sourcePath: String,
    targetDirectory: String,
    targetFile: String,
    token: String
) -> String {
    let stage = targetFile + ".screenclear-" + token
    return [
        "set -e",
        "stage=\(shellQuote(stage))",
        "cleanup() { /bin/rm -f \"$stage\"; }",
        "trap cleanup EXIT HUP INT TERM",
        "/bin/mkdir -p \(shellQuote(targetDirectory))",
        "/bin/cp \(shellQuote(sourcePath)) \"$stage\"",
        "/usr/bin/plutil -lint \"$stage\" >/dev/null",
        "/bin/chmod 0644 \"$stage\"",
        "/bin/mv -f \"$stage\" \(shellQuote(targetFile))",
        "trap - EXIT HUP INT TERM",
    ].joined(separator: "; ")
}

static func appleScriptStringLiteral(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}
```

The generated command’s array order is the contract: enable `set -e`, assign the quoted stage, install the cleanup trap, create the quoted directory, copy the quoted source, lint, chmod, move over the quoted target, then disable the success-path trap.

Update `install(plistXML:)` to create a unique temporary directory with `UUID`, write `override.plist` inside it, build the tested command with a separate UUID token, wrap it as an AppleScript string literal, call `runOSAScript`, and remove only the owned temporary directory in `defer`. Do not use the predictable `/tmp/screenclear-PID.plist` path.

Use this control flow:

```swift
static func install(plistXML: String) async -> Result<Void, String> {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screenclear-override-\(UUID().uuidString)", isDirectory: true)
    let source = root.appendingPathComponent("override.plist")
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try plistXML.write(to: source, atomically: true, encoding: .utf8)
    } catch {
        try? FileManager.default.removeItem(at: root)
        return .failure("写入临时 override 失败：\(error.localizedDescription)")
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let command = privilegedInstallCommand(
        sourcePath: source.path,
        targetDirectory: OverrideBuilder.targetDir,
        targetFile: OverrideBuilder.targetFile,
        token: UUID().uuidString
    )
    let script = "do shell script \(appleScriptStringLiteral(command)) with administrator privileges"
    return await runOSAScript(script)
}
```

- [ ] **Step 5: Run focused tests, the full suite, and syntax checks**

Run:

```bash
swift test --filter OverrideInstallerTests
swift test
swift build -c debug
git diff --check
```

Expected: the successful fixture replaces the target, the invalid fixture preserves `old-target`, no staged fixture files remain, all Swift tests pass, and Debug build succeeds.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/ScreenClear/OverrideInstaller.swift Tests/ScreenClearTests/OverrideInstallerTests.swift
git commit -m "feat: safely update HiDPI overrides"
```

---

### Task 3: Upgrade UI, Exact Activation Polling, Self-Test, and Documentation

**Files:**
- Modify: `Sources/ScreenClear/AppModel.swift:9-18,53-64,122-213`
- Modify: `Sources/ScreenClear/MenuContent.swift:127-145`
- Modify: `Sources/ScreenClear/SelfTest.swift:33-55`
- Modify: `README.md:35-47,68-72`
- Test: `Tests/ScreenClearTests/OverrideBuilderTests.swift`

**Interfaces:**
- Consumes: all Task 1 configuration APIs and Task 2 installer APIs.
- Produces: `AppModel.overrideConfigurationState`, `AppModel.installOrUpdateOverride()`, state-specific UI actions, and polling based on `OverrideBuilder.activationModesPresent(in:)`.

- [ ] **Step 1: Write the failing exact-activation regression test**

Add this complete test to `OverrideBuilderTests`:

```swift
func testActivationRequiresBothRequestedExactHiDPIModes() {
    let mode1080 = ModeEntry(
        logicalWidth: 1920, logicalHeight: 1080,
        pixelWidth: 3840, pixelHeight: 2160,
        refreshRate: 60, isHiDPI: true, isCurrent: false
    )
    let mode1440 = ModeEntry(
        logicalWidth: 2560, logicalHeight: 1440,
        pixelWidth: 5120, pixelHeight: 2880,
        refreshRate: 60, isHiDPI: true, isCurrent: false
    )
    XCTAssertFalse(OverrideBuilder.activationModesPresent(in: [mode1080]))
    XCTAssertFalse(OverrideBuilder.activationModesPresent(in: [mode1440]))
    XCTAssertTrue(OverrideBuilder.activationModesPresent(in: [mode1080, mode1440]))

let wrong1080Render = ModeEntry(
    logicalWidth: 1920, logicalHeight: 1080,
    pixelWidth: 1920, pixelHeight: 1080,
    refreshRate: 60, isHiDPI: false, isCurrent: false
)
let wrongFiveKLogical = ModeEntry(
    logicalWidth: 2880, logicalHeight: 1620,
    pixelWidth: 5120, pixelHeight: 2880,
    refreshRate: 60, isHiDPI: true, isCurrent: false
)
XCTAssertFalse(OverrideBuilder.activationModesPresent(in: [wrong1080Render, mode1440]))
XCTAssertFalse(OverrideBuilder.activationModesPresent(in: [mode1080, wrongFiveKLogical]))
}
```

- [ ] **Step 2: Run the focused test and confirm RED**

Run:

```bash
swift test --filter OverrideBuilderTests/testActivationRequiresBothRequestedExactHiDPIModes
```

Expected: compilation fails because `OverrideBuilder.activationModesPresent(in:)` does not exist.

- [ ] **Step 3: Replace the installed boolean with configuration state and add the install/update flow**

First add the exact shared predicate in `OverrideConfiguration.swift`:

```swift
extension OverrideBuilder {
    static let activationModes = managedModes.filter {
        ($0.logicalWidth == 1920 && $0.logicalHeight == 1080)
            || ($0.logicalWidth == 2560 && $0.logicalHeight == 1440)
    }

    static func activationModesPresent(in modes: [ModeEntry]) -> Bool {
        activationModes.allSatisfy { requirement in
            modes.contains(where: requirement.matches)
        }
    }
}
```

In `AppModel`, replace `overrideInstalled` with:

```swift
var overrideConfigurationState: OverrideConfigurationState = .missing
```

In `refresh()`, assign:

```swift
overrideConfigurationState = OverrideInstaller.configurationState()
```

Replace `installOverride()` with `installOrUpdateOverride()`. Re-read the target at click time so a stale menu state cannot overwrite a file that changed after `refresh()`:

```swift
func installOrUpdateOverride() {
    guard !isBusy else { return }

    let existingData: Data?
    switch OverrideInstaller.existingData() {
    case .failure(let message):
        setStatus(message, error: true)
        return
    case .success(let data):
        existingData = data
    }

    let freshState = existingData.map(OverrideBuilder.configurationState(for:)) ?? .missing
    switch freshState {
    case .current:
        overrideConfigurationState = .current
        setStatus("HiDPI 配置已是最新", error: false)
        return
    case .invalid(let reason):
        overrideConfigurationState = .invalid(reason)
        setStatus("配置无法安全更新：\(reason)", error: true)
        return
    case .missing, .outdated:
        break
    }

    let xml: String
    switch OverrideBuilder.buildManagedPlist(existingData: existingData) {
    case .failure(let message):
        setStatus(message, error: true)
        return
    case .success(let generated):
        xml = generated
    }

    isBusy = true
    setStatus("请在弹窗中输入管理员密码以写入 HiDPI 配置…", error: false)
    Task {
        let result = await OverrideInstaller.install(plistXML: xml)
        isBusy = false
        switch result {
        case .failure(let message):
            setStatus("写入失败：\(message)", error: true)
        case .success:
            let installedState = OverrideInstaller.configurationState()
            overrideConfigurationState = installedState
            guard installedState == .current else {
                setStatus("写入后校验失败：配置未达到最新状态", error: true)
                return
            }
            overridePending = true
            setStatus("配置已写入 ✓ 正在等待目标模式生效…", error: false)
            await pollForNewModes()
        }
    }
}
```

After uninstall success set `.missing` and `overridePending = false`, then call `refresh()` as today.

- [ ] **Step 4: Switch the tools UI over all four states without adding a preset**

Replace the current boolean branch in `MenuContent.toolsSection` with an exhaustive switch:

```swift
switch model.overrideConfigurationState {
case .missing:
    Button("解锁 HiDPI（需管理员密码）") {
        model.installOrUpdateOverride()
    }
    .disabled(model.isBusy)
case .outdated:
    Button("更新 HiDPI 配置（新增 1080p / 1440p @2x，需管理员密码）") {
        model.installOrUpdateOverride()
    }
    .disabled(model.isBusy)
case .current:
    if model.overridePending {
        Text("⏳ 配置已写入，正在等待 1080p / 1440p @2x…")
            .font(.caption2)
            .foregroundStyle(.orange)
    }
    Button("✓ HiDPI 配置已是最新（点击移除）") {
        model.uninstallOverride()
    }
    .disabled(model.isBusy)
case .invalid(let reason):
    Text("⚠️ HiDPI 配置无法安全更新：\(reason)")
        .font(.caption2)
        .foregroundStyle(.orange)
    Button("移除无效 HiDPI 配置（需管理员密码）") {
        model.uninstallOverride()
    }
    .disabled(model.isBusy)
}
```

Do not add a `Preset` case. Keep the other-mode list sorted by rendered pixel area so 5120×2880 is naturally visible.

- [ ] **Step 5: Replace polling’s any-target test with the exact shared activation predicate**

Inside `pollForNewModes()`, use:

```swift
func hasRequiredModes() -> Bool {
    OverrideBuilder.activationModesPresent(
        in: DisplayManager.modeEntries(for: display.id)
    )
}
```

Both polling loops must call `hasRequiredModes()`. Success messages must name “1920×1080 与 2560×1440 HiDPI”; timeout text must say that the config is written but one or both requested modes have not appeared and recommend reconnect/restart. Never report success when only one requirement exists.

- [ ] **Step 6: Make self-test and README consume/document the central catalog**

In `SelfTest`, iterate `OverrideBuilder.managedModes`, verify every base64 round trip, assert `buildManagedPlist(existingData: nil)` succeeds, and print logical→rendered pairs. Include the known `5120×2880 = AAAUAAAAC0AA` comparison.

Replace the local two-entry case list with:

```swift
var builderOK = true
for mode in OverrideBuilder.managedModes {
    let entry = OverrideBuilder.scaleEntry(
        pixelWidth: mode.pixelWidth,
        pixelHeight: mode.pixelHeight
    )
    let roundTrip = OverrideBuilder.verifyEntry(
        entry,
        pixelWidth: mode.pixelWidth,
        pixelHeight: mode.pixelHeight
    )
    let knownFiveKMatches = mode.pixelWidth != 5120
        || mode.pixelHeight != 2880
        || entry == "AAAUAAAAC0AA"
    lines.append(
        "  \(mode.logicalWidth)x\(mode.logicalHeight) @2x -> "
            + "\(mode.pixelWidth)x\(mode.pixelHeight): 往返=\(roundTrip) 已知值=\(knownFiveKMatches)"
    )
    if !(roundTrip && knownFiveKMatches) { builderOK = false }
}
if builderOK {
    switch OverrideBuilder.buildManagedPlist(existingData: nil) {
    case .success(let xml):
        lines.append("  buildManagedPlist OK，\(xml.count) 字符")
    case .failure(let message):
        lines.append("  buildManagedPlist FAIL: \(message)")
        builderOK = false
    }
}
```

In `README.md`:

- replace “中档 HiDPI” wording with “HiDPI 配置” where it describes the tool;
- state that 1920×1080 @2x renders 3840×2160 and 2560×1440 @2x renders 5120×2880;
- explain that existing two-entry configurations display a one-click update action;
- state that the 2560×1440 mode is not a preset and appears under “其他可用模式”;
- retain the hardware/macOS caveat and ad-hoc signing limitation.

- [ ] **Step 7: Run focused and full verification for Task 3**

Run:

```bash
swift test --filter OverrideBuilderTests
swift test --filter OverrideInstallerTests
swift test
swift build -c debug
swift build -c release
git diff --check
```

Expected: all tests report zero failures, both builds complete, and the diff check is silent.

- [ ] **Step 8: Commit Task 3**

```bash
git add Sources/ScreenClear/AppModel.swift Sources/ScreenClear/MenuContent.swift Sources/ScreenClear/SelfTest.swift README.md Tests/ScreenClearTests/OverrideBuilderTests.swift
git commit -m "feat: expose HiDPI override updates"
```

---

### Task 4: Release Gate, Package, Install, and User-Gated Override Acceptance

**Files:**
- Verify: `make-app.sh`
- Verify: `Scripts/Packaging/install-lifecycle.sh`
- Verify: `Tests/Packaging/*.sh`
- Generate (ignored): `ScreenClear.app`
- Generate (ignored): `dist/ScreenClear-macos-arm64.zip`
- Install: `/Applications/ScreenClear.app`
- User-gated update target: `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-5e3/DisplayProductID-2490`

**Interfaces:**
- Consumes: completed Tasks 1–3 and existing transactional packaging/install gates.
- Produces: verified app/ZIP artifacts, a running installed app from the exact path, and evidence that the old override is detected as outdated before the user elects to update it.

- [ ] **Step 1: Run the complete non-mutating source and packaging regression gate**

Run from the feature worktree:

```bash
swift test
swift build -c debug
swift build -c release
while IFS= read -r script_path; do
  /bin/bash -n "$script_path"
done < <(find make-app.sh Scripts/Packaging Tests/Packaging -type f -name '*.sh' -print | sort)
Tests/Packaging/make-app-arguments-tests.sh
Tests/Packaging/install-lifecycle-tests.sh
Tests/Packaging/verify-publication-transaction.sh
./make-app.sh
Tests/Packaging/verify-app-archive-tests.sh ScreenClear.app
Tests/Packaging/verify-app.sh ScreenClear.app dist/ScreenClear-macos-arm64.zip
git diff --check
```

Expected: the full Swift test count has zero failures; Debug/Release builds complete; argument/lifecycle/archive tests pass; publication reports `PASS: identity`, `PASS: zip-rollback`, and `PASS: signature-rollback`; App and ZIP verification exits 0.

- [ ] **Step 2: Capture exact pre-install external state without changing it**

Resolve and record:

- `/Applications/ScreenClear.app` is a real directory with bundle ID `local.screenclear`;
- its executable hash and exact running PIDs from `/usr/sbin/lsof -a -p <pid> -d txt`;
- the override SHA-256 and decoded `scale-resolutions` entry set;
- `~/Library/LaunchAgents/local.screenclear.plist` presence/absence;
- `/Applications/.ScreenClear.backup.*` count is zero.

Abort before installation if the app target is a symlink, has another bundle ID, any ScreenClear PID cannot be mapped safely, or a leftover application backup exists.

- [ ] **Step 3: Install the app through the guarded lifecycle exactly once**

Run:

```bash
./make-app.sh --install
```

Expected: old exact-path PIDs exit before replacement, install exits 0, and a new non-old PID maps to `/Applications/ScreenClear.app/Contents/MacOS/ScreenClear`.

- [ ] **Step 4: Verify installed artifact identity and prove install did not update display state**

Run read-only checks that require:

- `codesign --verify --deep --strict /Applications/ScreenClear.app` exits 0;
- bundle ID is `local.screenclear`, minimum macOS is `14.0`, and Mach-O is thin arm64;
- installed executable SHA-256 equals feature-worktree `ScreenClear.app` SHA-256;
- the exact new application PID is running;
- override SHA-256 and decoded entries are unchanged from Step 2;
- LaunchAgent state is unchanged and no application backup remains.

This proves app installation did not silently update the system override.

- [ ] **Step 5: Verify the update UI before requesting administrator approval**

Open the ScreenClear menu and confirm the tool action reads:

`更新 HiDPI 配置（新增 1080p / 1440p @2x，需管理员密码）`

If it instead says current, missing, or invalid, stop and diagnose the state classifier before asking the user to approve any system change.

- [ ] **Step 6: Pause for the user-triggered administrator update**

Ask the user to click the update action and approve the macOS administrator dialog. Do not type, request, store, or expose the user’s password. Do not use a separate privileged shell command to bypass the app’s explicit update flow.

- [ ] **Step 7: Verify the updated override and activation outcome read-only**

After the user confirms the prompt completed:

- parse the exact target file and verify vendor 1507/product 9360;
- require unique entries for 2880×1620, 3200×1800, 3840×2160, and 5120×2880;
- prove all pre-update extra keys and extra entries remain;
- verify the UI now reports the configuration current;
- if both logical/rendered HiDPI modes are visible, record success without switching modes;
- if either mode is absent, report that the configuration is correctly written and follow the product prompt to reconnect the cable or restart, without claiming activation.

- [ ] **Step 8: Commit any evidence-only documentation change only if the repository already tracks such reports**

This repository does not track generated verification reports, so the normal expected action is no source commit. Confirm:

```bash
git status --short --branch
git log --oneline --decorate -6
```

Expected: tracked worktree clean and HEAD contains the three implementation commits after the design/plan commits.

---

## Final Review Checklist

- [ ] Every design requirement maps to a task and test above.
- [ ] No automatic test or install command writes the real override.
- [ ] Only the explicit app UI update action can trigger administrator write access.
- [ ] Existing custom plist keys and extra entries survive the merge.
- [ ] Wrong IDs and malformed plists are blocked from update.
- [ ] Both exact requested HiDPI configurations are required before activation success.
- [ ] No new preset is added.
- [ ] Full Swift, build, packaging, signature, archive, installed-hash, PID, and external-state gates have fresh evidence.
