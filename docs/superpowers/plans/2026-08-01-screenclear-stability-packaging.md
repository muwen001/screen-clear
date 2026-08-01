# ScreenClear Stability and Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (\`- [ ]\`) syntax for tracking.

**Goal:** Make display-mode verification exact, keep self-tests isolated from user data, and produce a tested, ad-hoc-signed ScreenClear app that installs and launches from /Applications.

**Architecture:** Keep CoreGraphics as the source of truth and centralize mode comparison in the existing ModeEntry value type. Inject the plist backup destination so production keeps its current Application Support behavior while tests use temporary directories. Build the app in a disposable staging directory, verify it before publication, and use guarded replacement for local and installed bundles.

**Tech Stack:** Swift 6.1, SwiftPM, XCTest, SwiftUI, CoreGraphics, Bash 3.2, codesign, plutil, ditto, and standard macOS launch tools.

## Global Constraints

- Deployment target remains macOS 14.0 or newer.
- Add no third-party Swift or shell dependencies.
- Bundle identifier remains local.screenclear; version remains 1.0 build 1.
- Keep the application as an LSUIElement menu-bar accessory.
- Use ad-hoc signing only; do not claim Developer ID signing, notarization, or distribution readiness.
- Tests and installation must not switch modes, write display overrides, patch real LinkDescription data, or change LaunchAgents.
- Install only to /Applications/ScreenClear.app after validating that exact path.
- Commit each independently verified task to the initialized main branch.

---

## File Map

- Package.swift — declares the executable and XCTest targets.
- Sources/ScreenClear/Models.swift — owns mode identity and pure comparison.
- Sources/ScreenClear/DisplayManager.swift — converts CoreGraphics modes and reuses pure comparison.
- Sources/ScreenClear/LinkDescriptionPatcher.swift — patches files and writes backups to an injected destination.
- Sources/ScreenClear/SelfTest.swift — confines fixture, backup, and cleanup to one temporary directory.
- Tests/ScreenClearTests/ModeEntryTests.swift — mode identity and comparison regression tests.
- Tests/ScreenClearTests/OverrideBuilderTests.swift — preserved override encoding behavior.
- Tests/ScreenClearTests/LinkDescriptionPatcherTests.swift — UUID patch and backup isolation.
- Tests/Packaging/verify-app.sh — observable bundle, signature, architecture, and ZIP checks.
- make-app.sh — staged Release build, packaging, optional guarded install, and launch.
- README.md — test, package, install, and signing documentation.

---

### Task 1: Add the Test Target and Exact Mode Identity

**Files:**
- Modify: Package.swift
- Modify: Sources/ScreenClear/Models.swift
- Modify: Sources/ScreenClear/DisplayManager.swift
- Create: Tests/ScreenClearTests/ModeEntryTests.swift
- Create: Tests/ScreenClearTests/OverrideBuilderTests.swift

**Interfaces:**
- Consumes: the existing ModeEntry memberwise initializer and OverrideBuilder static methods.
- Produces: ModeEntry.matchesConfiguration(of:refreshRateTolerance:) -> Bool and an ID containing logical and rendered dimensions.

- [ ] **Step 1: Declare the test target**

Use this targets array in Package.swift:

~~~swift
targets: [
    .executableTarget(
        name: "ScreenClear",
        path: "Sources/ScreenClear"
    ),
    .testTarget(
        name: "ScreenClearTests",
        dependencies: ["ScreenClear"],
        path: "Tests/ScreenClearTests"
    ),
]
~~~

- [ ] **Step 2: Write the failing ID test**

Create Tests/ScreenClearTests/ModeEntryTests.swift:

~~~swift
import XCTest
@testable import ScreenClear

final class ModeEntryTests: XCTestCase {
    func testIDIncludesLogicalDimensions() {
        let standard = ModeEntry(
            logicalWidth: 1920, logicalHeight: 1080,
            pixelWidth: 3840, pixelHeight: 2160,
            refreshRate: 60, isHiDPI: true, isCurrent: false
        )
        let alternate = ModeEntry(
            logicalWidth: 1600, logicalHeight: 900,
            pixelWidth: 3840, pixelHeight: 2160,
            refreshRate: 60, isHiDPI: true, isCurrent: false
        )

        XCTAssertNotEqual(standard.id, alternate.id)
    }
}
~~~

