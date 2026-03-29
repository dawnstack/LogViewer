import SwiftUI
import Combine
import os

// MARK: - 行索引（只存偏移，不存文本）
// 每条 16 字节，1000 万行 = 160 MB，可接受
struct LineIndex {
    let byteOffset: Int64   // 行在文件中的起始字节位置
    let byteLength: Int32   // 行字节长度（不含 \n / \r\n）
}

// MARK: - 显示行（按需读取后短暂缓存）
struct LogLine: Identifiable {
    let id: Int             // = lineNumber，避免 UUID 开销
    let lineNumber: Int
    let text: String
}

// MARK: - LRU 行缓存
// 容量固定 2000 行，足够虚拟滚动需要；超出时淘汰最旧的
private class LineCache {
    private let capacity: Int
    private var cache:  [Int: String] = [:]   // lineNumber -> text
    private var order:  [Int] = []            // 访问顺序（末尾最新）

    init(capacity: Int = 2000) { self.capacity = capacity }

    func get(_ line: Int) -> String? { cache[line] }

    func set(_ line: Int, text: String) {
        if cache[line] != nil {
            order.removeAll { $0 == line }
        } else if order.count >= capacity {
            let evict = order.removeFirst()
            cache.removeValue(forKey: evict)
        }
        cache[line] = text
        order.append(line)
    }

    func clear() { cache.removeAll(); order.removeAll() }
}

// MARK: - LogFile
class LogFile: ObservableObject, Identifiable, Equatable {
    private let logger = Logger(subsystem: "com.logviewer.app", category: "LogFileLoad")
    let id   = UUID()
    let url  : URL
    var displayName: String { url.lastPathComponent }

    // ── 小文件（≤ LARGE_THRESHOLD）：全部存 lines ──────────────────
    @Published var lines: [LogLine] = []

    // ── 大文件：只存索引，通过 lineAt() 按需读取 ──────────────────
    @Published var isLargeFile   : Bool   = false
    @Published var isLoading     : Bool   = true
    @Published var loadProgress  : Double = 0
    @Published var totalLineCount: Int    = 0
    @Published var errorMessage  : String?

    // 大文件专用
    private var lineIndexes : [LineIndex] = []
    private var fileHandle  : FileHandle? = nil
    private let cache       = LineCache(capacity: 2000)
    private let ioQueue     = DispatchQueue(label: "logfile.io", qos: .userInitiated)
    private let ioQueueKey  = DispatchSpecificKey<Void>()

    private var loadTask: Task<Void, Never>?

    /// 大文件阈值：降低到 1 MB，避免高行数文件落入 NSTextView 路径后跳转不稳定
    static let largeThreshold: Int = 1 * 1024 * 1024

    init(url: URL) {
        self.url = url
        ioQueue.setSpecific(key: ioQueueKey, value: ())
        startLoading()
    }

    static func == (lhs: LogFile, rhs: LogFile) -> Bool { lhs.id == rhs.id }

    deinit {
        loadTask?.cancel()
        try? fileHandle?.close()
    }

    // MARK: - 公开接口

    /// 按行号读取行文本（1-based）。小文件直接查数组，大文件走缓存/磁盘
    func lineAt(_ lineNumber: Int) -> LogLine {
        if !isLargeFile {
            guard lineNumber >= 1 && lineNumber <= lines.count else {
                return LogLine(id: lineNumber, lineNumber: lineNumber, text: "")
            }
            return lines[lineNumber - 1]
        }
        if DispatchQueue.getSpecific(key: ioQueueKey) != nil {
            return lineAtLargeFile(lineNumber)
        }
        return ioQueue.sync {
            lineAtLargeFile(lineNumber)
        }
    }

