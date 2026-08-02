# ScreenClear Launchpad Icon Scale Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Reduce ScreenClear’s complete application-icon artwork to a centered 90% scale so its visible Launchpad footprint is about 83% of the canvas, close to local ZCode, while preserving small-size legibility and current package/install guarantees.

**Architecture:** Keep the 128-unit AppKit/CoreGraphics master drawing as the only geometry source for regular sizes. A center-preserving transform wraps the regular master; the 16 px compact path applies that transform to its colored background and uses its nearest-pixel foreground equivalent, so the monitor, stand, and sparkle remain readable. The generator test decodes real PNG output; it does not inspect source coordinates.

**Tech Stack:** Swift 6, AppKit, CoreGraphics, Foundation, Bash, xcrun swift, iconutil, sips, codesign, ditto.

## Global Constraints

- Scale complete app-icon artwork by exactly 0.90 about (64, 64) for the 128-unit master and (8, 8) for the 16 px compact path.
- The regular background moves from x=5…123 (92.2%) to about x=10.9…117.1 (83.0%). Do not alter colors, paths, corner ratios, monitor geometry, or sparkle geometry separately.
- Preserve the dedicated 16 px renderer. Its colored background receives the exact 0.90 transform; monitor, stand, and cyan sparkle use the nearest-pixel equivalent of that target geometry and remain visible in decoded output.
- Do not alter MenuBarIcon.pdf, MenuBarIcon.swift, menu-bar template behavior, or the display fallback.
- Preserve CFBundleIdentifier=local.screenclear, ScreenClear, version 1.0 (1), LSUIElement=true, NSHighResolutionCapable=true, accessory activation, and ad-hoc signing.
- Do not modify HiDPI overrides, current display modes, LinkDescription, LaunchAgents, Finder/Launch Services caches, or display configuration. Installation remains exactly /Applications/ScreenClear.app.
- Preserve generator staging/publish/rollback, iconset sizes, ICNS generation, resource paths, signature, archive, and metadata checks.

## File Structure

- Scripts/Icons/generate-icons.swift: one centered-scale helper, a regular app-icon branch, and split compact background/foreground drawing; the menu-bar PDF drawing remains unchanged.
- Tests/Packaging/icon-generator-tests.sh: decoded 1024 px footprint test plus decoded 16 px footprint/component/mutation checks.
- make-app.sh and existing package tests: no source edit planned; used as integration gates after regenerated artwork.

---

### Task 1: Center-scale the regular application-icon master

**Files:**

- Modify: Scripts/Icons/generate-icons.swift:68-215
- Modify: Tests/Packaging/icon-generator-tests.sh:42-242

**Interfaces:**

- Consumes: pngData(pixels:), drawAppIcon(in:pixels:), and all ten existing icon variants.
- Produces: drawCenteredAppArtwork(in:canvas:draw:), later used by Task 2.

- [ ] **Step 1: Write the failing high-resolution footprint test**

Add this function after the small_icon declaration and invoke it immediately after generation with regular_icon="$output_root/ScreenClear.iconset/icon_512x512@2x.png":

~~~bash
validate_regular_icon_footprint() {
    /usr/bin/xcrun swift - "$1" <<'SWIFT'
import AppKit
import Foundation

guard CommandLine.arguments.count == 2,
      let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      let image = NSBitmapImageRep(data: data),
      image.pixelsWide == 1024,
      image.pixelsHigh == 1024 else {
    fputs("cannot decode 1024px icon\n", stderr)
    exit(1)
}

let row = image.pixelsHigh / 2
let opaqueColumns = (0..<image.pixelsWide).filter {
    (image.colorAt(x: $0, y: row)?.alphaComponent ?? 0) >= 0.95
}
guard let first = opaqueColumns.first, let last = opaqueColumns.last else {
    fputs("regular icon footprint failure: center row is transparent\n", stderr)
    exit(1)
}
let span = last - first + 1
guard (87...89).contains(first),
      (935...937).contains(last),
      (847...851).contains(span),
      abs((first + last) - 1023) <= 1 else {
    fputs("regular icon footprint failure: expected centered 83% span, got first=\(first) last=\(last) span=\(span)\n", stderr)
    exit(1)
}
SWIFT
}
~~~

~~~bash
regular_icon="$output_root/ScreenClear.iconset/icon_512x512@2x.png"
validate_regular_icon_footprint "$regular_icon"
~~~

