# sync-engine —— macOS 原生数据同步工具

SwiftUI 界面 + Swift 引擎，单一语言、单一构建链、无第三方依赖。

当前做到**真实的目录扫描与内容哈希**（并发 SHA-256）；传输部分尚未实现
（P1 的 Reconciler 与 Transfer 还没写），界面上对此有明确标注。

---

## 快速开始

```bash
cd SyncApp

swift build                 # 构建
swift test                  # 单元测试（76 项：引擎 14 / 存储 29 / WebDAV 22 / SMB 11）
bash Scripts/build_app.sh   # 打包成 dist/sync-engine.app
open dist/sync-engine.app   # 运行
```

打发行版安装包（版本号从 build_app.sh 的 APP_VERSION 读取）：

```bash
bash Scripts/make_dmg.sh 1.0.0 arm64     # → dist/sync-engine-v1.0.0-arm64.dmg
bash Scripts/make_dmg.sh 1.0.0 x86_64    # → dist/sync-engine-v1.0.0-x86_64.dmg
```

无界面验证（**对打包产物本身**，覆盖真实交付路径）：

```bash
dist/sync-engine.app/Contents/MacOS/sync-engine --selfcheck [目录]
dist/sync-engine.app/Contents/MacOS/sync-engine --bench <目录> [并发数]
```

---

## 界面

`NavigationSplitView` 三段式，与方案文档的功能分区一致：

| 分区 | 内容 |
|---|---|
| **同步任务** | 任务列表、新建/编辑任务、预览扫描、文件条目明细、**目标端连接测试与列表** |
| **同步日志** | 引擎与界面动作的实时日志，可按级别筛选 |
| **设置** | 外观、关闭窗口行为、引擎信息与自检、扫描参数、存储连接 |

其它：

- **菜单栏常驻项** —— 关闭主窗口后仍可查看状态并唤回窗口
- **右上角外观切换按钮** —— 浅色/深色一键切换
- **外观三态（跟随系统 / 浅色 / 深色）** —— **「跟随系统」也解析成具体外观，不给 `nil`**。
  给 `nil` 会让"运行中切到跟随系统"时详情列变成空白深色并永久停留（详见"故障排查"）；
  代价是系统日落切换不再自动生效，因此额外订阅了
  `AppleInterfaceThemeChangedNotification` 重新解析。
  界面颜色一律取自 `AppModel.effectiveColorScheme`，不读 `\.colorScheme` 环境值
- **关闭主窗口行为可选** —— 退出软件 / 最小化到菜单栏（设置页）
- **编辑图标** —— 15pt 且带独立点击热区（只放大图标不放大热区是没用的，手感不变）
- **侧栏字号 15pt、行距 40pt** —— 字号与图标尺寸集中在 `RootView.sidebarFontSize` /
  `sidebarIconSize` 两个常量里；只放大字号而不给 `padding` 会让行与行贴得更紧。
  实测字形高度 13.0 → 15.5pt、条目行距 32.5 → 40.0pt。
  注意**侧栏列宽会被持久化**（`NSSplitView Subview Frames …` 写进应用偏好），
  存过之后 `navigationSplitViewColumnWidth` 的 `ideal` 不再生效 ——
  字号调大后要放宽列宽时得一并清掉那个偏好键
- **强调色按明暗分开取值** —— 浅色 `#22A322`（品牌绿深一档，白底 3.3:1）、
  深色 `#32CD32`（品牌色本身，深底 7.9:1）。品牌色本身在浅色下只有 2.12:1，
  作为小字号文字偏低。**应用图标底色始终是 `#32CD32`**（`Scripts/make_icon.swift`），
  不随界面强调色变化 —— 图标是品牌标识，界面强调色要受可读性约束
- **警告色为琥珀 `#B86B08`** —— 不与强调色同色系，且与错误的红色可区分
- **窗口与应用标题统一为 `sync-engine`** —— 四处同源：`WindowGroup` 标题、`.navigationTitle`、
  `MenuBarExtra` 标题、`Info.plist` 的 `CFBundleName`/`CFBundleDisplayName`
