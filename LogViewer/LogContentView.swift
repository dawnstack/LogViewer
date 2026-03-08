import SwiftUI
import AppKit

// MARK: - Tab 栏

struct LogTabsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(appState.openedFiles) { file in
                        LogTabItem(file: file, isSelected: appState.selectedFileID == file.id)
                            .onTapGesture { appState.selectedFileID = file.id }
                    }
                    Spacer()
                }
            }
            .frame(height: 32)
            .background(Color(NSColor.windowBackgroundColor))
            Divider()
            if let file = appState.selectedFile {
                LogContentView(file: file)
            } else {
                Color(NSColor.textBackgroundColor)
            }
        }
    }
}

struct LogTabItem: View {
    @EnvironmentObject var appState: AppState
    let file: LogFile
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.plaintext").font(.caption)
                .foregroundColor(isSelected ? .accentColor : .secondary)
            Text(file.displayName).font(.caption).lineLimit(1)
                .foregroundColor(isSelected ? .primary : .secondary)
            Button { appState.closeFile(file) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary)
            }
            .buttonStyle(.plain).padding(2)
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(isSelected ? Color(NSColor.controlBackgroundColor) : Color.clear)
        .overlay(Rectangle().frame(height: 2)
            .foregroundColor(isSelected ? .accentColor : .clear), alignment: .bottom)
    }
}

// MARK: - 文件内容视图（根据大小选渲染方案）

struct LogContentView: View {
    @EnvironmentObject var searchVM: SearchViewModel
    @ObservedObject var file: LogFile

    var body: some View {
        if file.isLoading {
            VStack(spacing: 12) {
                ProgressView(value: file.loadProgress).progressViewStyle(.circular)
                Text(file.isLargeFile ? "建立行索引… \(file.totalLineCount) 行" :
                                        "加载中… \(Int(file.loadProgress * 100))%")
                    .font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor))
        } else if let error = file.errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                Text("加载失败: \(error)").font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if file.isLargeFile {
            // 大文件：NSTableView 虚拟滚动，按需读取行
            LargeFileTableView(file: file, scrollTarget: searchVM.scrollToLine)
        } else {
            // 小文件：NSTextView（支持多行复制）
            SmallFileTextView(lines: file.lines,
                              fileID: file.id,
                              scrollTarget: searchVM.scrollToLine)
        }
    }
}

// MARK: - 小文件：NSTextView（多行选中复制 + 跳转高亮）

struct SmallFileTextView: NSViewRepresentable {
    let lines: [LogLine]
    let fileID: UUID
    let scrollTarget: ScrollTarget?

    func makeCoordinator() -> SmallCoord { SmallCoord() }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = context.coordinator.textView
        tv.isEditable = false; tv.isSelectable = true; tv.isRichText = true
        tv.drawsBackground = true
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView  = false
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: 1_000_000, height: 1_000_000)
        tv.maxSize = NSSize(width: 1_000_000, height: 1_000_000)
        tv.autoresizingMask = []

        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true; sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true; sv.drawsBackground = true
        context.coordinator.build(lines: lines)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let coord = context.coordinator
        if coord.loadedCount != lines.count { coord.build(lines: lines) }
        if let t = scrollTarget, t.fileID == fileID, t.token != coord.lastToken {
            coord.lastToken = t.token
            let idx = t.lineNumber - 1
            guard idx >= 0 && idx < coord.lineRanges.count else { return }
            DispatchQueue.main.async { coord.jumpAndHighlight(lineIndex: idx) }
        }
    }

    class SmallCoord: NSObject {
        let textView = NSTextView()
        var lineRanges: [NSRange] = []
        var loadedCount = 0
        var lastToken: UUID? = nil

        static let bodyFont  = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        static let gutterFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        func build(lines: [LogLine]) {
            let s = NSMutableAttributedString()
            var ranges: [NSRange] = []
let txtAttrs: [NSAttributedString.Key: Any] = [
                .font: SmallCoord.bodyFont, .foregroundColor: NSColor.textColor]
            for line in lines {
                let start = s.length
                s.append(NSAttributedString(string: (line.text.isEmpty ? "" : line.text) + "\n", attributes: txtAttrs))
                ranges.append(NSRange(location: start, length: s.length - start))
            }
            textView.textStorage?.setAttributedString(s)
            lineRanges = ranges; loadedCount = lines.count
            textView.textStorage?.removeAttribute(.backgroundColor,
                range: NSRange(location: 0, length: s.length))
        }

        func jumpAndHighlight(lineIndex: Int) {
            guard lineIndex < lineRanges.count,
                  let storage = textView.textStorage else { return }
            storage.removeAttribute(.backgroundColor,
                range: NSRange(location: 0, length: storage.length))
            let range = lineRanges[lineIndex]
            let hlRange = NSRange(location: range.location, length: max(0, range.length - 1))
            storage.addAttribute(.backgroundColor,
                value: NSColor.controlAccentColor.withAlphaComponent(0.30), range: hlRange)
            textView.scrollRangeToVisible(range)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self = self,
                      let lm = self.textView.layoutManager,
                      let tc = self.textView.textContainer else { return }
                var gr = NSRange()
                lm.characterRange(forGlyphRange:
                    lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                    actualGlyphRange: &gr)
                let rect = lm.boundingRect(forGlyphRange: gr, in: tc)
                let svH  = self.textView.enclosingScrollView?.contentView.bounds.height ?? 400
                let y    = max(0, rect.midY - svH / 2)
                self.textView.enclosingScrollView?.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
            }
        }
    }
}

