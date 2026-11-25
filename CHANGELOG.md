## 0.1.0

- Initial release of `qjs-dot` (`qjs_dot`) powered by vendored QuickJS-ng `v0.18.0`.
- Dedicated Worker `Isolate` runtime with event-driven `Promise` settlement.
- Zero-KGP Android Gradle Kotlin DSL (`com.android.library`) and 16 KB ELF page alignment.
- Polyfills for `console`, timers (`setTimeout`/`setInterval`/`queueMicrotask`), `sendMessage`/`onMessage`, pluggable `fetch()`, `atob`/`btoa`, `TextEncoder`/`TextDecoder`, `URL`/`URLSearchParams`, and ES Modules.
- Sandbox guards for memory limit, stack depth, synchronous infinite loops, and async timeouts.