- **启动时不播种任何示例任务**，任务列表从空开始；自检里有一条断言守着这件事

**没有常驻的引擎状态条**（曾经有一条显示"引擎版本 · 构建配置 · 哈希并发"）。
移除后引擎加载失败的可见性下降：界面能开、但操作会失败。这条信息现在只在两处出现 ——
设置页的「引擎」区块（含完整自检结果）与同步日志。若将来想"出问题才提示"，
正确做法是**仅在 `engineError != nil` 时**插入一条警告条，而不是恢复常驻条。

### 目标端存储（SMB / WebDAV）

三种目标端都可用，都不依赖第三方库。任务编辑器按类型切换字段，
并有一个**真实连接**的「测试连接」按钮（SMB 会真的去挂载，WebDAV 会真的发 PROPFIND）。

| 类型 | 输入 | 实现路线 |
|---|---|---|
| 本地目录 | 路径 + 选择器 | `FileManager`，含路径逃逸防护 |
| SMB | `smb://主机/共享` + 账号 + 子目录 | 经系统 **NetFS** 挂载，之后当本地目录读写 |
| WebDAV | `http(s)://主机/路径` + 账号 + 子目录 + 自签名证书开关 | `URLSession` 直发 `PROPFIND/PUT/MKCOL/DELETE`，自写 multistatus 解析 |

凭据（用户名/密码）存在**系统钥匙串**，任务配置里只留用户名。密码框不回填，
留空表示"不改"，另有显式的「清除已保存的密码」。

**注意：这是"连接与读写原语"，不等于"能同步"。** 目前具备探测、列目录、建目录、
单个文件上传/下载、删除；**三方比对、增量判定、冲突裁决、断点续传尚未实现**（P1）。

---

## 结构

```
SyncApp/                          SwiftPM 包
├── Sources/
│   ├── CNetFS/                     NetFS 的系统库封装（C 框架 → Swift）
│   │   └── module.modulemap        link framework "NetFS"
│   ├── SyncEngine/                 引擎（纯逻辑，**不 import SwiftUI**）
│   │   ├── EngineModels.swift      数据模型、选项、错误、格式化
│   │   ├── ContentHasher.swift     CryptoKit SHA-256 流式哈希
│   │   ├── SyncEngine.swift        遍历 + 并发哈希 + 单调时钟
│   │   └── Storage/                 目标端存储
│   │       ├── StorageModels.swift            种类、地址规范化、驱动协议、工厂
│   │       ├── LocalFileDriver.swift          本地文件系统（SMB 挂载后复用）
│   │       ├── SMBDriver.swift                NetFS 挂载 + 挂载协调 actor
│   │       ├── NetworkVolume.swift            NetFS 调用与错误码翻译
│   │       ├── WebDAVDriver.swift             URLSession + 认证
│   │       ├── WebDAVMultiStatusParser.swift  multistatus XML 解析
│   │       └── CredentialStore.swift          钥匙串
│   └── SyncApp/                    界面与入口
│       ├── SyncAppMain.swift       @main、AppDelegate、菜单栏
│       ├── State/                  AppModel、领域模型
│       ├── Support/                外观、强调色、关闭拦截、无界面运行器
│       │   ├── Appearance.swift                 模式、配色令牌、AppKit 应用器
│       │   ├── AppearanceTransitionProbe.swift  切换外观的复现钩子（诊断用）
│       │   ├── AppAccent.swift                  强调色的环境通道
│       │   └── CloseInterceptor.swift           关闭行为拦截
│       └── Views/                  三个功能页
├── Tests/SyncEngineTests/
│   ├── EngineTests.swift           引擎
│   ├── StorageTests.swift          地址解析、本地驱动、钥匙串
│   ├── WebDAVDriverTests.swift     真实 HTTP 往返
│   ├── MiniWebDAVServer.swift      进程内的测试服务端
│   └── SMBDriverTests.swift        真实挂载点的只读验证
├── Scripts/
│   ├── build_app.sh                组装 .app（图标 + Info.plist + 签名）
│   ├── make_dmg.sh                 打成发行版 DMG（版本号取自 build_app.sh）
│   ├── make_icon.swift             AppKit 绘制图标
│   ├── window_probe.swift          取窗口编号与标题（供精确截图）
│   ├── verify_appearance.sh        外观状态矩阵验证（静态 × 3 + 切换 × 3）
│   └── probe_close/main.swift      关闭行为探针
└── dist/                           打包产物（不入库）
```

