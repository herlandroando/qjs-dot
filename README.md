# qjs-dot (`qjs_dot`)

> [!NOTE]
> **Project Status & Transparency**
>
> - This library was **built entirely with the assistance of an AI coding agent** for a personal hobby project.
> - **Not recommended for production use** without your own thorough security, memory, and stability audit.
> - Issues, pull requests, forks, and serious contributors who want to improve, harden, or maintain this library are **very welcome**.

A lightweight, sandboxed JavaScript runtime plugin for Flutter powered by **QuickJS-ng (`v0.18.0`)** over `dart:ffi`.

## Features

- **Modern JavaScript Engine:** Vendored QuickJS-ng `v0.18.0` supporting ES2023+ syntax, `Promise`, `async/await`, and ES Modules (`import` / `export` + dynamic `import()`).
- **Zero-KGP Android Build:** Uses Flutter `ffiPlugin: true` with CMake and a minimal Kotlin DSL `build.gradle.kts` (`com.android.library` only), compatible with AGP 8.x and AGP 9.0+ Built-in Kotlin.
- **16 KB ELF Page Alignment:** Android native shared libraries are linked with `-Wl,-z,max-page-size=16384`.
- **Dedicated Worker Isolate:** Every `QjsRuntime` runs in its own Dart `Isolate` with event-driven microtask/Promise settlement so UI frames stay smooth.
- **Built-in Polyfills:**
  - `console.log`, `info`, `warn`, `error`, `debug`
  - `setTimeout`, `clearTimeout`, `setInterval`, `clearInterval`, `queueMicrotask`
  - `sendMessage(channel, payload)` / `onMessage(channel, handler)` bidirectional Dart ↔ JS bridge
  - `fetch(input, init)` + `Headers`, `Request`, `Response` (default `dart:io` `HttpClient` or custom `QjsFetchHandler`)
  - `atob` / `btoa`, `TextEncoder` / `TextDecoder` (UTF-8), `URL` / `URLSearchParams`
- **Sandbox Guards:** Configurable `memoryLimitBytes` (`JS_SetMemoryLimit`), `maxStackSizeBytes` (`JS_SetMaxStackSize`), synchronous interrupt timeout (`JS_SetInterruptHandler`), and async evaluation timeout.

## Installation

Add `qjs_dot` via Git dependency in your `pubspec.yaml`:

```yaml
dependencies:
  qjs_dot:
    git:
      url: https://github.com/your-org/qjs-dot.git
      ref: main
```

## Quick Start

```dart
import 'package:qjs_dot/qjs_dot.dart';

Future<void> main() async {
  final js = await QjsRuntime.create(
    options: QjsRuntimeOptions(
      memoryLimitBytes: 64 * 1024 * 1024, // 64 MB
      timeout: const Duration(seconds: 5),
      onConsoleLog: (level, message) {
        print('[$level] $message');
      },
    ),
  );

  // Register a Dart handler callable from JS via sendMessage(...)
  js.onMessage('getConfig', (payload) async {
    return {'region': 'id', 'retries': 3};
  });

  // Synchronous evaluation (runs off the UI thread in the Worker Isolate)
  final sum = await js.evaluate('10 + 25');
  print(sum); // 35

  // Asynchronous evaluation (Promises, timers, fetch, sendMessage)
  final result = await js.evaluateAsync('''
    (async () => {
      const cfg = await sendMessage('getConfig', null);
      const encoder = new TextEncoder();
      return {
        region: cfg.region,
        byteLength: encoder.encode('hello 🚀').length,
      };
    })()
  ''');
  print(result);

  await js.dispose();
}
```

## Custom `fetch()` Handler

You can plug in your own HTTP stack (e.g. `dio`, `rhttp`, cookie jars, or custom proxies) via `fetchHandler`:

```dart
final js = await QjsRuntime.create(
  options: QjsRuntimeOptions(
    fetchHandler: (QjsFetchRequest req) async {
      // Forward req.url, req.method, req.headers, req.bodyBytes using your client
      return QjsFetchResponse(
        status: 200,
        statusText: 'OK',
        headers: {'content-type': 'application/json'},
        bodyBytes: utf8.encode('{"ok":true}'),
        url: req.url,
      );
    },
  ),
);
```

## ES Modules

Provide modules statically via `QjsRuntimeOptions.modules` or `registerModule`, or resolve them dynamically on demand via `moduleLoader`:

```dart
final js = await QjsRuntime.create(
  options: QjsRuntimeOptions(
    modules: {
      'math.js': 'export const add = (a, b) => a + b;',
    },
    moduleLoader: (specifier, referrer) async {
      if (specifier == 'greeting.js') {
        return 'export default "Hello from dynamic loader";';
      }
      return null;
    },
  ),
);

final exports = await js.evaluateModule('''
  import { add } from 'math.js';
  import msg from 'greeting.js';
  export const total = add(20, 22);
  export const text = msg;
''');
// exports == {'total': 42, 'text': 'Hello from dynamic loader'}
```

## Platform Support

| Platform | Build Mechanism | Status |
| :--- | :--- | :--- |
| **Android** | CMake (`externalNativeBuild`), Zero-KGP, 16 KB ELF aligned | Verified (`build apk`) |
| **Windows** | CMake (`qjs_dot.dll`) | Verified (`build windows` + test suite) |
| **Linux** | CMake (`libqjs_dot.so`) | Scaffolded |
| **iOS** | CocoaPods C forwarders | Scaffolded |
| **macOS** | CocoaPods C forwarders | Scaffolded |

## License

MIT License — see [LICENSE](LICENSE).
QuickJS-ng (`src/quickjs-ng/`) is also licensed under the MIT License; see [src/quickjs-ng/LICENSE](src/quickjs-ng/LICENSE).
