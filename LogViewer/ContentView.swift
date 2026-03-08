import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        MainEditorView()
            .frame(minWidth: 900, minHeight: 600)
    }
}

struct MainEditorView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var searchVM = SearchViewModel()
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // ── 搜索工具栏 ──────────────────────────────
                SearchToolbarView()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.windowBackgroundColor))

                Divider()

                // ── 主体区域（文件内容 + 结果面板）──────────
                // 无论有无打开文件，结果面板都可显示
                let showPanel = appState.isSearchPanelVisible && !appState.searchSessions.isEmpty
                let panelH    = showPanel
                    ? max(120, min(geo.size.height * 0.8, appState.searchPanelHeight + dragOffset))
                    : CGFloat(0)
                // 4 = DragDivider高度
                let contentH  = geo.size.height - panelH - (showPanel ? 4 : 0)

                VStack(spacing: 0) {
                    // 文件内容区（空时显示欢迎页）
                    Group {
                        if appState.openedFiles.isEmpty {
                            EmptyStateView()
                        } else {
                            LogTabsView()
                        }
                    }
                    .frame(height: max(50, contentH))

                    // 结果面板（有搜索记录时始终可见）
                    if showPanel {
                        DragDivider(dragOffset: $dragOffset,
                                    panelHeight: $appState.searchPanelHeight)

                        // 标题栏固定高度
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").font(.caption).foregroundColor(.secondary)
                            Text("检索结果").font(.caption).foregroundColor(.secondary)
                            Text("· \(appState.searchSessions.count) 次").font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            Button { appState.searchSessions.removeAll() } label: {
                                Text("清除全部").font(.caption2)
                            }
                            .buttonStyle(.borderless).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .frame(height: 30)
                        .background(Color(NSColor.windowBackgroundColor))

                        Divider()

                        // ResultsTableView 独占剩余高度（panelH - 标题栏31px - divider1px）
                        ResultsTableView()
                            .frame(height: max(40, panelH - 32 - 40))
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: { appState.openFilePanel() }) {
                    Label("打开文件", systemImage: "doc.badge.plus")
                }
                .help("打开文件 (⌘O)")
            }
            // 问题2: 删掉工具栏里的"打开文件夹"按钮
        }
        .environmentObject(searchVM)
    }
}

// MARK: - 拖拽分隔线
struct DragDivider: View {
    @Binding var dragOffset: CGFloat
    @Binding var panelHeight: CGFloat
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? Color.accentColor.opacity(0.5) : Color(NSColor.separatorColor))
            .frame(height: 4)
            .cursor(.resizeUpDown)
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in dragOffset = -value.translation.height }
                    .onEnded   { value in
                        panelHeight = max(120, panelHeight - value.translation.height)
                        dragOffset  = 0
                    }
            )
    }
}

// MARK: - 空状态（仅保留打开文件）
struct EmptyStateView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text("打开日志文件开始查看")
                .font(.title3)
                .foregroundColor(.secondary)
            Button {
                appState.openFilePanel()
            } label: {
                Label("打开文件…", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("o", modifiers: .command)

            Text("⌘O 打开文件")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}