**分两个 target 是可验证性的基础**：SwiftPM 的依赖关系会在编译期强制
"引擎层不得引入 SwiftUI"。一旦有人误 import，编译就失败 ——
而不是悄悄破坏了"引擎可被无界面测试直接驱动"这个性质。

---

## 为什么用 SwiftPM 而不是 Xcode 工程

| | SwiftPM（采用） | Xcode 工程 |
|---|---|---|
| 工程文件 | **纯文本，可 diff** | `.pbxproj`，冲突难解、手工编辑易错 |
| 命令行构建 | `swift build` | `xcodebuild` + scheme |
| 目录结构 | 约定优于配置 | 显式维护 |
| 资源束 | 需手工组装 | 原生支持 |

界面只用 SwiftUI（无 xib/storyboard），资源只有图标与 Info.plist，
两者都能在打包脚本里生成 —— Xcode 工程的唯一优势在此不成立。

> 若将来上架 Mac App Store 需要 Xcode 工程，SwiftPM 包可被 Xcode 直接打开，
> 或用一个薄 Xcode 工程引用本包。现在不必为此付出 `.pbxproj` 的维护成本。

---

## 引擎设计要点

### 两个阶段，分开计时

| 阶段 | 瓶颈 | 优化方向 |
|---|---|---|
| 遍历 + stat | 文件**数量** | 减少系统调用 |
| 内容哈希 | 字节数 + 每文件一次 open/close 的固定开销 | **并发** |

耗时分开统计而不是只给一个总数，是为了让性能问题能被归因。

### 实测性能（6.3 GB / 91,743 文件）

| 并发度 | 哈希耗时 | 吞吐 |
|---|---|---|
| 1 | 22.66 s | 283 MB/s |
| 4 | 8.03 s | 799 MB/s |
| 10 | 5.45 s | **1179 MB/s** |

**10 核的加速比只有 4.2 倍，不是线性** —— 说明存在磁盘 IO 与文件系统
元数据锁的竞争。继续加并发收益会迅速衰减，下一步该做的是**哈希缓存**
（跳过未变化文件），而不是继续调并发度。

### 并发哈希用滑动窗口而非分批

「完成一个就补一个」而不是「每批等齐」：分批会在每批末尾等最慢的那个，
而同步场景里文件大小分布极不均匀（一堆小文件夹着几个大文件），
尾效应会显著拖慢整体。

### 几个刻意的选择

- **软链接一律不跟随。** 跟随会导致目录环使遍历不终止；同一份内容被多次计入
  使"总大小"失真。判断顺序必须是**先判 `isSymbolicLink` 再判 `isDirectory`** ——
  `isDirectory` 会跟随链接，顺序写反就会把链接目录当作真实目录展开。
- **`maxEntries` 只限展示条目，统计与哈希始终覆盖全部文件。** 否则性能基线
  量到的会是"扫前 N 个"的耗时，毫无意义。
- **单调时钟而非 `Date()`。** `Date` 取自墙上时钟，会被 NTP 校时影响，
  在这些数字要当性能基线用时不能有这种不确定性。
- **引擎层不吞错误。** 权限不足等记入 `readErrors` 继续扫描 ——
  用户目录里总有扫不动的地方，中断整次扫描毫无帮助。

---

## 验证策略

分层，且**不依赖肉眼**：

