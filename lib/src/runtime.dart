import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'default_fetch.dart';
import 'models.dart';
import 'polyfills.dart';
import 'worker_isolate.dart';

/// Isolated, sandboxed QuickJS-ng JavaScript runtime running in a dedicated
/// Dart [Isolate].
///
/// Each [QjsRuntime] owns a single native `QjsEngine` inside a dedicated worker
/// isolate so JavaScript execution never blocks the Flutter UI isolate. Host
/// interactions (`console.*`, `fetch()`, `sendMessage()`, and dynamic ES module
/// loading) are bridged asynchronously back to the host isolate.
///
/// ## Value Marshaling (JS ↔ Dart)
/// - `null` / `undefined` ↔ `null`
/// - `boolean`, `string`, finite `number` ↔ `bool`, `String`, `int`/`double`
/// - `NaN`, `Infinity`, `-Infinity` ↔ `double.nan`, `double.infinity`,
///   `double.negativeInfinity`
/// - `BigInt` → `BigInt` (Dart `BigInt` passed into JS is converted to string)
/// - `ArrayBuffer` / `TypedArray` ↔ `Uint8List`
/// - `Array` / plain `Object` ↔ `List<dynamic>` / `Map<String, dynamic>`
/// - `Date` → ISO-8601 `String`; `Error` → `{name, message, stack}`
/// - Circular references in JS objects are replaced with `'[Circular]'`.
///
/// Always call [dispose] when finished to release native QuickJS-ng memory,
/// close HTTP clients, and terminate the worker isolate.
class QjsRuntime {
  QjsRuntime._({
    required QjsRuntimeOptions options,
    required QjsBindings bindings,
    required Pointer<NativeQjsEngine> enginePtr,
    required SendPort workerPort,
    required ReceivePort mainPort,
    required StreamSubscription<dynamic> mainSub,
    required ReceivePort replyPort,
    required DefaultQjsFetchClient? defaultFetchClient,
  })  : _options = options,
        _bindings = bindings,
        _enginePtr = enginePtr,
        _workerPort = workerPort,
        _mainPort = mainPort,
        _mainSub = mainSub,
        _replyPort = replyPort,
        _defaultFetchClient = defaultFetchClient {
    _replySub = _replyPort.listen(_onReply);
  }

  final QjsRuntimeOptions _options;
  final QjsBindings _bindings;
  final Pointer<NativeQjsEngine> _enginePtr;
  final SendPort _workerPort;
  // Receives unsolicited worker->host events (console, fetch, sendMessage, module loads).
  final ReceivePort _mainPort;
  final StreamSubscription<dynamic> _mainSub;
  // Receives 1:1 RPC responses for commands sent over `_workerPort`.
  final ReceivePort _replyPort;
  final DefaultQjsFetchClient? _defaultFetchClient;

  late final StreamSubscription<dynamic> _replySub;

  final Map<int, Completer<dynamic>> _pendingCmds = {};
  final Map<String, QjsMessageHandler> _messageHandlers = {};
  int _nextCmdId = 1;
  bool _disposed = false;

  /// Whether [dispose] has been called on this runtime.
  bool get isDisposed => _disposed;

