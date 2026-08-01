# ScreenClear Icon System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the approved A-style blue/indigo ScreenClear app icon and matching adaptive menu-bar template icon, then rebuild, package, install, and verify the signed application.

**Architecture:** A standalone AppKit/CoreGraphics script is the parameterized vector master and generates the complete macOS iconset, `ScreenClear.icns`, and `MenuBarIcon.pdf` without third-party dependencies. The app loads the PDF from the main bundle as an `NSImage` template and falls back to the existing `display` SF Symbol, while the transactional packaging pipeline installs and verifies both resources before signing or publication.

**Tech Stack:** Swift 6.1, SwiftUI, AppKit, CoreGraphics, XCTest, Bash, macOS `iconutil`, `sips`, `plutil`, `codesign`, `ditto`, and existing packaging transaction gates.

## Global Constraints

- Deployment target remains macOS 14.0; add no external package dependency.
- The approved app icon is the A direction: blue-to-indigo rounded square, white display, upper-right clarity sparkle, and no text.
- The menu-bar icon uses the same display-and-sparkle composition as a monochrome template image and lets macOS choose its color.
- Preserve `LSUIElement=true` and `NSApp.setActivationPolicy(.accessory)`; do not add a Dock icon or change app activation behavior.
- Keep `CFBundleIdentifier=local.screenclear`, app name `ScreenClear`, version `1.0 (1)`, and ad-hoc signing.
- The generator must use only macOS system frameworks/tools and work in a unique temporary directory; generated failures must not publish a partial App or ZIP.
- Missing or invalid menu-bar resources must fall back to SF Symbol `display` without crashing; bare `swift run` must still work.
- App/ZIP/install verification must reject missing, symbolic-link, empty, mismatched, unsigned, or incorrectly declared icon resources.
- Building, packaging, installing, or launching the icon build must not update the HiDPI override, switch resolution, modify LinkDescription, or create a LaunchAgent.
- Do not delete global Finder or Launch Services caches to refresh the app icon.

## File Map

- Create `Scripts/Icons/generate-icons.swift` — parameterized vector drawing, ten iconset PNGs, `.icns` packaging, and menu-bar PDF generation.
- Create `Tests/Packaging/icon-generator-tests.sh` — isolated CLI, image-dimension, file-format, and overwrite-rejection tests for the generator.
- Create `Sources/ScreenClear/MenuBarIcon.swift` — bundle resource decoder, template marking, and SF Symbol fallback view.
- Create `Tests/ScreenClearTests/MenuBarIconTests.swift` — valid, missing, and invalid image loading tests.
- Modify `Sources/ScreenClear/ScreenClearApp.swift` — replace the generic `systemImage` initializer with the custom menu-bar label.
- Modify `make-app.sh` — generate/copy resources before plist validation and signing; validate the installed copies.
- Modify `Tests/Packaging/verify-app.sh` — verify icon plist declaration, resource types, signing, and App/ZIP resource identity.
- Modify `Tests/Packaging/verify-app-archive-tests.sh` — prove a re-signed archive with changed icon resources is rejected.
- Modify `Tests/Packaging/verify-publication-transaction.sh` — include the generator in isolated publication fixtures.
- Modify `README.md` — document icon generation, resources, and the new source files.

---

### Task 1: Deterministic App and Menu-Bar Icon Generator

**Files:**
- Create: `Tests/Packaging/icon-generator-tests.sh`
- Create: `Scripts/Icons/generate-icons.swift`

**Interfaces:**
- Consumes: one command-line argument, an existing ordinary output directory containing no `ScreenClear.iconset`, `ScreenClear.icns`, or `MenuBarIcon.pdf`.
- Produces: `ScreenClear.iconset` with ten standard PNG names, `ScreenClear.icns`, and `MenuBarIcon.pdf`; exits 64 for invalid CLI usage and nonzero without replacing existing outputs for generation errors.

- [ ] **Step 1: Write the failing generator contract test**

Create `Tests/Packaging/icon-generator-tests.sh`:

```bash
#!/bin/bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/../.." && pwd -P)
generator="$project_root/Scripts/Icons/generate-icons.swift"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/screenclear-icon-test.XXXXXX")

cleanup() {
    if [[ -n "${test_root:-}" && -d "$test_root" && ! -L "$test_root" ]]; then
        case "$test_root" in
            */screenclear-icon-test.*) /bin/rm -rf -- "$test_root" ;;
            *) printf 'refusing unexpected cleanup path: %s\n' "$test_root" >&2 ;;
        esac
    fi
}
trap cleanup EXIT

set +e
/usr/bin/xcrun swift "$generator" >"$test_root/usage.out" 2>&1
usage_status=$?
set -e
test "$usage_status" -eq 64
grep -q 'usage:' "$test_root/usage.out"

output_root="$test_root/output"
mkdir -p "$output_root"
/usr/bin/xcrun swift "$generator" "$output_root"

while IFS=: read -r name width height; do
    image="$output_root/ScreenClear.iconset/$name"
    test -f "$image"
    test ! -L "$image"
    test -s "$image"
    test "$(/usr/bin/sips -g pixelWidth "$image" | awk '/pixelWidth:/ {print $2}')" = "$width"
    test "$(/usr/bin/sips -g pixelHeight "$image" | awk '/pixelHeight:/ {print $2}')" = "$height"
done <<'SIZES'
icon_16x16.png:16:16
icon_16x16@2x.png:32:32
icon_32x32.png:32:32
icon_32x32@2x.png:64:64
icon_128x128.png:128:128
icon_128x128@2x.png:256:256
icon_256x256.png:256:256
icon_256x256@2x.png:512:512
icon_512x512.png:512:512
icon_512x512@2x.png:1024:1024
SIZES

test -f "$output_root/ScreenClear.icns"
test ! -L "$output_root/ScreenClear.icns"
test -s "$output_root/ScreenClear.icns"
/usr/bin/file "$output_root/ScreenClear.icns" | grep -q 'Mac OS X icon'

test -f "$output_root/MenuBarIcon.pdf"
test ! -L "$output_root/MenuBarIcon.pdf"
test -s "$output_root/MenuBarIcon.pdf"
/usr/bin/file "$output_root/MenuBarIcon.pdf" | grep -q 'PDF document'

icns_digest=$(shasum -a 256 "$output_root/ScreenClear.icns" | awk '{print $1}')
set +e
/usr/bin/xcrun swift "$generator" "$output_root" >"$test_root/repeat.out" 2>&1
repeat_status=$?
set -e
test "$repeat_status" -ne 0
test "$(shasum -a 256 "$output_root/ScreenClear.icns" | awk '{print $1}')" = "$icns_digest"

printf 'icon generator tests passed\n'
```

- [ ] **Step 2: Run the generator test and confirm RED**

Run:

```bash
bash Tests/Packaging/icon-generator-tests.sh
```

Expected: FAIL because `Scripts/Icons/generate-icons.swift` does not exist; after the shell parses the failed invocation, `usage_status` is not 64.

- [ ] **Step 3: Implement the parameterized vector generator**

Create `Scripts/Icons/generate-icons.swift` with this structure and exact output contract:

```swift
#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

enum GeneratorError: LocalizedError {
    case invalidOutput(String)
    case outputExists(String)
    case bitmap(Int)
    case png(Int)
    case pdf
    case iconutil(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidOutput(let path): return "invalid output directory: \(path)"
        case .outputExists(let path): return "refusing to replace existing output: \(path)"
        case .bitmap(let size): return "cannot create \(size)x\(size) bitmap"
        case .png(let size): return "cannot encode \(size)x\(size) PNG"
        case .pdf: return "cannot create menu-bar PDF"
        case .iconutil(let status): return "iconutil failed with status \(status)"
        }
    }
}

struct IconVariant {
    let name: String
    let pixels: Int
}

let variants = [
    IconVariant(name: "icon_16x16.png", pixels: 16),
    IconVariant(name: "icon_16x16@2x.png", pixels: 32),
    IconVariant(name: "icon_32x32.png", pixels: 32),
    IconVariant(name: "icon_32x32@2x.png", pixels: 64),
    IconVariant(name: "icon_128x128.png", pixels: 128),
    IconVariant(name: "icon_128x128@2x.png", pixels: 256),
    IconVariant(name: "icon_256x256.png", pixels: 256),
    IconVariant(name: "icon_256x256@2x.png", pixels: 512),
    IconVariant(name: "icon_512x512.png", pixels: 512),
    IconVariant(name: "icon_512x512@2x.png", pixels: 1024),
]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha).cgColor
}

func sparklePath(center: CGPoint, outer: CGFloat, inner: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let points = [
        CGPoint(x: center.x, y: center.y + outer),
        CGPoint(x: center.x + inner, y: center.y + inner),
        CGPoint(x: center.x + outer, y: center.y),
        CGPoint(x: center.x + inner, y: center.y - inner),
        CGPoint(x: center.x, y: center.y - outer),
        CGPoint(x: center.x - inner, y: center.y - inner),
        CGPoint(x: center.x - outer, y: center.y),
        CGPoint(x: center.x - inner, y: center.y + inner),
    ]
    path.move(to: points[0])
    points.dropFirst().forEach { path.addLine(to: $0) }
    path.closeSubpath()
    return path
}

func drawAppIcon(in context: CGContext, pixels: Int) {
    let lineWidth: CGFloat = pixels <= 32 ? 7 : 6
    let background = CGPath(
        roundedRect: CGRect(x: 5, y: 5, width: 118, height: 118),
        cornerWidth: 29,
        cornerHeight: 29,
        transform: nil
    )
    context.saveGState()
    context.addPath(background)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0.086, 0.467, 1), color(0.318, 0.275, 0.898)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 16, y: 118),
        end: CGPoint(x: 113, y: 9),
        options: []
    )
    context.restoreGState()

    let screen = CGPath(
        roundedRect: CGRect(x: 26, y: 40, width: 76, height: 57),
        cornerWidth: 7.5,
        cornerHeight: 7.5,
        transform: nil
    )
    context.addPath(screen)
    context.setFillColor(color(1, 1, 1, 0.20))
    context.fillPath()
    context.addPath(screen)
    context.setStrokeColor(color(1, 1, 1, 0.96))
    context.setLineWidth(lineWidth)
    context.strokePath()

    context.setLineCap(.round)
    context.setLineWidth(lineWidth)
    context.move(to: CGPoint(x: 64, y: 40))
    context.addLine(to: CGPoint(x: 64, y: 27))
    context.move(to: CGPoint(x: 52, y: 27))
    context.addLine(to: CGPoint(x: 76, y: 27))
    context.strokePath()

    context.addPath(sparklePath(center: CGPoint(x: 87, y: 96), outer: 13, inner: 4.8))
    context.setFillColor(color(0.73, 0.96, 1))
    context.fillPath()
    context.addPath(sparklePath(center: CGPoint(x: 87, y: 96), outer: 13, inner: 4.8))
    context.setStrokeColor(color(1, 1, 1))
    context.setLineWidth(2)
    context.setLineJoin(.round)
    context.strokePath()
}

func pngData(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw GeneratorError.bitmap(pixels)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    graphics.cgContext.scaleBy(x: CGFloat(pixels) / 128, y: CGFloat(pixels) / 128)
    drawAppIcon(in: graphics.cgContext, pixels: pixels)
    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw GeneratorError.png(pixels)
    }
    return data
}

func writeMenuBarPDF(to url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 18, height: 18)
    guard let consumer = CGDataConsumer(url: url as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        throw GeneratorError.pdf
    }
    context.beginPDFPage(nil)
    context.setStrokeColor(color(0, 0, 0))
    context.setFillColor(color(0, 0, 0))
    context.setLineWidth(1.55)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(CGPath(
        roundedRect: CGRect(x: 1.25, y: 5.5, width: 11.5, height: 8.25),
        cornerWidth: 1.6,
        cornerHeight: 1.6,
        transform: nil
    ))
    context.strokePath()
    context.move(to: CGPoint(x: 7, y: 5.5))
    context.addLine(to: CGPoint(x: 7, y: 3))
    context.move(to: CGPoint(x: 4.6, y: 3))
    context.addLine(to: CGPoint(x: 9.4, y: 3))
    context.strokePath()
    context.addPath(sparklePath(center: CGPoint(x: 14.7, y: 14.2), outer: 3.2, inner: 1.15))
    context.fillPath()
    context.endPDFPage()
    context.closePDF()
}

func runIconutil(iconset: URL, output: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GeneratorError.iconutil(process.terminationStatus)
    }
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-icons.swift OUTPUT_DIRECTORY\n", stderr)
    exit(64)
}

do {
    let manager = FileManager.default
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let values = try output.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw GeneratorError.invalidOutput(output.path)
    }
    let iconset = output.appendingPathComponent("ScreenClear.iconset", isDirectory: true)
    let icns = output.appendingPathComponent("ScreenClear.icns")
    let menuPDF = output.appendingPathComponent("MenuBarIcon.pdf")
    for target in [iconset, icns, menuPDF] where manager.fileExists(atPath: target.path) {
        throw GeneratorError.outputExists(target.path)
    }
    try manager.createDirectory(at: iconset, withIntermediateDirectories: false)
    for variant in variants {
        let imageURL = iconset.appendingPathComponent(variant.name)
        try pngData(pixels: variant.pixels).write(
            to: imageURL,
            options: .withoutOverwriting
        )
        let writtenData = try Data(contentsOf: imageURL)
        guard let representation = NSBitmapImageRep(data: writtenData),
              representation.pixelsWide == variant.pixels,
              representation.pixelsHigh == variant.pixels else {
            throw GeneratorError.png(variant.pixels)
        }
    }
    try writeMenuBarPDF(to: menuPDF)
    guard let menuImage = NSImage(contentsOf: menuPDF),
          menuImage.size.width > 0,
          menuImage.size.height > 0 else {
        throw GeneratorError.pdf
    }
    try runIconutil(iconset: iconset, output: icns)
    guard manager.fileExists(atPath: icns.path), manager.fileExists(atPath: menuPDF.path) else {
        throw GeneratorError.invalidOutput(output.path)
    }
} catch {
    fputs("generate-icons: \(error.localizedDescription)\n", stderr)
    exit(1)
}
```

