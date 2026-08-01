# ScreenClear —— macOS 外接 2K 屏幕优化工具

针对 **AOC Q2490W1（23.8" 2560×1440，HDMI）** 在 M1 Max 上的两个问题：
1. **文字模糊**：当前跑在 1x 1080p（非 HiDPI 拉伸）
2. **颜色发灰泛白**：M1 经 HDMI 输出 YCbCr 而非 RGB

## 测试、构建与安装

```bash
swift test
./make-app.sh
./make-app.sh --install
```

- `ScreenClear.app`
- `dist/ScreenClear-macos-arm64.zip`
- 使用 `--install` 时的 `/Applications/ScreenClear.app`

自动测试不会切换模式或修改系统显示配置。应用采用 ad-hoc 签名，仅用于本机运行；其他 Mac 分发仍需 Developer ID 签名和公证。

自检 / 命令行切换（开发用）：

```bash
swift run ScreenClear --selftest          # 只读自检
.build/debug/ScreenClear --apply 2560x1440@2x   # 切换到 1280×720@2x（渲染 2560×1440 原生点对点）
.build/debug/ScreenClear --apply 5120x2880@2x   # 切换到 2560×1440@2x（渲染 5120×2880）
.build/debug/ScreenClear --apply 1920x1080      # 切回 1x 1080p
```

自检会在临时目录保存其 fixture 和备份。

## 功能（菜单栏）

| 功能 | 说明 | 权限 |
|---|---|---|
| **标准尺寸（推荐）** | 1920×1080@2x，渲染 3840×2160 降采样，布局与 1x 1080p 一致（需先解锁） | 需先解锁 |
| **均衡（字更大）** | 1440×810@2x，渲染 2880×1620 降采样（需先解锁） | 需先解锁 |
| **更多空间（字更小）** | 1600×900@2x，渲染 3200×1800 降采样（需先解锁） | 需先解锁 |
| **清晰优先（字最大）** | 1280×720@2x，渲染 2560×1440 原生点对点，最锐利 | 无需 |
| **其他可用模式** | 包含非预设的 2560×1440@2x（渲染 5120×2880）；配置生效后在模式列表中选择 | 需先解锁 |
| **HiDPI 配置** | 写入 1440×810、1600×900、1920×1080、2560×1440 四档 @2x override；旧两档配置会显示一键更新，HDMI 重握手后生效（可能需重插线缆/重启） | 管理员一次 |
| **颜色修复** | 写 LinkDescription（RGB 全范围）到 ByHost windowserver plist，重启生效；系统级变体需管理员 | 无需（系统级需管理员） |
| **开机自启** | 写入 `~/Library/LaunchAgents/local.screenclear.plist` | 无需 |

## 技术要点

- **模式切换**：`CGBeginDisplayConfiguration` + `CGConfigureDisplayWithDisplayMode` + `CGCompleteDisplayConfiguration(.permanently)`，切换后 2s 校验逻辑尺寸、渲染尺寸与刷新率，失败重试一次；显示器休眠时切换会被系统拒绝，先 `caffeinate -u` 唤醒。
- **HiDPI 配置**：one-key-hidpi 同款格式 `base64(4B BE 渲染宽, 4B BE 渲染高, 0x00)`；1920×1080@2x 渲染 3840×2160，2560×1440@2x 渲染 5120×2880。应用读取现有 plist 后无损补齐缺失条目，写入前做 base64 往返自检 + `plutil -lint`；M 系列 + Sequoia 有效（Intel 已失效）。
- **颜色修复**：`LinkDescription = {BitDepth:8, EOTF:0, PixelEncoding:0, Range:1}`，写入 `~/Library/Preferences/ByHost/com.apple.windowserver.displays.*.plist` 的 `DisplaySets:Configs:*:DisplayConfig:*` 条目（按显示器 UUID 匹配，备用分辨率匹配），重启生效；先备份到 `~/Library/Application Support/ScreenClear/Backups/`，可一键恢复。注意：macOS 13.3+ 重启后可能被系统覆盖，属"尽力而为"，对照 BetterDisplay 的信号面板验证。
- **显示器枚举**：`CGGetOnlineDisplayList`（Active 列表在显示器休眠时返回空）。

## 目录结构

```
Sources/ScreenClear/
├── ScreenClearApp.swift       # @main + --selftest / --apply CLI
├── AppDelegate.swift          # accessory 策略（避免 Dock 闪现）
├── Models.swift               # DisplayInfo / ModeEntry（值类型）
├── AppModel.swift             # 状态与编排（@MainActor @Observable）
├── DisplayManager.swift       # CG 枚举/切换（含唤醒、节流、校验重试）
├── RegistryReader.swift       # IORegistry AppleCLCD2 属性读取
├── OverrideBuilder.swift      # scale-resolutions plist 生成 + 自检
├── OverrideConfiguration.swift # override 分类、无损合并 + 生效条件
├── OverrideInstaller.swift    # osascript 管理员原子安装/更新/移除
├── LinkDescriptionPatcher.swift # 颜色修复 + 备份恢复
├── MenuContent.swift          # 菜单栏 UI
├── SelfTest.swift             # 自检 + CLI 模式切换
└── Extensions.swift           # String: Error
```

## 已知限制

- 降采样 HiDPI（含 1920×1080 与 2560×1440）渲染像素高于面板原生，锐度和 GPU 开销取决于 macOS、连接与硬件；5120×2880 可能需要重插线缆或重启后才出现，也可能被系统拒绝。
- 颜色修复重启后可能被 macOS 覆盖（Ventura 13.3+ 行为），可重写或使用 BetterDisplay 的 Force RGB / 配置保护。
- 应用采用 ad-hoc 签名，仅用于本机运行；分发给其他 Mac 仍需 Developer ID 签名和公证。