| 层 | 手段 | 覆盖 |
|---|---|---|
| 引擎逻辑 | `swift test`（76 项） | 哈希向量、分块一致性、扫描统计、软链策略、计时不变量、错误路径 |
| 存储驱动 | `swift test`（同上，含真实 IO） | **对进程内真实 WebDAV 服务端的完整往返**；对**真实 SMB 挂载**的只读验证 |
| 打包产物 | `--selfcheck`（16 项） | **真实交付的二进制**能否跑通引擎与存储驱动接线 |
| 关闭行为 | `Scripts/probe_close`（10 项） | 真实源码编译的探针 |
| **外观状态** | `Scripts/verify_appearance.sh`（6 个场景） | 3 种模式静态启动 + 3 个方向的**运行中切换**，断言三处主题一致且详情区非空 |
| 界面渲染 | 单窗口截图 + 像素分析 | 主题、强调色是否统一、图标实际尺寸、内容对齐 |

### 只在某个操作路径上出现的缺陷，必须把那路径本身做成可复现的

「跟随系统显示错乱」拖到用户报出来才发现，根因在方法：此前每轮都只验**静态启动**
（以某模式启动 → 截图），而故障**只在运行中切换**时出现，静态那条路完全正常。

补上的办法是 `--appearance-transition-test [模式]` 这个诊断钩子：它直接调
`AppModel.setAppearance` —— 与设置页点选**同一个入口**，不复制逻辑。
本机辅助功能权限被拒（UI 脚本报 -10004），没法真去点那个 Picker，
钩子是唯一能让这条路径可复现的方式。

它把日志写进文件而不是 stdout：GUI 应用被 `open` 启动时 stdout 不可捕获，
而直接执行二进制虽然能捕获、窗口却**不一定出现**。

### 截图前必须先断言状态

界面层的一切结论都由截图得出，所以**截图前的状态断言是流程的一部分，不是事后分析**。
当前脚本会先判定三件事，全部通过才采用该图：

1. 主题确实是目标主题（整窗平均亮度）
2. 侧栏选中项是「同步任务」（行背景填充与其它行不同；**判据极性随主题反转** ——
   浅色下选中行更暗、深色下更亮，同一套判据会在深色下选错行）
3. 详情区确实是任务页（日志页的 `INFO` 徽标位没有绿色像素）

不这么做的代价已经付过：曾经用"有没有 34×16 的外观色块"当页面指纹，
它只能区分出设置页，把任务页与日志页混为一谈 —— 于是"每次启动都落在同一页"这个
结论其实是错的（见"故障排查"里的启动页一条）。
**指纹要取自该页独有的特征，不能取自多页共有的特征。**

另外，判"内容画出来了没有"要看**详情区的墨迹量**，不能只看底色 ——
修复前那个故障帧的底色是"深"，看起来像正常的深色主题，其实什么都没画。

还有一条：**对照图必须同为活动窗口**。窗口失焦时按钮文案由强调色变灰并出现边框、
标签文字整体变浅、红绿灯变灰 —— 跨这两种状态比较会产生大量幽灵差异。

### 存储驱动为什么要起一个真服务端

驱动层有两条验证路线：把 `URLSession` 换成 mock 去断言"我发了什么请求"，
或者真的起一个服务端走一遍 HTTP。**前者只能在"我以为的协议"上验证**，
而协议细节（尾斜杠、207 与 propstat 分组、href 的百分号编码、认证往返）
恰恰是最容易想错的地方。

所以测试里用 `Network` 框架起了一个真实的 WebDAV 服务端（真实磁盘做后端），
不需要第三方依赖、不需要外网。它刻意用 `D:`（大写）作 XML 前缀、把集合做成 `/dav` 子路径、
要求 Basic 认证 —— 每一条都在针对一个具体的失配可能。

SMB 同理：测试跑在**本机真实的 NAS 挂载点**上，而不是假设出来的路径。
没有 SMB 挂载的机器上这些用例会 `XCTSkip` 跳过，而不是失败 ——
它们依赖环境，不该让别的机器变红。

