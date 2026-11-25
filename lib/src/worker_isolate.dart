import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'models.dart';
import 'polyfills.dart';

/// Initialization payload passed from the host isolate to the worker isolate
/// via `Isolate.spawn`.
class WorkerInitMessage {
  const WorkerInitMessage({
    required this.mainPort,
    required this.memoryLimitBytes,
    required this.maxStackSizeBytes,
    required this.timeoutMs,
    required this.enableFetchPolyfill,
    required this.initialModules,
    required this.initialGlobalsJson,
    this.libraryPath,
  });

  /// Host isolate port receiving readiness and unsolicited worker events.
  final SendPort mainPort;

  /// Heap memory limit passed to `qjs_dot_create` (`0` = unlimited).
  final int memoryLimitBytes;

  /// JS call stack limit passed to `qjs_dot_create` (`0` = engine default).
  final int maxStackSizeBytes;

  /// Default per-evaluation timeout in milliseconds (`0` = disabled).
  final int timeoutMs;

  /// Whether to inject the JS `fetch`/`Headers`/`Request`/`Response` polyfill.
  final bool enableFetchPolyfill;

  /// Initial static ES module sources keyed by specifier.
  final Map<String, String> initialModules;

  /// Initial globals pre-encoded via `encodeDartValueToJsJson`.
  final Map<String, String> initialGlobalsJson;

  /// Optional explicit native library path override.
  final String? libraryPath;
}

/// Handshake event sent by the worker isolate once engine creation succeeds or
/// fails.
class WorkerReadyEvent {
  const WorkerReadyEvent({
    this.workerPort,
    this.engineAddress,
    this.error,
  });

  /// Worker command `SendPort` when initialization succeeded.
  final SendPort? workerPort;

  /// Raw native `QjsEngine*` address used by the host for cross-thread
  /// `completeModuleLoad` / `cancelModuleWait` calls.
  final int? engineAddress;

  /// Error description when initialization failed.
  final String? error;
}

/// Console log notification emitted from JS `console.*` to the host isolate.
class WorkerConsoleEvent {
  const WorkerConsoleEvent(this.level, this.message);

  /// Numeric index mapping into [QjsConsoleLevel.values].
  final int level;

  /// Pre-formatted console log string.
  final String message;
}

/// Request sent from JS `sendMessage(channel, payload)` to the host isolate.
class WorkerMessageRequest {
  const WorkerMessageRequest(this.requestId, this.channel, this.payloadJson);

  /// Monotonic JS request identifier used to correlate the host reply.
  final int requestId;

  /// Target message channel name.
  final String channel;

  /// JSON-encoded sanitized payload from JS.
  final String payloadJson;
}

/// HTTP request forwarded from JS `fetch()` to the host isolate.
class WorkerFetchRequest {
  const WorkerFetchRequest({
    required this.requestId,
    required this.url,
    required this.method,
    required this.headersJson,
    required this.bodyBase64,
    required this.hasBody,
  });

  /// Monotonic JS fetch identifier used to correlate the host reply.
  final int requestId;

  /// Target URL string.
  final String url;

  /// Uppercase HTTP method.
  final String method;

  /// JSON-encoded header object.
  final String headersJson;

  /// Base64-encoded request body bytes (empty when [hasBody] is `false`).
  final String bodyBase64;

  /// Whether a request body was provided.
  final bool hasBody;
}

/// Dynamic ES module resolution request sent when an import specifier misses
/// the native static registry.
class WorkerModuleLoadRequest {
  const WorkerModuleLoadRequest(this.requestId, this.specifier, this.referrer);

  /// Native request ID matched by `qjs_dot_complete_module_load`.
  final int requestId;

  /// Normalized ES module specifier.
  final String specifier;

  /// Referring module specifier (or empty string if unavailable).
  final String referrer;
}

/// Command instructing the worker isolate to evaluate JS code or an ES module.
class WorkerEvalCmd {
  const WorkerEvalCmd({
    required this.cmdId,
    required this.code,
    required this.filename,
    required this.isModule,
    required this.isAsync,
    required this.timeoutMs,
    required this.replyPort,
  });

  /// Host command ID correlated via [WorkerCmdSuccess] or [WorkerCmdError].
  final int cmdId;

  /// JavaScript source code to evaluate.
  final String code;

  /// Virtual filename shown in stack traces and used as module base path.
  final String filename;

  /// Whether to compile and evaluate [code] as an ES module.
  final bool isModule;

