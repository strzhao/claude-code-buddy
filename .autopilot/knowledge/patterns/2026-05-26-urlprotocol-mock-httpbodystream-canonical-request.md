# URLSession + URLProtocol mock 必须读 httpBodyStream 回 httpBody，否则 request body 永远 nil

<!-- tags: urlsession, urlprotocol, mock, http-body, http-body-stream, network-mock, swift-testing, body-capture, canonical-request -->
**Scenario**: 测试 HTTP client（如 AnthropicProvider）的 request body 字面量（`max_tokens=4096`、message schema 等）时，用 URLProtocol 子类拦截 URLSession 请求。但 `request.httpBody` 在 MockURLProtocol 的 `startLoading` 中永远 nil — URLSession 内部把 httpBody 转 `httpBodyStream` 后才传给 URLProtocol。如果 test 写 `XCTAssertEqual(request.httpBody...)` 会 fatal error 解包 nil。
**Lesson**: MockURLProtocol 必须 override `canonicalRequest(for:)` 把 `httpBodyStream` 内容读回 `httpBody` 字段：
```swift
override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
    var mutable = request
    stream.open(); defer { stream.close() }
    var data = Data()
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    defer { buf.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buf, maxLength: 4096)
        if read > 0 { data.append(buf, count: read) } else { break }
    }
    mutable.httpBody = data
    return mutable
}
```
这是 infra 修复（非 contract 削弱），所有上层断言保持原样。
**Evidence**: task 002 LauncherProviderAcceptanceTests 的 MockURLProtocol 加此 override 后，19 个 Provider acceptance 测试（含 max_tokens=4096 / x-api-key header / OAI message schema 等）全部通过。
