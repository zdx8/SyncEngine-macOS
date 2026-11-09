import AppKit
import SwiftUI
import SyncEngine

/// 编辑器要打开的目标：新建，或编辑某个已有任务。
///
/// 用一个包装类型而不是两个独立的 sheet 状态：两个 `isPresented`/`item` 同时挂在
/// 同一个视图上时，快速点击容易出现"打开了错误的那个"。
private struct EditorTarget: Identifiable {
    let id: String
    let task: SyncTask?

    static let create = EditorTarget(id: "__new__", task: nil)
    static func edit(_ task: SyncTask) -> EditorTarget {
        EditorTarget(id: task.id.uuidString, task: task)
    }
}

struct TasksView: View {
    @Environment(AppModel.self) private var model
    @State private var editorTarget: EditorTarget?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("同步任务")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(model.tasks.count) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    editorTarget = .create
                } label: {
                    Label("新建任务", systemImage: "plus")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)

            Divider()

            if model.tasks.isEmpty {
                ContentUnavailableView(
                    "还没有同步任务",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("点击右上角「新建任务」，选择源目录与目标位置")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.tasks) { task in
                            TaskCard(task: task) {
                                editorTarget = .edit(task)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            TaskEditorSheet(task: target.task)
                .environment(model)
        }
    }
}

// ─────────────────────────────────────────────────── 任务卡片 --