  /// Whether to await returned Promises/thenables via `__qjs_dot_attach_promise`.
  final bool isAsync;

  /// Per-call timeout in ms (`-1` = default, `0` = disabled, `> 0` = explicit).
  final int timeoutMs;

  /// Host port to send the settled evaluation result to.
  final SendPort replyPort;
}

/// Command instructing the worker isolate to set a property on `globalThis`.
class WorkerSetGlobalCmd {
  const WorkerSetGlobalCmd({
    required this.cmdId,
    required this.name,
    required this.valueJson,
    required this.replyPort,
  });

  final int cmdId;
  final String name;
  final String valueJson;
  final SendPort replyPort;
}

/// Command instructing the worker isolate to register a static ES module.
class WorkerRegisterModuleCmd {
  const WorkerRegisterModuleCmd({
    required this.cmdId,
    required this.specifier,
    required this.source,
    required this.replyPort,
  });

  final int cmdId;
  final String specifier;
  final String source;
  final SendPort replyPort;
}

/// Command instructing the worker isolate to remove a static ES module.
class WorkerUnregisterModuleCmd {
  const WorkerUnregisterModuleCmd({
    required this.cmdId,
    required this.specifier,
    required this.replyPort,
  });

  final int cmdId;
  final String specifier;
  final SendPort replyPort;
}

/// Command requesting a [QjsMemoryUsage] snapshot from the native engine.
class WorkerMemoryUsageCmd {
  const WorkerMemoryUsageCmd({
    required this.cmdId,
    required this.replyPort,
  });

  final int cmdId;
  final SendPort replyPort;
}

/// Host-to-worker reply resolving or rejecting a JS `sendMessage()` Promise.
class WorkerHostMessageReplyCmd {
  const WorkerHostMessageReplyCmd({
    required this.requestId,
    required this.ok,
    this.resultJson,
    this.errorMessage,
  });

  final int requestId;
  final bool ok;
  final String? resultJson;
  final String? errorMessage;
}

/// Host-to-worker reply resolving or rejecting a JS `fetch()` Promise.
class WorkerHostFetchReplyCmd {
  const WorkerHostFetchReplyCmd({
    required this.requestId,
    required this.ok,
    this.status = 0,
    this.statusText = '',
    this.headersJson = '{}',
    this.bodyBase64 = '',
    this.url = '',
    this.errorMessage,
  });

  final int requestId;
  final bool ok;
  final int status;
  final String statusText;
  final String headersJson;
  final String bodyBase64;
  final String url;
  final String? errorMessage;
}

/// Command instructing the worker isolate to destroy its native engine and exit.
class WorkerDisposeCmd {
  const WorkerDisposeCmd({
    required this.cmdId,
    required this.replyPort,
  });

  final int cmdId;
  final SendPort replyPort;
}

/// Successful RPC response sent back to the host on `replyPort`.
class WorkerCmdSuccess {
  const WorkerCmdSuccess(this.cmdId, this.value);
  final int cmdId;
  final dynamic value;
}

/// Failed RPC response sent back to the host on `replyPort`.
class WorkerCmdError {
  const WorkerCmdError(this.cmdId, this.error);
  final int cmdId;
  final Object error;
}

/// Tracks an in-flight asynchronous JS evaluation awaiting Promise settlement
/// or Dart-side timeout expiry.
class _PendingAsyncEval {
  _PendingAsyncEval(this.cmdId, this.replyPort, this.timeoutTimer);
  final int cmdId;
  final SendPort replyPort;
  Timer? timeoutTimer;
}