  /// Creates and initializes a new isolated [QjsRuntime] instance.
  ///
  /// Spawns a dedicated worker [Isolate], initializes the QuickJS-ng engine
  /// with [options], installs built-in polyfills, registers initial
  /// [QjsRuntimeOptions.modules], and injects [QjsRuntimeOptions.globals].
  ///
  /// Throws [QjsException] (with `name == 'InitializationError'`) if the native
  /// library fails to load or polyfill bootstrapping fails.
  static Future<QjsRuntime> create({
    QjsRuntimeOptions options = const QjsRuntimeOptions(),
  }) async {
    final bindings = QjsBindings.load(options.libraryPath);
    final mainPort = ReceivePort();
    final replyPort = ReceivePort();
    final readyCompleter = Completer<WorkerReadyEvent>();
    QjsRuntime? runtime;
    // Buffer events emitted during bootstrap (for example, console logs) until
    // the `QjsRuntime` wrapper is constructed.
    final bufferedEvents = <dynamic>[];

    final mainSub = mainPort.listen((dynamic event) {
      if (event is WorkerReadyEvent && !readyCompleter.isCompleted) {
        readyCompleter.complete(event);
      } else if (runtime != null) {
        runtime._onWorkerEvent(event);
      } else {
        bufferedEvents.add(event);
      }
    });

    final encodedGlobals = <String, String>{};
    options.globals.forEach((key, value) {
      encodedGlobals[key] = encodeDartValueToJsJson(value);
    });

    final timeoutMs = options.timeout <= Duration.zero
        ? 0
        : options.timeout.inMilliseconds;

    await Isolate.spawn<WorkerInitMessage>(
      qjsWorkerMain,
      WorkerInitMessage(
        mainPort: mainPort.sendPort,
        memoryLimitBytes: options.memoryLimitBytes,
        maxStackSizeBytes: options.maxStackSizeBytes,
        timeoutMs: timeoutMs,
        enableFetchPolyfill: options.enableFetchPolyfill,
        initialModules: Map<String, String>.from(options.modules),
        initialGlobalsJson: encodedGlobals,
        libraryPath: options.libraryPath,
      ),
      debugName: 'qjs_dot_worker',
    );

    final ready = await readyCompleter.future;

    if (ready.error != null || ready.workerPort == null || ready.engineAddress == null) {
      await mainSub.cancel();
      mainPort.close();
      replyPort.close();
      throw QjsException(
        name: 'InitializationError',
        message: ready.error ?? 'Failed to initialize QjsRuntime',
      );
    }

    final defaultFetch =
        (options.enableFetchPolyfill && options.fetchHandler == null)
            ? DefaultQjsFetchClient()
            : null;

    runtime = QjsRuntime._(
      options: options,
      bindings: bindings,
      enginePtr: Pointer<NativeQjsEngine>.fromAddress(ready.engineAddress!),
      workerPort: ready.workerPort!,
      mainPort: mainPort,
      mainSub: mainSub,
      replyPort: replyPort,
      defaultFetchClient: defaultFetch,
    );

    if (bufferedEvents.isNotEmpty) {
      for (final event in bufferedEvents) {
        runtime._onWorkerEvent(event);
      }
      bufferedEvents.clear();
    }

    return runtime;
  }

  /// Evaluates synchronous JavaScript [code] inside the worker isolate.
  ///
  /// The optional [filename] appears in JavaScript stack traces (defaults to
  /// `'<eval>'`). When [timeout] is omitted (`null`), [QjsRuntimeOptions.timeout]
  /// applies; pass [Duration.zero] to disable the timeout for this call.
  ///
  /// Returns the marshaled Dart value (primitives, `List`, `Map`, `Uint8List`,
  /// or `null`). Throws [QjsException] on syntax errors, uncaught JS
  /// exceptions, or sandbox limit violations, and [StateError] if disposed.
  Future<dynamic> evaluate(
    String code, {
    String filename = '<eval>',
    Duration? timeout,
  }) {
    return _sendEval(
      code: code,
      filename: filename,
      isModule: false,
      isAsync: false,
      timeout: timeout,
    );
  }

  /// Evaluates JavaScript [code] and awaits any returned `Promise` or thenable.
  ///
  /// Supports `async`/`await`, `setTimeout`/`setInterval`, `fetch()`, and
  /// `sendMessage()`. If the script evaluates to a non-Promise value, the
  /// returned `Future` resolves immediately with the marshaled value.
  ///
  /// The optional [filename] appears in stack traces (defaults to `'<eval>'`).
  /// When [timeout] is omitted (`null`), [QjsRuntimeOptions.timeout] applies to
  /// both synchronous execution and `Promise` settlement; pass [Duration.zero]
  /// to disable timeouts for this call.
  ///
  /// Throws [QjsException] on errors or timeouts, and [StateError] if disposed.
  Future<dynamic> evaluateAsync(
    String code, {
    String filename = '<eval>',
    Duration? timeout,
  }) {
    return _sendEval(
      code: code,
      filename: filename,
      isModule: false,
      isAsync: true,
      timeout: timeout,
    );
  }