- [ ] **Step 3: Confirm RED**

Run:

~~~bash
swift test --filter ModeEntryTests/testIDIncludesLogicalDimensions
~~~

Expected: FAIL because the current ID omits logical dimensions.

- [ ] **Step 4: Make the minimum ID change**

Replace ModeEntry.id with:

~~~swift
var id: String {
    "\(logicalWidth)x\(logicalHeight):\(pixelWidth)x\(pixelHeight)@\(Int(refreshRate))x\(isHiDPI ? "2" : "1")"
}
~~~

- [ ] **Step 5: Confirm GREEN**

Run the filtered command from Step 3. Expected: one test passes.

- [ ] **Step 6: Add comparison tests**

Append inside ModeEntryTests:

~~~swift
func testComparisonRejectsSamePixelsWithDifferentLogicalMode() {
    let hiDPI = ModeEntry(
        logicalWidth: 1280, logicalHeight: 720,
        pixelWidth: 2560, pixelHeight: 1440,
        refreshRate: 60, isHiDPI: true, isCurrent: false
    )
    let oneX = ModeEntry(
        logicalWidth: 2560, logicalHeight: 1440,
        pixelWidth: 2560, pixelHeight: 1440,
        refreshRate: 60, isHiDPI: false, isCurrent: false
    )

    XCTAssertFalse(hiDPI.matchesConfiguration(of: oneX))
}

func testComparisonUsesRefreshTolerance() {
    let target = ModeEntry(
        logicalWidth: 1920, logicalHeight: 1080,
        pixelWidth: 3840, pixelHeight: 2160,
        refreshRate: 60, isHiDPI: true, isCurrent: false
    )
    let within = ModeEntry(
        logicalWidth: 1920, logicalHeight: 1080,
        pixelWidth: 3840, pixelHeight: 2160,
        refreshRate: 60.08, isHiDPI: true, isCurrent: true
    )
    let outside = ModeEntry(
        logicalWidth: 1920, logicalHeight: 1080,
        pixelWidth: 3840, pixelHeight: 2160,
        refreshRate: 60.2, isHiDPI: true, isCurrent: true
    )

    XCTAssertTrue(target.matchesConfiguration(of: within))
    XCTAssertFalse(target.matchesConfiguration(of: outside))
}
~~~

- [ ] **Step 7: Confirm the missing comparison is RED**

Run:

~~~bash
swift test --filter ModeEntryTests
~~~

Expected: compilation fails because matchesConfiguration does not exist.

- [ ] **Step 8: Implement the pure comparison**

Add to ModeEntry:

~~~swift
func matchesConfiguration(
    of other: ModeEntry,
    refreshRateTolerance: Double = 0.1
) -> Bool {
    logicalWidth == other.logicalWidth
        && logicalHeight == other.logicalHeight
        && pixelWidth == other.pixelWidth
        && pixelHeight == other.pixelHeight
        && abs(refreshRate - other.refreshRate) < refreshRateTolerance
}
~~~

Run the filtered tests. Expected: all ModeEntry tests pass.

- [ ] **Step 9: Reuse the comparison in DisplayManager**

Add this translator:

~~~swift
private static func entry(for mode: CGDisplayMode, isCurrent: Bool = false) -> ModeEntry {
    ModeEntry(
        logicalWidth: Int(mode.width),
        logicalHeight: Int(mode.height),
        pixelWidth: Int(mode.pixelWidth),
        pixelHeight: Int(mode.pixelHeight),
        refreshRate: mode.refreshRate,
        isHiDPI: mode.pixelWidth != mode.width,
        isCurrent: isCurrent
    )
}
~~~

In modeEntries(for:), create currentEntry once and set isCurrent through the pure method:

~~~swift
let currentEntry = current.map { entry(for: $0, isCurrent: true) }
// Inside the loop:
let candidate = entry(for: mode)
let isCurrent = currentEntry?.matchesConfiguration(of: candidate) == true
~~~

Resolve an apply target with all fields:

~~~swift
guard let target = allModes(for: displayID).first(where: {
    mode.matchesConfiguration(of: entry(for: $0), refreshRateTolerance: 0.5)
}) else {
    return .failed("目标模式已失效，请重新打开菜单刷新")
}
~~~

Replace the final verifier:

