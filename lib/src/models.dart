import 'dart:async';
import 'dart:typed_data';

/// Log severity levels emitted by JavaScript `console.*` calls.
///
/// Passed to [QjsConsoleHandler] when [QjsRuntimeOptions.onConsoleLog] is
/// configured.
enum QjsConsoleLevel {
  /// Emitted by `console.debug(...)`.
  debug,

  /// Emitted by `console.log(...)`.
  log,

  /// Emitted by `console.info(...)`.
  info,

  /// Emitted by `console.warn(...)`.
  warn,

  /// Emitted by `console.error(...)`.
  error,
}

/// Listener invoked whenever JavaScript calls `console.debug`, `log`, `info`,
/// `warn`, or `error`.
///
/// Multiple arguments passed in JavaScript are formatted and joined with a
/// single space into [message].
typedef QjsConsoleHandler = void Function(
  QjsConsoleLevel level,
  String message,
);

/// Host callback invoked when JavaScript calls `sendMessage(channel, payload)`.
///
/// The decoded [payload] is a Dart primitive, `List`, `Map`, `Uint8List`, or
/// `null`. Returning a value (or completing a `Future`) resolves the JavaScript
/// `Promise` returned by `sendMessage`; throwing rejects that `Promise` with
/// the error message.
typedef QjsMessageHandler = FutureOr<dynamic> Function(dynamic payload);

/// Host callback invoked when JavaScript calls `fetch(input, init)`.
///
/// Implement this typedef to route JavaScript HTTP requests through a custom
/// client (such as `dio`, `package:http`, or an authenticated/mocked stack)
/// via [QjsRuntimeOptions.fetchHandler].
typedef QjsFetchHandler = Future<QjsFetchResponse> Function(
  QjsFetchRequest request,
);

/// Dynamic ES module resolver invoked when an `import` specifier is not found
/// in the static registry.
///
/// Receives the normalized [specifier] and [referrer] module name. Return the
/// module's UTF-8 JavaScript source code, or `null` if the module cannot be
/// resolved (which causes QuickJS-ng to throw a `ReferenceError`). Throwing an
/// exception propagates its message as a `ReferenceError` into JavaScript.
///
/// Note: Because QuickJS-ng compiles modules synchronously while waiting on the
/// C bridge condition variable, resolution of a single dynamic import has an
/// internal 30-second native wait limit.
typedef QjsModuleLoader = FutureOr<String?> Function(
  String specifier,
  String referrer,
);

/// Immutable HTTP request descriptor passed to a [QjsFetchHandler].
class QjsFetchRequest {
  /// Creates a fetch request descriptor.
  const QjsFetchRequest({
    required this.url,
    required this.method,
    required this.headers,
    this.bodyBytes,
  });

  /// Target request URL string.
  final String url;

  /// HTTP method normalized to uppercase (for example, `'GET'` or `'POST'`).
  final String method;

  /// Request headers with lowercase keys normalized by the JS `Headers` class.
  final Map<String, String> headers;

  /// Optional raw request body bytes, or `null` when no body was provided.
  final Uint8List? bodyBytes;
}

/// Immutable HTTP response descriptor returned from a [QjsFetchHandler].
class QjsFetchResponse {
  /// Creates a fetch response descriptor.
  const QjsFetchResponse({
    required this.status,
    this.statusText = '',
    this.headers = const {},
    this.bodyBytes,
    this.url = '',
  });

  /// HTTP status code (for example, `200`, `404`, or `500`).
  ///
  /// The JavaScript `Response.ok` getter evaluates to `true` when [status] is
  /// in the range `200..299`.
  final int status;

  /// HTTP status reason phrase (for example, `'OK'`).
  final String statusText;

  /// Response headers sent back to the JavaScript `Response.headers` object.
  final Map<String, String> headers;

  /// Raw response body bytes, or `null` for an empty body.
  final Uint8List? bodyBytes;

  /// Final resolved URL after redirects, if any.
  final String url;
}

/// Snapshot of QuickJS-ng heap and object allocations returned by
/// [QjsRuntime.getMemoryUsage].
///
/// Mirrors QuickJS-ng's `JSMemoryUsage` statistics at the moment of the call.
class QjsMemoryUsage {
  /// Creates a memory usage snapshot.
  const QjsMemoryUsage({
    required this.mallocSize,
    required this.mallocLimit,
    required this.memoryUsedSize,
    required this.mallocCount,
    required this.memoryUsedCount,
    required this.atomCount,
    required this.strCount,
    required this.objCount,
    required this.jsFuncCount,
    required this.binaryObjectCount,
    required this.binaryObjectSize,
  });

  /// Total bytes currently allocated through the QuickJS-ng runtime allocator.
  final int mallocSize;

  /// Configured maximum heap allocation limit in bytes (`0` if unlimited).
  final int mallocLimit;

  /// Total bytes actively used by live QuickJS-ng objects.
  final int memoryUsedSize;