  /// Evaluates an ES module [code] supporting `import`/`export` and top-level
  /// `await`.
  ///
  /// Static imports are resolved against [QjsRuntimeOptions.modules] and
  /// modules added via [registerModule], falling back to
  /// [QjsRuntimeOptions.moduleLoader]. The optional [filename] identifies the
  /// entry module (defaults to `'main.js'`) and serves as the base path for
  /// relative `./` and `../` imports.
  ///
  /// Resolves to a `Map<String, dynamic>` containing the module's exported
  /// namespace. Throws [QjsException] on syntax/link/runtime errors or timeouts,
  /// and [StateError] if disposed.
  Future<dynamic> evaluateModule(
    String code, {
    String filename = 'main.js',
    Duration? timeout,
  }) {
    return _sendEval(
      code: code,
      filename: filename,
      isModule: true,
      isAsync: true,
      timeout: timeout,
    );
  }

  /// Injects or updates a global property [name] on `globalThis` with [value].
  ///
  /// Supports primitives, `List`, `Map`, `Uint8List`, `double.nan`/infinities,
  /// `BigInt` (as string), and `null`. Throws [StateError] if disposed.
  Future<void> setGlobal(String name, dynamic value) {
    _ensureNotDisposed();
    final cmdId = _nextCmdId++;
    final completer = Completer<dynamic>();
    _pendingCmds[cmdId] = completer;
    _workerPort.send(
      WorkerSetGlobalCmd(
        cmdId: cmdId,
        name: name,
        valueJson: encodeDartValueToJsJson(value),
        replyPort: _replyPort.sendPort,
      ),
    );
    return completer.future.then((_) {});
  }

  /// Registers a Dart [handler] for messages sent by JavaScript via
  /// `sendMessage(channel, payload)`.
  ///
  /// Registering a second handler on the same [channel] replaces the previous
  /// one. Throws [StateError] if disposed.
  void onMessage(String channel, QjsMessageHandler handler) {
    _ensureNotDisposed();
    _messageHandlers[channel] = handler;
  }

  /// Removes a previously registered message handler for [channel].
  ///
  /// Subsequent JavaScript `sendMessage` calls on [channel] will reject with
  /// an error until a new handler is registered.
  void offMessage(String channel) {
    _messageHandlers.remove(channel);
  }

  /// Registers or replaces an ES module [source] under [specifier] in the
  /// static registry.
  ///
  /// Takes effect for subsequent `import` statements (note that already-loaded
  /// modules remain cached inside the active QuickJS-ng `JSContext`). Throws
  /// [StateError] if disposed or registration fails natively.
  Future<void> registerModule(String specifier, String source) {
    _ensureNotDisposed();
    final cmdId = _nextCmdId++;
    final completer = Completer<dynamic>();
    _pendingCmds[cmdId] = completer;
    _workerPort.send(
      WorkerRegisterModuleCmd(
        cmdId: cmdId,
        specifier: specifier,
        source: source,
        replyPort: _replyPort.sendPort,
      ),
    );
    return completer.future.then((_) {});
  }

  /// Removes [specifier] from the static ES module registry.
  ///
  /// Throws [StateError] if disposed.
  Future<void> unregisterModule(String specifier) {
    _ensureNotDisposed();
    final cmdId = _nextCmdId++;
    final completer = Completer<dynamic>();
    _pendingCmds[cmdId] = completer;
    _workerPort.send(
      WorkerUnregisterModuleCmd(
        cmdId: cmdId,
        specifier: specifier,
        replyPort: _replyPort.sendPort,
      ),
    );
    return completer.future.then((_) {});
  }