~~~swift
private static func matches(_ target: CGDisplayMode, on displayID: CGDirectDisplayID) -> Bool {
    guard let current = CGDisplayCopyDisplayMode(displayID) else { return false }
    return entry(for: target).matchesConfiguration(of: entry(for: current))
}
~~~

- [ ] **Step 10: Add OverrideBuilder characterization tests**

Create Tests/ScreenClearTests/OverrideBuilderTests.swift:

~~~swift
import Foundation
import XCTest
@testable import ScreenClear

final class OverrideBuilderTests: XCTestCase {
    func testKnownEntriesRoundTrip() {
        let cases = [
            (2880, 1620, "AAALQAAABlQA"),
            (3200, 1800, "AAAMgAAABwgA"),
        ]

        for (width, height, expected) in cases {
            let entry = OverrideBuilder.scaleEntry(pixelWidth: width, pixelHeight: height)
            XCTAssertEqual(entry, expected)
            XCTAssertTrue(
                OverrideBuilder.verifyEntry(entry, pixelWidth: width, pixelHeight: height)
            )
        }
    }

    func testGeneratedPlistContainsTargetAndThreeEntries() throws {
        let result = OverrideBuilder.buildPlist(
            renderResolutions: [(3840, 2160), (2880, 1620), (3200, 1800)]
        )
        let xml = try result.get()
        let data = try XCTUnwrap(xml.data(using: .utf8))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let entries = try XCTUnwrap(plist["scale-resolutions"] as? [Data])

        XCTAssertEqual(plist["DisplayVendorID"] as? Int, 1507)
        XCTAssertEqual(plist["DisplayProductID"] as? Int, 9360)
        XCTAssertEqual(entries.count, 3)
    }
}
~~~

These preserve existing behavior. Mutation-check the first test by temporarily replacing one expected literal with INVALID, observe an assertion failure, restore the literal, and rerun to PASS.

- [ ] **Step 11: Verify and commit Task 1**

Run:

~~~bash
swift test --filter ModeEntryTests
swift test --filter OverrideBuilderTests
swift build -c debug
git diff --check
~~~

Expected: tests and build pass. Commit:

~~~bash
git add Package.swift Sources/ScreenClear/Models.swift Sources/ScreenClear/DisplayManager.swift Tests/ScreenClearTests
git commit -m "fix: verify exact display modes"
~~~

---

### Task 2: Isolate Plist Backups and Self-Test Files

**Files:**
- Modify: Sources/ScreenClear/LinkDescriptionPatcher.swift
- Modify: Sources/ScreenClear/SelfTest.swift
- Create: Tests/ScreenClearTests/LinkDescriptionPatcherTests.swift

**Interfaces:**
- Consumes: LinkDescriptionPatcher.apply(filePath:uuid:fallbackLogical:).
- Produces: the same function with backupDirectory: URL = backupDir.

- [ ] **Step 1: Write the failing isolation test**

Create a test that uses a unique source filename so no existing user backup can satisfy it:

~~~swift
import Foundation
import XCTest
@testable import ScreenClear

final class LinkDescriptionPatcherTests: XCTestCase {
    func testApplyUsesProvidedBackupDirectoryAndPatchesUUID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenclear-tests-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("display-\(UUID().uuidString).plist")
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let unexpected = LinkDescriptionPatcher.backupDir
            .appendingPathComponent(source.lastPathComponent + ".bak")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: unexpected)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture: [String: Any] = [
            "DisplaySets": [
                "Configs": [[
                    "DisplayConfig": [[
                        "UUID": "TEST-UUID",
                        "CurrentInfo": ["Wide": 1920, "High": 1080, "Scale": 2],
                    ]],
                ]],
            ],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: fixture, format: .xml, options: 0
        )
        try data.write(to: source)

        let patched = try LinkDescriptionPatcher.apply(
            filePath: source.path,
            uuid: "TEST-UUID",
            fallbackLogical: nil,
            backupDirectory: backups
        )

        XCTAssertTrue(patched)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: backups.appendingPathComponent(source.lastPathComponent + ".bak").path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: unexpected.path))

        let patchedData = try Data(contentsOf: source)
        let patchedRoot = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: patchedData, format: nil)
                as? [String: Any]
        )
        let sets = try XCTUnwrap(patchedRoot["DisplaySets"] as? [String: Any])
        let configs = try XCTUnwrap(sets["Configs"] as? [[String: Any]])
        let displayConfig = try XCTUnwrap(configs.first?["DisplayConfig"] as? [[String: Any]])
        let link = try XCTUnwrap(displayConfig.first?["LinkDescription"] as? [String: Any])
        XCTAssertEqual(link["Range"] as? Int, 1)
        XCTAssertEqual(link["PixelEncoding"] as? Int, 0)
    }
}
~~~

