import SwiftUI
import Combine

class AppState: ObservableObject {
    @Published var openedFiles: [LogFile] = []
    @Published var selectedFileID: UUID?
    @Published var searchSessions: [SearchSession] = []
    @Published var isSearchPanelVisible: Bool = true
    @Published var searchPanelHeight: CGFloat = 250

    // 已授权访问的文件夹，持有 security scope
    private var accessedFolderURLs: [URL] = []

    var selectedFile: LogFile? {
        openedFiles.first { $0.id == selectedFileID }
    }

    // MARK: - 打开文件
    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.plainText, .log, .data, .item]
        panel.title = "打开日志文件"
        if panel.runModal() == .OK {
            for url in panel.urls { openFile(url: url) }
        }
    }

    // MARK: - 打开文件夹：加载其中所有文本文件
    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.title = "打开日志文件夹"
        panel.prompt = "打开"
        if panel.runModal() == .OK, let url = panel.url {
            openFolder(url: url)
        }
    }

    func openFolder(url: URL) {
        retainFolderAccess(url)

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var count = 0
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            // 跳过超大二进制文件（>500MB）和常见非文本后缀
            let ext = fileURL.pathExtension.lowercased()
            let skip = ["png","jpg","jpeg","gif","pdf","zip","gz","tar","dmg","pkg","app","dylib","so","o","a"]
            if skip.contains(ext) { continue }
            openFile(url: fileURL)
            count += 1
            if count >= 200 { break } // 单次最多打开200个文件防止卡死
        }
    }

    func openFile(url: URL) {
        if openedFiles.contains(where: { $0.url == url }) {
            selectedFileID = openedFiles.first(where: { $0.url == url })?.id
            return
        }
        let logFile = LogFile(url: url)
        openedFiles.append(logFile)
        selectedFileID = logFile.id
    }

    func closeFile(_ file: LogFile) {
        if let idx = openedFiles.firstIndex(where: { $0.id == file.id }) {
            openedFiles.remove(at: idx)
            if selectedFileID == file.id {
                selectedFileID = openedFiles.first?.id
            }
        }
    }

    func addSearchSession(_ session: SearchSession) {
        for s in searchSessions { s.isExpanded = false }
        searchSessions.append(session)
        isSearchPanelVisible = true
    }

    func retainFolderAccess(_ url: URL) {
        guard !accessedFolderURLs.contains(url) else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        if accessed { accessedFolderURLs.append(url) }
    }

    deinit {
        for url in accessedFolderURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
