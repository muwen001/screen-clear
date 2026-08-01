# ScreenClear 应用与菜单栏图标设计

日期：2026-08-02

状态：已获用户批准

## 目标

为 ScreenClear 增加一套一致、可维护的图标系统：应用包在 Finder、系统设置和其他 macOS 界面中显示正式应用图标；菜单栏入口使用同一视觉概念的模板图标，并自动适配浅色、深色及高对比度菜单栏。

用户已选择 A 款视觉方向和“矢量母版 + 自动生成 `.icns`”实现方案。

## 当前状态

- 应用通过 `MenuBarExtra("ScreenClear", systemImage: "display")` 使用通用 SF Symbol；
- `make-app.sh` 手工创建 `.app`，只写入 `Contents/MacOS` 与 `Info.plist`；
- 应用包没有 `Contents/Resources`、应用图标或 `CFBundleIconFile`；
- 应用以 `LSUIElement` 与 `.accessory` 方式运行，不显示 Dock 图标，但应用图标仍会用于 Finder、系统设置、打开方式和进程相关界面。

## 范围

### 包含

- A 款应用图标：蓝紫渐变圆角方形、白色显示器、右上角清晰闪光，不含文字；
- 同构的菜单栏模板图标：显示器轮廓、底座与右上角闪光；
- 可编辑的矢量/参数化母版与可重复执行的 macOS 图标生成脚本；
- macOS 标准多尺寸 `.iconset`/`.icns` 生成；
- 在应用包内安装应用图标和菜单栏资源；
- 在 `Info.plist` 设置应用图标键；
- 菜单栏图标加载失败时的安全回退；
- 编译、打包、签名、ZIP、安装及图标资源自动验证；
- README 中的构建说明更新。

### 不包含

- 显示 Dock 图标或改变 `LSUIElement`/`.accessory` 行为；
- 修改应用名称、Bundle ID 或版本号；
- 动态图标、状态动画或根据显示模式改变图标；
- Developer ID 签名、公证或 App Store 资源目录；
- 修改系统显示 override、当前分辨率或其他外部显示状态。

## 视觉设计

### 应用图标

图标采用 macOS 圆角方形轮廓。背景从左上亮蓝过渡到右下靛紫，主体为白色显示器轮廓和底座；显示器右上方放置四角清晰闪光，使用浅青高光。图形居中并为系统遮罩与小尺寸缩放保留安全边距。

图标不使用文字、微小像素网格或复杂纹理。16×16 和 32×32 等小尺寸可适当加粗线条、收紧细节，保证显示器和闪光仍可辨认，而不是机械缩放后依赖亚像素细节。

### 菜单栏图标

菜单栏图标只保留显示器轮廓、底座和单个闪光，以 18×18 pt 视觉区域设计。资源标记为 template image，由 macOS 根据菜单栏状态自动着色；不得在资源中固定蓝紫色，也不得自行判断系统外观。

菜单栏图形与应用图标共享构图，但采用更少节点、更粗的有效笔画和更大的负空间。选中、高亮、深色和浅色状态均交给系统模板渲染。

## 资源与生成流程

项目保存图标母版和一个仅依赖 macOS 系统框架的生成脚本。生成脚本根据同一组几何与颜色参数输出：

- `ScreenClear.iconset/icon_16x16.png`；
- `icon_16x16@2x.png`；
- `icon_32x32.png`；
- `icon_32x32@2x.png`；
- `icon_128x128.png`；
- `icon_128x128@2x.png`；
- `icon_256x256.png`；
- `icon_256x256@2x.png`；
- `icon_512x512.png`；
- `icon_512x512@2x.png`；
- 由 `iconutil` 打包得到的 `ScreenClear.icns`；
- 菜单栏模板资源。

生成过程必须在唯一临时目录工作，先验证所有尺寸、格式和非空内容，再将资源复制到暂存 `.app`。临时目录清理沿用项目现有的精确路径边界与失败保护，不在源码目录留下半成品。

## 应用集成

`make-app.sh` 在构建暂存应用时创建 `Contents/Resources`，生成并复制 `ScreenClear.icns` 与菜单栏模板资源。`Info.plist` 增加 `CFBundleIconFile`，值指向 `ScreenClear`（允许系统解析 `.icns` 扩展名）。签名在资源复制和 plist 校验全部完成后执行，确保资源包含在 bundle 签名中。

`ScreenClearApp` 将当前 `systemImage: "display"` 入口替换为自定义标签。运行时从主 bundle 的 `Contents/Resources` 加载菜单栏资源并设置模板属性。若资源缺失、不可解码或尺寸无效，则回退到现有 SF Symbol `display`，保证菜单入口不会消失，也不会阻止应用启动。

裸 `swift run` 或测试环境没有应用 bundle 资源时也使用同一回退路径，因此开发构建不要求先组装 `.app`。

## 错误处理与安全

- 任一必须尺寸生成失败时，打包立即失败，不发布半成品 App 或 ZIP；
- `iconutil` 失败时保留现有已发布产物，复用当前发布事务回滚；
- 资源路径必须是普通文件，不接受符号链接或目录替代；
- `plutil`、图像尺寸检查和资源加载检查必须在签名前完成；
- 安装校验除可执行文件外还必须验证应用图标键与资源哈希/存在性；
- 添加图标不得触发管理员授权，也不得修改 `/Library/Displays`、LaunchAgent 或当前显示模式。

## 测试设计

自动验证至少覆盖：

1. 生成脚本输出全部十个标准 iconset 文件，像素尺寸与文件名匹配；
2. `iconutil` 能生成非空、可识别的 `ScreenClear.icns`；
3. 菜单栏资源存在、可由 `NSImage` 解码并设置为模板图；
4. 资源缺失时菜单栏加载逻辑返回 `display` 回退，不崩溃；
5. 打包后的 `Info.plist` 包含正确 `CFBundleIconFile`；
6. App 与 ZIP 都含相同的图标资源，且无意外符号链接或 AppleDouble 元数据；
7. 资源参与 ad-hoc 签名，`codesign --verify --deep --strict` 通过；
8. 安装后的图标文件与打包产物一致，应用仍从精确安装路径启动；
9. 完整 `swift test`、Debug/Release 构建及现有打包事务测试全部通过。

人工验收检查 Finder 中的应用图标、浅色/深色菜单栏中的模板图标，以及高亮状态下的清晰度。若 Launch Services 或 Finder 暂存旧图标，可重新启动 Finder/应用或等待缓存刷新；不得通过删除用户级全局缓存来强制刷新。

## 验收标准

- `/Applications/ScreenClear.app` 在 Finder 中显示 A 款蓝紫应用图标；
- 菜单栏显示“显示器 + 闪光”模板图标，并随系统外观正确着色；
- 小尺寸图标保持显示器与闪光可辨认，无文字或糊成一团的细节；
- 菜单栏资源异常时仍显示原 `display` 图标，应用可继续使用；
- App、ZIP、安装副本的图标资源一致，签名与全部自动门禁通过；
- 安装图标版本不会自动更新或写入 HiDPI override；该管理员操作继续保持为独立、用户触发的待办。