- [ ] **Step 2: Confirm RED**

Run:

~~~bash
swift test --filter LinkDescriptionPatcherTests
~~~

Expected: compilation fails because apply lacks backupDirectory.

- [ ] **Step 3: Inject the backup directory**

Change apply to:

~~~swift
static func apply(
    filePath: String,
    uuid: String?,
    fallbackLogical: (w: Int, h: Int, isHiDPI: Bool)?,
    backupDirectory: URL = backupDir
) throws -> Bool {
    guard let root = readMutable(filePath) else { throw CocoaError(.fileReadUnknown) }
    try backup(filePath, to: backupDirectory)
    guard applyTo(root: root, uuid: uuid, fallbackLogical: fallbackLogical) else { return false }
    try write(root, to: filePath)
    return true
}
~~~

Change the helper to:

~~~swift
private static func backup(_ filePath: String, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(
        URL(fileURLWithPath: filePath).lastPathComponent + ".bak"
    )
    if !FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.copyItem(atPath: filePath, toPath: destination.path)
    }
}
~~~

Update the system call to backup(systemPath, to: backupDir). Production ByHost calls continue using the default.

- [ ] **Step 4: Confirm GREEN**

Run the filtered test. Expected: PASS and no file at the unique real backup path.

- [ ] **Step 5: Put the self-test backup beside its fixture**

In SelfTest.run use:

~~~swift
let tempRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent(
        "screenclear-selftest-\(ProcessInfo.processInfo.processIdentifier)",
        isDirectory: true
    )
let tempFile = tempRoot.appendingPathComponent("test.plist")
let tempBackups = tempRoot.appendingPathComponent("Backups", isDirectory: true)
defer { try? FileManager.default.removeItem(at: tempRoot) }
~~~

Write the fixture to tempFile and call:

~~~swift
let patched = try LinkDescriptionPatcher.apply(
    filePath: tempFile.path,
    uuid: "TEST-UUID-1234",
    fallbackLogical: nil,
    backupDirectory: tempBackups
)
guard patched else { throw "临时 plist 中未匹配测试 UUID" }
~~~

Remove the success-only cleanup because defer covers success and failure.

- [ ] **Step 6: Verify backup inventory is unchanged**

Run in one shell:

~~~bash
backup_dir="$HOME/Library/Application Support/ScreenClear/Backups"
before=$(find "$backup_dir" -maxdepth 1 -type f -print 2>/dev/null | sort || true)
swift run ScreenClear --selftest
after=$(find "$backup_dir" -maxdepth 1 -type f -print 2>/dev/null | sort || true)
test "$before" = "$after"
swift test
git diff --check
~~~

A disconnected external display may keep the existing read-only FAIL report, but the inventory comparison and XCTest suite must pass.

- [ ] **Step 7: Commit Task 2**

~~~bash
git add Sources/ScreenClear/LinkDescriptionPatcher.swift Sources/ScreenClear/SelfTest.swift Tests/ScreenClearTests/LinkDescriptionPatcherTests.swift
git commit -m "fix: isolate self-test display backups"
~~~

---

### Task 3: Stage, Sign, Package, and Verify the App

**Files:**
- Modify: make-app.sh
- Create: Tests/Packaging/verify-app.sh

**Interfaces:**
- Consumes: .build/release/ScreenClear.
- Produces: ScreenClear.app and dist/ScreenClear-macos-arm64.zip; --install additionally creates /Applications/ScreenClear.app.

- [ ] **Step 1: Write the failing artifact verifier**

Create Tests/Packaging/verify-app.sh and make it executable:

~~~bash
#!/bin/bash
set -euo pipefail

app_path="$1"
zip_path="$2"
info="$app_path/Contents/Info.plist"
executable="$app_path/Contents/MacOS/ScreenClear"

test -d "$app_path"
test ! -L "$app_path"
test -f "$info"
test -x "$executable"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" = "local.screenclear"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info")" = "14.0"