  /// Returns a snapshot of QuickJS-ng heap memory usage for this runtime.
  ///
  /// Throws [StateError] if disposed.
  Future<QjsMemoryUsage> getMemoryUsage() async {
    _ensureNotDisposed();
    final cmdId = _nextCmdId++;
    final completer = Completer<dynamic>();
    _pendingCmds[cmdId] = completer;
    _workerPort.send(
      WorkerMemoryUsageCmd(
        cmdId: cmdId,
        replyPort: _replyPort.sendPort,
      ),
    );
    return await completer.future as QjsMemoryUsage;
  }

  /// Releases all native QuickJS-ng resources, closes built-in HTTP clients,
  /// fails any pending evaluations, and shuts down the worker isolate.
  ///
  /// Idempotent; calling [dispose] multiple times is safe.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    // Wake any worker thread waiting on dynamic module loading before sending
    // dispose; otherwise the worker isolate cannot process `WorkerDisposeCmd`.
    _bindings.cancelModuleWait(_enginePtr);
    _defaultFetchClient?.close();

    final cmdId = _nextCmdId++;
    final completer = Completer<dynamic>();
    _pendingCmds[cmdId] = completer;
    _workerPort.send(
      WorkerDisposeCmd(cmdId: cmdId, replyPort: _replyPort.sendPort),
    );

    try {
      await completer.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      // Proceed with local teardown even if worker exited abruptly.
    }