After creation, mark only the shell test executable; the Swift script is invoked explicitly through `xcrun swift`:

```bash
chmod 755 Tests/Packaging/icon-generator-tests.sh
```

- [ ] **Step 4: Run the focused tests and inspect the generated master output**

Run:

```bash
bash -n Tests/Packaging/icon-generator-tests.sh
bash Tests/Packaging/icon-generator-tests.sh
```

Expected: `icon generator tests passed`. Also render a fresh 1024×1024 output from a unique temporary test directory and inspect it with `view_image`; verify blue-to-indigo background, white display, upper-right cyan sparkle, safe edge padding, and no text.

- [ ] **Step 5: Commit the generator deliverable**

```bash
git add Scripts/Icons/generate-icons.swift Tests/Packaging/icon-generator-tests.sh
git commit -m "feat: generate ScreenClear icon resources"
```

---

### Task 2: Adaptive Menu-Bar Icon With Safe Fallback

**Files:**
- Create: `Sources/ScreenClear/MenuBarIcon.swift`
- Create: `Tests/ScreenClearTests/MenuBarIconTests.swift`
- Modify: `Sources/ScreenClear/ScreenClearApp.swift:26-31`

**Interfaces:**
- Consumes: `Bundle.main/Contents/Resources/MenuBarIcon.pdf` when running as a packaged app.
- Produces: `MenuBarIcon.image(from:) -> NSImage?`, `MenuBarIcon.image(bundle:) -> NSImage?`, constant `MenuBarIcon.fallbackSystemName == "display"`, and `MenuBarIconLabel: View`.

- [ ] **Step 1: Write failing loader and fallback tests**

Create `Tests/ScreenClearTests/MenuBarIconTests.swift`:

```swift
import AppKit
import XCTest
@testable import ScreenClear

@MainActor
final class MenuBarIconTests: XCTestCase {
    private func temporaryURL(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenclear-menu-icon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root.appendingPathComponent(name)
    }

    func testValidPDFLoadsAsTemplateImage() throws {
        let url = try temporaryURL("MenuBarIcon.pdf")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        try view.dataWithPDF(inside: view.bounds).write(to: url, options: .atomic)

        let image = try XCTUnwrap(MenuBarIcon.image(from: url))

        XCTAssertTrue(image.isTemplate)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testMissingAndInvalidResourcesReturnNil() throws {
        XCTAssertNil(MenuBarIcon.image(from: nil))
        let invalid = try temporaryURL("MenuBarIcon.pdf")
        try Data("not an image".utf8).write(to: invalid, options: .atomic)
        XCTAssertNil(MenuBarIcon.image(from: invalid))
    }

    func testFallbackRemainsDisplaySymbol() {
        XCTAssertEqual(MenuBarIcon.fallbackSystemName, "display")
    }
}
```

