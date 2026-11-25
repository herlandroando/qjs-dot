/// Lightweight, sandboxed QuickJS-ng JavaScript runtime for Flutter over `dart:ffi`.
///
/// Each [QjsRuntime] runs in a dedicated Dart `Isolate` so synchronous and
/// asynchronous JavaScript evaluation never blocks the UI thread.
///
/// ## Highlights
/// - **ES2023+ Engine:** Powered by vendored QuickJS-ng (`v0.18.0`) with
///   `Promise`, `async`/`await`, and static/dynamic ES Modules.
/// - **Built-in Web Polyfills:** `console.*`, `setTimeout`/`setInterval`,
///   `queueMicrotask`, `atob`/`btoa`, `TextEncoder`/`TextDecoder`,
///   `URL`/`URLSearchParams`, and pluggable `fetch()`.
/// - **Bidirectional Bridge:** Call Dart handlers from JavaScript via
///   `sendMessage(channel, payload)` and [QjsRuntime.onMessage].
/// - **Sandbox Guardrails:** Configurable heap limits, call-stack limits, and
///   CPU/async timeouts via [QjsRuntimeOptions].
///
/// ## Quick Start
/// ```dart
/// import 'package:qjs_dot/qjs_dot.dart';
///
/// Future<void> main() async {
///   final js = await QjsRuntime.create(
///     options: QjsRuntimeOptions(
///       onConsoleLog: (level, message) => print('[$level] $message'),
///     ),
///   );
///
///   final value = await js.evaluate('40 + 2');
///   print(value); // 42
///
///   await js.dispose();
/// }
/// ```
///
/// See [QjsRuntime], [QjsRuntimeOptions], [QjsException], and [QjsMemoryUsage].
library;

export 'src/models.dart'
    show
        QjsConsoleHandler,
        QjsConsoleLevel,
        QjsException,
        QjsFetchHandler,
        QjsFetchRequest,
        QjsFetchResponse,
        QjsMemoryUsage,
        QjsMessageHandler,
        QjsModuleLoader,
        QjsRuntimeOptions;
export 'src/runtime.dart' show QjsRuntime;
