import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Opaque native handle for a QuickJS-ng engine instance.
final class NativeQjsEngine extends Opaque {}

/// Native evaluation result matching `QjsEvalResult` in `src/qjs_bridge.h`.
final class NativeEvalResult extends Struct {
  @Int32()
  external int ok;

  @Int32()
  external int pendingAsync;

  @Int32()
  external int isTimeout;

  @Int32()
  external int isMemoryLimit;

  external Pointer<Utf8> valueJson;
  external Pointer<Utf8> errorName;
  external Pointer<Utf8> errorMessage;
  external Pointer<Utf8> errorStack;
}

/// Native memory usage snapshot matching `QjsMemoryUsage` in `src/qjs_bridge.h`.
final class NativeMemoryUsage extends Struct {
  @Int64()
  external int mallocSize;

  @Int64()
  external int mallocLimit;

  @Int64()
  external int memoryUsedSize;

  @Int64()
  external int mallocCount;

  @Int64()
  external int memoryUsedCount;

  @Int64()
  external int atomCount;

  @Int64()
  external int strCount;

  @Int64()
  external int objCount;

  @Int64()
  external int jsFuncCount;

  @Int64()
  external int binaryObjectCount;

  @Int64()
  external int binaryObjectSize;
}

typedef NativeConsoleCallback = Void Function(
  Pointer<Void> opaque,
  Int32 level,
  Pointer<Utf8> message,
);

typedef NativeTimerSetCallback = Void Function(
  Pointer<Void> opaque,
  Int64 timerId,
  Int64 delayMs,
  Int32 isInterval,
);

typedef NativeTimerClearCallback = Void Function(
  Pointer<Void> opaque,
  Int64 timerId,
);

typedef NativePostMessageCallback = Void Function(
  Pointer<Void> opaque,
  Int64 requestId,
  Pointer<Utf8> channel,
  Pointer<Utf8> payloadJson,
);

typedef NativeFetchCallback = Void Function(
  Pointer<Void> opaque,
  Int64 requestId,
  Pointer<Utf8> url,
  Pointer<Utf8> method,
  Pointer<Utf8> headersJson,
  Pointer<Utf8> bodyBase64,
  Int32 hasBody,
);

typedef NativeEvalSettledCallback = Void Function(
  Pointer<Void> opaque,
  Int64 evalId,
  Int32 ok,
  Pointer<Utf8> valueJson,
  Pointer<Utf8> errorName,
  Pointer<Utf8> errorMessage,
  Pointer<Utf8> errorStack,
);

typedef NativeModuleRequestCallback = Void Function(
  Pointer<Void> opaque,
  Int64 requestId,
  Pointer<Utf8> specifier,
  Pointer<Utf8> referrer,
);

/// Native callback table matching `QjsCallbacks` in `src/qjs_bridge.h`.
final class NativeCallbacks extends Struct {
  external Pointer<Void> opaque;
  external Pointer<NativeFunction<NativeConsoleCallback>> onConsole;
  external Pointer<NativeFunction<NativeTimerSetCallback>> onTimerSet;
  external Pointer<NativeFunction<NativeTimerClearCallback>> onTimerClear;
  external Pointer<NativeFunction<NativePostMessageCallback>> onPostMessage;
  external Pointer<NativeFunction<NativeFetchCallback>> onFetch;
  external Pointer<NativeFunction<NativeEvalSettledCallback>> onEvalSettled;
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

/// Thin FFI wrapper around the `qjs_dot` native shared library.
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

  /// Opens the native library without caching bindings.
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

  final DynamicLibrary library;
  final Pointer<NativeQjsEngine> Function(
    int memoryLimitBytes,
    int maxStackSizeBytes,
    int defaultTimeoutMs,
    Pointer<NativeCallbacks> callbacks,
  ) create;
  final void Function(Pointer<NativeQjsEngine> engine) destroy;
  final int Function(
    Pointer<NativeQjsEngine> engine,
    Pointer<Utf8> code,
    Pointer<Utf8> filename,
    int isModule,
    int asyncEvalId,
    int timeoutMs,
    Pointer<NativeEvalResult> outResult,
  ) eval;
  final int Function(
    Pointer<NativeQjsEngine> engine,
    int timeoutMs,
    Pointer<NativeEvalResult> outResult,
  ) executePendingJobs;
  final int Function(
    Pointer<NativeQjsEngine> engine,
    Pointer<Utf8> specifier,
    Pointer<Utf8> source,
  ) registerModule;
  final int Function(
    Pointer<NativeQjsEngine> engine,
    Pointer<Utf8> specifier,
  ) unregisterModule;
  final void Function(
    Pointer<NativeQjsEngine> engine,
    int requestId,
    Pointer<Utf8> source,
    Pointer<Utf8> error,
  ) completeModuleLoad;
  final void Function(Pointer<NativeQjsEngine> engine) cancelModuleWait;
  final void Function(
    Pointer<NativeQjsEngine> engine,
    Pointer<NativeMemoryUsage> outUsage,
  ) memoryUsage;
  final void Function(Pointer<NativeEvalResult> result) freeResult;
}
