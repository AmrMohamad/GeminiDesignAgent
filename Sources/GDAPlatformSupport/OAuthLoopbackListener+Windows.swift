#if os(Windows)
import Foundation
import WinSDK

/// Windows Winsock implementation of the same single-use loopback callback
/// contract used on Darwin and Linux. It owns no credentials and never writes
/// the callback URL, authorization code, or query string to disk or logs.
public final class PlatformOAuthCallbackListener: OAuthCallbackListening, @unchecked Sendable {
    private static let winsockReady: Bool = {
        var data = WSADATA()
        return WSAStartup(0x0202, &data) == 0
    }()

    private let socketLock = NSLock()
    private var socketFD: SOCKET
    private let port: UInt16
    private let deadline: Date
    private let callbackPath: String

    public var redirectURI: String { "http://127.0.0.1:\(port)\(callbackPath)" }

    public init(timeoutSeconds: TimeInterval = 300, callbackPath: String = "/oauth/callback") throws {
        self.callbackPath = callbackPath
        guard Self.winsockReady else { throw OAuthError.callbackRejected }
        let fd = WinSDK.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd != INVALID_SOCKET else { throw OAuthError.callbackRejected }
        socketFD = fd
        deadline = Date().addingTimeInterval(timeoutSeconds)

        var address = SOCKADDR_IN()
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_port = 0
        address.sin_addr.S_un.S_addr = "127.0.0.1".withCString { inet_addr($0) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: SOCKADDR.self, capacity: 1) {
                WinSDK.bind(fd, $0, Int32(MemoryLayout<SOCKADDR_IN>.size))
            }
        }
        guard bound != SOCKET_ERROR, WinSDK.listen(fd, 4) != SOCKET_ERROR else {
            closesocket(fd)
            throw OAuthError.callbackRejected
        }

        var resolved = SOCKADDR_IN()
        var length = Int32(MemoryLayout<SOCKADDR_IN>.size)
        let resolvedOK = withUnsafeMutablePointer(to: &resolved) { pointer in
            pointer.withMemoryRebound(to: SOCKADDR.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard resolvedOK != SOCKET_ERROR else {
            closesocket(fd)
            throw OAuthError.callbackRejected
        }
        port = UInt16(bigEndian: resolved.sin_port)
    }

    deinit { close() }

    public func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: OAuthError.callbackRejected)
                    return
                }
                continuation.resume(with: Result { try self.receiveSynchronously() })
            }
        }
    }

    public func close() {
        socketLock.lock()
        let fd = socketFD
        socketFD = INVALID_SOCKET
        socketLock.unlock()
        if fd != INVALID_SOCKET { closesocket(fd) }
    }

    private func receiveSynchronously() throws -> URL {
        while Date() < deadline {
            let fd = currentSocket()
            guard fd != INVALID_SOCKET else { throw OAuthError.callbackRejected }
            var timeout = DWORD(1_000)
            _ = withUnsafePointer(to: &timeout) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<DWORD>.size) {
                    WinSDK.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, Int32(MemoryLayout<DWORD>.size))
                }
            }
            var peer = SOCKADDR_IN()
            var peerLength = Int32(MemoryLayout<SOCKADDR_IN>.size)
            let client = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: SOCKADDR.self, capacity: 1) {
                    WinSDK.accept(fd, $0, &peerLength)
                }
            }
            if client == INVALID_SOCKET { continue }
            defer { closesocket(client) }
            if let callback = readCallback(from: client) { return callback }
        }
        throw OAuthError.callbackTimedOut
    }

    private func currentSocket() -> SOCKET {
        socketLock.lock()
        defer { socketLock.unlock() }
        return socketFD
    }

    private func readCallback(from client: SOCKET) -> URL? {
        var bytes = [UInt8](repeating: 0, count: 8_192)
        let received = bytes.withUnsafeMutableBytes { buffer in
            WinSDK.recv(client, buffer.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(buffer.count), 0)
        }
        guard received > 0, received < bytes.count else {
            writeResponse(to: client, status: "400 Bad Request", body: "Invalid OAuth callback")
            return nil
        }
        let request = String(decoding: bytes.prefix(Int(received)), as: UTF8.self)
        guard request.contains("\r\n\r\n") else {
            writeResponse(to: client, status: "400 Bad Request", body: "Invalid OAuth callback")
            return nil
        }
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix(callbackPath) else {
            writeResponse(to: client, status: "400 Bad Request", body: "Invalid OAuth callback")
            return nil
        }
        let expectedHost = "127.0.0.1:\(port)"
        let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        guard host == expectedHost,
              let callback = URL(string: "http://\(expectedHost)\(parts[1])"),
              callback.hasWellFormedOAuthCallbackParameters else {
            writeResponse(to: client, status: "400 Bad Request", body: "Invalid OAuth callback")
            return nil
        }
        writeResponse(to: client, status: "200 OK", body: "Google authorization received. GDA is finishing sign-in; you may return to the terminal.")
        return callback
    }

    private func writeResponse(to client: SOCKET, status: String, body: String) {
        let bytes = Data("HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        _ = bytes.withUnsafeBytes { buffer in
            WinSDK.send(client, buffer.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(buffer.count), 0)
        }
    }
}
#endif