This tests decoded behavior. The current master has about a 944-pixel opaque center span starting near column 40, so it must fail before the renderer changes.

- [ ] **Step 2: Verify the red result**

Run:

~~~bash
Tests/Packaging/icon-generator-tests.sh
~~~

Expected: non-zero exit and regular icon footprint failure: expected centered 83% span.

- [ ] **Step 3: Add the single centered-scale helper and use it only for regular artwork**

Above drawCompactAppIcon, add:

~~~swift
let appIconArtworkScale: CGFloat = 0.90

func drawCenteredAppArtwork(
    in context: CGContext,
    canvas: CGFloat,
    draw: () -> Void
) {
    context.saveGState()
    context.translateBy(x: canvas / 2, y: canvas / 2)
    context.scaleBy(x: appIconArtworkScale, y: appIconArtworkScale)
    context.translateBy(x: -canvas / 2, y: -canvas / 2)
    draw()
    context.restoreGState()
}
~~~

In the non-16 branch of pngData, retain normalization and replace the direct draw:

~~~swift
graphics.cgContext.scaleBy(x: CGFloat(pixels) / 128, y: CGFloat(pixels) / 128)
drawCenteredAppArtwork(in: graphics.cgContext, canvas: 128) {
    drawAppIcon(in: graphics.cgContext, pixels: pixels)
}
~~~

Keep pixels == 16 calling drawCompactAppIcon directly in this task. Do not edit drawAppIcon geometry, colors, or PDF rendering.

- [ ] **Step 4: Verify green**

Run:

~~~bash
Tests/Packaging/icon-generator-tests.sh
~~~

Expected: generator test passes, including its original transaction and format gates; the existing 16 px path remains unchanged.

- [ ] **Step 5: Commit Task 1**

~~~bash
git add Scripts/Icons/generate-icons.swift Tests/Packaging/icon-generator-tests.sh
git commit -m "fix: align regular ScreenClear icon footprint"
~~~

### Task 2: Center-scale and protect the true 16 px compact rendition

**Files:**

- Modify: Scripts/Icons/generate-icons.swift:203-208
- Modify: Tests/Packaging/icon-generator-tests.sh:42-202

**Interfaces:**

- Consumes: drawCenteredAppArtwork(in:canvas:draw:) from Task 1 and split compact background/foreground drawing.
- Produces: an approximately 83% compact colored footprint plus executable monitor, stand, and cyan-sparkle regression checks.

- [ ] **Step 1: Write the failing compact-footprint regression**

Inside the embedded Swift of validate_small_icon, add after countPixels:

~~~swift
func alphaAt(x: Int, y: Int) -> CGFloat {
    image.colorAt(x: x, y: y)?.alphaComponent ?? 0
}

func failCompactFootprint() -> Never {
    fputs("16px icon visibility failure: compact footprint\n", stderr)
    exit(1)
}
~~~

Place this before the display-side assertion:

~~~swift
guard alphaAt(x: 1, y: 8) < 0.90,
      alphaAt(x: 2, y: 8) >= 0.95,
      alphaAt(x: 13, y: 8) >= 0.95,
      alphaAt(x: 14, y: 8) < 0.90 else {
    failCompactFootprint()
}
~~~

The unscaled compact background is opaque adjacent to its 0.625 px edge, so this must fail before changing the compact rendering path.

- [ ] **Step 2: Verify the compact red result**

Run:

~~~bash
Tests/Packaging/icon-generator-tests.sh
~~~

Expected: non-zero exit and 16px icon visibility failure: compact footprint.

- [ ] **Step 3: Apply the existing transform to the compact background and draw a pixel-aligned foreground**

Split the former compact renderer into a background function that retains its existing gradient/corner geometry and a foreground function with these nearest-pixel target primitives:

~~~swift
func drawCompactAppIconForeground(in context: CGContext) {
    let screen = CGPath(
        roundedRect: CGRect(x: 3, y: 5, width: 8, height: 7),
        cornerWidth: 1,
        cornerHeight: 1,
        transform: nil
    )
    context.addPath(screen)
    context.setFillColor(color(1, 1, 1))
    context.fillPath()

    let screenInterior = CGPath(
        roundedRect: CGRect(x: 4, y: 6, width: 6, height: 5),
        cornerWidth: 0.5,
        cornerHeight: 0.5,
        transform: nil
    )
    context.addPath(screenInterior)
    context.setFillColor(color(0.35, 0.47, 0.93))
    context.fillPath()

    context.setFillColor(color(1, 1, 1))
    context.fill(CGRect(x: 6, y: 3, width: 2, height: 3))
    context.addPath(CGPath(
        roundedRect: CGRect(x: 5, y: 2, width: 5, height: 2),
        cornerWidth: 1,
        cornerHeight: 1,
        transform: nil
    ))
    context.fillPath()

    context.addPath(sparklePath(center: CGPoint(x: 12.5, y: 12.5), outer: 2.15, inner: 0.9))
    context.setFillColor(color(1, 1, 1))
    context.fillPath()
    context.addPath(sparklePath(center: CGPoint(x: 12.5, y: 12.5), outer: 1.5, inner: 0.65))
    context.setFillColor(color(0.73, 0.96, 1))
    context.fillPath()
}

if pixels == 16 {
    drawCenteredAppArtwork(in: graphics.cgContext, canvas: 16) {
        drawCompactAppIconBackground(in: graphics.cgContext)
    }
    drawCompactAppIconForeground(in: graphics.cgContext)
} else {
    graphics.cgContext.scaleBy(x: CGFloat(pixels) / 128, y: CGFloat(pixels) / 128)
    drawCenteredAppArtwork(in: graphics.cgContext, canvas: 128) {
        drawAppIcon(in: graphics.cgContext, pixels: pixels)
    }
}
~~~

Do not change the compact colors; this raster alignment is required because a literal fractional transform blends the monitor's white border below the visibility threshold.

- [ ] **Step 4: Recalibrate only the decoded component probes and their fixtures**

Use these top-origin component regions in validate_small_icon after Step 3:

~~~swift
guard countPixels(x: 3...3, y: 6...10, matching: white) >= 3,
      countPixels(x: 10...10, y: 6...9, matching: white) >= 3 else {
    fail("display side boundary")
}
guard countPixels(x: 4...9, y: 4...5, matching: white) >= 4 else {
    fail("display top boundary")
}
guard countPixels(x: 4...9, y: 10...10, matching: white) >= 4 else {
    fail("display bottom boundary")
}
guard countPixels(x: 6...7, y: 11...12, matching: white) >= 2,
      countPixels(x: 5...9, y: 12...13, matching: white) >= 3 else {
    fail("display stand")
}
guard countPixels(x: 11...14, y: 2...5, matching: cyan) >= 3 else {
    fail("upper-right sparkle")
}
~~~

Make the sparkle mutation use the same cyan region:

~~~swift
case "sparkle" where (11...14).contains(x) && (2...5).contains(y) && isCyan(pixel):
~~~

Keep the top-boundary mutation at x=4...9, y=4...5. It must still create the exact error messages upper-right sparkle and display top boundary.

- [ ] **Step 5: Verify green and mutation resistance**

Run:

~~~bash
Tests/Packaging/icon-generator-tests.sh
~~~

Expected: exit 0 and final line icon generator tests passed. The test internally proves cyan-to-white mutation fails as upper-right sparkle and top-boundary mutation fails as display top boundary.

- [ ] **Step 6: Commit Task 2**

~~~bash
git add Scripts/Icons/generate-icons.swift Tests/Packaging/icon-generator-tests.sh
git commit -m "fix: scale compact ScreenClear icon artwork"
~~~

### Task 3: Package, preserve external state, install, and visually accept

**Files:**

- Modify: none unless a verification gate identifies a concrete regression.
- Test: existing generator, archive, transaction, package, and installed-bundle gates.

**Interfaces:**

- Consumes: Task 1 and Task 2 generated resources plus make-app.sh --install.
- Produces: signed app/ZIP, a running exact-path installed app, and before/after evidence for protected display-related state.

- [ ] **Step 1: Run source and package gates before publication**

~~~bash
git diff --check
bash -n make-app.sh Scripts/Packaging/bundle-metadata.sh \
  Tests/Packaging/icon-generator-tests.sh Tests/Packaging/verify-app.sh \
  Tests/Packaging/verify-app-archive-tests.sh Tests/Packaging/verify-publication-transaction.sh
