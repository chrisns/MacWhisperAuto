import Foundation
import Network
import os

/// WebSocket server accepting connections from the browser extension.
/// Listens on 127.0.0.1:8765 only (NFR13).
final class WebSocketServer: @unchecked Sendable {
    private var listener: NWListener?
    private let port: UInt16 = 8765
    private let serverQueue = DispatchQueue(label: "com.macwhisperauto.websocket.server")

    // Active connections (thread-safe)
    private let _connections = OSAllocatedUnfairLock(initialState: [NWConnection]())

    // Callbacks
    var onMessage: (@Sendable (Data) -> Void)?
    var onClientConnected: (@Sendable () -> Void)?
    var onClientDisconnected: (@Sendable () -> Void)?
    var onError: (@Sendable (ErrorKind) -> Void)?

    func start() {
        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        // Localhost only (NFR13)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(integerLiteral: port)
        )

        do {
            listener = try NWListener(using: params)
        } catch {
            DetectionLogger.shared.error(.webSocket, "Failed to create listener: \(error)")
            onError?(.webSocketPortUnavailable)
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                DetectionLogger.shared.webSocket("WebSocket server listening on 127.0.0.1:\(self?.port ?? 0)")
            case .failed(let error):
                DetectionLogger.shared.error(.webSocket, "Server failed: \(error)")
                self?.onError?(.webSocketPortUnavailable)
            case .cancelled:
                DetectionLogger.shared.webSocket("Server cancelled")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: serverQueue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let conns = _connections.withLock { c -> [NWConnection] in
            let copy = c
            c.removeAll()
            return copy
        }
        for conn in conns {
            conn.cancel()
        }
        DetectionLogger.shared.webSocket("WebSocket server stopped")
    }

    var hasConnections: Bool {
        _connections.withLock { !$0.isEmpty }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        DetectionLogger.shared.webSocket("New WebSocket connection")

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .ready:
                DetectionLogger.shared.webSocket("Client connected")
                self?.onClientConnected?()
                if let connection {
                    self?.receiveMessages(on: connection)
                }
            case .failed(let error):
                DetectionLogger.shared.error(.webSocket, "Connection failed: \(error)")
                if let connection {
                    self?.removeConnection(connection)
                }
                self?.onClientDisconnected?()
            case .cancelled:
                if let connection {
                    self?.removeConnection(connection)
                }
                self?.onClientDisconnected?()
            default:
                break
            }
        }

        _connections.withLock { $0.append(connection) }
        connection.start(queue: serverQueue)
    }

    private func receiveMessages(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, context, isComplete, error in
            if let error {
                DetectionLogger.shared.error(.webSocket, "Receive error: \(error)")
                return
            }

            if let content, !content.isEmpty {
                // Check if this is a WebSocket text message
                if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                    switch metadata.opcode {
                    case .text, .binary:
                        self?.onMessage?(content)
                    case .close:
                        connection?.cancel()
                        return
                    default:
                        break
                    }
                } else {
                    // No WebSocket metadata, treat as raw data
                    self?.onMessage?(content)
                }
            }

            // Continue receiving
            if let connection, connection.state == .ready {
                self?.receiveMessages(on: connection)
            }
        }
    }

    private func removeConnection(_ connection: NWConnection) {
        _connections.withLock { conns in
            conns.removeAll { $0 === connection }
        }
    }
}
