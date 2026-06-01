# Unix socket write 必须循环处理部分写入

<!-- tags: socket, posix, networking, write, partial-write -->
**Scenario**: 通过 Unix domain socket 向客户端发送 JSON 响应
**Lesson**: `Darwin.write()` 可能返回比请求更少的字节数（部分写入）。必须循环写入直到全部数据发送完毕或发生错误。单次 `write` 并不保证完整发送。这在本地 socket 上较少见但并非不可能（内核缓冲区满、信号中断等）。
**Evidence**: SocketServer.swift `sendResponse(data:to:)` 方法 — 从单次 write 改为 while 循环