swift test
swift build
swift build -c release
Tests/Packaging/icon-generator-tests.sh
Tests/Packaging/verify-app-archive-tests.sh ScreenClear.app
Tests/Packaging/verify-publication-transaction.sh all
~~~

Expected: all commands exit 0; Swift reports 20 tests and 0 failures; generator ends icon generator tests passed; archive test ends archive verifier rejection tests passed; all four transaction cases report PASS.

- [ ] **Step 2: Take read-only before snapshots**

~~~bash
state_root=$(mktemp -d /tmp/screenclear-launchpad-scale-state.XXXXXX)
override_path=/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-5e3/DisplayProductID-2490
launch_agent_path=/Users/share/Library/LaunchAgents/local.screenclear.plist
byhost_path=/Users/share/Library/Preferences/ByHost/com.apple.windowserver.displays.4C32E97C-38FB-5A2C-870C-6EA57833EA6B.plist
system_display_path=/Library/Preferences/com.apple.windowserver.displays.plist
/usr/sbin/system_profiler SPDisplaysDataType > "$state_root/displays.before"
for path in "$override_path" "$launch_agent_path" "$byhost_path" "$system_display_path"; do
  test -f "$path"
  test ! -L "$path"
  stat -f '%N|%HT|%i|%z|%m' "$path"
  shasum -a 256 "$path"
  plutil -p "$path"
done > "$state_root/protected.before"
~~~

Expected: the four paths are regular, non-symlink files. Do not invoke a HiDPI update, touch display settings, or clear caches.

- [ ] **Step 3: Build, validate, and install**

~~~bash
./make-app.sh
Tests/Packaging/verify-app.sh ScreenClear.app dist/ScreenClear-macos-arm64.zip
./make-app.sh --install
/usr/bin/codesign --verify --deep --strict --verbose=2 /Applications/ScreenClear.app
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' /Applications/ScreenClear.app/Contents/Info.plist)" = ScreenClear
test -x /Applications/ScreenClear.app/Contents/MacOS/ScreenClear
pgrep -fl '/Applications/ScreenClear.app/Contents/MacOS/ScreenClear'
~~~

Expected: all commands exit 0 and pgrep reports a process from the exact installed executable path.

- [ ] **Step 4: Compare read-only after snapshots**

~~~bash
/usr/sbin/system_profiler SPDisplaysDataType > "$state_root/displays.after"
for path in "$override_path" "$launch_agent_path" "$byhost_path" "$system_display_path"; do
  test -f "$path"
  test ! -L "$path"
  stat -f '%N|%HT|%i|%z|%m' "$path"
  shasum -a 256 "$path"
  plutil -p "$path"
done > "$state_root/protected.after"
cmp -s "$state_root/displays.before" "$state_root/displays.after"
cmp -s "$state_root/protected.before" "$state_root/protected.after"
test -z "$(find /Applications -maxdepth 1 -name '.ScreenClear.backup.*' -print)"
~~~

Expected: both comparisons exit 0 and no backup bundle remains. On any mismatch, stop and inspect its exact diff without modifying display/cache state.

- [ ] **Step 5: Perform visual acceptance without cache deletion**

Open Launchpad through the ordinary macOS UI, compare ScreenClear beside ZCode, and confirm the blue/purple visible footprint now has comparable outer margin/weight while monitor, stand, and cyan sparkle stay centered. Confirm the menu-bar resource remains monochrome/template-rendered in normal and highlighted states.

Do not clear Finder or Launch Services caches. If macOS continues showing a stale icon, record it as a cache/UI limitation rather than claiming visual confirmation.

- [ ] **Step 6: Confirm final tracked state**

~~~bash
git status --short
git log --oneline -3
~~~

Expected: the two implementation commits are present and generated ScreenClear.app/dist artifacts are not staged. Make no empty verification commit.

## Plan Self-Review

- Spec coverage: Task 1 supplies exact 90% regular scaling and decoded 83% footprint proof. Task 2 applies the same transform to the compact drawing and preserves real component/mutation checks. Task 3 covers package, signature, metadata, exact install path/process, protected state, and Launchpad/menu-bar acceptance.
- Placeholder scan: no unfinished markers, implied test, or unspecified command remains.
- Interface consistency: drawCenteredAppArtwork(in:canvas:draw:) is declared in Task 1 and consumed in Task 2 with CGFloat canvases 128 and 16; pngData(pixels:) remains the only raster entry point.
