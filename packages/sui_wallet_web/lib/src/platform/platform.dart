// Picks the browser implementation on the web and a no-wallet stub
// elsewhere, so apps' VM widget tests still compile.
export 'platform_stub.dart'
    if (dart.library.js_interop) 'platform_web.dart'
    show
        createDefaultBackend,
        createDefaultStorage,
        createDefaultTransactionLock,
        openExternalUrl,
        ensureBridgeLoaded;