**但写入没有对用户的 NAS 执行。** 那会在真实共享里写文件；改为提供一条由
环境变量显式开启的集成用例（见 `SMBDriverTests` 末尾），写入路径本身由
`LocalFileDriver` 的测试覆盖 —— SMB 挂载后走的正是同一条代码路径。

### 断言要验结构性不变量

`testTimingComponentsNeverExceedElapsed` 断言"分项耗时之和 ≤ 总耗时"——
这是**任何情况下都必须成立**的结构性约束，不随机器快慢变化，因此不会变成
flaky 测试。而"遍历耗时应该小于 500 ms"这类断言会随机失败。

这条测试抓到过真问题：早期在遍历循环里反复累加累计时长，
把 37 秒的总耗时记成了「30 分 35 秒遍历」。

### 无界面模式

同一个二进制既能双击运行，又能被脚本驱动：

```bash
sync-engine --selfcheck    # 自检
sync-engine --bench <目录> [并发数]   # 性能基准
```

**新增无界面模式时必须加到 `SyncAppEntry.headlessFlags`。**
判断若散落在多处很容易漏改，而漏改的表现是「GUI 悄悄启动了、
命令行一直不返回」—— 因为窗口开在那里等用户操作。这个症状极具误导性。

**绝对不要用 `dispatchMain()` 驱动无界面模式。** 实测：`@MainActor` 函数体内
甚至 `MainActor.run { }` 内部，`Thread.isMainThread` **恒为 false**，
任何 `NSWindow` 创建都会抛异常，而用 `DispatchQueue.main.sync` 补救会**彻底死锁**。
正确做法是自己泵主 RunLoop。

---

## 已知限制

- **无持久化**。任务列表、设置（外观与关闭行为除外）、日志都在内存里，退出即丢。
- **无同步能力**。目标端的连接与读写原语已具备（探测/列目录/建目录/传单文件/删除），
  但**没有三方比对、增量判定、冲突裁决、断点续传** —— 这些全在 P1。
  界面上不把"能连上"说成"能同步"。
- **不做增量**。每次扫描都是全量重算哈希。
- **扫描期间不能取消**。十万文件级要等它跑完。
- **网络卷未自动降并发**。哈希并发默认取 CPU 核心数，而这对网络卷是错的
  （并发读写会让网络往返互相竞争）。目前只在探测结果里提示，尚未自动调整。
- **SMB 挂载后不自动卸载**。断开的时机与卸载策略未设计。
- **日志不落盘**。与方案文档的日志体系设计（分级 + 轮转 + `os.Logger`）还有距离。
- **单窗口**。`CloseInterceptor` 目前是按单窗口设计的。

---

## 分发的现实

`Scripts/build_app.sh` 用的是 **ad-hoc 签名**（`codesign --sign -`），
只能保证本机运行。产物经网络传输后会带上 quarantine 属性，**Gatekeeper 会直接拦下**。

**这不是 bug，也无法靠重新签名绕过** —— 需要开发者证书签名 + 公证。
详见技术方案第 10 节。