    for (final pending in _pendingCmds.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('QjsRuntime has been disposed'));
      }
    }
    _pendingCmds.clear();
    _messageHandlers.clear();

    await _replySub.cancel();
    await _mainSub.cancel();
    _replyPort.close();
    _mainPort.close();
  }

  // Timeout convention sent to native C bridge: `-1` inherits engine default,
  // `0` disables timeout, `> 0` sets explicit millisecond deadline.
  Future<dynamic> _sendEval({
    required String code,
    required String filename,
    required bool isModule,
    required bool isAsync,
    Duration? timeout,
  }) {
    _ensureNotDisposed();
    final cmdId = _nextCmdId++;
    final completer = Completer<dynamic>();
    _pendingCmds[cmdId] = completer;

    final timeoutMs = timeout == null
        ? -1
        : (timeout <= Duration.zero ? 0 : timeout.inMilliseconds);

    _workerPort.send(
      WorkerEvalCmd(
        cmdId: cmdId,
        code: code,
        filename: filename,
        isModule: isModule,
        isAsync: isAsync,
        timeoutMs: timeoutMs,
        replyPort: _replyPort.sendPort,
      ),
    );
    return completer.future;
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('QjsRuntime has been disposed');
    }
  }

  // Completes host-side Futures for RPC responses arriving on `_replyPort`.
  void _onReply(dynamic message) {
    if (message is WorkerCmdSuccess) {
      final completer = _pendingCmds.remove(message.cmdId);
      if (completer != null && !completer.isCompleted) {
        completer.complete(message.value);
      }
    } else if (message is WorkerCmdError) {
      final completer = _pendingCmds.remove(message.cmdId);
      if (completer != null && !completer.isCompleted) {
        completer.completeError(message.error);
      }
    }
  }

  // Dispatches unsolicited worker->host notifications arriving on `_mainPort`.
  void _onWorkerEvent(dynamic event) {
    if (_disposed) return;

    if (event is WorkerConsoleEvent) {
      final level = event.level >= 0 && event.level < QjsConsoleLevel.values.length
          ? QjsConsoleLevel.values[event.level]
          : QjsConsoleLevel.log;
      _options.onConsoleLog?.call(level, event.message);
      return;
    }

    if (event is WorkerMessageRequest) {
      unawaited(_handleMessageRequest(event));
      return;
    }

    if (event is WorkerFetchRequest) {
      unawaited(_handleFetchRequest(event));
      return;
    }

    if (event is WorkerModuleLoadRequest) {
      unawaited(_handleModuleLoadRequest(event));
    }
  }

  Future<void> _handleMessageRequest(WorkerMessageRequest req) async {
    final handler = _messageHandlers[req.channel];
    if (handler == null) {
      if (!_disposed) {
        _workerPort.send(
          WorkerHostMessageReplyCmd(
            requestId: req.requestId,
            ok: false,
            errorMessage: 'No handler registered for channel "${req.channel}"',
          ),
        );
      }
      return;
    }

    try {
      final payload = decodeJsPayload(req.payloadJson);
      final result = await handler(payload);
      if (_disposed) return;
      _workerPort.send(
        WorkerHostMessageReplyCmd(
          requestId: req.requestId,
          ok: true,
          resultJson: encodeDartValueToJsJson(result),
        ),
      );
    } catch (e) {
      if (_disposed) return;
      _workerPort.send(
        WorkerHostMessageReplyCmd(
          requestId: req.requestId,
          ok: false,
          errorMessage: e.toString(),
        ),
      );
    }
  }

  Future<void> _handleFetchRequest(WorkerFetchRequest req) async {
    final handler = _options.fetchHandler ?? _defaultFetchClient?.fetch;
    if (handler == null) {
      if (!_disposed) {
        _workerPort.send(
          WorkerHostFetchReplyCmd(
            requestId: req.requestId,
            ok: false,
            errorMessage: 'Fetch polyfill is disabled',
          ),
        );
      }
      return;
    }

    try {
      final rawHeaders = jsonDecode(req.headersJson);
      final headers = <String, String>{};
      if (rawHeaders is Map) {
        rawHeaders.forEach((k, v) {
          headers[k.toString()] = v.toString();
        });
      }
      final bodyBytes =
          req.hasBody && req.bodyBase64.isNotEmpty
              ? base64Decode(req.bodyBase64)
              : null;

      final response = await handler(
        QjsFetchRequest(
          url: req.url,
          method: req.method,
          headers: headers,
          bodyBytes: bodyBytes,
        ),
      );
      if (_disposed) return;

      _workerPort.send(
        WorkerHostFetchReplyCmd(
          requestId: req.requestId,
          ok: true,
          status: response.status,
          statusText: response.statusText,
          headersJson: jsonEncode(response.headers),
          bodyBase64:
              response.bodyBytes != null && response.bodyBytes!.isNotEmpty
                  ? base64Encode(response.bodyBytes!)
                  : '',
          url: response.url,
        ),
      );
    } catch (e) {
      if (_disposed) return;
      _workerPort.send(
        WorkerHostFetchReplyCmd(
          requestId: req.requestId,
          ok: false,
          errorMessage: e.toString(),
        ),
      );
    }
  }

  Future<void> _handleModuleLoadRequest(WorkerModuleLoadRequest req) async {
    final loader = _options.moduleLoader;
    if (loader == null) {
      _completeNativeModuleLoad(
        req.requestId,
        null,
        'Module not found: ${req.specifier}',
      );
      return;
    }

    try {
      final source = await loader(req.specifier, req.referrer);
      if (_disposed) return;
      if (source == null) {
        _completeNativeModuleLoad(
          req.requestId,
          null,
          'Module not found: ${req.specifier}',
        );
      } else {
        _completeNativeModuleLoad(req.requestId, source, null);
      }
    } catch (e) {
      if (_disposed) return;
      _completeNativeModuleLoad(req.requestId, null, e.toString());
    }
  }

  // Calls directly into the C bridge condvar wakeup from the host isolate while
  // the worker isolate is blocked inside QuickJS-ng's module loader hook.
  void _completeNativeModuleLoad(
    int requestId,
    String? source,
    String? error,
  ) {
    final srcPtr = source == null ? nullptr : source.toNativeUtf8();
    final errPtr = error == null ? nullptr : error.toNativeUtf8();
    try {
      _bindings.completeModuleLoad(_enginePtr, requestId, srcPtr, errPtr);
    } finally {
      if (srcPtr != nullptr) calloc.free(srcPtr);
      if (errPtr != nullptr) calloc.free(errPtr);
    }
  }
}
