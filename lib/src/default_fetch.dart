import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

/// Default `fetch()` implementation backed by `dart:io` [HttpClient].
class DefaultQjsFetchClient {
  DefaultQjsFetchClient({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;
  bool _closed = false;

  /// Executes [request] and returns a [QjsFetchResponse].
  Future<QjsFetchResponse> fetch(QjsFetchRequest request) async {
    if (_closed) {
      throw StateError('HttpClient has already been closed');
    }

    final uri = Uri.parse(request.url);
    final httpRequest = await _client.openUrl(request.method, uri);
    httpRequest.followRedirects = true;

    request.headers.forEach((key, value) {
      httpRequest.headers.set(key, value);
    });

    if (request.bodyBytes != null && request.bodyBytes!.isNotEmpty) {
      httpRequest.add(request.bodyBytes!);
    }

    final httpResponse = await httpRequest.close();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in httpResponse) {
      builder.add(chunk);
    }

    final responseHeaders = <String, String>{};
    httpResponse.headers.forEach((name, values) {
      responseHeaders[name] = values.join(', ');
    });

    final finalUrl = httpResponse.redirects.isNotEmpty
        ? httpResponse.redirects.last.location.toString()
        : request.url;

    return QjsFetchResponse(
      status: httpResponse.statusCode,
      statusText: httpResponse.reasonPhrase,
      headers: responseHeaders,
      bodyBytes: builder.takeBytes(),
      url: finalUrl,
    );
  }

  /// Closes the underlying [HttpClient].
  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }
}
