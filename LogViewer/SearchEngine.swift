import SwiftUI
import Combine

// MARK: - Models

enum SearchScope {
    case currentFile
    case allOpenFiles
    case folder(URL)

    var label: String {
        switch self {
        case .currentFile:     return "当前文件"
        case .allOpenFiles:    return "所有打开文件"
        case .folder(let url): return "文件夹: \(url.lastPathComponent)"
        }
    }
}

enum SearchDirection { case down, up }

struct SearchOptions {
    var keyword  : String          = ""
    var ignoreCase: Bool           = true
    var direction : SearchDirection = .down
    var scope     : SearchScope    = .currentFile
}

struct SearchResult: Identifiable {
    let id         = UUID()
    let fileURL    : URL
    let lineNumber : Int
    let lineText   : String
}

struct FileSearchResult: Identifiable {
    let id      = UUID()
    let fileURL : URL
    var results : [SearchResult]
    var isExpanded: Bool = true
}

class SearchSession: Identifiable, ObservableObject {
    let id        = UUID()
    let keyword   : String
    let timestamp : Date
    let options   : SearchOptions
    @Published var fileResults: [FileSearchResult] = []
    @Published var isExpanded : Bool  = true
    @Published var isSearching: Bool  = true
    @Published var totalCount : Int   = 0
    @Published var fileCount  : Int   = 0

    var displayTitle: String {
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
        return "\"\(keyword)\"  [\(fmt.string(from: timestamp))]"
    }

    init(keyword: String, options: SearchOptions) {
        self.keyword = keyword; self.options = options; self.timestamp = Date()
    }
}

// MARK: - SearchEngine
// 小文件：并发内存搜索
// 大文件：调用 LogFile.searchStream 分块流式搜索，不全加载

class SearchEngine {
    static let shared = SearchEngine()

    // 搜索已打开的文件列表
    func search(options: SearchOptions, files: [LogFile]) async -> SearchSession {
        let session = SearchSession(keyword: options.keyword, options: options)

        await withTaskGroup(of: Void.self) { group in
            for file in files {
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    await self.searchOneFile(file, options: options, session: session)
                }
            }
        }

        await MainActor.run { session.isSearching = false }
        return session
    }

    // 搜索文件夹
    func searchFolder(_ folderURL: URL, options: SearchOptions) async -> SearchSession {
        let session = SearchSession(keyword: options.keyword, options: options)
        let fm = FileManager.default

        let accessed = folderURL.startAccessingSecurityScopedResource()
        defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }

        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            await MainActor.run { session.isSearching = false }
            return session
        }

        let skipExts: Set<String> = [
            // 图片
            "png","jpg","jpeg","gif","bmp","tiff","tif","webp","ico","heic","heif","svg",
            // 文档/压缩
            "pdf","zip","gz","tar","bz2","xz","7z","rar","dmg","pkg","iso",
            // 二进制/编译产物
            "app","dylib","so","o","a","framework","xcarchive","dSYM",
            "class","jar","war","ear","pyc","pyd",
            // 媒体
            "mp3","mp4","mov","avi","mkv","flv","wav","aac","m4a","m4v",
            // 字体/数据库
            "ttf","otf","woff","woff2","eot","sqlite","db","sqlite3",
            // 其他二进制
            "exe","dll","bin","dat","img","vmdk","ipa","apk",
            // Xcode
            "xcassets","car","nib","storyboard","xib","strings",
        ]
        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true
            else { continue }
            if skipExts.contains(url.pathExtension.lowercased()) { continue }
            urls.append(url)
        }

        // 100个小文件场景：16并发跑6轮，IO/CPU均衡
        let concurrency = 16
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for url in urls {
                if running >= concurrency {
                    await group.next()
                    running -= 1
                }
                group.addTask {
                    await self.searchFileURL(url, options: options, session: session)
                }
                running += 1
            }
            for await _ in group {}
        }

        await MainActor.run { session.isSearching = false }
        return session
    }

    // MARK: - 私有方法

    // 搜索一个已打开的 LogFile（大文件走流式）
    private func searchOneFile(_ file: LogFile,
                                options: SearchOptions,
                                session: SearchSession) async {
        let fileURL = file.url
        var allResults: [SearchResult] = []

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            file.searchStream(keyword: options.keyword, ignoreCase: options.ignoreCase) { batch in
                allResults.append(contentsOf: batch)
            } onComplete: {
                cont.resume()
            }
        }

        guard !allResults.isEmpty else { return }
        let fr = FileSearchResult(fileURL: fileURL, results: allResults)
        await MainActor.run {
            session.fileResults.append(fr)
            session.totalCount += allResults.count
            session.fileCount  += 1
        }
    }

    // 检测文件是否为二进制：读取前 8KB，检查是否含 NULL 字节（rg 的经典算法）
    private func isBinaryFile(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? fh.close() }
        let sample = fh.readData(ofLength: 8192)
        guard !sample.isEmpty else { return false }
        // 含 NULL 字节 (0x00) → 二进制
        return sample.contains(0x00)
    }

    // 搜索文件夹中的单个 URL（直接流式读，不创建 LogFile 对象）
    private func searchFileURL(_ url: URL,
                                options: SearchOptions,
                                session: SearchSession) async {
        // 先嗅探二进制，跳过
        guard !isBinaryFile(url) else { return }

        let opts: String.CompareOptions = options.ignoreCase ? [.caseInsensitive] : []

        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }

        var results  : [SearchResult] = []
        var buffer   = Data()
        var lineNum  = 1
        let chunkSize = 1024 * 1024  // 1 MB

        func processBuffer(flush: Bool) {
            while true {
                guard let nlRange = buffer.range(of: Data([0x0A])) else {
                    if flush && !buffer.isEmpty {
                        // 最后一行
                        let text = String(data: buffer, encoding: .utf8)
                                ?? String(data: buffer, encoding: .isoLatin1) ?? ""
                        if text.range(of: options.keyword, options: opts) != nil {
                            results.append(SearchResult(fileURL: url, lineNumber: lineNum, lineText: text))
                        }
                        buffer.removeAll()
                    }
                    break
                }
                var lineData = buffer.subdata(in: buffer.startIndex..<nlRange.lowerBound)
                // 去掉 \r
                if lineData.last == 0x0D { lineData.removeLast() }
                let text = String(data: lineData, encoding: .utf8)
                        ?? String(data: lineData, encoding: .isoLatin1) ?? ""
                if text.range(of: options.keyword, options: opts) != nil {
                    results.append(SearchResult(fileURL: url, lineNumber: lineNum, lineText: text))
                }
                lineNum += 1
                buffer.removeSubrange(buffer.startIndex...nlRange.lowerBound)
            }
        }

        while true {
            let chunk = fh.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            processBuffer(flush: false)
        }
        processBuffer(flush: true)

        guard !results.isEmpty else { return }
        let fr = FileSearchResult(fileURL: url, results: results)
        await MainActor.run {
            session.fileResults.append(fr)
            session.totalCount += results.count
            session.fileCount  += 1
        }
    }
}
