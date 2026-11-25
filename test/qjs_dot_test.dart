import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qjs_dot/qjs_dot.dart';

String _resolveTestLibraryPath() {
  final candidates = [
    '${Directory.current.path}\\build\\windows_test\\Release\\qjs_dot.dll',
    '${Directory.current.path}\\build\\windows_test\\Debug\\qjs_dot.dll',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) {
      return path;
    }
  }
  throw StateError(
    'Compiled test DLL not found. Build src/CMakeLists.txt into build/windows_test first.',
  );
}

void main() {
  late String libPath;

  setUpAll(() {
    libPath = _resolveTestLibraryPath();
  });

  group('Lifecycle', () {
    test('creates and disposes repeatedly without errors', () async {
      for (var i = 0; i < 5; i++) {
        final js = await QjsRuntime.create(
          options: QjsRuntimeOptions(libraryPath: libPath),
        );
        expect(js.isDisposed, isFalse);
        expect(await js.evaluate('1 + $i'), equals(1 + i));
        await js.dispose();
        expect(js.isDisposed, isTrue);
        await js.dispose(); // idempotent
      }
    });

    test('throws StateError after dispose', () async {
      final js = await QjsRuntime.create(
        options: QjsRuntimeOptions(libraryPath: libPath),
      );
      await js.dispose();
      expect(() => js.evaluate('1 + 1'), throwsStateError);
    });
  });

  group('Synchronous evaluation & types', () {
    late QjsRuntime js;

    setUp(() async {
      js = await QjsRuntime.create(
        options: QjsRuntimeOptions(libraryPath: libPath),
      );
    });

    tearDown(() async {
      await js.dispose();
    });

    test('evaluates primitives, arrays, maps, Uint8List, and ES2023+ syntax', () async {
      expect(await js.evaluate('null'), isNull);
      expect(await js.evaluate('undefined'), isNull);
      expect(await js.evaluate('true'), isTrue);
      expect(await js.evaluate('false'), isFalse);
      expect(await js.evaluate('40 + 2'), equals(42));
      expect(await js.evaluate('3.14'), closeTo(3.14, 0.0001));
      expect(await js.evaluate('NaN'), isNaN);
      expect(await js.evaluate('Infinity'), equals(double.infinity));
      expect(await js.evaluate('-Infinity'), equals(double.negativeInfinity));
      expect(await js.evaluate('"hello 🚀"'), equals('hello 🚀'));

      expect(await js.evaluate('[1, "two", true, null]'), equals([1, 'two', true, null]));
      expect(
        await js.evaluate('({ a: 1, nested: { b: "ok" } })'),
        equals({
          'a': 1,
          'nested': {'b': 'ok'},
        }),
      );

      final bytes = await js.evaluate('new Uint8Array([10, 20, 30, 255])');
      expect(bytes, isA<Uint8List>());
      expect(bytes, equals(Uint8List.fromList([10, 20, 30, 255])));

      // ES2023+ features: Array.prototype.at, findLast, Object.hasOwn, private fields
      final es2023 = await js.evaluate('''
        (() => {
          class Counter {
            #value = 10;
            inc() { this.#value += 5; return this.#value; }
          }
          const arr = [1, 2, 3, 4];
          const c = new Counter();
          return {
            last: arr.at(-1),
            even: arr.findLast((x) => x % 2 === 0),
            has: Object.hasOwn({ x: 1 }, 'x'),
            count: c.inc(),
          };
        })()
      ''');
      expect(es2023, equals({'last': 4, 'even': 4, 'has': true, 'count': 15}));
    });

    test('supports global injection on create and setGlobal', () async {
      await js.dispose();
      js = await QjsRuntime.create(
        options: QjsRuntimeOptions(
          libraryPath: libPath,
          globals: {
            'APP_ENV': 'test',
            'SEED_BYTES': Uint8List.fromList([1, 2, 3]),
          },
        ),
      );

      expect(await js.evaluate('APP_ENV'), equals('test'));
      expect(
        await js.evaluate('Array.from(SEED_BYTES)'),
        equals([1, 2, 3]),
      );

      await js.setGlobal('DYNAMIC_CFG', {'limit': 99, 'enabled': true});
      expect(
        await js.evaluate('DYNAMIC_CFG.limit + (DYNAMIC_CFG.enabled ? 1 : 0)'),
        equals(100),
      );
    });
  });

  group('Async, Timers, Console & Messaging', () {
    test('supports Promise, async/await, queueMicrotask, setTimeout, setInterval', () async {
      final logs = <(QjsConsoleLevel, String)>[];
      final js = await QjsRuntime.create(
        options: QjsRuntimeOptions(
          libraryPath: libPath,
          onConsoleLog: (level, msg) => logs.add((level, msg)),
        ),
      );
      addTearDown(js.dispose);

      final asyncRes = await js.evaluateAsync('''
        (async () => {
          const order = [];
          console.debug('dbg', 1);
          console.log('hello', { ok: true });
          console.warn('careful');
          queueMicrotask(() => order.push('microtask'));
          await new Promise((resolve) => {
            const cancelled = setTimeout(() => order.push('cancelled'), 10);
            clearTimeout(cancelled);
            setTimeout(() => {
              order.push('timeout');
              resolve();
            }, 25);
          });
          let ticks = 0;
          await new Promise((resolve) => {
            const iv = setInterval(() => {
              ticks++;
              if (ticks >= 2) {
                clearInterval(iv);
                order.push('interval:' + ticks);
                resolve();
              }
            }, 15);
          });
          return order;
        })()
      ''');

      expect(asyncRes, equals(['microtask', 'timeout', 'interval:2']));
      expect(
        logs,
        equals([
          (QjsConsoleLevel.debug, 'dbg 1'),
          (QjsConsoleLevel.log, 'hello {"ok":true}'),
          (QjsConsoleLevel.warn, 'careful'),
        ]),
      );
    });

    test('supports bidirectional sendMessage/onMessage and error propagation', () async {
      final js = await QjsRuntime.create(
        options: QjsRuntimeOptions(libraryPath: libPath),
      );
      addTearDown(js.dispose);

      js.onMessage('echo', (payload) => {'received': payload});
      js.onMessage('asyncSum', (payload) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final map = payload as Map<String, dynamic>;
        return (map['a'] as int) + (map['b'] as int);
      });
      js.onMessage('fail', (_) => throw Exception('boom from dart'));

      final res = await js.evaluateAsync('''
        (async () => {
          const a = await sendMessage('echo', { hi: 'dart' });
          const b = await sendMessage('asyncSum', { a: 17, b: 25 });
          let errMsg = '';
          try {
            await sendMessage('fail', null);
          } catch (e) {
            errMsg = e.message;
          }
          return { a, b, errMsg };
        })()
      ''');

      expect(res['a'], equals({'received': {'hi': 'dart'}}));
      expect(res['b'], equals(42));
      expect(res['errMsg'], contains('boom from dart'));
    });
  });

  group('Fetch Polyfill', () {
    test('supports custom FetchHandler (GET, POST, headers, binary)', () async {
      final captured = <QjsFetchRequest>[];
      final js = await QjsRuntime.create(
        options: QjsRuntimeOptions(
          libraryPath: libPath,
          fetchHandler: (req) async {
            captured.add(req);
            if (req.url.endsWith('/json')) {
              return QjsFetchResponse(
                status: 201,
                statusText: 'Created',
                headers: {'content-type': 'application/json', 'x-custom': 'yes'},
                bodyBytes: Uint8List.fromList(utf8.encode('{"saved":true}')),
                url: req.url,
              );
            }
            return QjsFetchResponse(
              status: 200,
              statusText: 'OK',
              bodyBytes: Uint8List.fromList([1, 2, 3, 4]),
              url: req.url,
            );
          },
        ),
      );
      addTearDown(js.dispose);

      final result = await js.evaluateAsync('''
        (async () => {
          const res1 = await fetch('https://api.example.test/json', {
            method: 'POST',
            headers: { 'X-Token': 'abc' },
            body: JSON.stringify({ name: 'qjs' }),
          });
          const data = await res1.json();

          const res2 = await fetch('https://api.example.test/bin');
          const bin = await res2.bytes();

          return {
            ok: res1.ok,
            status: res1.status,
            header: res1.headers.get('X-Custom'),
            data,
            bin: Array.from(bin),
          };
        })()
      ''');

      expect(result, equals({
        'ok': true,
        'status': 201,
        'header': 'yes',
        'data': {'saved': true},
        'bin': [1, 2, 3, 4],
      }));
      expect(captured, hasLength(2));
      expect(captured[0].method, equals('POST'));
      expect(captured[0].headers['x-token'], equals('abc'));
      expect(utf8.decode(captured[0].bodyBytes!), equals('{"name":"qjs"}'));
    });

    test('supports default dart:io HttpClient fetch against local HttpServer', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((HttpRequest req) async {
        final body = await utf8.decoder.bind(req).join();
        req.response.statusCode = 200;
        req.response.headers.set('x-server', 'local-dart');
        req.response.write('echo:${req.method}:$body');
        await req.response.close();
      });

      final js = await QjsRuntime.create(
        options: QjsRuntimeOptions(libraryPath: libPath),
      );
      addTearDown(js.dispose);

      final url = 'http://127.0.0.1:${server.port}/hello';
      final res = await js.evaluateAsync('''
        (async () => {
          const r = await fetch('$url', { method: 'PUT', body: 'payload-123' });
          return {
            status: r.status,
            server: r.headers.get('x-server'),
            text: await r.text(),
          };
        })()
      ''');

      expect(res, equals({
        'status': 200,
        'server': 'local-dart',
        'text': 'echo:PUT:payload-123',
      }));
    });
  });

  group('Web APIs', () {
    test('supports atob/btoa, TextEncoder/TextDecoder, URL & URLSearchParams', () async {
      final js = await QjsRuntime.create(
        options: QjsRuntimeOptions(libraryPath: libPath),
      );
      addTearDown(js.dispose);

      final res = await js.evaluate('''
        (() => {
          const b64 = btoa('Hello, World!');
          const decodedB64 = atob(b64);

          const text = 'Halo 🌍 世界';
          const encoded = new TextEncoder().encode(text);
          const decodedText = new TextDecoder().decode(encoded);

          const u = new URL('../v2/items?a=1&b=two', 'https://example.com/api/v1/list');
          u.searchParams.append('c', 'three four');
          u.searchParams.delete('a');

          return {
            b64,
            decodedB64,
            byteLen: encoded.length,
            decodedText,
            origin: u.origin,
            pathname: u.pathname,
            href: u.href,
            bParam: u.searchParams.get('b'),
          };
        })()
      ''');

      expect(res['b64'], equals('SGVsbG8sIFdvcmxkIQ=='));
      expect(res['decodedB64'], equals('Hello, World!'));
      expect(res['byteLen'], equals(utf8.encode('Halo 🌍 世界').length));
      expect(res['decodedText'], equals('Halo 🌍 世界'));
      expect(res['origin'], equals('https://example.com'));
      expect(res['pathname'], equals('/api/v2/items'));
      expect(res['href'], equals('https://example.com/api/v2/items?b=two&c=three+four'));
      expect(res['bParam'], equals('two'));
    });
  });

  group('ES Modules', () {
    test('supports static registry with relative imports, dynamic moduleLoader, and dynamic import()', () async {
      final js = await QjsRuntime.create(
        options: QjsRuntimeOptions(
          libraryPath: libPath,
          modules: {
            'pkg/utils/math.js': 'export const multiply = (a, b) => a * b;',
            'pkg/entry_helper.js': '''
              import { multiply } from './utils/math.js';
              export const square = (x) => multiply(x, x);
            ''',
          },
          moduleLoader: (specifier, referrer) async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            if (specifier == 'dynamic/greeting.js') {
              return 'export const greet = (name) => "Hi " + name;';
            }
            if (specifier == 'dynamic/lazy.js') {
              return 'export default 777;';
            }
            return null;
          },
        ),
      );
      addTearDown(js.dispose);

      await js.registerModule('pkg/constants.js', 'export const FACTOR = 6;');

      final exports = await js.evaluateModule('''
        import { square } from './entry_helper.js';
        import { FACTOR } from 'pkg/constants.js';
        import { greet } from 'dynamic/greeting.js';
        const lazy = await import('dynamic/lazy.js');
        export const result = square(FACTOR);
        export const message = greet('Dart');
        export const lazyVal = lazy.default;
      ''', filename: 'pkg/main.js');

      expect(exports, equals({
        'result': 36,
        'message': 'Hi Dart',
        'lazyVal': 777,
      }));
    });

    test('throws QjsException when module is missing', () async {
      final js = await QjsRuntime.create(
        options: QjsRuntimeOptions(libraryPath: libPath),
      );
      addTearDown(js.dispose);

      expect(
        () => js.evaluateModule("import 'non_existent.js'; export const x = 1;"),
        throwsA(isA<QjsException>()),
      );
    });
  });

  group('Errors, Sandbox & Memory Stability', () {
    test('captures SyntaxError and ReferenceError with stack trace', () async {
      final js = await QjsRuntime.create(
        options: QjsRuntimeOptions(libraryPath: libPath),
      );
      addTearDown(js.dispose);

      await expectLater(
        () => js.evaluate('const x = ;'),
        throwsA(
          isA<QjsException>().having((e) => e.name, 'name', 'SyntaxError'),
        ),
      );

      await expectLater(
        () => js.evaluate('function boom() { return missingVar; } boom();'),
        throwsA(
          isA<QjsException>()
              .having((e) => e.name, 'name', 'ReferenceError')
              .having((e) => e.stack, 'stack', contains('boom')),
        ),
      );
    });

    test('aborts synchronous infinite loops via interrupt handler', () async {
      final js = await QjsRuntime.create(
        options: QjsRuntimeOptions(
          libraryPath: libPath,
          timeout: const Duration(milliseconds: 120),
        ),
      );
      addTearDown(js.dispose);

      await expectLater(
        () => js.evaluate('while (true) {}'),
        throwsA(
          isA<QjsException>().having((e) => e.isTimeout, 'isTimeout', isTrue),
        ),
      );

      // Runtime remains responsive after interruption.
      expect(await js.evaluate('2 + 3'), equals(5));
    });

    test('aborts unresolved Promises via async timeout', () async {
      final js = await QjsRuntime.create(
        options: QjsRuntimeOptions(
          libraryPath: libPath,
          timeout: const Duration(milliseconds: 100),
        ),
      );
      addTearDown(js.dispose);

      await expectLater(
        () => js.evaluateAsync('new Promise(() => {})'),
        throwsA(
          isA<QjsException>().having((e) => e.isTimeout, 'isTimeout', isTrue),
        ),
      );
    });

    test('enforces memory limit and stack guard cleanly', () async {
      final js = await QjsRuntime.create(
        options: QjsRuntimeOptions(
          libraryPath: libPath,
          memoryLimitBytes: 2 * 1024 * 1024, // 2 MB
          maxStackSizeBytes: 256 * 1024,
        ),
      );
      addTearDown(js.dispose);

      await expectLater(
        () => js.evaluate('function rec() { return rec(); } rec();'),
        throwsA(
          isA<QjsException>().having((e) => e.name, 'name', 'RangeError'),
        ),
      );

      await expectLater(
        () => js.evaluate('new Uint8Array(10 * 1024 * 1024)'),
        throwsA(
          isA<QjsException>()
              .having((e) => e.isMemoryLimit, 'isMemoryLimit', isTrue),
        ),
      );
    });

    test('remains memory-stable over 10,000 repeated evaluations', () async {
      final js = await QjsRuntime.create(
        options: QjsRuntimeOptions(libraryPath: libPath),
      );
      addTearDown(js.dispose);

      final before = await js.getMemoryUsage();
      for (var i = 0; i < 10000; i++) {
        final v = await js.evaluate('($i * 2) + 1');
        if (v != (i * 2) + 1) {
          fail('Unexpected evaluation result at $i: $v');
        }
      }
      final after = await js.getMemoryUsage();
      final deltaBytes = after.memoryUsedSize - before.memoryUsedSize;
      // Should stay well under 2 MB growth across 10,000 iterations.
      expect(deltaBytes, lessThan(2 * 1024 * 1024));
    });
  });
}
