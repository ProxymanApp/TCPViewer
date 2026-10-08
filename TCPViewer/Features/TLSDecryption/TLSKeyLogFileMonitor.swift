//
//  TLSKeyLogFileMonitor.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 6/10/26.
//

import Foundation

// Follows one key log file and reports the complete lines appended to it, so a running capture can
// decrypt connections that start after the capture did. Work is bounded by what was appended, never
// by the size of the file.
final class TLSKeyLogFileMonitor {
    static let maximumReadBytes = 1024 * 1024

    private let url: URL
    private let queue: DispatchQueue
    private let appendHandler: (Data) -> Void
    private let resetHandler: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64

    // `queue` serialises all reads and both handlers. `startOffset` is where the caller's own read
    // of the file ended, so nothing is delivered twice.
    init(
        url: URL,
        startOffset: UInt64,
        queue: DispatchQueue,
        appendHandler: @escaping (Data) -> Void,
        resetHandler: @escaping () -> Void
    ) {
        self.url = url
        self.offset = startOffset
        self.queue = queue
        self.appendHandler = appendHandler
        self.resetHandler = resetHandler
    }

    deinit {
        source?.cancel()
    }

    // Begin watching. Dropping the monitor is what stops it.
    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    private func startOnQueue() {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            // Truncation only shows up as an attribute change, never as a write.
            eventMask: [.extend, .write, .attrib, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.handleEvent()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
        // Lines can land between the caller's read and the moment the source starts listening.
        readAppendedLines()
    }

    private func stop() {
        source?.cancel()
        source = nil
    }

    private func handleEvent() {
        guard let source else {
            return
        }
        // Editors and log rotation replace the file, which leaves this descriptor on the old one.
        if !source.data.intersection([.delete, .rename]).isEmpty {
            stop()
            resetHandler()
            return
        }
        readAppendedLines()
    }

    // Deliver bytes up to the last newline; a line still being written waits for its ending.
    private func readAppendedLines() {
        guard source != nil, let handle = try? FileHandle(forReadingFrom: url) else {
            return
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size != offset else {
            return
        }
        // A shorter file was truncated or rewritten, so the offset no longer means anything.
        guard size > offset else {
            stop()
            resetHandler()
            return
        }

        let readLength = Int(min(size - offset, UInt64(Self.maximumReadBytes)))
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: readLength),
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            return
        }
        let completeLines = data[...lastNewline]
        offset += UInt64(completeLines.count)
        appendHandler(Data(completeLines))

        // A burst larger than one read continues on the next pass instead of holding the queue.
        if size > offset, completeLines.count == data.count {
            queue.async { [weak self] in
                self?.readAppendedLines()
            }
        }
    }
}
