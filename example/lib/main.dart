import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qjs_dot/qjs_dot.dart';

void main() {
  runApp(const QjsDotExampleApp());
}

class QjsDotExampleApp extends StatelessWidget {
  const QjsDotExampleApp({super.key, this.autoInit = true});

  final bool autoInit;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'qjs-dot Playground',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: PlaygroundPage(autoInit: autoInit),
    );
  }
}

class PlaygroundPage extends StatefulWidget {
  const PlaygroundPage({super.key, this.autoInit = true});

  final bool autoInit;

  @override
  State<PlaygroundPage> createState() => _PlaygroundPageState();
}

class _PlaygroundPageState extends State<PlaygroundPage> {
  QjsRuntime? _runtime;
  final List<String> _logs = [];
  String _output = 'Initializing runtime...';
  bool _running = false;

  final _codeController = TextEditingController(
    text: '''
(async () => {
  console.log('Running inside QuickJS-ng Worker Isolate!');
  const msg = await sendMessage('ping', { from: 'js' });
  const encoded = new TextEncoder().encode('qjs-dot');
  return {
    messageReply: msg,
    utf8Bytes: Array.from(encoded),
    url: new URL('/v1/items?ok=1', 'https://example.org').href,
  };
})()
'''.trim(),
  );

  @override
  void initState() {
    super.initState();
    if (widget.autoInit) {
      _initRuntime();
    } else {
      _output = 'Runtime init skipped.';
    }
  }

  Future<void> _initRuntime() async {
    try {
      final rt = await QjsRuntime.create(
        options: QjsRuntimeOptions(
          timeout: const Duration(seconds: 3),
          onConsoleLog: (level, message) {
            if (!mounted) return;
            setState(() {
              _logs.add('[${level.name}] $message');
            });
          },
          fetchHandler: (req) async {
            return QjsFetchResponse(
              status: 200,
              statusText: 'OK',
              headers: {'content-type': 'application/json'},
              bodyBytes: Uint8List.fromList(
                utf8.encode(
                  jsonEncode({'echoUrl': req.url, 'method': req.method}),
                ),
              ),
              url: req.url,
            );
          },
          modules: {
            'math.js': 'export const add = (a, b) => a + b;',
          },
        ),
      );

      rt.onMessage('ping', (payload) async {
        return {'pong': true, 'received': payload};
      });

      if (!mounted) {
        await rt.dispose();
        return;
      }

      setState(() {
        _runtime = rt;
        _output = 'Runtime ready.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _output = 'Init error:\n$e';
      });
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    _runtime?.dispose();
    super.dispose();
  }

  Future<void> _runSnippet({bool asModule = false}) async {
    final rt = _runtime;
    if (rt == null || _running) return;
    setState(() {
      _running = true;
      _logs.clear();
    });
    try {
      final result = asModule
          ? await rt.evaluateModule(_codeController.text)
          : await rt.evaluateAsync(_codeController.text);
      setState(() {
        _output = const JsonEncoder.withIndent('  ').convert(result);
      });
    } catch (e) {
      setState(() {
        _output = 'ERROR:\n$e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
        });
      }
    }
  }

  Future<void> _runInfiniteLoopTest() async {
    _codeController.text = 'while (true) {}';
    await _runSnippet();
  }

  Future<void> _runModuleDemo() async {
    _codeController.text = '''
import { add } from 'math.js';
export const sum = add(19, 23);
export const note = 'ES Module OK';
'''.trim();
    await _runSnippet(asModule: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('qjs-dot Playground')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _codeController,
              maxLines: 8,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                labelText: 'JavaScript',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: _runtime == null || _running ? null : () => _runSnippet(),
                  child: const Text('Run Async'),
                ),
                OutlinedButton(
                  onPressed: _runtime == null || _running ? null : _runModuleDemo,
                  child: const Text('ES Module Demo'),
                ),
                OutlinedButton(
                  onPressed: _runtime == null || _running ? null : _runInfiniteLoopTest,
                  child: const Text('Timeout Guard'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Result', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _output,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ),
            if (_logs.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('Console', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(
                height: 80,
                child: ListView(
                  children: _logs
                      .map((l) => Text(l, style: const TextStyle(fontSize: 12)))
                      .toList(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