  /// Number of active allocator blocks.
  final int mallocCount;

  /// Number of live runtime object allocations.
  final int memoryUsedCount;

  /// Number of interned JS atoms (property names and symbols).
  final int atomCount;

  /// Number of live JS string objects.
  final int strCount;

  /// Number of live JS objects.
  final int objCount;

  /// Number of live JS function objects.
  final int jsFuncCount;

  /// Number of live binary objects (`ArrayBuffer`, `TypedArray`).
  final int binaryObjectCount;

  /// Total byte size held by live binary objects.
  final int binaryObjectSize;
}

/// Structured exception thrown when JavaScript initialization, compilation, or
/// execution fails, throws, or hits a sandbox limit.
class QjsException implements Exception {
  /// Creates a structured JavaScript exception.
  const QjsException({
    required this.name,
    required this.message,
    this.stack,
    this.isTimeout = false,
    this.isMemoryLimit = false,
  });

  /// JavaScript error name (for example, `'SyntaxError'`, `'TypeError'`,
  /// `'ReferenceError'`, `'TimeoutError'`, or `'InitializationError'`).
  final String name;

  /// Human-readable error message.
  final String message;

  /// Optional JavaScript stack trace captured from the thrown `Error` object.
  final String? stack;

  /// Whether execution was aborted because it exceeded the configured timeout.
  final bool isTimeout;

  /// Whether execution failed because the runtime exceeded
  /// [QjsRuntimeOptions.memoryLimitBytes].
  final bool isMemoryLimit;

  @override
  String toString() {
    final buffer = StringBuffer('$name: $message');
    if (stack != null && stack!.trim().isNotEmpty) {
      buffer.write('\n$stack');
    }
    return buffer.toString();
  }
}

/// Configuration options passed to [QjsRuntime.create].
///
/// Provides sensible sandbox defaults (64 MB heap limit, 512 KB call stack,
/// 5-second evaluation timeout, and built-in `fetch()` enabled).
class QjsRuntimeOptions {
  /// Creates runtime configuration options.
  const QjsRuntimeOptions({
    this.memoryLimitBytes = 64 * 1024 * 1024,
    this.maxStackSizeBytes = 512 * 1024,
    this.timeout = const Duration(seconds: 5),
    this.enableFetchPolyfill = true,
    this.fetchHandler,
    this.onConsoleLog,
    this.modules = const {},
    this.moduleLoader,
    this.globals = const {},
    this.libraryPath,
  });

  /// Maximum heap memory in bytes per runtime instance (default: 64 MB).
  ///
  /// Set to `0` to disable the native heap limit.
  final int memoryLimitBytes;

  /// Maximum JS call stack size in bytes (default: 512 KB).
  ///
  /// Keeps deep recursion safely below native OS thread stack limits. Set to
  /// `0` to use QuickJS-ng's default limit.
  final int maxStackSizeBytes;

  /// Default maximum execution duration per evaluation turn (default: 5 s).
  ///
  /// Applies to both synchronous CPU loops (via QuickJS-ng's interrupt
  /// handler) and unresolved async evaluations. Set to [Duration.zero] (or any
  /// non-positive duration) to disable timeouts by default. Individual calls
  /// can override this via the `timeout` parameter on [QjsRuntime.evaluate],
  /// [QjsRuntime.evaluateAsync], and [QjsRuntime.evaluateModule].
  final Duration timeout;

  /// Whether to install the global `fetch`, `Headers`, `Request`, and
  /// `Response` polyfills during runtime bootstrap (default: `true`).
  final bool enableFetchPolyfill;

  /// Custom HTTP handler for JavaScript `fetch()` calls.
  ///
  /// When omitted (`null`) and [enableFetchPolyfill] is `true`, requests are
  /// handled by a built-in `dart:io` `HttpClient` wrapper on the host isolate.
  final QjsFetchHandler? fetchHandler;

  /// Optional listener invoked when JavaScript calls `console.debug`, `log`,
  /// `info`, `warn`, or `error`.
  final QjsConsoleHandler? onConsoleLog;

  /// Initial static ES modules keyed by module specifier.
  ///
  /// Additional modules can be added or removed later with
  /// [QjsRuntime.registerModule] and [QjsRuntime.unregisterModule].
  final Map<String, String> modules;

  /// Optional dynamic callback invoked when an ES module specifier is not
  /// present in the static module registry.
  final QjsModuleLoader? moduleLoader;

  /// Initial global properties injected onto `globalThis` before user scripts
  /// execute.
  ///
  /// Values are serialized using the same marshaling rules as
  /// [QjsRuntime.setGlobal].
  final Map<String, dynamic> globals;

  /// Optional explicit path to the native `qjs_dot` shared library.
  ///
  /// Useful in host unit tests or custom desktop packaging where the compiled
  /// shared library is not on the default dynamic linker search path.
  final String? libraryPath;
}