- [ ] **Step 2: Run the focused test and confirm RED**

Run:

```bash
swift test --filter MenuBarIconTests
```

Expected: compilation fails because `MenuBarIcon` does not exist.

- [ ] **Step 3: Implement the loader, template marking, and fallback label**

Create `Sources/ScreenClear/MenuBarIcon.swift`:

```swift
import AppKit
import SwiftUI

@MainActor
enum MenuBarIcon {
    static let fallbackSystemName = "display"

    static func image(from url: URL?) -> NSImage? {
        guard let url,
              url.isFileURL,
              let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0,
              let image = NSImage(contentsOf: url),
              image.size.width > 0,
              image.size.height > 0 else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    static func image(bundle: Bundle = .main) -> NSImage? {
        image(from: bundle.url(forResource: "MenuBarIcon", withExtension: "pdf"))
    }
}

struct MenuBarIconLabel: View {
    var body: some View {
        Group {
            if let image = MenuBarIcon.image() {
                Image(nsImage: image)
            } else {
                Image(systemName: MenuBarIcon.fallbackSystemName)
            }
        }
        .accessibilityLabel("ScreenClear")
    }
}
```

Replace the `MenuBarExtra` initializer in `Sources/ScreenClear/ScreenClearApp.swift`:

```swift
var body: some Scene {
    MenuBarExtra {
        MenuContent()
            .environment(model)
    } label: {
        MenuBarIconLabel()
    }
    .menuBarExtraStyle(.menu)
}
```

- [ ] **Step 4: Run focused and full Swift gates**

Run:

```bash
swift test --filter MenuBarIconTests
swift test
swift build
swift build -c release
```

Expected: all tests pass and both build configurations compile. Run `.build/debug/ScreenClear --selftest` and confirm it exits successfully without requiring packaged resources, proving the fallback path does not break bare builds.

- [ ] **Step 5: Commit the menu-bar deliverable**

```bash
git add Sources/ScreenClear/MenuBarIcon.swift Sources/ScreenClear/ScreenClearApp.swift Tests/ScreenClearTests/MenuBarIconTests.swift
git commit -m "feat: add adaptive ScreenClear menu icon"
```

---

### Task 3: Transactional Bundle Packaging and Resource Verification

**Files:**
- Modify: `make-app.sh:12-19,261-287,421-449`
- Modify: `Tests/Packaging/verify-app.sh:18-68`
- Modify: `Tests/Packaging/verify-app-archive-tests.sh:20-52`
- Modify: `Tests/Packaging/verify-publication-transaction.sh:38-50`

**Interfaces:**
- Consumes: Task 1 generator and its `ScreenClear.icns`/`MenuBarIcon.pdf` outputs.
- Produces: a signed `.app`, ZIP, and installed copy containing ordinary nonempty `Contents/Resources/ScreenClear.icns` and `MenuBarIcon.pdf`, with `CFBundleIconFile=ScreenClear` and exact cross-artifact resource hashes.

- [ ] **Step 1: Strengthen the bundle and archive verifier before packaging changes**

In `Tests/Packaging/verify-app.sh`, extend `verify_bundle()` after the executable declaration and plist assertions:

```bash
local icon="$bundle_path/Contents/Resources/ScreenClear.icns"
local menu_icon="$bundle_path/Contents/Resources/MenuBarIcon.pdf"

test -f "$icon"
test ! -L "$icon"
test -s "$icon"
test -f "$menu_icon"
test ! -L "$menu_icon"
test -s "$menu_icon"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$info")" = "ScreenClear"
/usr/bin/file "$icon" | grep -q 'Mac OS X icon'
/usr/bin/file "$menu_icon" | grep -q 'PDF document'
```

After `unzip -tq "$zip_path"`, reject metadata-only ZIP entries:

```bash
if unzip -Z1 "$zip_path" | grep -Eq '(^|/)\._|^__MACOSX/'; then
    printf 'archive contains unexpected AppleDouble metadata\n' >&2
    exit 1
fi
```

After extracting and validating `archived_app`, replace the executable-only digest comparison with:

```bash
for relative_path in \
    Contents/MacOS/ScreenClear \
    Contents/Resources/ScreenClear.icns \
    Contents/Resources/MenuBarIcon.pdf; do
    supplied_hash=$(shasum -a 256 "$app_path/$relative_path" | awk '{print $1}')
    archived_hash=$(shasum -a 256 "$archived_app/$relative_path" | awk '{print $1}')
    test "$supplied_hash" = "$archived_hash"
done
```

In `Tests/Packaging/verify-app-archive-tests.sh`, add a re-signed valid-PDF mismatch after the executable mismatch case:

```bash
resource_mismatch_root="$test_root/resource-mismatch"
mkdir -p "$resource_mismatch_root"
ditto "$source_app" "$resource_mismatch_root/ScreenClear.app"
printf '\n' >> "$resource_mismatch_root/ScreenClear.app/Contents/Resources/MenuBarIcon.pdf"
codesign --force --deep --sign - --timestamp=none \
    "$resource_mismatch_root/ScreenClear.app" >/dev/null
ditto -c -k --norsrc --keepParent \
    "$resource_mismatch_root/ScreenClear.app" "$test_root/resource-mismatch.zip"
assert_rejected "$test_root/resource-mismatch.zip"
```

Replace the existing extra-root and executable-mismatch archive commands with these metadata-free forms, so each rejection exercises its intended condition instead of failing early on AppleDouble entries:

```bash
ditto -c -k --norsrc "$extra_root" "$test_root/extra.zip"
ditto -c -k --norsrc --keepParent \
    "$mismatch_root/ScreenClear.app" "$test_root/mismatch.zip"
```

- [ ] **Step 2: Run the verifier against a fresh old-format build and confirm RED**

Run:

```bash
./make-app.sh
Tests/Packaging/verify-app.sh ScreenClear.app dist/ScreenClear-macos-arm64.zip
```

Expected: `make-app.sh` still succeeds, then `verify-app.sh` fails because `CFBundleIconFile` and `Contents/Resources/ScreenClear.icns` are missing.

- [ ] **Step 3: Generate resources in the staging transaction before signing**

Add these variables near the other `make-app.sh` path declarations:

```bash
icon_generator="$project_root/Scripts/Icons/generate-icons.swift"
generated_resources="$stage_root/generated-resources"
staged_resources="$staged_app/Contents/Resources"
```

Replace the build/staging start with:

```bash
swift build -c release
[[ -f "$icon_generator" && ! -L "$icon_generator" ]] || {
    printf '图标生成器缺失或不是普通文件: %s\n' "$icon_generator" >&2
    exit 1
}
mkdir -p "$generated_resources"
/usr/bin/xcrun swift "$icon_generator" "$generated_resources"

mkdir -p "$staged_app/Contents/MacOS" "$staged_resources"
cp .build/release/ScreenClear "$staged_app/Contents/MacOS/ScreenClear"
chmod 755 "$staged_app/Contents/MacOS/ScreenClear"
for resource_name in ScreenClear.icns MenuBarIcon.pdf; do
    generated_resource="$generated_resources/$resource_name"
    [[ -f "$generated_resource" && ! -L "$generated_resource" && -s "$generated_resource" ]] || {
        printf '生成的图标资源无效: %s\n' "$generated_resource" >&2
        exit 1
    }
    cp "$generated_resource" "$staged_resources/$resource_name"
done
/usr/bin/file "$staged_resources/ScreenClear.icns" | grep -q 'Mac OS X icon'
/usr/bin/file "$staged_resources/MenuBarIcon.pdf" | grep -q 'PDF document'
```

Add the icon declaration to the generated plist before `LSMinimumSystemVersion`:

```xml
    <key>CFBundleIconFile</key><string>ScreenClear</string>
```

Keep `plutil -lint` and both signing commands after all resource copies and format checks.

Replace the staged ZIP creation and validation with:

```bash
ditto -c -k --norsrc --keepParent "$staged_app" "$staged_zip"
unzip -tq "$staged_zip"
if unzip -Z1 "$staged_zip" | grep -Eq '(^|/)\._|^__MACOSX/'; then
    printf 'ZIP 包含意外 AppleDouble 元数据\n' >&2
    exit 1
fi
```

- [ ] **Step 4: Extend installed-app validation and transaction fixtures**

Inside `validate_new_install()` in `make-app.sh`, add:

```bash
local icon_file
local relative_resource
local packaged_resource
local installed_resource
local packaged_resource_hash
local installed_resource_hash

icon_file=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' \
    "$install_target/Contents/Info.plist" 2>/dev/null || true)
[[ "$installed_id" = "$bundle_id" && "$minimum_system" = "14.0" &&
   "$icon_file" = "ScreenClear" ]] || return 1

for relative_resource in ScreenClear.icns MenuBarIcon.pdf; do
    packaged_resource="$project_app/Contents/Resources/$relative_resource"
    installed_resource="$install_target/Contents/Resources/$relative_resource"
    [[ -f "$packaged_resource" && ! -L "$packaged_resource" && -s "$packaged_resource" ]] || return 1
    [[ -f "$installed_resource" && ! -L "$installed_resource" && -s "$installed_resource" ]] || return 1
    packaged_resource_hash=$(shasum -a 256 "$packaged_resource" | awk '{print $1}')
    installed_resource_hash=$(shasum -a 256 "$installed_resource" | awk '{print $1}')
    [[ "$packaged_resource_hash" = "$installed_resource_hash" ]] || return 1
done
```

Replace the old two-condition installed ID/minimum-version assertion with the three-condition assertion above instead of leaving both versions in the function.

In `Tests/Packaging/verify-publication-transaction.sh`, create and copy the icon script into every isolated fixture:

```bash
mkdir -p "$case_root/.build/release" \
    "$case_root/Scripts/Packaging" \
    "$case_root/Scripts/Icons" \
    "$shim_dir"
cp "$project_root/Scripts/Icons/generate-icons.swift" \
    "$case_root/Scripts/Icons/generate-icons.swift"
```

The existing `swift` shim continues to accept only `swift build -c release`; icon generation uses absolute `/usr/bin/xcrun swift` and therefore exercises the real generator inside the fixture.

- [ ] **Step 5: Run packaging and rollback gates**

Run:

```bash
bash -n make-app.sh Tests/Packaging/verify-app.sh Tests/Packaging/verify-app-archive-tests.sh Tests/Packaging/verify-publication-transaction.sh
./make-app.sh
Tests/Packaging/verify-app.sh ScreenClear.app dist/ScreenClear-macos-arm64.zip
Tests/Packaging/verify-app-archive-tests.sh ScreenClear.app
Tests/Packaging/verify-publication-transaction.sh all
```

Expected: bundle/ZIP verification passes; archive rejection tests report success; transaction cases print `PASS: identity`, `PASS: zip-rollback`, and `PASS: signature-rollback`. Confirm `codesign --verify --deep --strict ScreenClear.app` succeeds after resources are included.

- [ ] **Step 6: Commit the packaging deliverable**

```bash
git add make-app.sh Tests/Packaging/verify-app.sh Tests/Packaging/verify-app-archive-tests.sh Tests/Packaging/verify-publication-transaction.sh
git commit -m "build: package and verify ScreenClear icons"
```

---

### Task 4: Documentation, Full Verification, Packaging, and Local Installation

**Files:**
- Modify: `README.md:5-28,51-66`
- Verify only: all source, tests, packaging scripts, generated App/ZIP, and `/Applications/ScreenClear.app`

**Interfaces:**
- Consumes: all Task 1–3 outputs and the existing `./make-app.sh --install` transactional installer.
- Produces: documented icon generation, a fully verified App/ZIP, a locally installed and running icon-enabled ScreenClear, plus evidence that external display state was not changed by installation.

- [ ] **Step 1: Document the icon pipeline and source layout**

Add this after the build command block in `README.md`:

````markdown
打包时会通过 `Scripts/Icons/generate-icons.swift` 生成 A 款蓝紫应用图标、标准多尺寸 `ScreenClear.icns` 和自适应菜单栏模板图标。生成过程只依赖 macOS 自带 AppKit/CoreGraphics、`iconutil` 与 `sips`，不需要第三方图像工具。

单独验证图标生成器：

```bash
Tests/Packaging/icon-generator-tests.sh
```
````

Add these entries to the source tree section:

```text
├── MenuBarIcon.swift          # 菜单栏模板资源加载 + display 回退
Scripts/Icons/
└── generate-icons.swift       # A 款矢量图标与标准 macOS 资源生成
```

