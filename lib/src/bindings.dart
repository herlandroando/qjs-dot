import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Opaque native handle for a QuickJS-ng engine instance (`QjsEngine*`).
final class NativeQjsEngine extends Opaque {}

/// Native evaluation result struct matching `QjsEvalResult` in `src/qjs_bridge.h`.
///
/// Heap-allocated strings populated by C (`valueJson`, `errorName`,
/// `errorMessage`, `errorStack`) must be released via [QjsBindings.freeResult].
final class NativeEvalResult extends Struct {
  /// Non-zero (`1`) when evaluation succeeded; `0` on exception or failure.
  @Int32()
  external int ok;

  /// Non-zero (`1`) when an async `Promise` or thenable is still pending and
  /// will settle later via [NativeEvalSettledCallback].
  @Int32()
  external int pendingAsync;

  /// Non-zero (`1`) if evaluation was interrupted by the timeout deadline.
  @Int32()
  external int isTimeout;

  /// Non-zero (`1`) if evaluation failed due to exhausting the heap limit.
  @Int32()
  external int isMemoryLimit;

  /// Encoded JSON payload of the resolved value, or `nullptr` for `null`/`undefined`.
  external Pointer<Utf8> valueJson;

  /// JavaScript error `name` when [ok] is `0`.
  external Pointer<Utf8> errorName;

  /// JavaScript error `message` when [ok] is `0`.
  external Pointer<Utf8> errorMessage;

  /// Optional JavaScript stack trace when [ok] is `0`.
  external Pointer<Utf8> errorStack;
}

/// Native memory usage snapshot matching `QjsMemoryUsage` in `src/qjs_bridge.h`.
final class NativeMemoryUsage extends Struct {
  /// Total bytes currently allocated by the QuickJS-ng allocator.
  @Int64()
  external int mallocSize;

  /// Configured maximum heap allocation limit in bytes (`0` if unlimited).
  @Int64()
  external int mallocLimit;

  /// Bytes actively used by live QuickJS-ng objects.
  @Int64()
  external int memoryUsedSize;

  /// Number of active allocator blocks.
  @Int64()
  external int mallocCount;

  /// Number of live runtime allocations.
  @Int64()
  external int memoryUsedCount;

  /// Number of interned JS atoms.
  @Int64()
  external int atomCount;

  /// Number of live JS strings.
  @Int64()
  external int strCount;

  /// Number of live JS objects.
  @Int64()
  external int objCount;

  /// Number of live JS functions.
  @Int64()
  external int jsFuncCount;

  /// Number of live binary objects (`ArrayBuffer`, `TypedArray`).
  @Int64()
  external int binaryObjectCount;

  /// Total bytes held by binary objects.
  @Int64()
  external int binaryObjectSize;
}

/// C-to-Dart callback signature for `console.*` log events.
///
/// Invoked synchronously on the worker isolate thread; [message] is only valid
/// for the duration of the callback.
typedef NativeConsoleCallback = Void Function(
  Pointer<Void> opaque,
  Int32 level,
  Pointer<Utf8> message,
);

/// C-to-Dart callback signature for scheduling a JS timer (`setTimeout`/`setInterval`).
typedef NativeTimerSetCallback = Void Function(
  Pointer<Void> opaque,
  Int64 timerId,
  Int64 delayMs,
  Int32 isInterval,
);

/// C-to-Dart callback signature for cancelling a pending JS timer.
typedef NativeTimerClearCallback = Void Function(
  Pointer<Void> opaque,
  Int64 timerId,
);

/// C-to-Dart callback signature for JS `sendMessage(channel, payload)` calls.
typedef NativePostMessageCallback = Void Function(
  Pointer<Void> opaque,
  Int64 requestId,
  Pointer<Utf8> channel,
  Pointer<Utf8> payloadJson,
);

/// C-to-Dart callback signature for JS `fetch()` requests.
typedef NativeFetchCallback = Void Function(
  Pointer<Void> opaque,
  Int64 requestId,
  Pointer<Utf8> url,
  Pointer<Utf8> method,
  Pointer<Utf8> headersJson,
  Pointer<Utf8> bodyBase64,
  Int32 hasBody,
);

/// C-to-Dart callback signature invoked when an async evaluation `Promise` settles.
typedef NativeEvalSettledCallback = Void Function(
  Pointer<Void> opaque,
  Int64 evalId,
  Int32 ok,
  Pointer<Utf8> valueJson,
  Pointer<Utf8> errorName,
  Pointer<Utf8> errorMessage,
  Pointer<Utf8> errorStack,
);

/// C-to-Dart callback signature for dynamic ES module resolution.
///
/// The worker isolate blocks on a native condition variable until the host
/// calls [QjsBindings.completeModuleLoad] or [QjsBindings.cancelModuleWait].
typedef NativeModuleRequestCallback = Void Function(
  Pointer<Void> opaque,
  Int64 requestId,
  Pointer<Utf8> specifier,
  Pointer<Utf8> referrer,
);

