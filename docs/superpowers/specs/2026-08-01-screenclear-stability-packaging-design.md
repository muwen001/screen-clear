# ScreenClear 稳定性与打包优化设计

## 目标

在不重做界面、不增加显示器功能的前提下，提高 ScreenClear 的模式切换校验、自检隔离性和本机交付可靠性。最终产物应能够通过自动测试和 Release 编译，生成经过完整 ad-hoc 签名验证的 macOS 应用与压缩包，并安装到 `/Applications/ScreenClear.app` 后成功启动。

## 范围

本次包含：

- 修复显示模式切换后只校验渲染像素、可能混淆 1x 与 2x 模式的问题。
- 消除 `--selftest` 在真实 Application Support 备份目录中留下文件的副作用。
- 为纯逻辑和 plist 补丁行为增加 SwiftPM 自动测试。
- 改进 `.app` 组装、Info.plist 校验、完整应用签名、压缩包生成和本机安装流程。
- 安装后验证应用结构、签名、二进制一致性和启动状态。

本次不包含：

- 菜单栏界面改版或新增图标资源。
- 多外接显示器选择、动态显示器型号配置或新的 HiDPI 预设。
- 安装时切换分辨率、写入显示器 override、修改 LinkDescription 或启用开机自启。
- Developer ID 签名、公证或面向其他 Mac 分发。

## 现状与问题

项目是 Swift 6.1 的 macOS 14+ SwiftPM 可执行应用，使用 SwiftUI `MenuBarExtra` 提供菜单栏界面。基线 Debug 和 Release 构建均成功，但没有测试 target。当前构建脚本直接删除并重建仓库根目录下的 `ScreenClear.app`，复制的可执行文件只有链接器 ad-hoc 签名，应用的 Info.plist 与资源未被完整签名封装。

`DisplayManager.verify` 最终只比较当前模式与目标模式的 `pixelWidth` 和 `pixelHeight`。项目本身已经明确存在渲染像素相同但逻辑尺寸或缩放倍数不同的模式，因此这不是足以确认切换成功的条件。

`SelfTest.run` 在临时 plist 上调用 `LinkDescriptionPatcher.apply`，而该入口固定调用真实 `backupDir`。因此自检虽然不修改显示配置，却会在 `~/Library/Application Support/ScreenClear/Backups/` 留下测试备份。

## 架构设计

### 精确的显示模式身份

`ModeEntry` 继续作为视图层和显示管理层共享的值类型，同时提供可测试的精确模式匹配能力。模式身份由以下字段共同决定：

- 逻辑宽度与高度；
- 渲染像素宽度与高度；
- 刷新率，使用当前代码已有的容差比较。

`ModeEntry.id` 同时纳入逻辑尺寸，避免不同逻辑模式在列表去重和 SwiftUI 标识中碰撞。`DisplayManager.modeEntries` 的当前模式判定和切换后的 `matches` 校验都复用统一比较规则，避免三处逻辑漂移。系统中的权威事实仍然来自 CoreGraphics 当前模式；不增加持久化状态，也不改变 `AppModel` 的状态所有权。

### 可隔离的 plist 备份

`LinkDescriptionPatcher.apply` 接受明确的备份目录参数，并为正常应用调用保留真实备份目录作为默认值。生产 UI 流程保持现有备份与恢复语义；`SelfTest` 和自动测试传入各自临时目录，使所有测试文件、备份和清理都局限于临时目录。

这项调整只改变备份目的地的依赖注入，不增加测试专用生产 API，也不改变真实 ByHost 或系统级修复的行为。

### 自动测试边界

在 `Package.swift` 中添加依赖 `ScreenClear` executable target 的测试 target。测试覆盖：

- 逻辑尺寸不同但渲染像素相同的模式不得匹配；
- 所有模式字段一致、刷新率位于容差内时可以匹配；
- Override 条目编码、往返验证和 plist 生成保持正确；
- LinkDescription 能匹配 UUID 并写入临时 plist；
- 使用临时备份目录时不会在真实 ScreenClear 备份目录创建测试文件。

涉及 CoreGraphics 实际切换、管理员授权和系统配置写入的行为不做自动化调用，避免测试改变本机显示状态。

### 可验证的打包与安装

`make-app.sh` 保持单一入口，但使用临时 staging 目录组装应用。脚本流程为：