- [ ] **Step 2: Run the complete non-mutating verification matrix**

Record the real override digest before the build when the target exists:

```bash
override_path=/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-5e3/DisplayProductID-2490
if [[ -f "$override_path" && ! -L "$override_path" ]]; then
    shasum -a 256 "$override_path"
fi
```

Then run:

```bash
swift test
swift build
swift build -c release
bash -n make-app.sh Scripts/Packaging/install-lifecycle.sh Tests/Packaging/*.sh
Tests/Packaging/icon-generator-tests.sh
Tests/Packaging/make-app-arguments-tests.sh
Tests/Packaging/install-lifecycle-tests.sh
Tests/Packaging/verify-publication-transaction.sh all
./make-app.sh
Tests/Packaging/verify-app.sh ScreenClear.app dist/ScreenClear-macos-arm64.zip
Tests/Packaging/verify-app-archive-tests.sh ScreenClear.app
```

Expected: every command exits 0; all Swift tests pass; Debug/Release compile; all packaging gates pass; the App and ZIP are ad-hoc signed, arm64, and contain matching icon resources.

Recompute the override digest and confirm it is identical. Confirm no `~/Library/LaunchAgents/local.screenclear.plist` or `/Applications/.ScreenClear.backup.*` was created by the non-installing build.

- [ ] **Step 3: Render and inspect the packaged application icon**

Create a unique preview directory and ask Quick Look to render the packaged app icon:

```bash
preview_root=$(mktemp -d "${TMPDIR:-/tmp}/screenclear-icon-preview.XXXXXX")
/usr/bin/qlmanage -t -s 512 -o "$preview_root" ScreenClear.app >/dev/null
find "$preview_root" -maxdepth 1 -type f -print
```

Inspect the emitted PNG with `view_image`. Acceptance: blue-to-indigo rounded square, centered white display, upper-right cyan sparkle, balanced safe margins, no text, and no clipped strokes. Inspect the generated 16×16 and 32×32 PNGs as enlarged nearest-neighbor previews and confirm the display and sparkle remain distinguishable.

- [ ] **Step 4: Install transactionally and verify the exact installed resources**

Run:

```bash
./make-app.sh --install
/usr/bin/codesign --verify --deep --strict --verbose=2 /Applications/ScreenClear.app
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' /Applications/ScreenClear.app/Contents/Info.plist)" = ScreenClear
for resource_name in ScreenClear.icns MenuBarIcon.pdf; do
    packaged_hash=$(shasum -a 256 "ScreenClear.app/Contents/Resources/$resource_name" | awk '{print $1}')
    installed_hash=$(shasum -a 256 "/Applications/ScreenClear.app/Contents/Resources/$resource_name" | awk '{print $1}')
    test "$packaged_hash" = "$installed_hash"
done
pgrep -af '^/Applications/ScreenClear.app/Contents/MacOS/ScreenClear$'
```

Expected: the previous exact-path process exits, a new exact-path process starts, resource hashes match, signature verification passes, and no backup bundle remains. Recompute the real override digest and confirm install/launch did not change it.

- [ ] **Step 5: Inspect the live menu-bar result without clearing global caches**

Inspect the running ScreenClear status item in both the current menu-bar state and its highlighted/open-menu state using the available local UI inspection surface. Acceptance: a monochrome display-and-sparkle icon is visible, macOS supplies its foreground color, strokes remain legible, and opening the menu still shows the existing controls. If the UI inspection surface is unavailable, record that limitation, verify `MenuBarIcon.pdf` decodes as a template via `MenuBarIconTests`, and ask the user for the final visual confirmation; do not delete Finder or Launch Services caches.

- [ ] **Step 6: Commit documentation after all gates pass**

```bash
git add README.md
git commit -m "docs: document ScreenClear icon generation"
```

- [ ] **Step 7: Finish with branch review and handoff**

Run:

```bash
git status --short --branch
git log --oneline --decorate -8
git diff main...HEAD --stat
```

Expected: no tracked changes remain, the icon generator/menu integration/packaging/docs commits are visible, and the installed application is the verified build. Then use `verification-before-completion` before reporting success and `finishing-a-development-branch` to offer integration choices. Keep the separate HiDPI administrator update explicitly pending until the user clicks the installed app’s update action and approves macOS authentication.