codesign --verify --deep --strict --verbose=2 "$app_path"
details=$(codesign -dv --verbose=4 "$app_path" 2>&1)
printf '%s\n' "$details"
printf '%s\n' "$details" | grep -q '^Identifier=local.screenclear$'
printf '%s\n' "$details" | grep -q '^Signature=adhoc$'
file "$executable" | grep -q 'Mach-O 64-bit executable arm64'
test -f "$zip_path"
unzip -tq "$zip_path"
~~~

Run chmod 755 Tests/Packaging/verify-app.sh.

- [ ] **Step 2: Confirm RED against the current artifact**

Run:

~~~bash
Tests/Packaging/verify-app.sh ScreenClear.app dist/ScreenClear-macos-arm64.zip
~~~

Expected: FAIL because the complete bundle is not signed under local.screenclear and no ZIP exists.

- [ ] **Step 3: Replace direct construction with staging**

The top of make-app.sh must parse only an optional --install and create a unique stage:

~~~bash
#!/bin/bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")" && pwd -P)
cd "$project_root"

install_requested=false
case "${1:-}" in
    "") ;;
    --install) install_requested=true ;;
    *) printf '用法: %s [--install]\n' "$0" >&2; exit 64 ;;
esac

app_name="ScreenClear.app"
bundle_id="local.screenclear"
project_app="$project_root/$app_name"
zip_path="$project_root/dist/ScreenClear-macos-arm64.zip"
install_target="/Applications/$app_name"
stage_root=$(mktemp -d "${TMPDIR:-/tmp}/screenclear-build.XXXXXX")
staged_app="$stage_root/$app_name"
~~~

The cleanup may remove only this unique stage:

~~~bash
cleanup() {
    if [[ -n "${stage_root:-}" && -d "$stage_root" && ! -L "$stage_root" ]]; then
        case "$stage_root" in
            */screenclear-build.*) /bin/rm -rf -- "$stage_root" ;;
            *) printf '拒绝清理意外路径: %s\n' "$stage_root" >&2 ;;
        esac
    fi
}
trap cleanup EXIT
~~~

Build, copy, lint, and sign only inside staging:

~~~bash
swift build -c release
mkdir -p "$staged_app/Contents/MacOS"
cp .build/release/ScreenClear "$staged_app/Contents/MacOS/ScreenClear"
chmod 755 "$staged_app/Contents/MacOS/ScreenClear"
cat > "$staged_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ScreenClear</string>
    <key>CFBundleDisplayName</key><string>ScreenClear</string>
    <key>CFBundleIdentifier</key><string>local.screenclear</string>
    <key>CFBundleExecutable</key><string>ScreenClear</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$staged_app/Contents/Info.plist"
codesign --force --deep --sign - --timestamp=none "$staged_app"
codesign --verify --deep --strict --verbose=2 "$staged_app"
~~~

- [ ] **Step 4: Publish the verified bundle rollback-safely**

Use a helper that refuses links and unknown file types:

~~~bash
publish_project_app() {
    local previous="$stage_root/previous-project.app"

    [[ ! -L "$project_app" ]] || { printf '拒绝覆盖符号链接: %s\n' "$project_app" >&2; return 1; }
    [[ ! -e "$project_app" || -d "$project_app" ]] || {
        printf '拒绝覆盖非目录: %s\n' "$project_app" >&2
        return 1
    }

    [[ ! -d "$project_app" ]] || mv "$project_app" "$previous"
    if ! mv "$staged_app" "$project_app"; then
        [[ ! -d "$previous" ]] || mv "$previous" "$project_app"
        return 1
    fi
    if ! codesign --verify --deep --strict --verbose=2 "$project_app"; then
        mv "$project_app" "$stage_root/failed-project.app"
        [[ ! -d "$previous" ]] || mv "$previous" "$project_app"
        return 1
    fi
}
~~~

Create and test the ZIP before publishing it:

~~~bash
mkdir -p "$project_root/dist"
staged_zip="$stage_root/ScreenClear-macos-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$project_app" "$staged_zip"
unzip -tq "$staged_zip"
mv -f "$staged_zip" "$zip_path"
~~~

- [ ] **Step 5: Add guarded installation**

The install function must:

