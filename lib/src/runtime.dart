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

/// Isolated, sandboxed QuickJS-ng JavaScript runtime running in a dedicated Dart [Isolate].
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
  final ReceivePort _mainPort;
  final StreamSubscription<dynamic> _mainSub;
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
  static Future<QjsRuntime> create({
    QjsRuntimeOptions options = const QjsRuntimeOptions(),
  }) async {
    final bindings = QjsBindings.load(options.libraryPath);
    final mainPort = ReceivePort();
    final replyPort = ReceivePort();
    final readyCompleter = Completer<WorkerReadyEvent>();
    QjsRuntime? runtime;
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
  /// Returns primitives, [List], [Map], [Uint8List], or `null`.
  /// Throws [QjsException] on syntax errors, runtime exceptions, or sandbox violations.
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
  /// Supports `async/await`, `setTimeout`, `fetch()`, and `sendMessage()`.
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

  /// Evaluates an ES module [code] supporting `import` / `export` and top-level `await`.
  ///
  /// Resolves to a `Map<String, dynamic>` containing the module's exported namespace.
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

  /// Registers a Dart [handler] for messages sent by JS via `sendMessage(channel, payload)`.
  void onMessage(String channel, QjsMessageHandler handler) {
    _ensureNotDisposed();
    _messageHandlers[channel] = handler;
  }

  /// Removes a previously registered message handler for [channel].
  void offMessage(String channel) {
    _messageHandlers.remove(channel);
  }

  /// Registers or replaces an ES module [source] under [specifier] in the static registry.
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

  /// Releases all native QuickJS-ng resources, HTTP clients, and shuts down the worker isolate.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    // Wake any worker thread waiting on dynamic module loading before sending dispose.
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