struct TaskCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appAccent) private var accent
    let task: SyncTask
    /// 点击"编辑"时通知上层打开编辑器。
    /// 不由卡片自己持有 sheet 状态：卡片会被列表复用，
    /// 把模态状态放在被复用的视图里容易出现串台。
    let onEdit: () -> Void

    @State private var isEntriesExpanded = false
    @State private var isTargetExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            paths
            if task.isScanning || task.isProbingTarget {
                ProgressView().progressViewStyle(.linear).controlSize(.small)
                    .padding(.horizontal, 16)
            }
            if let error = task.errorMessage {
                errorRow(error)
            }
            if let error = task.targetProbeError {
                errorRow("目标端：\(error)")
            }
            if let preview = task.preview {
                PreviewStats(result: preview)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                if isEntriesExpanded {
                    EntryList(result: preview)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                }
            }
            if let probe = task.targetProbe {
                TargetProbeSummary(probe: probe)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                if isTargetExpanded, let entries = task.targetEntries {
                    TargetEntryList(entries: entries, location: probe.resolvedLocation)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                }
            }
            actions
        }
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: 各段

    private var header: some View {
        HStack(spacing: 8) {
            Text(task.name)
                .font(.system(size: 13.5, weight: .semibold))

            Badge(text: task.mode.label, style: .accent)
            Badge(text: task.target.kind.shortLabel, style: .neutral)

            Spacer()

            Toggle("", isOn: Binding(
                get: { task.isEnabled },
                set: { newValue in
                    guard let index = model.tasks.firstIndex(where: { $0.id == task.id })
                    else { return }
                    model.tasks[index].isEnabled = newValue
                    model.append(
                        level: .info, source: "任务",
                        message: "\(newValue ? "启用" : "停用")「\(task.name)」")
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            // 编辑图标放大到 15pt，并给它一块独立的点击区域。
            //
            // **光放大图标是不够的**：图标变大但按钮热区不变，视觉上"看得清"了、
            // 手感上依然难点中 —— 用户会以为没生效。所以用 frame 把热区撑开，
            // 再用 contentShape 确保透明区域也响应点击（不然只有笔画本身可点）。
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("编辑任务")

            // 删除图标同步放大到同一尺寸：两个按钮并排却大小不一，
            // 看起来像渲染错误，而不是"有意的层级差异"。
            Button {
                model.removeTask(task)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("删除任务")
        }
        .padding(.horizontal, 16)
    }

    private var paths: some View {
        VStack(alignment: .leading, spacing: 3) {
            PathRow(label: "源", value: task.sourcePath, dimmed: false)
            PathRow(
                label: "目标",
                value: targetDescription,
                dimmed: task.target.address.isEmpty
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 7)
    }

    private var targetDescription: String {
        guard !task.target.address.isEmpty else { return "(未指定)" }
        var text = task.target.displayText
        if task.target.kind.requiresCredentials {
            text += "  ·  \(task.target.credentialSummary)"
        }
        return text
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
            Text(message)
                .font(.system(size: 11.5))
                .textSelection(.enabled)
        }
        .foregroundStyle(Palette.warning)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.previewScan(task.id) }
            } label: {
                Label(task.preview == nil ? "预览扫描" : "重新扫描",
                      systemImage: "magnifyingglass")
            }
            .disabled(task.isScanning)

            // 目标端连接测试。这是一次真实往返，所以按钮状态要如实反映进行中。
            Button {
                Task { await model.testTargetConnection(task.id) }
            } label: {
                Label(task.isProbingTarget ? "连接中…" : "测试目标连接",
                      systemImage: "network")
            }
            .disabled(task.isProbingTarget || task.target.address.isEmpty)

            if task.preview != nil {
                Button {
                    isEntriesExpanded.toggle()
                } label: {
                    Label(
                        isEntriesExpanded ? "收起源文件列表" : "源文件列表",
                        systemImage: isEntriesExpanded ? "chevron.up" : "chevron.down"
                    )
                }
                // 不用 `.buttonStyle(.link)`：那个样式写死了系统的链接蓝，
                // 在橙色强调色下会露出一抹毫不相干的蓝。改成无边框 + 显式强调色。
                .buttonStyle(.borderless)
                .foregroundStyle(accent)
            }

            if task.targetEntries != nil {
                Button {
                    isTargetExpanded.toggle()
                } label: {
                    Label(
                        isTargetExpanded ? "收起目标列表" : "目标列表",
                        systemImage: isTargetExpanded ? "chevron.up" : "chevron.down"
                    )
                }
                .buttonStyle(.borderless)
                .foregroundStyle(accent)
            }

            Spacer()

            if let date = task.lastPreviewAt {
                Text("预览于 \(Self.timeText(date))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 11)
    }

    static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// ─────────────────────────────────────────────── 预览统计 --

/// 预览统计。
///
/// 刻意把「遍历」与「哈希」分开显示，并给出各自耗时：
/// 这两项的瓶颈成因完全不同（前者是文件数，后者是字节数 + 每文件一次 open/close），
/// 合并成一个总数会让性能问题无法归因。
struct PreviewStats: View {
    let result: ScanResult

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 22) {
                Metric("文件", "\(result.fileCount)")
                Metric("目录", "\(result.directoryCount)")
                Metric("总大小", ByteFormatter.string(fromBytes: result.totalBytes))
                Metric("已哈希", "\(result.hashedCount)")
                if result.symlinksSkipped > 0 {
                    Metric("跳过软链", "\(result.symlinksSkipped)")
                }
                Spacer(minLength: 0)
            }

            Divider()

            HStack(spacing: 22) {
                Metric("遍历", ByteFormatter.string(fromSeconds: result.walkSeconds))
                Metric("哈希", ByteFormatter.string(fromSeconds: result.hashSeconds))
                Metric("合计", ByteFormatter.string(fromSeconds: result.elapsedSeconds))
                if let throughput = result.hashThroughputMBps {
                    Metric("哈希吞吐", String(format: "%.0f MB/s", throughput))
                }
                Metric("最大深度", "\(result.maxDepth)")
                Spacer(minLength: 0)
            }

            if result.readErrors > 0 || result.hashErrors > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text("读取失败 \(result.readErrors) 项 · 哈希失败 \(result.hashErrors) 项")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Palette.warning)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        )
    }
}

struct Metric: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
    }
}

// ─────────────────────────────────────────────── 目标端状态 --