1. Resolve /Applications to /Applications.
2. Refuse an existing link or non-directory.
3. If an app exists, require bundle ID local.screenclear and ask it to quit.
4. Move an existing app to /Applications/.ScreenClear.backup.PID.
5. Copy the already verified project app to the exact target.
6. Remove a partial new bundle and restore the backup on copy or verification failure.
7. Remove only the validated backup path after success, then open the app.

Use this complete implementation:

~~~bash
install_app() {
    local resolved_parent
    local install_backup="/Applications/.ScreenClear.backup.$$"
    local existing_id=""

    remove_new_install() {
        [[ "$install_target" = "/Applications/ScreenClear.app" ]]
        [[ -d "$install_target" && ! -L "$install_target" ]]
        /bin/rm -rf -- "$install_target"
    }

    resolved_parent=$(cd /Applications && pwd -P)
    [[ "$resolved_parent" = "/Applications" ]] || {
        printf '安装目录解析异常: %s\n' "$resolved_parent" >&2
        return 1
    }
    [[ ! -e "$install_backup" && ! -L "$install_backup" ]] || {
        printf '临时备份目标已存在: %s\n' "$install_backup" >&2
        return 1
    }
    [[ ! -L "$install_target" ]] || {
        printf '拒绝覆盖符号链接: %s\n' "$install_target" >&2
        return 1
    }
    if [[ -e "$install_target" ]]; then
        [[ -d "$install_target" ]] || {
            printf '拒绝覆盖非目录: %s\n' "$install_target" >&2
            return 1
        }
        existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$install_target/Contents/Info.plist" 2>/dev/null || true)
        [[ "$existing_id" = "$bundle_id" ]] || {
            printf '拒绝覆盖未知应用，Bundle ID=%s\n' "$existing_id" >&2
            return 1
        }
        /usr/bin/osascript -e 'tell application id "local.screenclear" to quit' \
            >/dev/null 2>&1 || true
        mv "$install_target" "$install_backup"
    fi

    if ! ditto "$project_app" "$install_target"; then
        if [[ -d "$install_target" && ! -L "$install_target" ]]; then
            remove_new_install
        fi
        [[ ! -d "$install_backup" ]] || mv "$install_backup" "$install_target"
        return 1
    fi
    if ! codesign --verify --deep --strict --verbose=2 "$install_target"; then
        if [[ -d "$install_target" && ! -L "$install_target" ]]; then
            remove_new_install
        fi
        [[ ! -d "$install_backup" ]] || mv "$install_backup" "$install_target"
        return 1
    fi
    if [[ -d "$install_backup" && ! -L "$install_backup" ]]; then
        [[ "$install_backup" = "/Applications/.ScreenClear.backup.$$" ]]
        /bin/rm -rf -- "$install_backup"
    fi
    open "$install_target"
}

if [[ "$install_requested" = true ]]; then
    install_app
fi
~~~

Call installation only when install_requested is true.

- [ ] **Step 6: Confirm GREEN and commit Task 3**

Run:

~~~bash
bash -n make-app.sh
bash -n Tests/Packaging/verify-app.sh
./make-app.sh
Tests/Packaging/verify-app.sh ScreenClear.app dist/ScreenClear-macos-arm64.zip
git diff --check
~~~

Expected: all commands exit 0, the signature identifier is local.screenclear, Signature is adhoc, and ZIP validation passes.

Commit:

~~~bash
git add make-app.sh Tests/Packaging/verify-app.sh
git commit -m "build: verify and package signed app"
~~~

---

### Task 4: Document and Run the Full Pre-Install Gate

**Files:**
- Modify: README.md

**Interfaces:**
- Consumes: swift test, make-app.sh, make-app.sh --install.
- Produces: accurate local build and installation documentation.

- [ ] **Step 1: Replace the build instructions**

Document these commands and artifacts:

~~~~markdown
## 测试、构建与安装

~~~bash
swift test
./make-app.sh
./make-app.sh --install
~~~

- ScreenClear.app
- dist/ScreenClear-macos-arm64.zip
- 使用 --install 时的 /Applications/ScreenClear.app

自动测试不会切换模式或修改系统显示配置。应用采用 ad-hoc 签名，仅用于本机运行；其他 Mac 分发仍需 Developer ID 签名和公证。
~~~~

Keep CLI mode-switch examples. State that self-test stores its fixture and backup in a temporary directory.