// MARK: - 大文件：NSTableView 虚拟滚动（只渲染可见行，按需读磁盘）

struct LargeFileTableView: NSViewRepresentable {
    let file: LogFile
    let scrollTarget: ScrollTarget?

    func makeCoordinator() -> LargeCoord { LargeCoord(file: file) }

    func makeNSView(context: Context) -> NSScrollView {
        let coord = context.coordinator
        let tv = coord.tableView
        tv.style = .plain
        tv.backgroundColor   = NSColor.textBackgroundColor
        tv.intercellSpacing  = .zero
        tv.rowHeight         = 18
        tv.headerView        = nil
        tv.usesAlternatingRowBackgroundColors = false
        tv.selectionHighlightStyle = .regular      // 允许行选中（多行复制）
        tv.allowsMultipleSelection = true
        tv.allowsColumnReordering  = false
        tv.columnAutoresizingStyle = .noColumnAutoresizing

        // 行号列宽度设为 0，不显示
        let gc = NSTableColumn(identifier: .init("g"))
        gc.width = 0; gc.minWidth = 0; gc.maxWidth = 0
        tv.addTableColumn(gc)

        let cc = NSTableColumn(identifier: .init("c"))
        cc.width = 4000; cc.minWidth = 400
        tv.addTableColumn(cc)

        tv.dataSource = coord; tv.delegate = coord

        // 监听滚动，预取下一屏
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true; sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true; sv.drawsBackground = true
        NotificationCenter.default.addObserver(coord,
            selector: #selector(LargeCoord.onScroll(_:)),
            name: NSScrollView.didLiveScrollNotification, object: sv)

        // 覆盖 ⌘C 复制选中行
        coord.setupCopy()

        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let coord = context.coordinator
        let total = file.totalLineCount
        if coord.totalRows != total {
            coord.totalRows = total
            coord.tableView.reloadData()
        }
        if let t = scrollTarget, t.token != coord.lastToken {
            coord.lastToken = t.token
            let row = t.lineNumber - 1
            guard row >= 0 && row < total else { return }
            DispatchQueue.main.async {
                coord.highlightRow = row
                coord.tableView.reloadData()
                coord.tableView.scrollRowToVisible(row)
                // 居中
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard let sv = coord.tableView.enclosingScrollView else { return }
                    let rowRect = coord.tableView.rect(ofRow: row)
                    let svH = sv.contentView.bounds.height
                    let y = max(0, rowRect.midY - svH / 2)
                    sv.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
                }
            }
        }
    }

    // MARK: Large Coordinator
    class LargeCoord: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let tableView  = NSTableView()
        weak var file  : LogFile?
        var totalRows  : Int     = 0
        var highlightRow: Int?   = nil
        var lastToken  : UUID?   = nil

        static let bodyFont   = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        static let gutterFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        init(file: LogFile) {
            self.file = file
            self.totalRows = file.totalLineCount
        }

        func numberOfRows(in tv: NSTableView) -> Int { totalRows }

        func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
            guard let file = file else { return nil }
            let lineNum = row + 1
            let line    = file.lineAt(lineNum)
            let isHL    = (row == highlightRow)

            if col?.identifier == NSUserInterfaceItemIdentifier("g") {
                let id  = NSUserInterfaceItemIdentifier("GC")
                let cell = tv.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? makeField(id: id)
                cell.stringValue     = String(format: "%d", lineNum)
                cell.font            = LargeCoord.gutterFont
                cell.textColor       = .secondaryLabelColor
                cell.alignment       = .right
                cell.backgroundColor = isHL
                    ? NSColor.controlAccentColor.withAlphaComponent(0.30)
                    : NSColor.windowBackgroundColor.withAlphaComponent(0.6)
                cell.drawsBackground = true
                return cell
            } else {
                let id  = NSUserInterfaceItemIdentifier("CC")
                let cell = tv.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? makeField(id: id)
                cell.stringValue     = line.text.isEmpty ? " " : line.text
                cell.font            = LargeCoord.bodyFont
                cell.textColor       = .textColor
                cell.backgroundColor = isHL
                    ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                    : .clear
                cell.drawsBackground = isHL
                return cell
            }
        }

        func tableView(_ tv: NSTableView, heightOfRow row: Int) -> CGFloat { 18 }

        // 滚动时预取前后各 200 行
        @objc func onScroll(_ n: Notification) {
            guard let file = file else { return }
            let mid = tableView.rows(in: tableView.visibleRect).location
            file.prefetch(from: mid - 200, to: mid + 400)
        }

        // ⌘C：把选中行的文本拼起来复制
        func setupCopy() {
            let menu = NSMenu()
            let item = NSMenuItem(title: "复制", action: #selector(copySelected), keyEquivalent: "c")
            item.target = self
            menu.addItem(item)
            tableView.menu = menu
        }

        @objc func copySelected() {
            guard let file = file else { return }
            var texts: [String] = []
            tableView.selectedRowIndexes.forEach { row in
                texts.append(file.lineAt(row + 1).text)
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(texts.joined(separator: "\n"), forType: .string)
        }

        private func makeField(id: NSUserInterfaceItemIdentifier) -> NSTextField {
            let f = NSTextField()
            f.identifier = id; f.isEditable = false; f.isSelectable = false
            f.isBordered = false; f.lineBreakMode = .byClipping
            f.cell?.isScrollable = true; f.cell?.wraps = false
            f.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return f
        }
    }
}
