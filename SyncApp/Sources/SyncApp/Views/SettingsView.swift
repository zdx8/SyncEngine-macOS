import SwiftUI
import SyncEngine

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AppearanceSection()
                WindowSection()
                EngineSection()
                ScanSettingsSection()
                StorageSection()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
    }
}

// ────────────────────────────────────────────────────── 外观 --

private struct AppearanceSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SectionBox(
            title: "外观",
            subtitle: "右上角的切换按钮可在浅色与深色间快速切换；"
                + "想恢复跟随系统（如日落到日出自动切换），在这里选择。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("外观模式", selection: Binding(
                    get: { model.appearanceMode },
                    set: { model.setAppearance($0) }
                )) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 20) {
                    Text("强调色")
                        .font(.system(size: 12))
                    HStack(spacing: 7) {
                        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Palette.accent(for: scheme))
                                .frame(width: 34, height: 16)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(Color(nsColor: .separatorColor),
                                                      lineWidth: 0.5)
                                )
                                .help(scheme == .dark
                                      ? "深色模式下的强调色（品牌绿 #32CD32）"
                                      : "浅色模式下的强调色（深绿 #22A322）")
                        }
                    }
                    Text("淡橙。浅色模式下用偏深的橙（约 3.1:1 对比度）、"
                        + "深色模式下用更亮的橙 —— 单一色值必然在某种模式下对比度不足。"
                        + "注意：警告色因此改用红色，不再用橙色，否则两者无法区分。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                Text("当前生效：\(colorScheme == .dark ? "深色" : "浅色")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// ──────────────────────────────────────────────── 关闭窗口行为 --

private struct WindowSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SectionBox(
            title: "关闭主窗口时",
            subtitle: "决定点窗口左上角关闭按钮后的行为。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("关闭主窗口时", selection: Binding(
                    get: { model.closeBehavior },
                    set: { model.setCloseBehavior($0) }
                )) {
                    ForEach(CloseBehavior.allCases) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(model.closeBehavior.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.closeBehavior == .minimizeToMenuBar {
                    Label("应用会驻留在菜单栏，可从菜单栏重新打开主窗口或退出。",
                          systemImage: "menubar.rectangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SectionBox<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
                .padding(.bottom, 9)
            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
    }
}

// ────────────────────────────────────────────────────── 引擎 --

private struct EngineSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appAccent) private var accent

    var body: some View {
        SectionBox(
            title: "引擎",
            subtitle: "同步引擎与界面同进程、同语言，之间没有 FFI 边界。"
                + "下面这些信息由引擎自身回读，用于确认它确实可用。"
        ) {
            VStack(alignment: .leading, spacing: 13) {
                if let error = model.engineError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                } else if let info = model.engineInfo {
                    HStack(alignment: .top, spacing: 28) {
                        Metric("版本", info.version)
                        Metric("构建配置", info.buildConfig)
                        Metric("哈希算法", info.hashAlgorithm)
                        Metric("哈希并发", "\(info.hashConcurrency)")
                        Spacer(minLength: 0)
                    }
                    Text(info.platform)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("正在探测…").foregroundStyle(.secondary)
                }

                Divider()

                HStack(alignment: .top, spacing: 12) {
                    Button {
                        Task { await model.runSelfCheck() }
                    } label: {
                        Label("运行自检", systemImage: "checkmark.seal")
                    }
                    .disabled(model.engineInfo == nil)

                    Text("用 SHA-256 官方测试向量与流式分块一致性做判据，"
                        + "一次覆盖「哈希实现 + 文件分块读取 + 异步调用」整条路径。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let report = model.selfCheck {
                    Divider()
                    if let failure = report.errorMessage {
                        Text("自检异常：\(failure)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.red)
                    }
                    ForEach(report.items) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.passed
                                  ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(item.passed ? accent : Palette.warning)
                            Text(item.label)
                                .font(.system(size: 11.5))
                                .frame(width: 210, alignment: .leading)
                            Text(item.detail)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }
}

// ────────────────────────────────────────────────── 扫描参数 --

private struct ScanSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        return SectionBox(
            title: "扫描参数",
            subtitle: "决定预览扫描的行为。哈希开关对耗时影响极大 —— 关闭后只做目录遍历与 stat。"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $model.computeHash) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("计算内容哈希").font(.system(size: 12.5))
                        Text("正式同步时必须开启：外接盘可能是 FAT/exFAT（mtime 精度 2 秒），"
                            + "时钟也可能漂移，变更仲裁只能依赖内容哈希。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("文件列表条目上限").font(.system(size: 12.5))
                        Spacer()
                        Text("\(model.maxEntries)")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(model.maxEntries) },
                            set: { model.maxEntries = Int($0) }
                        ),
                        in: 50...2000,
                        step: 50
                    )
                    Text("只影响界面上列出的条目数。**统计与哈希始终覆盖全部文件** —— "
                        + "否则量到的会是「扫前 N 个」的耗时，性能基线就失去意义了。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// ────────────────────────────────────────────────── 存储连接 --

/// 存储连接。
///
/// 三种目标端都已接入。这里不列"已实现/未实现"，而是写清**各自的实现路线**：
/// 用户最需要知道的不是"能不能用"，而是"它是怎么连上去的"——
/// 这决定了他遇到问题该去哪里排查（系统挂载 vs 服务端配置）。
private struct StorageSection: View {
    @Environment(\.appAccent) private var accent

    var body: some View {
        SectionBox(
            title: "存储连接",
            subtitle: "三种目标端都已接入，且都不依赖任何第三方库 —— "
                + "用的是 macOS 自带的系统能力。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(StorageKind.allCases) { kind in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(accent)
                            Text(kind.label)
                                .font(.system(size: 12, weight: .medium))
                            Spacer(minLength: 0)
                        }
                        Text(kind.capabilitySummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 20)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Label("凭据保存在系统钥匙串", systemImage: "key")
                        .font(.system(size: 11.5))
                    Text("SMB 与 WebDAV 的用户名密码存在钥匙串，"
                        + "**不写进任务配置、也不进日志**。任务里只保存用户名，"
                        + "密码在需要连接时才从钥匙串取出。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 20)

                VStack(alignment: .leading, spacing: 4) {
                    Label("明文 HTTP 与自签名证书", systemImage: "lock.open")
                        .font(.system(size: 11.5))
                    Text("WebDAV 允许指向明文 http://（很多 NAS 只提供这种），"
                        + "也允许为自签证书放行。两者都会降低传输安全性，"
                        + "任务编辑器里会分别给出提示，请按实际网络环境决定。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 20)
            }
        }
    }
}
