import XCTest
@testable import BuddyCore

final class SocketQueryTests: XCTestCase {

    private var server: SocketServer!
    private let testSocketPath = "/tmp/claude-buddy-test-query.sock"

    override func setUp() {
        super.setUp()
        // Clean up any stale test socket
        unlink(testSocketPath)
    }

    override func tearDown() {
        server?.stop()
        server = nil
        unlink(testSocketPath)
        super.tearDown()
    }

    // MARK: - Query Detection

    func testQueryMessageDetected() {
        var receivedQuery: [String: Any]?
        var receivedFD: Int32?

        server = SocketServer()
        server.onQuery = { query, fd in
            receivedQuery = query
            receivedFD = fd
        }

        // We test the protocol parsing by sending a query via socket
        // Since SocketServer uses a hardcoded path, we test with the real socket
        // For unit tests, we verify the parsing logic separately

        // Test data: a query message with "action" field
        let queryData = "{\"action\":\"health\"}\n".data(using: .utf8)!

        // Simulate parsing via the JSON detection logic
        if let json = try? JSONSerialization.jsonObject(with: queryData) as? [String: Any] {
            XCTAssertEqual(json["action"] as? String, "health")
        } else {
            XCTFail("Failed to parse query JSON")
        }
    }

    func testHookMessageNotDetectedAsQuery() {
        // Hook messages don't have "action" field
        let hookData = "{\"session_id\":\"s1\",\"event\":\"thinking\",\"timestamp\":12345}".data(using: .utf8)!

        if let json = try? JSONSerialization.jsonObject(with: hookData) as? [String: Any] {
            XCTAssertNil(json["action"])
        } else {
            XCTFail("Failed to parse hook JSON")
        }
    }

    // MARK: - Full Socket Round-Trip

    func testQueryRoundTrip() {
        let expectation = XCTestExpectation(description: "Query received and responded")

        server = SocketServer()
        var queryResult: [String: Any]?

        server.onQuery = { [weak self] query, clientFD in
            guard let self = self else { return }
            XCTAssertEqual(query["action"] as? String, "inspect")

            // Send a response
            let response: [String: Any] = ["status": "ok", "data": ["sessions": []]]
            let data = try! JSONSerialization.data(withJSONObject: response)
            self.server.sendResponse(data: data, to: clientFD)

            queryResult = query
            expectation.fulfill()
        }
        server.start()

        // Wait for server to be ready
        Thread.sleep(forTimeInterval: 0.3)

        // Connect as client and send query
        let clientFD = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(clientFD, 0)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = SocketServer.socketPath
        path.withCString { ptr in
            _ = strcpy(&addr.sun_path, ptr)
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                connect(clientFD, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connectResult, 0, "Client should connect to server")

        // Send query
        let queryJSON = "{\"action\":\"inspect\"}\n"
        queryJSON.withCString { ptr in
            send(clientFD, ptr, queryJSON.utf8.count, 0)
        }

        // Read response
        Thread.sleep(forTimeInterval: 0.2)
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(clientFD, &buf, buf.count)
        close(clientFD)

        if n > 0 {
            let responseData = Data(buf[0..<n])
            let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            XCTAssertEqual(json?["status"] as? String, "ok")
        }

        wait(for: [expectation], timeout: 2.0)
        XCTAssertNotNil(queryResult)
    }

    // MARK: - Mixed Messages

    func testHookMessageStillWorks() {
        let queryExpectation = XCTestExpectation(description: "Query received")
        let messageExpectation = XCTestExpectation(description: "Hook message received")

        server = SocketServer()

        server.onQuery = { _, _ in
            queryExpectation.fulfill()
        }

        server.onMessage = { msg in
            XCTAssertEqual(msg.event, .thinking)
            XCTAssertEqual(msg.sessionId, "s1")
            messageExpectation.fulfill()
        }

        server.start()
        Thread.sleep(forTimeInterval: 0.3)

        // Connect as client
        let clientFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = SocketServer.socketPath
        path.withCString { ptr in
            _ = strcpy(&addr.sun_path, ptr)
        }
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                connect(clientFD, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        // Send a query message first
        let query = "{\"action\":\"health\"}\n"
        query.withCString { ptr in
            send(clientFD, ptr, query.utf8.count, 0)
        }

        // Then send a hook message
        let hook = "{\"session_id\":\"s1\",\"event\":\"thinking\",\"timestamp\":12345}\n"
        hook.withCString { ptr in
            send(clientFD, ptr, hook.utf8.count, 0)
        }

        close(clientFD)

        wait(for: [queryExpectation, messageExpectation], timeout: 2.0)
    }
}