因此从 [Releases](https://github.com/zdx8/SyncEngine-macOS/releases) 下载的安装包
首次打开会被拦下，用户需手动放行：把 `sync-engine.app` 拖进「应用程序」后，
**右键 → 打开**，或到「系统设置 → 隐私与安全性」点「仍要打开」。
（一次即可，之后正常双击启动。）

---

## 故障排查

**命令行不返回、Dock 里冒出图标**
→ 无界面参数没加进 `SyncAppEntry.headlessFlags`，落到了启动 GUI 的分支。

**改了图标但访达/Dock 还显示旧的**
→ 图标缓存以 `CFBundleVersion` 为键。打包脚本已用时间戳版本号并调用
`lsregister -f`，若仍不生效，手动 `killall Dock`。

**`swift build` 报 manifest 沙箱错误**
→ 当前 shell 本身被沙箱隔离时，嵌套沙箱会失败。加 `--disable-sandbox`。

**脚本报 `VAR: unbound variable` 且变量名带乱码**
→ macOS 自带 bash 3.2 不识别 UTF-8，`$VAR（` 会把全角字节并进变量名。
规则：变量引用紧跟非 ASCII 字符时一律写 `${VAR}`。
自查：`grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' Scripts/*.sh`

**改了图标颜色但图标没变**
→ 三层缓存，缺一层就会"改了没生效"：
1. `Resources/AppIcon.icns` 是**生成物**。打包脚本按 `make_icon.swift` 的时间戳判断
   是否重出（早期只判"文件在不在"，改品牌色不会重出）。
2. 系统按 `CFBundleVersion` 缓存图标，打包脚本已用时间戳版本号 + `lsregister -f`。
3. 仍不生效就 `killall Dock`。

**每次打开都落在不同的页面**
→ 侧栏的选中项会被恢复、或被 AppKit 侧推回绑定，与我们启动时的赋值**竞速**。
修法：`RootView` 的 `.task` 里**设两次**（第二次留 300ms 让侧栏先安定），
并关掉窗口状态恢复（`isRestorable = false`）。只设一次不够 ——
实测确实出现过落在「同步日志」页。这条同时是**验证问题**：截图不可复现等于没有验证。

**页头浮在窗口正中间**
→ `.frame(maxWidth: .infinity, maxHeight: .infinity)` 的默认对齐是 `.center`。
配合"内容高度是固有的"（`ContentUnavailableView` 不会撑满可用空间），
整个页面就被垂直居中了。加 `alignment: .top`。
判据：内容区最上一行墨迹的 y 值（居中时 ≈300，顶部对齐后 ≈69）。

**侧栏图标在深色下颜色不对（浅色看着正常）**
→ 侧栏那一列**拿不到** `.environment(\.appAccent, …)` 注入的值（它由 AppKit 的分栏控制器承载），
于是退回 `AppAccentKey.defaultValue`（浅色强调色）。结果：深色下侧栏图标是深绿 `#22A321`、
而同一窗口里其它强调色元素是品牌绿 `#32CD32`。**浅色下完全正确，只看浅色发现不了。**
修法：侧栏里按当前明暗直接算 `Palette.accent(for: colorScheme)`，不走环境注入。
判据：分别取"侧栏图标"与"详情区强调色元素"的像素众数，要求同主题下一致、且随主题变化。

**自检报"钥匙串写入失败（Operation not permitted）"**
→ 多半是在受限/沙箱化的执行上下文里跑的（例如绕过沙箱的提权执行）。
换普通终端会话重跑即通过；代码本身没问题。

**切到「跟随系统」后界面错乱（详情区变一块空白深色）**
→ 「跟随系统」曾经被解析成 `nil`（"交给系统决定"）。从浅色切到跟随系统、系统为深色时，
SwiftUI 的详情列会变成空白深色并**永久停留**：标题栏浅、侧栏中、详情深、强调色还是浅色档，
四处互相矛盾。静态启动正常，所以只在切换时暴露。
修法：`nil` 这个中间态不用 —— 把「跟随系统」解析成系统当前的具体外观，
切换退化成普通的「浅色 → 深色」。代价是系统日落切换不再自动生效，
因此额外订阅 `AppleInterfaceThemeChangedNotification` 重新解析。
回归手段：`bash Scripts/verify_appearance.sh`（6 个场景的矩阵）。

**深色模式下观感割裂（深标题栏 + 浅内容）**
→ 检查 `NSApp.appearance` 与 `.preferredColorScheme` 是否都设了。只设一处不会报错。

**判断"二进制里是不是新代码"时被 `strings` / `grep` 骗过**
→ macOS 的 `strings` 默认只输出 ASCII，**中文会被丢弃**；`grep` 匹配中文同样不可靠
（实测同一份二进制里 ASCII 模式能匹配、中文模式恒为 0）。
用 **ASCII 哨兵**代替，并同时核对文件时间戳：

```bash
grep -ac 'AppleInterfaceStyle' dist/sync-engine.app/Contents/MacOS/sync-engine   # 应为 1
ls -lT dist/sync-engine.app/Contents/MacOS/sync-engine                           # 时间应是刚才
```

**改了源码但 `swift build` 报 `Build complete! (0.19s)` 且没编译**
→ 遇到过构建数据库不认时间戳的情况（源文件已是新内容，构建却判定"无事可做"）。
先用上面的哨兵确认产物是否真的更新；不更新就重建
（换构建路径如 `--scratch-path` 最稳，或先 `swift build -c release` 再打包）。

**界面上同时出现自定义强调色与系统蓝**
→ 某处用了 `Color.accentColor`。它解析的是**系统强调色、无视 `.tint()`**，所以不会跟着
我们的强调色走。一律改用注入的 `appAccent` 环境值（见 `Support/AppAccent.swift`）。
自查：`grep -rn 'accentColor' Sources/SyncApp/`（只剩注释即正常）。
侧栏条目要额外注意：`List` 会用系统强调色渲染 `Label` 的图标，`.tint()` 管不到，
必须拆成图标 + 文字显式着色。`.buttonStyle(.link)` 同样写死了系统链接蓝。

**同一个界面里出现两种深浅不同的强调色**
→ 有一处**没拿到**注入的环境值、退回了默认值。最典型的是
`NavigationSplitView` 的侧栏那一列（见上一条"侧栏图标在深色下颜色不对"）。
**验证手段：取"异色像素"的思路同样适用** —— 逐区域统计强调色像素的精确众数，
不同区域给出的众数不一致就是它。

**`Color(srgb:)` 编译不过**
→ SwiftUI 的写法是 `Color(.sRGB, red:green:blue:opacity:)`。

**扫描一个目录返回"成功但 0 个文件"**
→ 根目录是个软链。Foundation 的 URL 版目录枚举**不跟随末端软链**
（对指向目录的软链抛 `NSFileReadUnknownError(256)`，而 `opendir(3)` 对同一路径正常）。
引擎已在 `scan` / `LocalFileDriver` 里解开软链，但若新增别处的遍历代码要记得同样处理。

**新增遍历代码后 `relativePath` 变成绝对路径**
→ 比较前缀时两侧口径不一致。macOS 上"解析软链"有两套：
`resolvingSymlinksInPath()` 保留 `/var` 前缀（Foundation 历史行为），
而 `contentsOfDirectory` 内部用真正的 realpath 返回 `/private/var/...`。
两侧都过一遍 `standardizedFileURL` 再比。

**`library 'NetFS' not found`**
→ module map 里写了 `link "NetFS"`。NetFS 是 framework 不是 dylib，
必须写 `link framework "NetFS"`。

**SMB 测试或者连接时进程卡住不返回**
→ 用了 `NetFSMountURLSync`。它实测会一直阻塞且无超时，还会拉起认证代理。
必须用 `NetFSMountURLAsync` + `NetFSMountURLCancel`，并把 `kNAUIOptionNoUI` 设上
（不设的话缺凭据时会弹系统对话框，后台任务等于永久挂起）。

**SMB 上传失败**
→ `replaceItemAt` 底层的 `renamex_np(RENAME_SWAP)` 在 smbfs 上未必支持。
`LocalFileDriver.upload` 已做降级（删旧再改名），若在别处新增写入逻辑要记得同样处理。

**WebDAV 列表里文件大小全是 0**
→ multistatus 解析时把失败 `propstat` 的空值覆盖了成功分支的真实值。
`<status>` 出现在 `<prop>` **之后**，必须先把一个 propstat 的属性攒起来、读到 status 再合并。

**WebDAV 服务端用 `D:` 前缀或默认命名空间时列表为空**
→ 解析器按拼接后的限定名匹配了。要开 `shouldProcessNamespaces`，
按 `namespaceURI + 局部名` 判断。

**WebDAV 连不上且报"传输安全策略"**
→ Info.plist 缺 `NSAppTransportSecurity`。明文 http 需要放行（理由与取舍见方案 7.2）。