/// 目标端连接测试的结果。
///
/// 这块的每一行都对应一次**真实往返**得到的事实，不是本地推断出来的：
/// 挂载点 / 最终 URL、文件系统类型、条目数、是否可写，全部来自驱动的探测。
struct TargetProbeSummary: View {
    let probe: StorageProbe

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 22) {
                Metric("目标类型", probe.kind.label)
                if let fileSystem = probe.fileSystemType {
                    Metric("文件系统", fileSystem)
                }
                if let count = probe.rootEntryCount {
                    Metric("基准目录条目", "\(count)")
                }
                Metric("可写", probe.isWritable.map { $0 ? "是" : "否" } ?? "未知")
                Metric("探测耗时", ByteFormatter.string(fromSeconds: probe.elapsedSeconds))
                Spacer(minLength: 0)
            }

            labeledValue(label: "实际位置", value: probe.resolvedLocation, dimmed: true)

            if let serverInfo = probe.serverInfo, !serverInfo.isEmpty {
                labeledValue(label: "服务端", value: serverInfo, dimmed: true)
            }

            ForEach(probe.notes, id: \.self) { note in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                    Text(note)
                        .font(.system(size: 10.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.secondary)
            }

            if probe.isWritable == false {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text("目标端报告为只读：同步写入会失败。请检查服务端对该账号的权限。")
                        .font(.system(size: 10.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.warning)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        )
    }

    private func labeledValue(label: String, value: String, dimmed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// 目标端基准目录下的条目。
///
/// 它同时是一份**证据**：内容来自驱动真实发出的 PROPFIND 或真实挂载点枚举，
/// 所以"能列出东西"本身就说明这条链路是通的。
struct TargetEntryList: View {
    let entries: [RemoteEntry]
    let location: String

    private var shown: [RemoteEntry] { Array(entries.prefix(60)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("目标端基准目录（\(entries.count) 项\(entries.count > shown.count ? "，显示前 \(shown.count)" : "")）")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if entries.isEmpty {
                Text("目录为空")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: entry.isDirectory ? "folder" : "doc")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                Text(entry.name)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(entry.isDirectory ? "—" : ByteFormatter.string(fromBytes: entry.size))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 68, alignment: .trailing)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
    }
}

// ─────────────────────────────────────────────── 文件条目 --

struct EntryList: View {
    let result: ScanResult

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("体积最大的 \(result.entries.count) 个文件")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if result.truncated {
                    Text("（共 \(result.fileCount) 个，列表已截断）")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(result.entries) { entry in
                        HStack(spacing: 10) {
                            Text(entry.relativePath)
                                .font(.system(size: 10.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(entry.path)

                            Text(ByteFormatter.string(fromBytes: entry.size))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 68, alignment: .trailing)

                            Text(entry.contentHash.map { String($0.prefix(10)) + "…" } ?? "—")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .leading)
                                .help(entry.contentHash ?? "未计算")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }
}

// ─────────────────────────────────────────────── 小部件 --

struct Badge: View {
    enum Style { case accent, warning, neutral }

    let text: String
    let style: Style

    @Environment(\.appAccent) private var accent

    private var color: Color {
        switch style {
        case .accent: return accent
        // 警告色走 Palette 令牌，不直接写 .orange：强调色曾长期是橙色，
        // 那时必须把警告色挪开。现在强调色是绿，警告色恢复为琥珀，
        // 但**仍然只从令牌取** —— 这样下次改品牌色时只有一处需要重新审视。
        case .warning: return Palette.warning
        case .neutral: return .secondary
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3.5))
            .foregroundStyle(color)
    }
}

struct PathRow: View {
    let label: String
    let value: String
    let dimmed: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// ─────────────────────────────────────────────────── 任务编辑器 --

/// 新建 / 编辑任务。
///
/// 用同一个视图兼顾两种用途，而不是写两份几乎相同的表单：
/// 字段、校验规则、目录选择逻辑完全一致，分成两份必然会随时间漂移
/// （改了新建的忘了改编辑的）。
struct TaskEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent

    /// nil 表示新建
    let task: SyncTask?

    @State private var name: String
    @State private var sourcePath: String
    @State private var target: TargetConfiguration
    @State private var mode: SyncMode

    /// 密码框**刻意不回填**已有密码（见 `.task` 里的说明）。
    /// 留空表示"不改"，因此还需要一个显式的清除标记，否则用户无法把密码删掉。
    @State private var password = ""
    @State private var hasStoredPassword = false
    @State private var clearStoredPassword = false

    @State private var isTesting = false
    @State private var testResult: Result<StorageProbe, Error>?

    init(task: SyncTask?) {
        self.task = task
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let documents = home + "/Documents"

        _name = State(initialValue: task?.name ?? "新建同步任务")
        _sourcePath = State(initialValue: task?.sourcePath
            ?? (FileManager.default.fileExists(atPath: documents) ? documents : home))
        _target = State(initialValue: task?.target ?? TargetConfiguration())
        _mode = State(initialValue: task?.mode ?? .bidirectional)
    }

    private var isEditing: Bool { task != nil }

    private var trimmedName: String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未命名任务" : value
    }

    /// 地址格式问题。
    ///
    /// 在保存前就报出来，而不是等到用户点了"测试连接"才失败 ——
    /// 地址写错和连不上是两回事，混在一起会让人去查网络。
    private var addressProblem: String? {
        guard !target.address.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        do {
            _ = try target.makeEndpoint()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var canSubmit: Bool {
        !sourcePath.trimmingCharacters(in: .whitespaces).isEmpty
            && !target.address.trimmingCharacters(in: .whitespaces).isEmpty
            && addressProblem == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isEditing ? "编辑同步任务" : "新建同步任务")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)

            Form {
                TextField("任务名称", text: $name)

                LabeledContent("源目录") {
                    HStack(spacing: 6) {
                        TextField("", text: $sourcePath)
                            .font(.system(size: 11, design: .monospaced))
                        Button("选择…") { chooseDirectory(into: $sourcePath) }
                    }
                }
                .disabled(task != nil && task!.isScanning)

                Divider()

                Picker("目标位置", selection: $target.kind) {
                    ForEach(StorageKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .onChange(of: target.kind) { _, _ in
                    // 换了类型，原地址的格式基本不再适用（本地是路径、
                    // SMB 是 smb://、WebDAV 是 URL）。留着只会立刻报"地址无效"，
                    // 不如清空，让占位提示告诉用户该填什么。
                    target.address = ""
                    target.subpath = ""
                    testResult = nil
                }

                Text(target.kind.capabilitySummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent(target.kind == .local ? "目标目录" : "服务器地址") {
                    HStack(spacing: 6) {
                        TextField(target.kind.addressPlaceholder, text: $target.address)
                            .font(.system(size: 11, design: .monospaced))
                        if target.kind == .local {
                            Button("选择…") { chooseDirectory(into: $target.address) }
                        }
                    }
                }

                if let addressProblem {
                    Label(addressProblem, systemImage: "xmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.warning)
                }

                if target.kind.requiresCredentials {
                    TextField("用户名（留空为访客访问）", text: $target.user)

                    SecureField(
                        hasStoredPassword ? "密码（留空则沿用已保存的）" : "密码",
                        text: $password
                    )
                    .disabled(clearStoredPassword)

                    if hasStoredPassword {
                        HStack(spacing: 8) {
                            Button(clearStoredPassword ? "已标记清除" : "清除已保存的密码") {
                                clearStoredPassword.toggle()
                                password = ""
                            }
                            .controlSize(.small)
                            .disabled(clearStoredPassword)
                            if clearStoredPassword {
                                Button("撤销") { clearStoredPassword = false }
                                    .controlSize(.small)
                            }
                            Text("凭据存在系统钥匙串，不写进任务配置。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Label("凭据存在系统钥匙串，不写进任务配置。", systemImage: "key")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                TextField(
                    target.kind == .webdav ? "服务器上的子路径（可留空）" : "共享内子目录（可留空）",
                    text: $target.subpath
                )

                if target.kind.supportsInsecureTLS {
                    Toggle(isOn: $target.allowInsecureTLS) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("允许自签名证书").font(.system(size: 12.5))
                            Text("NAS 的 WebDAV 常年用自签证书，不勾选会连不上。"
                                + "勾选后无法通过证书链确认服务器身份，中间人攻击将无法察觉 —— "
                                + "只在可信局域网内开启。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if target.kind == .webdav, target.address.lowercased().hasPrefix("http://") {
                    Label("当前是明文 HTTP：账号与内容在网络上不加密传输。"
                        + "若服务端支持，建议改成 https://。",
                        systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.warning)
                }

                Divider()

                Picker("同步模式", selection: $mode) {
                    ForEach(SyncMode.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                Text(mode.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if isEditing, let task, task.preview != nil, task.sourcePath != sourcePath {
                    Label("源目录已改动，保存后旧的预览结果会被清除",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.warning)
                }
                if isEditing, let task, task.target != target {
                    Label("目标端已改动，保存后旧的连接结果会被清除",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.warning)
                }
            }
            .formStyle(.grouped)

            if let testResult {
                testSummary(testResult)
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
            }

            HStack(spacing: 10) {
                Button {
                    runTest()
                } label: {
                    Label(isTesting ? "测试中…" : "测试连接", systemImage: "network")
                }
                .disabled(isTesting || !canSubmitForTest)
                .help("真实连接一次目标端，验证地址与凭据是否可用")

                Spacer()

                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button(isEditing ? "保存" : "创建") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 580)
        .task {
            // 密码不回填到界面上。
            //
            // 哪怕用 SecureField，框里的内容也会随截图、录屏、投屏一起泄漏；
            // 而"编辑任务"这个动作通常只是想改个名字或路径，没有理由让密码
            // 再次出现在屏幕上。留空 + 一句"留空则沿用已保存的"就够了。
            if let task {
                hasStoredPassword = !model.credentials(for: task.target).password.isEmpty
            }
        }
    }

    private var canSubmitForTest: Bool {
        !target.address.trimmingCharacters(in: .whitespaces).isEmpty && addressProblem == nil
    }

    // MARK: 动作

    private func runTest() {
        isTesting = true
        testResult = nil
        let configuration = target
        let typedPassword = password
        Task {
            let result = await model.probe(target: configuration, password: typedPassword)
            isTesting = false
            testResult = result
            switch result {
            case .success(let probe):
                model.append(
                    level: .info, source: "目标",
                    message: "连接成功 · \(probe.resolvedLocation)"
                        + " · \(ByteFormatter.string(fromSeconds: probe.elapsedSeconds))"
                )
                if let writable = probe.isWritable, !writable {
                    model.append(level: .warning, source: "目标", message: "目标端报告为只读")
                }
            case .failure(let error):
                model.append(
                    level: .error, source: "目标",
                    message: "连接失败：\(error.localizedDescription)")
            }
        }
    }

    private func submit() {
        // 密码更新的三种情形必须区分清楚，混起来会出现"编辑一次任务
        // 就把密码清空"这种让人莫名其妙的故障：
        //   * 标记了清除        → 传空字符串（写空即删记录）
        //   * 留空且有已存密码  → 传 nil（保持不动）
        //   * 输入了新密码      → 传新值
        let passwordUpdate: String?
        if clearStoredPassword {
            passwordUpdate = ""
        } else if password.isEmpty && hasStoredPassword {
            passwordUpdate = nil
        } else {
            passwordUpdate = password
        }

        if let task {
            model.updateTask(
                id: task.id,
                name: trimmedName,
                sourcePath: sourcePath,
                target: target,
                mode: mode,
                password: passwordUpdate
            )
        } else {
            model.addTask(
                name: trimmedName,
                sourcePath: sourcePath,
                target: target,
                mode: mode,
                password: passwordUpdate ?? ""
            )
        }
        dismiss()
    }

    @ViewBuilder
    private func testSummary(_ result: Result<StorageProbe, Error>) -> some View {
        switch result {
        case .success(let probe):
            VStack(alignment: .leading, spacing: 4) {
                Label("连接成功", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(accent)
                Text(probe.resolvedLocation)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 16) {
                    if let fileSystem = probe.fileSystemType {
                        Text("文件系统 \(fileSystem)").font(.system(size: 10.5))
                    }
                    if let count = probe.rootEntryCount {
                        Text("基准目录 \(count) 项").font(.system(size: 10.5))
                    }
                    Text("可写 \(probe.isWritable.map { $0 ? "是" : "否" } ?? "未知")")
                        .font(.system(size: 10.5))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accent.opacity(0.10))
            )

        case .failure(let error):
            Label(error.localizedDescription, systemImage: "xmark.circle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Palette.warning.opacity(0.10))
                )
        }
    }

    /// 弹出系统目录选择器。
    ///
    /// 用 NSOpenPanel 而不是引入文件选择类的第三方包：需要的功能只有这几行，
    /// 而每个依赖都要承担维护与供应链风险（见技术方案 2.3）。
    ///
    /// 注意：若将来开启 App Sandbox，仅取回路径字符串是**不够的** ——
    /// 沙盒下必须同时保存安全作用域书签，否则应用重启后就失去该目录的访问权。
    /// 详见技术方案 5.1。
    private func chooseDirectory(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择一个用于同步的目录"
        if !binding.wrappedValue.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: binding.wrappedValue)
        }
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }
}
