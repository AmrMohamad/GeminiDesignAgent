#if os(Linux)
import Foundation
import Glibc

/// Linux implementation of the OAuth loopback listener. Secret Service is
/// still required for persistence; this adapter is intentionally limited to
/// the local IPv4 loopback interface and a single callback.
public final class PlatformOAuthCallbackListener: OAuthCallbackListening, @unchecked Sendable {
    private let socketLock = NSLock()
    private var socketFD: Int32
    private let port: UInt16
    private let deadline: Date
    private let callbackPath: String

    public var redirectURI: String { "http://127.0.0.1:\(port)\(callbackPath)" }

    public init(timeoutSeconds: TimeInterval = 300, callbackPath: String = "/oauth/callback") throws {
        self.callbackPath = callbackPath
        let fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw OAuthError.callbackRejected }
        socketFD = fd
        deadline = Date().addingTimeInterval(timeoutSeconds)

        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Glibc.listen(fd, 4) == 0 else {
            Glibc.close(fd)
            throw OAuthError.callbackRejected
        }

        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolvedOK = withUnsafeMutablePointer(to: &resolved) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard resolvedOK == 0 else {
            Glibc.close(fd)
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
        socketFD = -1
        socketLock.unlock()
        if fd >= 0 { Glibc.close(fd) }
    }

    private func receiveSynchronously() throws -> URL {
        while Date() < deadline {
            let fd = currentSocket()
            guard fd >= 0 else { throw OAuthError.callbackRejected }
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var peer = sockaddr_in()
            var peerLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Glibc.accept(fd, $0, &peerLength)
                }
            }
            if client < 0 { continue }
            defer { Glibc.close(client) }
            if let callback = readCallback(from: client) { return callback }
        }
        throw OAuthError.callbackTimedOut
    }

    private func currentSocket() -> Int32 {
        socketLock.lock()
        defer { socketLock.unlock() }
        return socketFD
    }

    private func readCallback(from client: Int32) -> URL? {
        var bytes = [UInt8](repeating: 0, count: 8_192)
        let received = bytes.withUnsafeMutableBytes { buffer in
            Glibc.recv(client, buffer.baseAddress, buffer.count, 0)
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

    private func writeResponse(to client: Int32, status: String, body: String) {
        let bytes = Data("HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        _ = bytes.withUnsafeBytes { buffer in Glibc.send(client, buffer.baseAddress, buffer.count, 0) }
    }
}
#endif