/// Native callback table matching `QjsCallbacks` in `src/qjs_bridge.h`.
///
/// All function pointers must be `NativeCallable.isolateLocal` callbacks owned
/// by the worker isolate that created the `QjsEngine`.
final class NativeCallbacks extends Struct {
  /// User-supplied opaque pointer forwarded to every callback.
  external Pointer<Void> opaque;

  /// Callback for `console.*` output.
  external Pointer<NativeFunction<NativeConsoleCallback>> onConsole;

  /// Callback for `setTimeout` and `setInterval`.
  external Pointer<NativeFunction<NativeTimerSetCallback>> onTimerSet;

  /// Callback for `clearTimeout` and `clearInterval`.
  external Pointer<NativeFunction<NativeTimerClearCallback>> onTimerClear;

  /// Callback for `sendMessage(channel, payload)`.
  external Pointer<NativeFunction<NativePostMessageCallback>> onPostMessage;

  /// Callback for `fetch()`.
  external Pointer<NativeFunction<NativeFetchCallback>> onFetch;

  /// Callback for async `Promise` settlement.
  external Pointer<NativeFunction<NativeEvalSettledCallback>> onEvalSettled;

  /// Callback for dynamic ES module resolution.
  external Pointer<NativeFunction<NativeModuleRequestCallback>> onModuleRequest;
}

typedef _CreateNative = Pointer<NativeQjsEngine> Function(
  Uint64 memoryLimitBytes,
  Uint64 maxStackSizeBytes,
  Int64 defaultTimeoutMs,
  Pointer<NativeCallbacks> callbacks,
);
typedef _CreateDart = Pointer<NativeQjsEngine> Function(
  int memoryLimitBytes,
  int maxStackSizeBytes,
  int defaultTimeoutMs,
  Pointer<NativeCallbacks> callbacks,
);

typedef _DestroyNative = Void Function(Pointer<NativeQjsEngine> engine);
typedef _DestroyDart = void Function(Pointer<NativeQjsEngine> engine);

typedef _EvalNative = Int32 Function(
  Pointer<NativeQjsEngine> engine,
  Pointer<Utf8> code,
  Pointer<Utf8> filename,
  Int32 isModule,
  Int64 asyncEvalId,
  Int64 timeoutMs,
  Pointer<NativeEvalResult> outResult,
);
typedef _EvalDart = int Function(
  Pointer<NativeQjsEngine> engine,
  Pointer<Utf8> code,
  Pointer<Utf8> filename,
  int isModule,
  int asyncEvalId,
  int timeoutMs,
  Pointer<NativeEvalResult> outResult,
);

typedef _ExecJobsNative = Int32 Function(
  Pointer<NativeQjsEngine> engine,
  Int64 timeoutMs,
  Pointer<NativeEvalResult> outResult,
);
typedef _ExecJobsDart = int Function(
  Pointer<NativeQjsEngine> engine,
  int timeoutMs,
  Pointer<NativeEvalResult> outResult,
);

typedef _RegisterModuleNative = Int32 Function(
  Pointer<NativeQjsEngine> engine,
  Pointer<Utf8> specifier,
  Pointer<Utf8> source,
);
typedef _RegisterModuleDart = int Function(
  Pointer<NativeQjsEngine> engine,
  Pointer<Utf8> specifier,
  Pointer<Utf8> source,
);

typedef _UnregisterModuleNative = Int32 Function(
  Pointer<NativeQjsEngine> engine,
  Pointer<Utf8> specifier,
);
typedef _UnregisterModuleDart = int Function(
  Pointer<NativeQjsEngine> engine,
  Pointer<Utf8> specifier,
);

typedef _CompleteModuleLoadNative = Void Function(
  Pointer<NativeQjsEngine> engine,
  Int64 requestId,
  Pointer<Utf8> source,
  Pointer<Utf8> error,
);
typedef _CompleteModuleLoadDart = void Function(
  Pointer<NativeQjsEngine> engine,
  int requestId,
  Pointer<Utf8> source,
  Pointer<Utf8> error,
);

typedef _CancelModuleWaitNative = Void Function(
  Pointer<NativeQjsEngine> engine,
);
typedef _CancelModuleWaitDart = void Function(
  Pointer<NativeQjsEngine> engine,
);

typedef _MemoryUsageNative = Void Function(
  Pointer<NativeQjsEngine> engine,
  Pointer<NativeMemoryUsage> outUsage,
);
typedef _MemoryUsageDart = void Function(
  Pointer<NativeQjsEngine> engine,
  Pointer<NativeMemoryUsage> outUsage,
);

typedef _FreeResultNative = Void Function(Pointer<NativeEvalResult> result);
typedef _FreeResultDart = void Function(Pointer<NativeEvalResult> result);

