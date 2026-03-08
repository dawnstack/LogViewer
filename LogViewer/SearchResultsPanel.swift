import SwiftUI
import AppKit

// MARK: - 结果面板：纯 NSTableView，彻底绕开 SwiftUI 滚动布局问题

// SearchResultsPanel 已拆解，标题栏在 ContentView 里，ResultsTableView 直接使用

// MARK: - NSTableView 封装

struct ResultsTableView: NSViewRepresentable {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var searchVM: SearchViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = context.coordinator.tableView
        tv.style = .plain
        tv.backgroundColor         = NSColor.controlBackgroundColor
        tv.intercellSpacing        = NSSize(width: 0, height: 0)
        tv.headerView              = nil
        tv.rowHeight               = 20
        tv.usesAlternatingRowBackgroundColors = false
        tv.selectionHighlightStyle = .regular
        tv.allowsEmptySelection    = true
        tv.allowsMultipleSelection = true
        tv.floatsGroupRows         = false
        tv.columnAutoresizingStyle = .uniformColumnAutoresizingStyle  // 列宽随父视图拉伸

        let col = NSTableColumn(identifier: .init("main"))
        col.resizingMask = .autoresizingMask
        tv.addTableColumn(col)

        tv.dataSource = context.coordinator
        tv.delegate   = context.coordinator

        context.coordinator.appState  = appState
        context.coordinator.searchVM  = searchVM

        let sv = NSScrollView()
        sv.documentView        = tv
        sv.hasVerticalScroller = true
        sv.autohidesScrollers  = true
        sv.drawsBackground     = true
        sv.backgroundColor     = NSColor.controlBackgroundColor
        sv.autoresizingMask    = [.width, .height]  // scrollView跟随父视图大小
        tv.autoresizingMask    = [.width]            // tableView宽度跟随scrollView

        // 单击选中，双击跳转
        tv.target = context.coordinator
        tv.action = #selector(Coordinator.rowSingleClick)
        tv.doubleAction = #selector(Coordinator.rowDoubleClick)

        // 注册 ⌘C 复制菜单
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "复制", action: #selector(Coordinator.copySelectedRows), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        copyItem.target = context.coordinator
        menu.addItem(copyItem)
        tv.menu = menu

        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.appState = appState
        coord.searchVM = searchVM

