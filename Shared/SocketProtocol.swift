// SocketProtocol.swift — Unix domain socket helpers
// OpenSlap – macOS accelerometer-based slap detection
//
// Provides a thin wrapper around POSIX sockets for newline-delimited JSON
// messaging. We use Unix domain sockets (AF_UNIX) instead of XPC because:
//   1. No special code-signing / entitlement requirements for open-source builds
//   2. Easy to test with standard tools (socat, nc -U)
//   3. Works reliably across privilege boundaries (root daemon ↔ user app)

import Foundation

// MARK: - Socket Server (used by daemon)

/// A minimal Unix domain socket server that accepts one client at a time.
/// The daemon creates this to listen for the app's connection.
final class SocketServer: @unchecked Sendable {
    private let path: String
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.openslap.socket-server")
    private var listenSource: DispatchSourceRead?

    /// Called on the server queue when a complete JSON line arrives from the client.
    var onMessage: ((SocketMessage) -> Void)?

    /// Called when the client connects or disconnects.
    var onClientChange: ((Bool) -> Void)?

    init(path: String = OpenSlapConstants.socketPath) {
        self.path = path
    }

    deinit {
        stop()
    }

    /// Start listening. Removes any stale socket file first.
    func start() throws {
        // Clean up stale socket from a previous crash
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw SocketError.createFailed(errno: errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy the path into the sun_path fixed-size tuple.
        // withCString + withUnsafeMutablePointer lets us memcpy safely.
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw SocketError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(listenFD, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            throw SocketError.bindFailed(errno: errno)
        }

        // Allow the app user to connect to the root-owned socket
        chmod(path, 0o666)

        guard listen(listenFD, 1) == 0 else {
            throw SocketError.listenFailed(errno: errno)
        }

        // Use GCD to accept connections without blocking the run loop
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.listenFD, fd >= 0 { close(fd) }
        }
        source.resume()
        listenSource = source
    }

    /// Send a message to the connected client. No-op if nobody is connected.
    func send(_ message: SocketMessage) {
        queue.async { [weak self] in
            guard let self, self.clientFD >= 0 else { return }
            do {
                let data = try message.serialized()
                data.withUnsafeBytes { buffer in
                    _ = Darwin.send(self.clientFD, buffer.baseAddress!, buffer.count, 0)
                }
            } catch {
                // Serialization failure is a programming error, log and continue
                print("[OpenSlapDaemon] Failed to serialize message: \(error)")
            }
        }
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
        queue.sync {
            if clientFD >= 0 { close(clientFD); clientFD = -1 }
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
        }
        unlink(path)
    }

    // MARK: - Private

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }

        // Close any existing client (single-client model)
        if clientFD >= 0 { close(clientFD) }
        clientFD = fd
        onClientChange?(true)

        // Read loop for incoming messages from the app
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.readFromClient()
        }
        readSource.setCancelHandler { [weak self] in
            close(fd)
            self?.clientFD = -1
            self?.onClientChange?(false)
        }
        readSource.resume()
    }

    private var readBuffer = Data()

    private func readFromClient() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(clientFD, &buf, buf.count, 0)
        guard n > 0 else {
            // Client disconnected
            if clientFD >= 0 { close(clientFD); clientFD = -1 }
            onClientChange?(false)
            return
        }

        readBuffer.append(contentsOf: buf[..<n])

        // Split on newlines and parse each complete line
        while let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer[readBuffer.startIndex..<newlineIndex]
            readBuffer = Data(readBuffer[(newlineIndex + 1)...])

            guard !lineData.isEmpty else { continue }
            do {
                let message = try SocketMessage.deserialize(from: Data(lineData))
                onMessage?(message)
            } catch {
                print("[OpenSlapDaemon] Failed to parse client message: \(error)")
            }
        }
    }
}

// MARK: - Socket Client (used by app)

/// Connects to the daemon's Unix domain socket and streams incoming messages.
final class SocketClient: @unchecked Sendable {
    private let path: String
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "com.openslap.socket-client")
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()
    private var reconnectTimer: DispatchSourceTimer?

    /// Called on the client queue when a message arrives from the daemon.
    var onMessage: ((SocketMessage) -> Void)?

    /// Called when connection state changes.
    var onConnectionChange: ((Bool) -> Void)?

    init(path: String = OpenSlapConstants.socketPath) {
        self.path = path
    }

    deinit {
        disconnect()
    }

    /// Attempt to connect. If the daemon isn't running yet, retries every 2 seconds.
    func connect() {
        queue.async { [weak self] in
            self?.attemptConnect()
        }
    }

    /// Send a message to the daemon.
    func send(_ message: SocketMessage) {
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            do {
                let data = try message.serialized()
                data.withUnsafeBytes { buffer in
                    _ = Darwin.send(self.fd, buffer.baseAddress!, buffer.count, 0)
                }
            } catch {
                print("[OpenSlap] Failed to serialize message: \(error)")
            }
        }
    }

    func disconnect() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
        readSource?.cancel()
        readSource = nil
        queue.sync {
            if fd >= 0 { close(fd); fd = -1 }
        }
    }

    // MARK: - Private

    private func attemptConnect() {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { scheduleReconnect(); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, addrLen)
            }
        }

        guard result == 0 else {
            close(fd); fd = -1
            scheduleReconnect()
            return
        }

        onConnectionChange?(true)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readFromServer() }
        source.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
            self?.onConnectionChange?(false)
        }
        source.resume()
        readSource = source
    }

    private func readFromServer() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else {
            // Server disconnected
            readSource?.cancel()
            readSource = nil
            onConnectionChange?(false)
            scheduleReconnect()
            return
        }

        readBuffer.append(contentsOf: buf[..<n])

        while let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer[readBuffer.startIndex..<newlineIndex]
            readBuffer = Data(readBuffer[(newlineIndex + 1)...])
            guard !lineData.isEmpty else { continue }
            do {
                let message = try SocketMessage.deserialize(from: Data(lineData))
                onMessage?(message)
            } catch {
                print("[OpenSlap] Failed to parse daemon message: \(error)")
            }
        }
    }

    private func scheduleReconnect() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2.0)
        timer.setEventHandler { [weak self] in
            self?.reconnectTimer = nil
            self?.attemptConnect()
        }
        timer.resume()
        reconnectTimer = timer
    }
}

// MARK: - Errors

enum SocketError: Error, LocalizedError {
    case createFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case connectFailed(errno: Int32)
    case pathTooLong

    var errorDescription: String? {
        switch self {
        case .createFailed(let e):  return "Socket creation failed: \(String(cString: strerror(e)))"
        case .bindFailed(let e):    return "Socket bind failed: \(String(cString: strerror(e)))"
        case .listenFailed(let e):  return "Socket listen failed: \(String(cString: strerror(e)))"
        case .connectFailed(let e): return "Socket connect failed: \(String(cString: strerror(e)))"
        case .pathTooLong:          return "Socket path exceeds maximum length"
        }
    }
}