/// Thin `dart:ffi` wrapper around the `qjs_dot` native shared library.
///
/// Loads symbol bindings from `src/qjs_bridge.h`. Each [Isolate] that accesses
/// native `qjs_dot_*` symbols loads its own [QjsBindings] instance.
class QjsBindings {
  QjsBindings._(this.library)
      : create = library.lookupFunction<_CreateNative, _CreateDart>('qjs_dot_create'),
        destroy = library.lookupFunction<_DestroyNative, _DestroyDart>('qjs_dot_destroy'),
        eval = library.lookupFunction<_EvalNative, _EvalDart>('qjs_dot_eval'),
        executePendingJobs = library.lookupFunction<_ExecJobsNative, _ExecJobsDart>(
          'qjs_dot_execute_pending_jobs',
        ),
        registerModule = library.lookupFunction<_RegisterModuleNative, _RegisterModuleDart>(
          'qjs_dot_register_module',
        ),
        unregisterModule = library.lookupFunction<_UnregisterModuleNative, _UnregisterModuleDart>(
          'qjs_dot_unregister_module',
        ),
        completeModuleLoad = library.lookupFunction<_CompleteModuleLoadNative, _CompleteModuleLoadDart>(
          'qjs_dot_complete_module_load',
        ),
        cancelModuleWait = library.lookupFunction<_CancelModuleWaitNative, _CancelModuleWaitDart>(
          'qjs_dot_cancel_module_wait',
        ),
        memoryUsage = library.lookupFunction<_MemoryUsageNative, _MemoryUsageDart>(
          'qjs_dot_memory_usage',
        ),
        freeResult = library.lookupFunction<_FreeResultNative, _FreeResultDart>(
          'qjs_dot_free_result',
        );

  /// Loads the `qjs_dot` native library for the current platform or [libraryPath].
  factory QjsBindings.load([String? libraryPath]) {
    return QjsBindings._(openDynamicLibrary(libraryPath));
  }

  /// Opens the native `qjs_dot` [DynamicLibrary] for the current OS.
  ///
  /// Uses [libraryPath] when non-empty; otherwise resolves `libqjs_dot.so` on
  /// Android/Linux, `qjs_dot.dll` on Windows, or [DynamicLibrary.process] on
  /// iOS/macOS where CocoaPods statically links the symbols into the process.
  static DynamicLibrary openDynamicLibrary([String? libraryPath]) {
    if (libraryPath != null && libraryPath.isNotEmpty) {
      return DynamicLibrary.open(libraryPath);
    }
    if (Platform.isAndroid || Platform.isLinux) {
      return DynamicLibrary.open('libqjs_dot.so');
    }
    if (Platform.isWindows) {
      return DynamicLibrary.open('qjs_dot.dll');
    }
    if (Platform.isIOS || Platform.isMacOS) {
      return DynamicLibrary.process();
    }
    throw UnsupportedError(
      'qjs_dot is not supported on ${Platform.operatingSystem}',
    );
  }

  /// Loaded native [DynamicLibrary] handle.
  final DynamicLibrary library;

  /// Bound `qjs_dot_create` function.
  final Pointer<NativeQjsEngine> Function(
    int memoryLimitBytes,
    int maxStackSizeBytes,
    int defaultTimeoutMs,
    Pointer<NativeCallbacks> callbacks,
  ) create;

  /// Bound `qjs_dot_destroy` function.
  final void Function(Pointer<NativeQjsEngine> engine) destroy;

  /// Bound `qjs_dot_eval` function.
  final int Function(
    Pointer<NativeQjsEngine> engine,
    Pointer<Utf8> code,
    Pointer<Utf8> filename,
    int isModule,
    int asyncEvalId,
    int timeoutMs,
    Pointer<NativeEvalResult> outResult,
  ) eval;

  /// Bound `qjs_dot_execute_pending_jobs` function.
  final int Function(
    Pointer<NativeQjsEngine> engine,
    int timeoutMs,
    Pointer<NativeEvalResult> outResult,
  ) executePendingJobs;

  /// Bound `qjs_dot_register_module` function.
  final int Function(
    Pointer<NativeQjsEngine> engine,
    Pointer<Utf8> specifier,
    Pointer<Utf8> source,
  ) registerModule;

  /// Bound `qjs_dot_unregister_module` function.
  final int Function(
    Pointer<NativeQjsEngine> engine,
    Pointer<Utf8> specifier,
  ) unregisterModule;

  /// Bound `qjs_dot_complete_module_load` function (safe to call cross-thread).
  final void Function(
    Pointer<NativeQjsEngine> engine,
    int requestId,
    Pointer<Utf8> source,
    Pointer<Utf8> error,
  ) completeModuleLoad;

  /// Bound `qjs_dot_cancel_module_wait` function (safe to call cross-thread).
  final void Function(Pointer<NativeQjsEngine> engine) cancelModuleWait;

  /// Bound `qjs_dot_memory_usage` function.
  final void Function(
    Pointer<NativeQjsEngine> engine,
    Pointer<NativeMemoryUsage> outUsage,
  ) memoryUsage;

  /// Bound `qjs_dot_free_result` function.
  final void Function(Pointer<NativeEvalResult> result) freeResult;
}
