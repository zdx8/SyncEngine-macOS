import AppKit
import SwiftUI
import SyncEngine

/// 同步日志页。
///
/// 日志条目全部来自真实动作（引擎调用、任务增删、自检），
/// **没有为了"看起来有内容"而预填的假数据** —— 假日志会让这个页面失去排查价值。
struct LogsView: View {
    @Environment(AppModel.self) private var model

    /// nil 表示不筛选，显示全部级别
    @State private var levelFilter: LogLevel?

    private var visibleLogs: [LogEntry] {
        guard let levelFilter else { return model.logs }
        return model.logs.filter { $0.level == levelFilter }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if visibleLogs.isEmpty {
                ContentUnavailableView(
                    "暂无日志",
                    systemImage: "list.bullet.rectangle",
                    description: Text("执行一次「预览扫描」后，引擎的调用记录会出现在这里")
                )
            } else {
                logList
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("同步日志")
                .font(.system(size: 14, weight: .semibold))
            Text("\(visibleLogs.count) / \(model.logs.count) 条")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            Picker("", selection: $levelFilter) {
                Text("全部").tag(LogLevel?.none)
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level.label).tag(LogLevel?.some(level))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            Button("清空") { model.clearLogs() }
                .disabled(model.logs.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleLogs) { entry in
                        LogRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .onChange(of: model.logs.count) { _, _ in
                // 新日志进来时滚到底部。放在 onChange 而不是每次 body 里，
                // 是为了避免在渲染过程中触发状态变更。
                if let last = visibleLogs.last {
                    withAnimation(.linear(duration: 0.12)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

struct LogRow: View {
    let entry: LogEntry
    @Environment(\.appAccent) private var accent

    private var color: Color {
        switch entry.level {
        // 读注入的强调色而不是 `.accentColor`：后者是系统强调色、无视 `.tint()`。
        case .info: return accent
        // 警告用 Palette.warning（红）而不是橙色 —— 强调色本身就是橙，
        // 两者撞在一起就分不出"可以点"和"要注意"了。
        case .warning: return Palette.warning
        case .error: return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(entry.timeText)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(entry.level.tag)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color)

            Text(entry.source)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}
