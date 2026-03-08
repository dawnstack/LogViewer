import SwiftUI

struct ScrollTarget: Equatable {
    let fileID: UUID
    let lineNumber: Int
    let token: UUID = UUID()  // 每次新建token不同，确保onChange必触发

    static func == (lhs: ScrollTarget, rhs: ScrollTarget) -> Bool {
        lhs.token == rhs.token
    }
}

class SearchViewModel: ObservableObject {
    @Published var keyword: String = ""
    @Published var ignoreCase: Bool = true
    @Published var direction: SearchDirection = .down
    @Published var scope: SearchScope = .currentFile
    @Published var selectedFolderURL: URL? = nil
    @Published var scrollToLine: ScrollTarget? = nil
    @Published var highlightResult: SearchResult? = nil
}

// MARK: - Search Toolbar

struct SearchToolbarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var searchVM: SearchViewModel
    @State private var isSearching = false
    @State private var noMatchAlert = false   // 问题4: 无匹配提示

    var body: some View {
        HStack(spacing: 8) {

            // ── 关键字输入框 ────────────────────────────
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary).font(.caption)
                TextField("搜索关键字…", text: $searchVM.keyword)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { performSearch() }
                if !searchVM.keyword.isEmpty {
                    Button { searchVM.keyword = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
            )
            .frame(minWidth: 200)

            Divider().frame(height: 24)

            // ── 向上 / 向下跳转（问题4：大按钮）──────────
            HStack(spacing: 4) {
                Button {
                    jumpToNearest(direction: .up)
                } label: {
                    Label("上一个", systemImage: "chevron.up")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .help("跳转到上一个匹配 (⇧↩)")
                .keyboardShortcut(.return, modifiers: .shift)
                .disabled(searchVM.keyword.isEmpty)

                Button {
                    jumpToNearest(direction: .down)
                } label: {
                    Label("下一个", systemImage: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .help("跳转到下一个匹配 (↩)")
                .disabled(searchVM.keyword.isEmpty)
            }
            .alert("无匹配项", isPresented: $noMatchAlert) {
                Button("好") { }
            } message: {
                let msg = "当前文件中没有找到「" + searchVM.keyword + "」"
                Text(msg)
            }

            Divider().frame(height: 24)

            // ── 搜索范围 ────────────────────────────────
            ScopePicker()

            Divider().frame(height: 24)

            // ── 检索按钮 ────────────────────────────────
            Button(action: performSearch) {
                HStack(spacing: 4) {
                    if isSearching {
                        ProgressView().scaleEffect(0.65).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text("检索")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(minWidth: 60)
            }
            .buttonStyle(.borderedProminent)
            .disabled(searchVM.keyword.isEmpty || isSearching)
            .keyboardShortcut(.return, modifiers: [])

            Spacer()

            // ── 问题5：结果面板大按钮 ────────────────────
            if !appState.searchSessions.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.isSearchPanelVisible.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: appState.isSearchPanelVisible
                              ? "chevron.down.square.fill" : "chevron.up.square.fill")
                        Text(appState.isSearchPanelVisible ? "收起结果" : "展开结果")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .help(appState.isSearchPanelVisible ? "收起检索结果面板" : "展开检索结果面板")
            }
        }
    }

    // MARK: - 执行搜索
    private func performSearch() {
        guard !searchVM.keyword.isEmpty else { return }
        isSearching = true

        let options = SearchOptions(
            keyword: searchVM.keyword,
            ignoreCase: searchVM.ignoreCase,
            direction: searchVM.direction,
            scope: searchVM.scope
        )

        Task {
            // 等待相关文件加载完成（最多10秒）
            let filesToWait: [LogFile]
            switch options.scope {
            case .currentFile:
                filesToWait = await MainActor.run { appState.selectedFile.map { [$0] } ?? [] }
            case .allOpenFiles:
                filesToWait = await MainActor.run { appState.openedFiles }
            case .folder:
                filesToWait = []
            }
            for _ in 0..<100 {
                let loading = await MainActor.run { filesToWait.contains { $0.isLoading } }
                if !loading { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            let session: SearchSession
            switch options.scope {
            case .currentFile:
                let files = await MainActor.run { appState.selectedFile.map { [$0] } ?? [] }
                session = await SearchEngine.shared.search(options: options, files: files)
            case .allOpenFiles:
                let files = await MainActor.run { appState.openedFiles }
                session = await SearchEngine.shared.search(options: options, files: files)
            case .folder(let url):
                session = await SearchEngine.shared.searchFolder(url, options: options)
            }

            await MainActor.run {
                appState.addSearchSession(session)
                isSearching = false
            }
        }
    }

    // MARK: - 向上/向下跳转
    // 先从搜索结果里找（不依赖 lines，大文件也能用）；没有搜索结果时 fallback 到内存扫描
    private func jumpToNearest(direction: SearchDirection) {
        guard !searchVM.keyword.isEmpty,
              let file = appState.selectedFile else { return }

        let currentLine = searchVM.highlightResult?.lineNumber ?? (direction == .down ? 0 : Int.max)

        // 优先从当前文件的已有搜索结果中找（不读磁盘）
        let allResults = appState.searchSessions
            .flatMap { $0.fileResults }
            .filter { $0.fileURL == file.url }
            .flatMap { $0.results }
            .sorted { $0.lineNumber < $1.lineNumber }

        let candidate: SearchResult?
        if direction == .down {
            candidate = allResults.first { $0.lineNumber > currentLine }
        } else {
            candidate = allResults.last  { $0.lineNumber < currentLine }
        }

        if let found = candidate {
            searchVM.highlightResult = found
            searchVM.scrollToLine = ScrollTarget(fileID: file.id, lineNumber: found.lineNumber)
            return
        }

        // 没有搜索结果时：小文件直接扫 lines，大文件提示先执行检索
        if file.isLargeFile {
            noMatchAlert = true
            return
        }
        let compareOptions: String.CompareOptions = searchVM.ignoreCase ? [.caseInsensitive] : []
        let lines = file.lines
        let found2: LogLine?
        if direction == .down {
            found2 = lines.first { $0.lineNumber > currentLine &&
                $0.text.range(of: searchVM.keyword, options: compareOptions) != nil }
        } else {
            found2 = lines.last { $0.lineNumber < currentLine &&
                $0.text.range(of: searchVM.keyword, options: compareOptions) != nil }
        }
        if let f = found2 {
            let result = SearchResult(fileURL: file.url, lineNumber: f.lineNumber, lineText: f.text)
            searchVM.highlightResult = result
            searchVM.scrollToLine = ScrollTarget(fileID: file.id, lineNumber: f.lineNumber)
        } else {
            noMatchAlert = true
        }
    }
}

// MARK: - Scope Picker

struct ScopePicker: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var searchVM: SearchViewModel

    var body: some View {
        Menu {
            Button("当前文件")     { searchVM.scope = .currentFile }
            Button("所有打开文件") { searchVM.scope = .allOpenFiles }
            Divider()
            Button("选择文件夹…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.title = "选择搜索文件夹"
                if panel.runModal() == .OK, let url = panel.url {
                    searchVM.selectedFolderURL = url
                    searchVM.scope = .folder(url)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: scopeIcon)
                Text(scopeLabel).lineLimit(1).frame(maxWidth: 130, alignment: .leading)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("搜索范围")
    }

    private var scopeIcon: String {
        switch searchVM.scope {
        case .currentFile:  return "doc.text"
        case .allOpenFiles: return "doc.on.doc"
        case .folder:       return "folder"
        }
    }

    private var scopeLabel: String {
        switch searchVM.scope {
        case .currentFile:       return "当前文件"
        case .allOpenFiles:      return "所有打开文件"
        case .folder(let url):   return url.lastPathComponent
        }
    }
}