- [ ] **Step 2: Verify documentation and the full pre-install gate**

Run:

~~~bash
rg -n 'swift test|make-app\.sh --install|ScreenClear-macos-arm64\.zip|ad-hoc|临时目录' README.md
swift test
swift build -c debug
swift build -c release
bash -n make-app.sh
bash -n Tests/Packaging/verify-app.sh
./make-app.sh
Tests/Packaging/verify-app.sh ScreenClear.app dist/ScreenClear-macos-arm64.zip
git diff --check
~~~

Expected: every command exits 0 and XCTest reports zero failures.

- [ ] **Step 3: Commit Task 4**

~~~bash
git add README.md
git commit -m "docs: add tested local installation workflow"
~~~

---

### Task 5: Install and Verify the Running App

**Files:**
- Create artifact: /Applications/ScreenClear.app
- Verify artifact: ScreenClear.app
- Verify artifact: dist/ScreenClear-macos-arm64.zip

**Interfaces:**
- Consumes: make-app.sh --install.
- Produces: a running installed app with the same executable hash as the package.

- [ ] **Step 1: Inspect exact install targets**

Run:

~~~bash
ls -ld /Applications /Applications/ScreenClear.app 2>&1 || true
test ! -L /Applications/ScreenClear.app
if test -e /Applications/ScreenClear.app; then
    test -d /Applications/ScreenClear.app
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/ScreenClear.app/Contents/Info.plist)" = "local.screenclear"
fi
~~~

Stop if the target is a link, a non-directory, or an unrelated bundle.

- [ ] **Step 2: Install while checking unrelated state**

In one shell invocation, record the presence of the display override and LaunchAgent, install, and confirm those flags are unchanged:

~~~bash
override_path='/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-5e3/DisplayProductID-2490'
launch_agent="$HOME/Library/LaunchAgents/local.screenclear.plist"
before_override=$(test -e "$override_path"; printf '%d' "$?")
before_launch=$(test -e "$launch_agent"; printf '%d' "$?")
./make-app.sh --install
after_override=$(test -e "$override_path"; printf '%d' "$?")
after_launch=$(test -e "$launch_agent"; printf '%d' "$?")
test "$before_override" = "$after_override"
test "$before_launch" = "$after_launch"
~~~

- [ ] **Step 3: Verify signature, identity, hash, architecture, and process**

Run:

~~~bash
codesign --verify --deep --strict --verbose=2 /Applications/ScreenClear.app
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/ScreenClear.app/Contents/Info.plist)" = "local.screenclear"
packaged_hash=$(shasum -a 256 ScreenClear.app/Contents/MacOS/ScreenClear | awk '{print $1}')
installed_hash=$(shasum -a 256 /Applications/ScreenClear.app/Contents/MacOS/ScreenClear | awk '{print $1}')
test "$packaged_hash" = "$installed_hash"
file /Applications/ScreenClear.app/Contents/MacOS/ScreenClear | grep -q 'Mach-O 64-bit executable arm64'

running=false
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if pgrep -x ScreenClear >/dev/null; then running=true; break; fi
    sleep 1
done
test "$running" = true
pgrep -afil '/Applications/ScreenClear.app/Contents/MacOS/ScreenClear'
~~~

- [ ] **Step 4: Run the final fresh evidence gate**

Run as one chain:

~~~bash
swift test && \
swift build -c release && \
Tests/Packaging/verify-app.sh ScreenClear.app dist/ScreenClear-macos-arm64.zip && \
codesign --verify --deep --strict --verbose=2 /Applications/ScreenClear.app && \
test "$(shasum -a 256 ScreenClear.app/Contents/MacOS/ScreenClear | awk '{print $1}')" = \
     "$(shasum -a 256 /Applications/ScreenClear.app/Contents/MacOS/ScreenClear | awk '{print $1}')" && \
pgrep -x ScreenClear >/dev/null
~~~

Expected: exit 0, zero XCTest failures, valid packaged and installed signatures, identical hashes, and a live process.

- [ ] **Step 5: Push verified source history**

Check that generated artifacts are ignored and source history is clean:

~~~bash
git status --short --ignored
git check-ignore .build ScreenClear.app dist/ScreenClear-macos-arm64.zip
git push origin main
~~~

Report the commit range, modified source paths, app/ZIP sizes, install path, signature type, and verification results.