    /// 预热缓存：提前加载 [from, to] 范围的行（供虚拟滚动提前请求）
    func prefetch(from: Int, to: Int) {
        guard isLargeFile else { return }
        let lo = max(1, from)
        let hi = min(totalLineCount, to)
        guard lo <= hi else { return }
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            for n in lo...hi {
                let idx = n - 1
                guard idx < self.lineIndexes.count else { break }
                if self.cache.get(n) == nil {
                    let text = self.readLineFromDisk(index: self.lineIndexes[idx])
                    self.cache.set(n, text: text)
                }
            }
        }
    }

    // MARK: - 搜索接口（兼容 SearchEngine）
    // 小文件：直接搜 lines
    // 大文件：分块流式搜索，边读边返回，不全加载
    func searchStream(keyword: String, ignoreCase: Bool,
                      onBatch: @escaping ([SearchResult]) -> Void,
                      onComplete: @escaping () -> Void = {}) {
        let opts: String.CompareOptions = ignoreCase ? [.caseInsensitive] : []
        let fileURL = self.url

        if !isLargeFile {
            var batch: [SearchResult] = []
            for line in lines {
                if line.text.range(of: keyword, options: opts) != nil {
                    batch.append(SearchResult(fileURL: fileURL,
                                              lineNumber: line.lineNumber,
                                              lineText: line.text))
                }
            }
            if !batch.isEmpty { onBatch(batch) }
            onComplete()
            return
        }

        // 大文件：先嗅探二进制（检查前 8KB 是否含 NULL 字节）
        if let sniff = try? FileHandle(forReadingFrom: url) {
            let sample = sniff.readData(ofLength: 8192)
            try? sniff.close()
            if sample.contains(0x00) {
                onComplete()
                return
            }
        }

        // 大文件：分块读取搜索，每 1000 条回调一次
        ioQueue.async { [weak self] in
            guard let self = self,
                  let fh = try? FileHandle(forReadingFrom: self.url) else {
                onComplete()
                return
            }
            defer { try? fh.close() }
            defer { onComplete() }

            var batch: [SearchResult] = []
            let batchSize = 1000
            for (i, idx) in self.lineIndexes.enumerated() {
                let text = self.readLineFromDisk(index: idx, handle: fh)
                if text.range(of: keyword, options: opts) != nil {
                    batch.append(SearchResult(fileURL: fileURL,
                                              lineNumber: i + 1,
                                              lineText: text))
                    if batch.count >= batchSize {
                        let out = batch; batch = []
                        onBatch(out)
                    }
                }
            }
            if !batch.isEmpty { onBatch(batch) }
        }
    }

    // MARK: - 加载

    func startLoading() {
        loadTask?.cancel()
        loadTask = Task { await self.doLoad() }
    }

    private func doLoad() async {
        await MainActor.run {
            isLoading = true; lines = []; errorMessage = nil
            lineIndexes = []; isLargeFile = false
        }
        do {
            let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            logger.info("Load start file=\(self.url.path, privacy: .public) size=\(fileSize)")
            if fileSize > Self.largeThreshold {
                await buildIndex(fileSize: Int64(fileSize))
            } else {
                await loadSmall()
            }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
        logger.info("Load finished file=\(self.url.path, privacy: .public) large=\(self.isLargeFile) totalLines=\(self.totalLineCount)")
        await MainActor.run { isLoading = false }
    }

    // 小文件：全部读入 lines
    private func loadSmall() async {
        await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let content = (try? String(contentsOf: self.url, encoding: .utf8))
                       ?? (try? String(contentsOf: self.url, encoding: .isoLatin1))
                       ?? ""
            let raw = content.components(separatedBy: .newlines)
            var result: [LogLine] = []
            result.reserveCapacity(raw.count)
            for (i, t) in raw.enumerated() {
                result.append(LogLine(id: i + 1, lineNumber: i + 1, text: t))
            }
            await MainActor.run {
                self.lines          = result
                self.totalLineCount = result.count
                self.loadProgress   = 1.0
            }
        }.value
    }

    // 大文件：只扫偏移，建行索引
    private func buildIndex(fileSize: Int64) async {
        await MainActor.run { isLargeFile = true }

        await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self,
                  let fh = try? FileHandle(forReadingFrom: self.url) else { return }
            defer { try? fh.close() }

            var indexes  : [LineIndex] = []
            indexes.reserveCapacity(500_000)

            let chunkSize = 4 * 1024 * 1024   // 4 MB 读取块
            var buffer   = Data()
            var offset   : Int64 = 0
            var bytesRead: Int64 = 0

            while true {
                let chunk = fh.readData(ofLength: chunkSize)
                if chunk.isEmpty { break }
                bytesRead += Int64(chunk.count)
                buffer.append(chunk)

                // 扫描 \n，记录每行偏移
                var lineStart = 0
                for i in 0..<buffer.count {
                    if buffer[i] == 0x0A {  // \n
                        // 去掉末尾 \r（Windows 换行）
                        let len = (i > lineStart && buffer[i-1] == 0x0D)
                            ? i - lineStart - 1 : i - lineStart
                        indexes.append(LineIndex(
                            byteOffset: offset + Int64(lineStart),
                            byteLength: Int32(len)
                        ))
                        lineStart = i + 1
                    }
                }
                offset += Int64(lineStart)
                buffer  = Data(buffer[lineStart...])

                let progress = Double(bytesRead) / Double(fileSize)
                if indexes.count % 50_000 == 0 {
                    let snap = indexes.count
                    await MainActor.run {
                        self.loadProgress   = progress
                        self.totalLineCount = snap
                    }
                }
                if Task.isCancelled { return }
            }

            // 最后一行（无 \n 结尾）
            if !buffer.isEmpty {
                indexes.append(LineIndex(
                    byteOffset: offset,
                    byteLength: Int32(buffer.count)
                ))
            }

            // 保留 fileHandle 供后续按需读取
            let keepHandle = try? FileHandle(forReadingFrom: self.url)
            let total      = indexes.count
            await MainActor.run {
                self.lineIndexes    = indexes
                self.fileHandle     = keepHandle
                self.totalLineCount = total
                self.loadProgress   = 1.0
            }
        }.value
    }

    // MARK: - 磁盘读取（内部）

    private func lineAtLargeFile(_ lineNumber: Int) -> LogLine {
        let idx = lineNumber - 1
        guard idx >= 0 && idx < lineIndexes.count else {
            return LogLine(id: lineNumber, lineNumber: lineNumber, text: "")
        }
        if let cached = cache.get(lineNumber) {
            return LogLine(id: lineNumber, lineNumber: lineNumber, text: cached)
        }
        let text = readLineFromDisk(index: lineIndexes[idx])
        cache.set(lineNumber, text: text)
        return LogLine(id: lineNumber, lineNumber: lineNumber, text: text)
    }

    private func readLineFromDisk(index: LineIndex) -> String {
        guard let fh = fileHandle else { return "" }
        return readLineFromDisk(index: index, handle: fh)
    }

    private func readLineFromDisk(index: LineIndex, handle: FileHandle) -> String {
        guard index.byteLength > 0 else { return "" }
        do {
            try handle.seek(toOffset: UInt64(index.byteOffset))
            let data = handle.readData(ofLength: Int(index.byteLength))
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
        } catch {
            return ""
        }
    }
}
