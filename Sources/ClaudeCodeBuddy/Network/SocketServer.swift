import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - SocketServer

/// A simple Unix Domain Socket server that listens for newline-delimited JSON
/// messages from Claude Code hook scripts.
class SocketServer {

    // MARK: - Properties

    static let socketPath = "/tmp/claude-buddy.sock"

    /// Called on the main queue whenever a valid HookMessage arrives.
    var onMessage: ((HookMessage) -> Void)?

    private var serverFD: Int32 = -1
    private var serverSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var clientBuffers: [Int32: Data] = [:]
    private let queue = DispatchQueue(label: "com.claudebuddy.socket", qos: .utility)

    // MARK: - Start / Stop

    func start() {
        queue.async { [weak self] in
            self?.setupServer()
        }
    }

    func stop() {
        queue.sync {
            serverSource?.cancel()
            serverSource = nil
            for (_, source) in clientSources {
                source.cancel()
            }
            clientSources.removeAll()
            clientBuffers.removeAll()
            // serverFD and client FDs are closed by their respective cancel handlers
            serverFD = -1
        }
    }

    deinit {
        stop()
    }

    // MARK: - Private Setup

    private func setupServer() {
        NSLog("[SocketServer] setupServer() called")
        // Remove stale socket file so bind doesn't fail after a crash
        unlink(SocketServer.socketPath)

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("[SocketServer] socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        // Allow address reuse
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = SocketServer.socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { charPtr in
                for (i, byte) in pathBytes.enumerated() {
                    charPtr[i] = byte
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            print("[SocketServer] bind() failed: \(String(cString: strerror(errno)))")
            Darwin.close(fd)
            return
        }

        // Listen
        guard listen(fd, 8) == 0 else {
            print("[SocketServer] listen() failed: \(String(cString: strerror(errno)))")
            Darwin.close(fd)
            return
        }

        serverFD = fd
        NSLog("[SocketServer] Listening on %@", SocketServer.socketPath)

        // Accept loop via DispatchSource
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        source.setCancelHandler {
            Darwin.close(fd)
            unlink(SocketServer.socketPath)
        }
        source.resume()
        serverSource = source
    }

    // MARK: - Accept

    private func acceptClient() {
        var clientAddr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(serverFD, sockPtr, &addrLen)
            }
        }

        guard clientFD >= 0 else {
            print("[SocketServer] accept() failed: \(String(cString: strerror(errno)))")
            return
        }

        NSLog("[SocketServer] Accepted client fd=%d", clientFD)
        clientBuffers[clientFD] = Data()

        let clientSource = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        clientSource.setEventHandler { [weak self] in
            self?.readFromClient(fd: clientFD)
        }
        clientSource.setCancelHandler { [weak self] in
            Darwin.close(clientFD)
            self?.clientBuffers.removeValue(forKey: clientFD)
        }
        clientSource.resume()
        clientSources[clientFD] = clientSource
    }

    // MARK: - Read

    private func readFromClient(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)

        if n <= 0 {
            NSLog("[SocketServer] Client fd=%d EOF/error, n=%d", fd, n)
            // EOF or error — flush remaining buffer then close client
            if let remaining = clientBuffers[fd], !remaining.isEmpty {
                NSLog("[SocketServer] Flushing buffer (%d bytes) for fd=%d", remaining.count, fd)
                handleLine(remaining)
            }
            clientSources[fd]?.cancel()
            clientSources.removeValue(forKey: fd)
            return
        }

        clientBuffers[fd]?.append(contentsOf: buf[0..<n])

        // Process all complete lines
        while let data = clientBuffers[fd],
              let newlineIdx = data.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = data[data.startIndex..<newlineIdx]
            clientBuffers[fd] = Data(data[(data.index(after: newlineIdx))...])
            handleLine(Data(lineData))
        }
    }

    // MARK: - Message Parsing

    private func handleLine(_ data: Data) {
        guard !data.isEmpty else { return }
        do {
            let msg = try JSONDecoder().decode(HookMessage.self, from: data)
            NSLog("[SocketServer] Decoded message: event=%@, session=%@", "\(msg.event)", msg.sessionId)
            DispatchQueue.main.async { [weak self] in
                self?.onMessage?(msg)
            }
        } catch {
            if let raw = String(data: data, encoding: .utf8) {
                NSLog("[SocketServer] JSON decode error: %@ — raw: %@", "\(error)", raw)
            }
        }
    }
}
