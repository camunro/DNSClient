## Project Overview

This is a Swift library for DNS resolution. It provides a `DNSClient` that can be used to send DNS queries to a server. It supports UDP and TCP, as well as multicast DNS. The library is built on top of SwiftNIO.

## Building and Running

The project is a Swift package. It can be built and tested using the Swift Package Manager.

**Build:**
```swift
swift build
```

**Test:**
```swift
swift test
```

## Development Conventions

*   The project uses XCTest for testing.
*   The code is written in Swift and uses modern features like `async/await`.
*   The project has a clear separation of concerns, with different files for different functionalities.
*   The project uses `swift-nio` for networking.
