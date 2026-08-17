# v2 RuntimeMode and physical isolation

The application composition is selected before any root, URL, Keychain, or
transport is constructed. The public shape is intentionally closed:

```swift
enum RuntimeMode: Sendable {
    case production(ProductionDependencies)
    case test(TestDependencies)
    case preview(PreviewDependencies)
}

struct TestDependencies: Sendable {
    let root: TestRoot
    let transport: FakeTransport
    let keychain: TestKeychain
}
```

`ProductionDependencies`, `TestRoot`, `FakeTransport`, and `TestKeychain` are
distinct types. A test cannot construct a production root, production URL, or
production Keychain through this API; a production composition cannot accept a
test root. There is no archive case in `RuntimeMode`. Archive reading belongs
to a separate offline migration executable and cannot construct a live worker.

`preview` uses fixed values and no SQLite/network/Keychain. `test` requires a
temporary root and injected fake transport/keychain. It rejects symlink roots,
production URLs, and any URL whose host is not the test harness. `production`
derives the v2 root from the platform application-support container and uses
only the `/v2` HTTPS origin. The runtime mode is not selected by an arbitrary
UserDefaults string after startup.