        // 重建扁平行数据并 reload
        coord.rebuild(sessions: appState.searchSessions)
        coord.tableView.reloadData()
        // 底部加20行高度缓冲，防止末尾内容被裁切
        let rowH: CGFloat = 20
        let contentHeight = CGFloat(coord.rows.count) * rowH
        // 加上 scrollView 自身高度，保证最后几行能滚入可视区
        let totalHeight = contentHeight + sv.bounds.height
        coord.tableView.frame = NSRect(x: 0, y: 0,
                                       width: max(sv.contentView.bounds.width, 100),
                                       height: totalHeight)
    }

    // MARK: - Coordinator + 数据模型

    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let tableView = NSTableView()
        var appState: AppState?
        var searchVM: SearchViewModel?

        // 扁平化的行数据
        enum RowItem {
            case session(SearchSession)                          // 一级：检索会话
            case file(SearchSession, FileSearchResult, Int)     // 二级：文件（session, fileResult, fileIndex）
            case result(SearchSession, FileSearchResult, SearchResult) // 三级：结果行
        }
        var rows: [RowItem] = []

        // 展开状态（用 session.id + fileResult.id 作 key）
        var sessionExpanded: [UUID: Bool] = [:]
        var fileExpanded   : [String: Bool] = [:]   // "\(sessionID)-\(fileID)"

        func rebuild(sessions: [SearchSession]) {
            rows = []
            let list = sessions.reversed()
            for session in list {
                let sExp = sessionExpanded[session.id] ?? session.isExpanded
                rows.append(.session(session))
                guard sExp else { continue }
                for (fi, fr) in session.fileResults.enumerated() {
                    let fKey = "\(session.id)-\(fr.id)"
                    let fExp = fileExpanded[fKey] ?? true
                    rows.append(.file(session, fr, fi))
                    guard fExp else { continue }
                    for result in fr.results {
                        rows.append(.result(session, fr, result))
                    }
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tv: NSTableView, isGroupRow row: Int) -> Bool { false }

        func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
            guard row < rows.count else { return nil }
            switch rows[row] {
            case .session(let s):
                return makeSessionCell(s, tv: tv)
            case .file(_, let fr, _):
                return makeFileCell(fr, tv: tv)
            case .result(let s, _, let r):
                return makeResultCell(r, keyword: s.keyword, ignoreCase: s.options.ignoreCase, tv: tv)
            }
        }

        func tableView(_ tv: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < rows.count else { return 20 }
            switch rows[row] {
            case .session: return 24
            case .file:    return 20
            case .result:  return 20
            }
        }

        func tableView(_ tv: NSTableView, rowViewFor row: Int) -> NSTableRowView? {
            let v = NSTableRowView()
            v.isEmphasized = true   // 保持选中高亮色
            return v
        }

        // ⌘C 复制选中行的 lineText
        @objc func copySelectedRows() {
            var texts: [String] = []
            tableView.selectedRowIndexes.forEach { idx in
                guard idx < rows.count else { return }
                if case .result(_, _, let r) = rows[idx] {
                    texts.append(r.lineText)
                }
            }
            guard !texts.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(texts.joined(separator: "\n"), forType: .string)
        }

        // 单击：展开/折叠 session 和 file，result 行只选中不跳转
        @objc func rowSingleClick() {
            let row = tableView.clickedRow
            guard row >= 0 && row < rows.count else { return }
            switch rows[row] {
            case .session(let s):
                let cur = sessionExpanded[s.id] ?? s.isExpanded
                sessionExpanded[s.id] = !cur
                rebuild(sessions: appState?.searchSessions ?? [])
                tableView.reloadData()
            case .file(let s, let fr, _):
                let key = "\(s.id)-\(fr.id)"
                let cur = fileExpanded[key] ?? true
                fileExpanded[key] = !cur
                rebuild(sessions: appState?.searchSessions ?? [])
                tableView.reloadData()
            case .result:
                break  // 单击只选中，不跳转
            }
        }

        // 双击：跳转到对应行
        @objc func rowDoubleClick() {
            let row = tableView.clickedRow
            guard row >= 0 && row < rows.count else { return }
            if case .result(_, _, let r) = rows[row] {
                jumpTo(result: r)
            }
        }

        private func jumpTo(result: SearchResult) {
            guard let appState = appState, let searchVM = searchVM else { return }
            let url = result.fileURL
            if let file = appState.openedFiles.first(where: { $0.url == url }) {
                appState.selectedFileID = file.id
                searchVM.highlightResult = result
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    searchVM.scrollToLine = ScrollTarget(fileID: file.id, lineNumber: result.lineNumber)
                }
            } else {
                appState.openFile(url: url)
                Task { @MainActor in
                    for _ in 0..<80 {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        if let file = appState.openedFiles.first(where: { $0.url == url }),
                           !file.isLoading {
                            appState.selectedFileID = file.id
                            searchVM.highlightResult = result
                            try? await Task.sleep(nanoseconds: 80_000_000)
                            searchVM.scrollToLine = ScrollTarget(fileID: file.id, lineNumber: result.lineNumber)
                            return
                        }
                    }
                }
            }
        }

        // MARK: - Cell 构建

        private func makeSessionCell(_ s: SearchSession, tv: NSTableView) -> NSView {
            let id  = NSUserInterfaceItemIdentifier("SC")
            let row = tv.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
                   ?? NSTableCellView()
            row.identifier = id

            // 清空旧子视图
            row.subviews.forEach { $0.removeFromSuperview() }

            let expanded = sessionExpanded[s.id] ?? s.isExpanded
            let arrow = NSTextField(labelWithString: expanded ? "▾" : "▸")
            arrow.font      = .systemFont(ofSize: 10)
            arrow.textColor = .secondaryLabelColor
            arrow.frame     = NSRect(x: 6, y: 4, width: 12, height: 16)

            let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
            let title = "\"\(s.keyword)\"  [\(fmt.string(from: s.timestamp))]"
            let label = NSTextField(labelWithString: title)
            label.font      = .boldSystemFont(ofSize: 11)
            label.textColor = .labelColor
            label.frame     = NSRect(x: 22, y: 4, width: 280, height: 16)

            let countStr = s.isSearching ? "搜索中…" : "\(s.totalCount) 条 · \(s.fileCount) 个文件"
            let count = NSTextField(labelWithString: countStr)
            count.font      = .systemFont(ofSize: 10)
            count.textColor = .secondaryLabelColor
            count.frame     = NSRect(x: 310, y: 4, width: 200, height: 16)

            row.addSubview(arrow)
            row.addSubview(label)
            row.addSubview(count)
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            return row
        }

        private func makeFileCell(_ fr: FileSearchResult, tv: NSTableView) -> NSView {
            let id  = NSUserInterfaceItemIdentifier("FC")
            let row = tv.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
                   ?? NSTableCellView()
            row.identifier = id
            row.subviews.forEach { $0.removeFromSuperview() }

            let arrow = NSTextField(labelWithString: "  ▸")
            arrow.font      = .systemFont(ofSize: 10)
            arrow.textColor = .secondaryLabelColor
            arrow.frame     = NSRect(x: 20, y: 2, width: 20, height: 16)

            let path = NSTextField(labelWithString: fr.fileURL.path)
            path.font            = .monospacedSystemFont(ofSize: 10, weight: .regular)
            path.textColor       = .labelColor
            path.lineBreakMode   = .byTruncatingMiddle
            path.frame           = NSRect(x: 44, y: 2, width: 400, height: 16)

            let cnt = NSTextField(labelWithString: "\(fr.results.count) 条")
            cnt.font      = .systemFont(ofSize: 10)
            cnt.textColor = .secondaryLabelColor
            cnt.alignment = .right
            cnt.frame     = NSRect(x: 450, y: 2, width: 60, height: 16)

            row.addSubview(arrow)
            row.addSubview(path)
            row.addSubview(cnt)
            return row
        }

        private func makeResultCell(_ r: SearchResult, keyword: String,
                                     ignoreCase: Bool, tv: NSTableView) -> NSView {
            let id  = NSUserInterfaceItemIdentifier("RC")
            let row = tv.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
                   ?? NSTableCellView()
            row.identifier = id
            row.subviews.forEach { $0.removeFromSuperview() }

            let lineNum = NSTextField(labelWithString: "\(r.lineNumber)")
            lineNum.font            = .monospacedSystemFont(ofSize: 10, weight: .regular)
            lineNum.textColor       = .white
            lineNum.alignment       = .center
            lineNum.wantsLayer      = true
            lineNum.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.6).cgColor
            lineNum.layer?.cornerRadius    = 3
            lineNum.frame = NSRect(x: 52, y: 2, width: 44, height: 16)

            let text = NSTextField(labelWithString: r.lineText.trimmingCharacters(in: .whitespaces))
            text.font          = .monospacedSystemFont(ofSize: 10, weight: .regular)
            text.textColor     = .labelColor
            text.lineBreakMode = .byTruncatingTail
            text.frame         = NSRect(x: 102, y: 2, width: 1200, height: 16)

            row.addSubview(lineNum)
            row.addSubview(text)
            return row
        }
    }
}
