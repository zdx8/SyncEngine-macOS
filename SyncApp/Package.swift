// swift-tools-version: 5.9
//
// sync-engine —— macOS 原生数据同步工具
//
// 刻意分成两个 target：
//   SyncEngine —— 纯逻辑引擎，**不依赖任何界面框架**
//   SyncApp    —— SwiftUI 界面与入口
//
// 这个分层不是洁癖，而是可验证性的基础：
// SwiftPM 的 target 依赖关系会在编译期强制「引擎层不得引入 SwiftUI」，
// 从而保证引擎能被 swift test 与无界面自检直接驱动。
// 一旦有人误在引擎里 import SwiftUI，编译就会失败，而不是悄悄破坏了这个性质。
//
// 依赖策略：只用系统框架，不引入任何第三方 Swift 包。理由见技术方案 2.3。

import PackageDescription

let package = Package(
    name: "SyncEngine",
    platforms: [
        // macOS 14 是 Observation 框架（@Observable）与 NavigationSplitView
        // 稳定可用的下限。抬高这个值会缩小可安装范围，非必要不抬。
        .macOS(.v14)
    ],
    products: [
        // 说明：SwiftPM 产出的**可执行文件名取自 target 名**，product 名只是个别名
        //（实测 `.executable(name: "sync-engine", targets: ["SyncApp"])` 仍然产出
        // `SyncApp`）。而 target 名会变成 Swift 模块名，若改成 `sync-engine`
        // 就得到模块 `sync_engine` —— 与下面的库模块 `SyncEngine` 只差大小写，
        // 在编译错误里极易看错，代价比收益大。
        //
        // 所以用户可见的程序名 `sync-engine` 由 `Scripts/build_app.sh` 在组装
        // .app 时赋予（bundle 名与 bundle 内可执行文件名同为一个值）。
        .executable(name: "SyncApp", targets: ["SyncApp"]),
        .library(name: "SyncEngine", targets: ["SyncEngine"]),
    ],
    targets: [
        // NetFS 是 C 框架，SDK 里只有头文件、没有 Swift 模块，无法直接 import。
        // 用一个 systemLibrary 目标把 module map 提供给 Swift：
        // 这是 SwiftPM 支持的官方途径，比手写 bridging header 或 dlopen 都干净。
        .systemLibrary(
            name: "CNetFS",
            path: "Sources/CNetFS"
        ),
        .target(
            name: "SyncEngine",
            dependencies: ["CNetFS"],
            path: "Sources/SyncEngine"
        ),
        .executableTarget(
            name: "SyncApp",
            dependencies: ["SyncEngine"],
            path: "Sources/SyncApp",
            swiftSettings: [
                // GUI 可执行目标必须加 -parse-as-library，
                // 否则 @main 会与顶层代码判定冲突而编译失败。
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "SyncEngineTests",
            dependencies: ["SyncEngine"],
            path: "Tests/SyncEngineTests"
        ),
    ]
)