/// Entry point for the dedicated JavaScript worker isolate.
///
/// Owns the `QjsEngine*`, all `NativeCallable.isolateLocal` C callbacks,
/// active JS timers, and pending async evaluation timers for the lifetime of
/// the runtime.
void qjsWorkerMain(WorkerInitMessage init) {
  final workerPort = ReceivePort();
  QjsBindings bindings;
  try {
    bindings = QjsBindings.load(init.libraryPath);
  } catch (e) {
    init.mainPort.send(WorkerReadyEvent(error: e.toString()));
    workerPort.close();
    return;
  }

  Pointer<NativeQjsEngine> engine = nullptr;
  final timers = <int, Timer>{};
  final pendingAsyncEvals = <int, _PendingAsyncEval>{};
  var nextAsyncEvalId = 1;
  var disposed = false;

  // Completes a pending async eval at most once (either via Promise settlement
  // or the async wall-clock timeout timer) and cancels its timeout timer.
  void sendAsyncResult(int evalId, bool ok, dynamic valueOrError) {
    final pending = pendingAsyncEvals.remove(evalId);
    if (pending == null) return;
    pending.timeoutTimer?.cancel();
    if (ok) {
      pending.replyPort.send(WorkerCmdSuccess(pending.cmdId, valueOrError));
    } else {
      pending.replyPort.send(WorkerCmdError(pending.cmdId, valueOrError));
    }
  }

  // Executes an internal bridge snippet (timer callback, global setter, or
  // host reply) without producing a return value.
  void runJsSilent(String code, String filename) {
    if (disposed || engine == nullptr) return;
    final codePtr = code.toNativeUtf8();
    final filePtr = filename.toNativeUtf8();
    final resPtr = calloc<NativeEvalResult>();
    try {
      bindings.eval(engine, codePtr, filePtr, 0, 0, -1, resPtr);
    } finally {
      bindings.freeResult(resPtr);
      calloc.free(resPtr);
      calloc.free(codePtr);
      calloc.free(filePtr);
    }
  }

  // Flushes QuickJS-ng's microtask/Promise job queue after timer or host
  // callbacks re-enter JS.
  void drainPendingJobs() {
    if (disposed || engine == nullptr) return;
    final resPtr = calloc<NativeEvalResult>();
    try {
      bindings.executePendingJobs(engine, -1, resPtr);
    } finally {
      bindings.freeResult(resPtr);
      calloc.free(resPtr);
    }
  }

  // Isolate-local NativeCallables can be invoked synchronously from C on this
  // worker thread. They must remain open until `bindings.destroy(engine)`.
  late final NativeCallable<NativeConsoleCallback> onConsoleCb;
  late final NativeCallable<NativeTimerSetCallback> onTimerSetCb;
  late final NativeCallable<NativeTimerClearCallback> onTimerClearCb;
  late final NativeCallable<NativePostMessageCallback> onPostMessageCb;
  late final NativeCallable<NativeFetchCallback> onFetchCb;
  late final NativeCallable<NativeEvalSettledCallback> onEvalSettledCb;
  late final NativeCallable<NativeModuleRequestCallback> onModuleRequestCb;

  onConsoleCb = NativeCallable<NativeConsoleCallback>.isolateLocal(
    (Pointer<Void> opaque, int level, Pointer<Utf8> message) {
      if (disposed || message == nullptr) return;
      init.mainPort.send(WorkerConsoleEvent(level, message.toDartString()));
    },
  );

  onTimerSetCb = NativeCallable<NativeTimerSetCallback>.isolateLocal(
    (Pointer<Void> opaque, int timerId, int delayMs, int isInterval) {
      if (disposed) return;
      timers.remove(timerId)?.cancel();
      final duration = Duration(milliseconds: delayMs < 0 ? 0 : delayMs);
      if (isInterval != 0) {
        timers[timerId] = Timer.periodic(duration, (_) {
          if (disposed) return;
          runJsSilent('__qjs_dot_fire_timer($timerId)', '<timer>');
          drainPendingJobs();
        });
      } else {
        timers[timerId] = Timer(duration, () {
          timers.remove(timerId);
          if (disposed) return;
          runJsSilent('__qjs_dot_fire_timer($timerId)', '<timer>');
          drainPendingJobs();
        });
      }
    },
  );

  onTimerClearCb = NativeCallable<NativeTimerClearCallback>.isolateLocal(
    (Pointer<Void> opaque, int timerId) {
      timers.remove(timerId)?.cancel();
    },
  );

  onPostMessageCb = NativeCallable<NativePostMessageCallback>.isolateLocal(
    (
      Pointer<Void> opaque,
      int requestId,
      Pointer<Utf8> channel,
      Pointer<Utf8> payloadJson,
    ) {
      if (disposed) return;
      final ch = channel == nullptr ? '' : channel.toDartString();
      final payload = payloadJson == nullptr ? 'null' : payloadJson.toDartString();
      init.mainPort.send(WorkerMessageRequest(requestId, ch, payload));
    },
  );

  onFetchCb = NativeCallable<NativeFetchCallback>.isolateLocal(
    (
      Pointer<Void> opaque,
      int requestId,
      Pointer<Utf8> url,
      Pointer<Utf8> method,
      Pointer<Utf8> headersJson,
      Pointer<Utf8> bodyBase64,
      int hasBody,
    ) {
      if (disposed) return;
      init.mainPort.send(
        WorkerFetchRequest(
          requestId: requestId,
          url: url == nullptr ? '' : url.toDartString(),
          method: method == nullptr ? 'GET' : method.toDartString(),
          headersJson: headersJson == nullptr ? '{}' : headersJson.toDartString(),
          bodyBase64: bodyBase64 == nullptr ? '' : bodyBase64.toDartString(),
          hasBody: hasBody != 0,
        ),
      );
    },
  );

  onEvalSettledCb = NativeCallable<NativeEvalSettledCallback>.isolateLocal(
    (
      Pointer<Void> opaque,
      int evalId,
      int ok,
      Pointer<Utf8> valueJson,
      Pointer<Utf8> errorName,
      Pointer<Utf8> errorMessage,
      Pointer<Utf8> errorStack,
    ) {
      if (ok != 0) {
        try {
          final jsonStr = valueJson == nullptr ? null : valueJson.toDartString();
          final decoded = decodeJsPayload(jsonStr);
          sendAsyncResult(evalId, true, decoded);
        } catch (e) {
          sendAsyncResult(evalId, false, e);
        }
      } else {
        final exc = QjsException(
          name: errorName == nullptr ? 'Error' : errorName.toDartString(),
          message: errorMessage == nullptr ? 'Unknown error' : errorMessage.toDartString(),
          stack: errorStack == nullptr ? null : errorStack.toDartString(),
        );
        sendAsyncResult(evalId, false, exc);
      }
    },
  );

  onModuleRequestCb = NativeCallable<NativeModuleRequestCallback>.isolateLocal(
    (
      Pointer<Void> opaque,
      int requestId,
      Pointer<Utf8> specifier,
      Pointer<Utf8> referrer,
    ) {
      if (disposed) return;
      init.mainPort.send(
        WorkerModuleLoadRequest(
          requestId,
          specifier == nullptr ? '' : specifier.toDartString(),
          referrer == nullptr ? '' : referrer.toDartString(),
        ),
      );
    },
  );

  final callbacksPtr = calloc<NativeCallbacks>();
  callbacksPtr.ref
    ..opaque = nullptr
    ..onConsole = onConsoleCb.nativeFunction
    ..onTimerSet = onTimerSetCb.nativeFunction
    ..onTimerClear = onTimerClearCb.nativeFunction
    ..onPostMessage = onPostMessageCb.nativeFunction
    ..onFetch = onFetchCb.nativeFunction
    ..onEvalSettled = onEvalSettledCb.nativeFunction
    ..onModuleRequest = onModuleRequestCb.nativeFunction;

  // Destroys the native engine first so QuickJS-ng cannot invoke any callback
  // after its `NativeCallable` is closed.
  void cleanupNative() {
    for (final timer in timers.values) {
      timer.cancel();
    }
    timers.clear();

    for (final entry in pendingAsyncEvals.values) {
      entry.timeoutTimer?.cancel();
      entry.replyPort.send(
        WorkerCmdError(entry.cmdId, StateError('QjsRuntime has been disposed')),
      );
    }
    pendingAsyncEvals.clear();

    if (engine != nullptr) {
      bindings.destroy(engine);
      engine = nullptr;
    }

    calloc.free(callbacksPtr);
    onConsoleCb.close();
    onTimerSetCb.close();
    onTimerClearCb.close();
    onPostMessageCb.close();
    onFetchCb.close();
    onEvalSettledCb.close();
    onModuleRequestCb.close();
  }

  engine = bindings.create(
    init.memoryLimitBytes,
    init.maxStackSizeBytes,
    init.timeoutMs,
    callbacksPtr,
  );

  if (engine == nullptr) {
    cleanupNative();
    init.mainPort.send(
      const WorkerReadyEvent(error: 'Failed to create QuickJS-ng engine'),
    );
    workerPort.close();
    return;
  }

  // Bootstrap sequence: 1) polyfills, 2) static modules, 3) initial globals.
  final bootstrapCode = buildPolyfillBootstrap(
    enableFetchPolyfill: init.enableFetchPolyfill,
  );
  final bootCodePtr = bootstrapCode.toNativeUtf8();
  final bootFilePtr = '<bootstrap>'.toNativeUtf8();
  final bootResPtr = calloc<NativeEvalResult>();
  try {
    final rc = bindings.eval(engine, bootCodePtr, bootFilePtr, 0, 0, -1, bootResPtr);
    if (rc != 0 || bootResPtr.ref.ok == 0) {
      final errMsg = bootResPtr.ref.errorMessage == nullptr
          ? 'Failed to bootstrap polyfills'
          : bootResPtr.ref.errorMessage.toDartString();
      bindings.freeResult(bootResPtr);
      cleanupNative();
      init.mainPort.send(WorkerReadyEvent(error: errMsg));
      workerPort.close();
      return;
    }
    bindings.freeResult(bootResPtr);
  } finally {
    calloc.free(bootResPtr);
    calloc.free(bootCodePtr);
    calloc.free(bootFilePtr);
  }

  init.initialModules.forEach((specifier, source) {
    final specPtr = specifier.toNativeUtf8();
    final srcPtr = source.toNativeUtf8();
    try {
      bindings.registerModule(engine, specPtr, srcPtr);
    } finally {
      calloc.free(specPtr);
      calloc.free(srcPtr);
    }
  });

  init.initialGlobalsJson.forEach((name, valueJson) {
    runJsSilent(
      '__qjs_dot_set_global(${jsonEncode(name)}, ${jsonEncode(valueJson)})',
      '<global>',
    );
  });

  init.mainPort.send(
    WorkerReadyEvent(
      workerPort: workerPort.sendPort,
      engineAddress: engine.address,
    ),
  );

  QjsException exceptionFromNative(NativeEvalResult res) {
    return QjsException(
      name: res.errorName == nullptr ? 'Error' : res.errorName.toDartString(),
      message: res.errorMessage == nullptr
          ? 'Unknown JavaScript error'
          : res.errorMessage.toDartString(),
      stack: res.errorStack == nullptr ? null : res.errorStack.toDartString(),
      isTimeout: res.isTimeout != 0,
      isMemoryLimit: res.isMemoryLimit != 0,
    );
  }

  workerPort.listen((dynamic message) {
    if (message is WorkerEvalCmd) {
      if (disposed) {
        message.replyPort.send(
          WorkerCmdError(message.cmdId, StateError('QjsRuntime has been disposed')),
        );
        return;
      }

      // Async evals and ES modules share a dual timeout: C's interrupt handler
      // aborts tight synchronous JS loops, while `asyncTimer` aborts Promises
      // that never settle while the isolate is idle waiting on timers/I/O.
      final useAsync = message.isAsync || message.isModule;
      final evalId = useAsync ? nextAsyncEvalId++ : 0;
      final effectiveTimeoutMs =
          message.timeoutMs >= 0 ? message.timeoutMs : init.timeoutMs;

      if (useAsync) {
        Timer? asyncTimer;
        if (effectiveTimeoutMs > 0) {
          asyncTimer = Timer(Duration(milliseconds: effectiveTimeoutMs), () {
            sendAsyncResult(
              evalId,
              false,
              const QjsException(
                name: 'TimeoutError',
                message: 'Async JavaScript evaluation timed out',
                isTimeout: true,
              ),
            );
          });
        }
        pendingAsyncEvals[evalId] = _PendingAsyncEval(
          message.cmdId,
          message.replyPort,
          asyncTimer,
        );
      }

      final codePtr = message.code.toNativeUtf8();
      final filePtr = message.filename.toNativeUtf8();
      final resPtr = calloc<NativeEvalResult>();
      try {
        final rc = bindings.eval(
          engine,
          codePtr,
          filePtr,
          message.isModule ? 1 : 0,
          evalId,
          message.timeoutMs,
          resPtr,
        );
        final res = resPtr.ref;

        if (rc != 0 || res.ok == 0) {
          final exc = exceptionFromNative(res);
          if (useAsync) {
            sendAsyncResult(evalId, false, exc);
          } else {
            message.replyPort.send(WorkerCmdError(message.cmdId, exc));
          }
        } else if (useAsync && res.pendingAsync != 0) {
          // Will settle via onEvalSettledCb or asyncTimer.
        } else {
          final valJson =
              res.valueJson == nullptr ? null : res.valueJson.toDartString();
          final decoded = decodeJsPayload(valJson);
          if (useAsync) {
            sendAsyncResult(evalId, true, decoded);
          } else {
            message.replyPort.send(WorkerCmdSuccess(message.cmdId, decoded));
          }
        }
      } catch (e) {
        if (useAsync) {
          sendAsyncResult(evalId, false, e);
        } else {
          message.replyPort.send(WorkerCmdError(message.cmdId, e));
        }
      } finally {
        bindings.freeResult(resPtr);
        calloc.free(resPtr);
        calloc.free(codePtr);
        calloc.free(filePtr);
      }
      return;
    }

    if (message is WorkerSetGlobalCmd) {
      if (disposed) {
        message.replyPort.send(
          WorkerCmdError(message.cmdId, StateError('QjsRuntime has been disposed')),
        );
        return;
      }
      try {
        runJsSilent(
          '__qjs_dot_set_global(${jsonEncode(message.name)}, ${jsonEncode(message.valueJson)})',
          '<global>',
        );
        message.replyPort.send(WorkerCmdSuccess(message.cmdId, null));
      } catch (e) {
        message.replyPort.send(WorkerCmdError(message.cmdId, e));
      }
      return;
    }

    if (message is WorkerRegisterModuleCmd) {
      if (disposed) {
        message.replyPort.send(
          WorkerCmdError(message.cmdId, StateError('QjsRuntime has been disposed')),
        );
        return;
      }
      final specPtr = message.specifier.toNativeUtf8();
      final srcPtr = message.source.toNativeUtf8();
      try {
        final rc = bindings.registerModule(engine, specPtr, srcPtr);
        if (rc != 0) {
          message.replyPort.send(
            WorkerCmdError(message.cmdId, StateError('Failed to register module')),
          );
        } else {
          message.replyPort.send(WorkerCmdSuccess(message.cmdId, null));
        }
      } finally {
        calloc.free(specPtr);
        calloc.free(srcPtr);
      }
      return;
    }

    if (message is WorkerUnregisterModuleCmd) {
      if (disposed) {
        message.replyPort.send(
          WorkerCmdError(message.cmdId, StateError('QjsRuntime has been disposed')),
        );
        return;
      }
      final specPtr = message.specifier.toNativeUtf8();
      try {
        bindings.unregisterModule(engine, specPtr);
        message.replyPort.send(WorkerCmdSuccess(message.cmdId, null));
      } finally {
        calloc.free(specPtr);
      }
      return;
    }

    if (message is WorkerMemoryUsageCmd) {
      if (disposed) {
        message.replyPort.send(
          WorkerCmdError(message.cmdId, StateError('QjsRuntime has been disposed')),
        );
        return;
      }
      final usagePtr = calloc<NativeMemoryUsage>();
      try {
        bindings.memoryUsage(engine, usagePtr);
        final u = usagePtr.ref;
        message.replyPort.send(
          WorkerCmdSuccess(
            message.cmdId,
            QjsMemoryUsage(
              mallocSize: u.mallocSize,
              mallocLimit: u.mallocLimit,
              memoryUsedSize: u.memoryUsedSize,
              mallocCount: u.mallocCount,
              memoryUsedCount: u.memoryUsedCount,
              atomCount: u.atomCount,
              strCount: u.strCount,
              objCount: u.objCount,
              jsFuncCount: u.jsFuncCount,
              binaryObjectCount: u.binaryObjectCount,
              binaryObjectSize: u.binaryObjectSize,
            ),
          ),
        );
      } finally {
        calloc.free(usagePtr);
      }
      return;
    }

    if (message is WorkerHostMessageReplyCmd) {
      if (disposed) return;
      final resArg = message.resultJson == null
          ? 'null'
          : jsonEncode(message.resultJson);
      final errArg = message.errorMessage == null
          ? 'null'
          : jsonEncode(message.errorMessage);
      runJsSilent(
        '__qjs_dot_resolve_message(${message.requestId}, ${message.ok ? 1 : 0}, $resArg, $errArg)',
        '<message-reply>',
      );
      drainPendingJobs();
      return;
    }

    if (message is WorkerHostFetchReplyCmd) {
      if (disposed) return;
      runJsSilent(
        '__qjs_dot_resolve_fetch('
        '${message.requestId}, '
        '${message.ok ? 1 : 0}, '
        '${message.status}, '
        '${jsonEncode(message.statusText)}, '
        '${jsonEncode(message.headersJson)}, '
        '${jsonEncode(message.bodyBase64)}, '
        '${jsonEncode(message.url)}, '
        '${jsonEncode(message.errorMessage)}'
        ')',
        '<fetch-reply>',
      );
      drainPendingJobs();
      return;
    }

    if (message is WorkerDisposeCmd) {
      disposed = true;
      cleanupNative();
      workerPort.close();
      message.replyPort.send(WorkerCmdSuccess(message.cmdId, null));
    }
  });
}
