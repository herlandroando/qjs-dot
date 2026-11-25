import 'dart:async';
import 'dart:typed_data';

/// Log severity levels emitted by JavaScript `console.*` calls.
enum QjsConsoleLevel {
  /// `console.debug(...)`
  debug,

  /// `console.log(...)`
  log,

  /// `console.info(...)`
  info,

  /// `console.warn(...)`
  warn,

  /// `console.error(...)`
  error,
}

/// Callback for receiving JavaScript `console.*` output.
typedef QjsConsoleHandler = void Function(
  QjsConsoleLevel level,
  String message,
);

/// Callback for handling messages sent from JavaScript via `sendMessage(channel, payload)`.
typedef QjsMessageHandler = FutureOr<dynamic> Function(dynamic payload);

/// Callback for handling HTTP requests triggered by JavaScript `fetch()`.
typedef QjsFetchHandler = Future<QjsFetchResponse> Function(
  QjsFetchRequest request,
);

/// Callback for dynamically resolving ES module specifiers not present in the static registry.
///
/// Return the module's UTF-8 JavaScript source code, or `null` if the module cannot be found.
typedef QjsModuleLoader = FutureOr<String?> Function(
  String specifier,
  String referrer,
);

/// Represents an HTTP request initiated by JavaScript `fetch()`.
class QjsFetchRequest {
  /// Creates a fetch request descriptor.
  const QjsFetchRequest({
    required this.url,
    required this.method,
    required this.headers,
    this.bodyBytes,
  });

  /// Target request URL.
  final String url;

  /// HTTP method in uppercase (e.g. `GET`, `POST`).
  final String method;

  /// Request headers normalized to string key-value pairs.
  final Map<String, String> headers;

  /// Optional raw request body bytes.
  final Uint8List? bodyBytes;
}

/// Represents an HTTP response returned to JavaScript `fetch()`.
class QjsFetchResponse {
  /// Creates a fetch response descriptor.
  const QjsFetchResponse({
    required this.status,
    this.statusText = '',
    this.headers = const {},
    this.bodyBytes,
    this.url = '',
  });

  /// HTTP status code (e.g. `200`, `404`).
  final int status;

  /// HTTP status reason phrase (e.g. `OK`).
  final String statusText;

  /// Response headers.
  final Map<String, String> headers;

  /// Raw response body bytes.
  final Uint8List? bodyBytes;

  /// Final resolved URL after redirects, if any.
  final String url;
}

/// Snapshot of QuickJS-ng runtime memory allocations.
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

  /// Total bytes currently allocated via the runtime allocator.
  final int mallocSize;

  /// Configured maximum heap allocation limit in bytes (`0` if unlimited).
  final int mallocLimit;

  /// Bytes used by live runtime objects.
  final int memoryUsedSize;

  /// Active allocation block count.
  final int mallocCount;

  /// Active live object allocation count.
  final int memoryUsedCount;

  /// Interned atom count.
  final int atomCount;

  /// Live JS string count.
  final int strCount;

  /// Live JS object count.
  final int objCount;

  /// Live JS function count.
  final int jsFuncCount;

  /// Live binary object count (`ArrayBuffer`, `TypedArray`).
  final int binaryObjectCount;

  /// Total bytes held by binary objects.
  final int binaryObjectSize;
}

/// Exception thrown when JavaScript execution fails, throws, or hits a sandbox limit.
class QjsException implements Exception {
  /// Creates a structured JavaScript exception.
  const QjsException({
    required this.name,
    required this.message,
    this.stack,
    this.isTimeout = false,
    this.isMemoryLimit = false,
  });

  /// JavaScript error name (e.g. `SyntaxError`, `TypeError`, `TimeoutError`).
  final String name;

  /// Error message.
  final String message;

  /// Optional JavaScript stack trace.
  final String? stack;

  /// Whether execution was aborted due to exceeding the configured timeout.
  final bool isTimeout;

  /// Whether execution failed due to exceeding the configured memory limit.
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

/// Configuration options for creating a [QjsRuntime] instance.
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
  /// Set to `0` to disable the limit.
  final int memoryLimitBytes;

  /// Maximum JS call stack size in bytes (default: 512 KB).
  /// Keeps deep recursion safely below native OS thread stack limits.
  final int maxStackSizeBytes;

  /// Maximum execution duration per evaluation turn (default: 5 seconds).
  /// Set to `Duration.zero` to disable timeouts.
  final Duration timeout;

  /// Whether to install the global `fetch`, `Headers`, `Request`, and `Response` polyfills.
  final bool enableFetchPolyfill;

  /// Custom HTTP handler for `fetch()` calls.
  /// When omitted and [enableFetchPolyfill] is `true`, a default `dart:io` `HttpClient` handler is used.
  final QjsFetchHandler? fetchHandler;

  /// Optional listener invoked when JavaScript calls `console.log/info/warn/error/debug`.
  final QjsConsoleHandler? onConsoleLog;

  /// Initial static ES modules keyed by specifier.
  final Map<String, String> modules;

  /// Optional dynamic callback invoked when an ES module specifier is not in the static registry.
  final QjsModuleLoader? moduleLoader;

  /// Initial global variables injected into `globalThis` before user scripts run.
  final Map<String, dynamic> globals;

  /// Optional explicit path to the native `qjs_dot` shared library (useful in host unit tests).
  final String? libraryPath;
}