1. Release 编译；
2. 在 staging 目录生成标准 bundle 结构和 Info.plist；
3. 复制 Release 可执行文件并校验 plist；
4. 对整个 `.app` 执行 ad-hoc 签名；
5. 使用 `codesign --verify --deep --strict` 验证；
6. 将已验证 bundle 发布为仓库根目录的 `ScreenClear.app`；
7. 在 `dist/` 生成保留资源属性的 macOS ZIP 包。

脚本增加 `--install` 选项。安装目标固定为 `/Applications/ScreenClear.app`，操作前解析并检查准确目标：拒绝符号链接，若已存在则必须是目录且 bundle identifier 必须为 `local.screenclear`。替换现有安装时先保留可恢复的临时备份；复制或验证失败则恢复旧版本，成功后再移除临时备份。安装前终止已运行的 ScreenClear，安装后重新启动。

当前机器上的 `/Applications` 对当前用户可写，且审计时没有既有 ScreenClear 安装，因此首次安装不会覆盖用户数据。

## 数据流与生命周期

模式切换仍由 `AppModel` 发起，`DisplayManager` 从 CoreGraphics 重新解析目标模式、执行切换，并从 CoreGraphics 读取当前模式进行精确校验。成功或失败结果返回 `AppModel` 更新菜单状态，流程不引入缓存或新的状态源。

自检创建唯一临时目录，将测试 plist 与测试备份都放入其中，完成后清理临时目录。任何步骤失败时输出 `FAIL`，但不触碰真实显示配置或真实备份目录。

打包过程中 staging 目录是未发布产物，只有编译、plist 校验和签名验证全部成功后才发布。安装过程中 `/Applications/ScreenClear.app` 是最终权威安装位置；旧安装只在验证新安装通过后删除备份。

## 错误处理

- 模式校验不通过时沿用现有失败结果和用户提示，不把相同渲染像素误报为成功。
- 自检创建、写入或清理临时资源失败时记录明确失败项；清理采用 best-effort，不掩盖原始错误。
- 打包脚本使用严格 shell 模式和退出时清理 staging 目录；任一构建、plist 或签名步骤失败即停止发布。
- 安装拒绝不符合预期的现有目标，不删除符号链接或其他 bundle；替换失败时恢复旧应用。
- ad-hoc 签名只用于本机运行。脚本和文档不宣称它满足 Gatekeeper 分发或公证要求。

## 文件变更

- `Package.swift`：添加测试 target。
- `Sources/ScreenClear/Models.swift`：提供统一、可测试的模式匹配规则。
- `Sources/ScreenClear/DisplayManager.swift`：复用精确规则判断当前模式和验证切换结果。
- `Sources/ScreenClear/LinkDescriptionPatcher.swift`：注入备份目录，同时保持生产默认行为。
- `Sources/ScreenClear/SelfTest.swift`：将补丁测试及备份限制在临时目录。
- `Tests/ScreenClearTests/`：新增模式、Override 与 plist 补丁测试。
- `make-app.sh`：实现 staging、验证、完整 ad-hoc 签名、ZIP 打包和安全安装。
- `README.md`：更新测试、构建、安装、产物和签名说明。

## 验证与成功标准

依次执行并满足以下条件：

1. 新增模式匹配测试在实现前因 1x/2x 误判而失败，实现后通过。
2. plist 隔离测试在实现前能观察到错误备份位置，实现后只在临时目录产生备份。
3. `swift test` 零失败且无编译错误。
4. `swift build -c debug` 和 `swift build -c release` 均退出 0。
5. `./make-app.sh` 退出 0，并生成 `ScreenClear.app` 与 `dist/ScreenClear-macos-arm64.zip`。
6. `plutil` 能读取生成应用的 Info.plist，bundle identifier 为 `local.screenclear`。
7. `codesign --verify --deep --strict ScreenClear.app` 退出 0，签名显示为 ad-hoc。
8. `./make-app.sh --install` 退出 0，安装位置为 `/Applications/ScreenClear.app`。
9. 安装产物的可执行文件哈希与打包产物一致，安装包签名验证通过。
10. 启动安装后的应用并确认 ScreenClear 进程存活；不自动执行任何显示模式或颜色配置修改。

## 回滚

代码和脚本更改按独立任务提交到 Git，可通过提交历史回滚。安装脚本在替换失败时自动恢复旧应用。首次安装后如需卸载，只需退出 ScreenClear 并移除固定目标 `/Applications/ScreenClear.app`；本次安装本身不会写入系统显示配置或 LaunchAgent。
