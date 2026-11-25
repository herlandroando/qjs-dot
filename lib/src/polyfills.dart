import 'dart:convert';
import 'dart:typed_data';

/// Builds the JavaScript bootstrap script injected once per QuickJS-ng context.
String buildPolyfillBootstrap({required bool enableFetchPolyfill}) {
  return '''
(function(global) {
  'use strict';

  // --- Base64 helpers (RFC 4648) ---
  var _B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var _B64_LOOKUP = new Uint8Array(256);
  _B64_LOOKUP.fill(255);
  for (var i = 0; i < _B64_CHARS.length; i++) {
    _B64_LOOKUP[_B64_CHARS.charCodeAt(i)] = i;
  }

  function _bytesToBase64(bytes) {
    var len = bytes.length;
    var out = '';
    for (var i = 0; i < len; i += 3) {
      var b0 = bytes[i];
      var b1 = i + 1 < len ? bytes[i + 1] : 0;
      var b2 = i + 2 < len ? bytes[i + 2] : 0;
      var triplet = (b0 << 16) | (b1 << 8) | b2;
      out += _B64_CHARS[(triplet >> 18) & 63];
      out += _B64_CHARS[(triplet >> 12) & 63];
      out += i + 1 < len ? _B64_CHARS[(triplet >> 6) & 63] : '=';
      out += i + 2 < len ? _B64_CHARS[triplet & 63] : '=';
    }
    return out;
  }

  function _base64ToBytes(b64) {
    var clean = String(b64).replace(/[\\t\\n\\f\\r ]+/g, '');
    if (clean.length % 4 === 1) {
      throw new Error('Invalid base64 string');
    }
    var pad = 0;
    if (clean.endsWith('==')) pad = 2;
    else if (clean.endsWith('=')) pad = 1;
    var outLen = (clean.length / 4) * 3 - pad;
    var out = new Uint8Array(outLen);
    var pos = 0;
    for (var i = 0; i < clean.length; i += 4) {
      var c0 = _B64_LOOKUP[clean.charCodeAt(i)];
      var c1 = _B64_LOOKUP[clean.charCodeAt(i + 1)];
      var c2 = clean[i + 2] === '=' ? 0 : _B64_LOOKUP[clean.charCodeAt(i + 2)];
      var c3 = clean[i + 3] === '=' ? 0 : _B64_LOOKUP[clean.charCodeAt(i + 3)];
      if (c0 === 255 || c1 === 255 || (clean[i + 2] !== '=' && c2 === 255) || (clean[i + 3] !== '=' && c3 === 255)) {
        throw new Error('Invalid character in base64 string');
      }
      var triplet = (c0 << 18) | (c1 << 12) | (c2 << 6) | c3;
      if (pos < outLen) out[pos++] = (triplet >> 16) & 255;
      if (pos < outLen) out[pos++] = (triplet >> 8) & 255;
      if (pos < outLen) out[pos++] = triplet & 255;
    }
    return out;
  }

  // --- Value Marshaling between JS and Dart ---
  function _sanitize(value, seen) {
    if (value === null || value === undefined) return null;
    var t = typeof value;
    if (t === 'boolean' || t === 'string') return value;
    if (t === 'number') {
      if (Number.isNaN(value)) return { __qjs_dot_t: 'n', d: 'NaN' };
      if (value === Infinity) return { __qjs_dot_t: 'n', d: 'Inf' };
      if (value === -Infinity) return { __qjs_dot_t: 'n', d: '-Inf' };
      return value;
    }
    if (t === 'bigint') return value.toString();
    if (t === 'function' || t === 'symbol') return undefined;

    if (value instanceof ArrayBuffer) {
      return { __qjs_dot_t: 'b', d: _bytesToBase64(new Uint8Array(value)) };
    }
    if (ArrayBuffer.isView(value)) {
      var bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
      return { __qjs_dot_t: 'b', d: _bytesToBase64(bytes) };
    }
    if (value instanceof Date) {
      return value.toISOString();
    }
    if (value instanceof Error) {
      return { name: value.name, message: value.message, stack: value.stack || '' };
    }

    if (seen.has(value)) return '[Circular]';
    seen.add(value);

    try {
      if (Array.isArray(value)) {
        var arr = new Array(value.length);
        for (var i = 0; i < value.length; i++) {
          var item = _sanitize(value[i], seen);
          arr[i] = item === undefined ? null : item;
        }
        return arr;
      }
      var obj = {};
      var keys = Object.keys(value);
      for (var j = 0; j < keys.length; j++) {
        var k = keys[j];
        var v = _sanitize(value[k], seen);
        if (v !== undefined) {
          obj[k] = v;
        }
      }
      return obj;
    } finally {
      seen.delete(value);
    }
  }

  global.__qjs_dot_encode = function(value) {
    if (value === null || value === undefined) return null;
    var t = typeof value;
    if (t === 'number') {
      if (Number.isNaN(value)) return JSON.stringify({ k: 'n', v: 'NaN' });
      if (value === Infinity) return JSON.stringify({ k: 'n', v: 'Inf' });
      if (value === -Infinity) return JSON.stringify({ k: 'n', v: '-Inf' });
      return JSON.stringify({ k: 'j', v: value });
    }
    if (t === 'boolean' || t === 'string') {
      return JSON.stringify({ k: 'j', v: value });
    }
    if (t === 'bigint') {
      return JSON.stringify({ k: 'i', v: value.toString() });
    }
    if (value instanceof ArrayBuffer) {
      return JSON.stringify({ k: 'b', v: _bytesToBase64(new Uint8Array(value)) });
    }
    if (ArrayBuffer.isView(value)) {
      var view = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
      return JSON.stringify({ k: 'b', v: _bytesToBase64(view) });
    }
    var sanitized = _sanitize(value, new Set());
    if (sanitized === undefined) return null;
    return JSON.stringify({ k: 'j', v: sanitized });
  };

  function _unwrapDartValue(v) {
    if (v === null || typeof v !== 'object') return v;
    if (Array.isArray(v)) {
      for (var i = 0; i < v.length; i++) {
        v[i] = _unwrapDartValue(v[i]);
      }
      return v;
    }
    if (v.__qjs_dot_t === 'b' && typeof v.d === 'string') {
      return _base64ToBytes(v.d);
    }
    if (v.__qjs_dot_t === 'n') {
      if (v.d === 'NaN') return NaN;
      if (v.d === 'Inf') return Infinity;
      if (v.d === '-Inf') return -Infinity;
    }
    var keys = Object.keys(v);
    for (var j = 0; j < keys.length; j++) {
      var k = keys[j];
      v[k] = _unwrapDartValue(v[k]);
    }
    return v;
  }

  global.__qjs_dot_decode = function(jsonStr) {
    if (jsonStr === null || jsonStr === undefined) return null;
    var parsed = JSON.parse(jsonStr);
    return _unwrapDartValue(parsed);
  };

  global.__qjs_dot_set_global = function(name, jsonStr) {
    global[name] = global.__qjs_dot_decode(jsonStr);
  };

  // --- Async Promise settlement bridge ---
  global.__qjs_dot_attach_promise = function(evalId, promise, resolveOverride) {
    Promise.resolve(promise).then(
      function(val) {
        var finalVal = resolveOverride !== undefined ? resolveOverride : val;
        var encoded = global.__qjs_dot_encode(finalVal);
        global.__qjs_dot_eval_settled(evalId, 1, encoded, null, null, null);
      },
      function(err) {
        var errName = 'Error';
        var errMsg = String(err);
        var errStack = null;
        if (err && typeof err === 'object') {
          if (err.name) errName = String(err.name);
          if (err.message !== undefined) errMsg = String(err.message);
          if (err.stack) errStack = String(err.stack);
        }
        global.__qjs_dot_eval_settled(evalId, 0, null, errName, errMsg, errStack);
      }
    );
  };

  // --- console.* ---
  function _formatArg(arg) {
    if (arg === undefined) return 'undefined';
    if (arg === null) return 'null';
    var t = typeof arg;
    if (t === 'string') return arg;
    if (t === 'number' || t === 'boolean' || t === 'bigint' || t === 'symbol') {
      return String(arg);
    }
    if (t === 'function') return '[Function: ' + (arg.name || 'anonymous') + ']';
    if (arg instanceof Error) {
      return arg.stack ? (arg.name + ': ' + arg.message + '\\n' + arg.stack) : (arg.name + ': ' + arg.message);
    }
    try {
      return JSON.stringify(_sanitize(arg, new Set()));
    } catch (_) {
      return String(arg);
    }
  }

  function _log(level, args) {
    var parts = new Array(args.length);
    for (var i = 0; i < args.length; i++) {
      parts[i] = _formatArg(args[i]);
    }
    global.__qjs_dot_console(level, parts.join(' '));
  }

  global.console = {
    debug: function() { _log(0, arguments); },
    log: function() { _log(1, arguments); },
    info: function() { _log(2, arguments); },
    warn: function() { _log(3, arguments); },
    error: function() { _log(4, arguments); },
  };

  // --- Timers & queueMicrotask ---
  var _nextTimerId = 1;
  var _timers = new Map();

  function _scheduleTimer(fn, delay, isInterval, args) {
    if (typeof fn !== 'function') {
      var code = String(fn);
      fn = function() { (0, eval)(code); };
    }
    var id = _nextTimerId++;
    var ms = Number(delay);
    if (!Number.isFinite(ms) || ms < 0) ms = 0;
    ms = Math.floor(ms);
    _timers.set(id, { fn: fn, args: args, isInterval: isInterval });
    global.__qjs_dot_set_timer(id, ms, isInterval ? 1 : 0);
    return id;
  }

  global.setTimeout = function(fn, delay) {
    var args = Array.prototype.slice.call(arguments, 2);
    return _scheduleTimer(fn, delay, false, args);
  };

  global.setInterval = function(fn, delay) {
    var args = Array.prototype.slice.call(arguments, 2);
    return _scheduleTimer(fn, delay, true, args);
  };

  global.clearTimeout = function(id) {
    if (_timers.delete(id)) {
      global.__qjs_dot_clear_timer(id);
    }
  };

  global.clearInterval = global.clearTimeout;

  global.__qjs_dot_fire_timer = function(id) {
    var entry = _timers.get(id);
    if (!entry) return;
    if (!entry.isInterval) {
      _timers.delete(id);
    }
    entry.fn.apply(global, entry.args);
  };

  if (typeof global.queueMicrotask !== 'function') {
    global.queueMicrotask = function(cb) {
      if (typeof cb !== 'function') {
        throw new TypeError('queueMicrotask requires a function');
      }
      Promise.resolve().then(cb);
    };
  }

  // --- Bidirectional sendMessage(channel, payload) ---
  var _nextMsgId = 1;
  var _pendingMessages = new Map();

  global.sendMessage = function(channel, payload) {
    if (typeof channel !== 'string' || channel.length === 0) {
      return Promise.reject(new TypeError('channel must be a non-empty string'));
    }
    var id = _nextMsgId++;
    var serialized = JSON.stringify(_sanitize(payload === undefined ? null : payload, new Set()));
    return new Promise(function(resolve, reject) {
      _pendingMessages.set(id, { resolve: resolve, reject: reject });
      global.__qjs_dot_post_message(id, channel, serialized);
    });
  };

  global.__qjs_dot_resolve_message = function(id, ok, resultJson, errorMessage) {
    var pending = _pendingMessages.get(id);
    if (!pending) return;
    _pendingMessages.delete(id);
    if (ok) {
      pending.resolve(resultJson === null ? null : global.__qjs_dot_decode(resultJson));
    } else {
      pending.reject(new Error(errorMessage || 'Host message handler failed'));
    }
  };

  // --- atob / btoa ---
  global.btoa = function(input) {
    var str = String(input);
    var bytes = new Uint8Array(str.length);
    for (var i = 0; i < str.length; i++) {
      var code = str.charCodeAt(i);
      if (code > 255) {
        throw new Error('btoa failed: character outside Latin-1 range');
      }
      bytes[i] = code;
    }
    return _bytesToBase64(bytes);
  };

  global.atob = function(input) {
    var bytes = _base64ToBytes(input);
    var out = '';
    for (var i = 0; i < bytes.length; i++) {
      out += String.fromCharCode(bytes[i]);
    }
    return out;
  };

  // --- TextEncoder / TextDecoder (UTF-8) ---
  function TextEncoder() {
    this.encoding = 'utf-8';
  }
  TextEncoder.prototype.encode = function(input) {
    var str = input === undefined ? '' : String(input);
    var out = [];
    for (var i = 0; i < str.length; i++) {
      var cp = str.charCodeAt(i);
      if (cp < 0x80) {
        out.push(cp);
      } else if (cp < 0x800) {
        out.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
      } else if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < str.length) {
        var low = str.charCodeAt(i + 1);
        if (low >= 0xdc00 && low <= 0xdfff) {
          i++;
          var full = 0x10000 + (((cp - 0xd800) << 10) | (low - 0xdc00));
          out.push(
            0xf0 | (full >> 18),
            0x80 | ((full >> 12) & 0x3f),
            0x80 | ((full >> 6) & 0x3f),
            0x80 | (full & 0x3f)
          );
          continue;
        }
        out.push(0xef, 0xbf, 0xbd);
      } else if (cp >= 0xd800 && cp <= 0xdfff) {
        out.push(0xef, 0xbf, 0xbd);
      } else {
        out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
      }
    }
    return new Uint8Array(out);
  };
  TextEncoder.prototype.encodeInto = function(source, destination) {
    var encoded = this.encode(source);
    var written = Math.min(encoded.length, destination.length);
    destination.set(encoded.subarray(0, written));
    return { read: source.length, written: written };
  };

  function TextDecoder(label) {
    var norm = (label === undefined ? 'utf-8' : String(label)).trim().toLowerCase();
    if (norm !== 'utf-8' && norm !== 'utf8' && norm !== 'unicode-1-1-utf-8') {
      throw new RangeError('Unsupported encoding: ' + label);
    }
    this.encoding = 'utf-8';
  }
  TextDecoder.prototype.decode = function(input) {
    if (input === undefined || input === null) return '';
    var bytes;
    if (input instanceof Uint8Array) {
      bytes = input;
    } else if (input instanceof ArrayBuffer) {
      bytes = new Uint8Array(input);
    } else if (ArrayBuffer.isView(input)) {
      bytes = new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
    } else {
      throw new TypeError('TextDecoder.decode requires an ArrayBuffer or ArrayBufferView');
    }

    var out = '';
    var i = 0;
    while (i < bytes.length) {
      var b0 = bytes[i++];
      if (b0 < 0x80) {
        out += String.fromCharCode(b0);
      } else if ((b0 & 0xe0) === 0xc0 && i < bytes.length) {
        var b1 = bytes[i++];
        if ((b1 & 0xc0) === 0x80) {
          out += String.fromCharCode(((b0 & 0x1f) << 6) | (b1 & 0x3f));
        } else {
          out += '\\ufffd';
        }
      } else if ((b0 & 0xf0) === 0xe0 && i + 1 < bytes.length) {
        var c1 = bytes[i++];
        var c2 = bytes[i++];
        if ((c1 & 0xc0) === 0x80 && (c2 & 0xc0) === 0x80) {
          out += String.fromCharCode(((b0 & 0x0f) << 12) | ((c1 & 0x3f) << 6) | (c2 & 0x3f));
        } else {
          out += '\\ufffd';
        }
      } else if ((b0 & 0xf8) === 0xf0 && i + 2 < bytes.length) {
        var d1 = bytes[i++];
        var d2 = bytes[i++];
        var d3 = bytes[i++];
        if ((d1 & 0xc0) === 0x80 && (d2 & 0xc0) === 0x80 && (d3 & 0xc0) === 0x80) {
          var cp = ((b0 & 0x07) << 18) | ((d1 & 0x3f) << 12) | ((d2 & 0x3f) << 6) | (d3 & 0x3f);
          if (cp <= 0x10ffff) {
            cp -= 0x10000;
            out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
          } else {
            out += '\\ufffd';
          }
        } else {
          out += '\\ufffd';
        }
      } else {
        out += '\\ufffd';
      }
    }
    return out;
  };

  global.TextEncoder = TextEncoder;
  global.TextDecoder = TextDecoder;

  // --- URL & URLSearchParams ---
  function URLSearchParams(init) {
    this._entries = [];
    this._onChange = null;
    if (init instanceof URLSearchParams) {
      for (var i = 0; i < init._entries.length; i++) {
        this._entries.push([init._entries[i][0], init._entries[i][1]]);
      }
    } else if (Array.isArray(init)) {
      for (var j = 0; j < init.length; j++) {
        var pair = init[j];
        if (!Array.isArray(pair) || pair.length !== 2) {
          throw new TypeError('URLSearchParams sequence element must have length 2');
        }
        this._entries.push([String(pair[0]), String(pair[1])]);
      }
    } else if (init && typeof init === 'object') {
      var keys = Object.keys(init);
      for (var k = 0; k < keys.length; k++) {
        this._entries.push([keys[k], String(init[keys[k]])]);
      }
    } else if (typeof init === 'string') {
      var q = init.startsWith('?') ? init.slice(1) : init;
      if (q.length > 0) {
        var parts = q.split('&');
        for (var p = 0; p < parts.length; p++) {
          var part = parts[p];
          if (part.length === 0) continue;
          var eq = part.indexOf('=');
          var rawKey = eq >= 0 ? part.slice(0, eq) : part;
          var rawVal = eq >= 0 ? part.slice(eq + 1) : '';
          this._entries.push([
            decodeURIComponent(rawKey.replace(/\\+/g, ' ')),
            decodeURIComponent(rawVal.replace(/\\+/g, ' ')),
          ]);
        }
      }
    }
  }
  URLSearchParams.prototype._notify = function() {
    if (typeof this._onChange === 'function') this._onChange();
  };
  URLSearchParams.prototype.append = function(name, value) {
    this._entries.push([String(name), String(value)]);
    this._notify();
  };
  URLSearchParams.prototype.delete = function(name) {
    var n = String(name);
    this._entries = this._entries.filter(function(e) { return e[0] !== n; });
    this._notify();
  };
  URLSearchParams.prototype.get = function(name) {
    var n = String(name);
    for (var i = 0; i < this._entries.length; i++) {
      if (this._entries[i][0] === n) return this._entries[i][1];
    }
    return null;
  };
  URLSearchParams.prototype.getAll = function(name) {
    var n = String(name);
    var res = [];
    for (var i = 0; i < this._entries.length; i++) {
      if (this._entries[i][0] === n) res.push(this._entries[i][1]);
    }
    return res;
  };
  URLSearchParams.prototype.has = function(name) {
    var n = String(name);
    for (var i = 0; i < this._entries.length; i++) {
      if (this._entries[i][0] === n) return true;
    }
    return false;
  };
  URLSearchParams.prototype.set = function(name, value) {
    var n = String(name);
    var v = String(value);
    var replaced = false;
    var next = [];
    for (var i = 0; i < this._entries.length; i++) {
      if (this._entries[i][0] === n) {
        if (!replaced) {
          next.push([n, v]);
          replaced = true;
        }
      } else {
        next.push(this._entries[i]);
      }
    }
    if (!replaced) next.push([n, v]);
    this._entries = next;
    this._notify();
  };
  URLSearchParams.prototype.sort = function() {
    this._entries.sort(function(a, b) {
      return a[0] < b[0] ? -1 : (a[0] > b[0] ? 1 : 0);
    });
    this._notify();
  };
  URLSearchParams.prototype.entries = function() {
    return this._entries.map(function(e) { return [e[0], e[1]]; })[Symbol.iterator]();
  };
  URLSearchParams.prototype.keys = function() {
    return this._entries.map(function(e) { return e[0]; })[Symbol.iterator]();
  };
  URLSearchParams.prototype.values = function() {
    return this._entries.map(function(e) { return e[1]; })[Symbol.iterator]();
  };
  URLSearchParams.prototype[Symbol.iterator] = URLSearchParams.prototype.entries;
  URLSearchParams.prototype.forEach = function(cb, thisArg) {
    for (var i = 0; i < this._entries.length; i++) {
      cb.call(thisArg, this._entries[i][1], this._entries[i][0], this);
    }
  };
  URLSearchParams.prototype.toString = function() {
    return this._entries.map(function(e) {
      return encodeURIComponent(e[0]).replace(/%20/g, '+') + '=' + encodeURIComponent(e[1]).replace(/%20/g, '+');
    }).join('&');
  };

  function _normalizePath(path) {
    var segs = path.split('/');
    var out = [];
    for (var i = 0; i < segs.length; i++) {
      var s = segs[i];
      if (s === '' || s === '.') continue;
      if (s === '..') {
        if (out.length > 0) out.pop();
      } else {
        out.push(s);
      }
    }
    return '/' + out.join('/') + (path.endsWith('/') && out.length > 0 ? '/' : '');
  }

  function _parseUrl(raw, base) {
    var str = String(raw).trim();
    var m = /^([a-zA-Z][a-zA-Z0-9+.-]*):\\/\\/([^\\/?#]*)([^?#]*)(\\?[^#]*)?(#.*)?\$/.exec(str);
    if (!m && base !== undefined) {
      var b = base instanceof URL ? base : new URL(String(base));
      if (str.startsWith('//')) {
        m = /^([a-zA-Z][a-zA-Z0-9+.-]*):\\/\\/([^\\/?#]*)([^?#]*)(\\?[^#]*)?(#.*)?\$/.exec(b.protocol + str);
      } else {
        var qIdx = str.indexOf('?');
        var hIdx = str.indexOf('#');
        var pathEnd = str.length;
        if (qIdx >= 0) pathEnd = Math.min(pathEnd, qIdx);
        if (hIdx >= 0) pathEnd = Math.min(pathEnd, hIdx);
        var relPath = str.slice(0, pathEnd);
        var relSearch = qIdx >= 0 && (hIdx < 0 || qIdx < hIdx)
            ? str.slice(qIdx, hIdx >= 0 ? hIdx : str.length)
            : '';
        var relHash = hIdx >= 0 ? str.slice(hIdx) : '';
        var resolvedPath;
        if (relPath.length === 0) {
          resolvedPath = b.pathname;
          if (!relSearch) relSearch = b.search;
        } else if (relPath.startsWith('/')) {
          resolvedPath = _normalizePath(relPath);
        } else {
          var baseDir = b.pathname.slice(0, b.pathname.lastIndexOf('/') + 1);
          resolvedPath = _normalizePath(baseDir + relPath);
        }
        return {
          protocol: b.protocol,
          username: b.username,
          password: b.password,
          hostname: b.hostname,
          port: b.port,
          pathname: resolvedPath,
          search: relSearch,
          hash: relHash,
        };
      }
    }
    if (!m) {
      throw new TypeError('Invalid URL: ' + raw);
    }
    var protocol = m[1].toLowerCase() + ':';
    var authority = m[2] || '';
    var username = '';
    var password = '';
    var hostPart = authority;
    var atIdx = authority.lastIndexOf('@');
    if (atIdx >= 0) {
      var creds = authority.slice(0, atIdx);
      hostPart = authority.slice(atIdx + 1);
      var colonIdx = creds.indexOf(':');
      if (colonIdx >= 0) {
        username = creds.slice(0, colonIdx);
        password = creds.slice(colonIdx + 1);
      } else {
        username = creds;
      }
    }
    var hostname = hostPart;
    var port = '';
    if (hostPart.startsWith('[')) {
      var closeBracket = hostPart.indexOf(']');
      if (closeBracket >= 0) {
        hostname = hostPart.slice(0, closeBracket + 1);
        if (hostPart[closeBracket + 1] === ':') {
          port = hostPart.slice(closeBracket + 2);
        }
      }
    } else {
      var portColon = hostPart.lastIndexOf(':');
      if (portColon >= 0) {
        hostname = hostPart.slice(0, portColon);
        port = hostPart.slice(portColon + 1);
      }
    }
    if ((protocol === 'http:' && port === '80') || (protocol === 'https:' && port === '443')) {
      port = '';
    }
    return {
      protocol: protocol,
      username: username,
      password: password,
      hostname: hostname.toLowerCase(),
      port: port,
      pathname: _normalizePath(m[3] || '/'),
      search: m[4] === '?' ? '' : (m[4] || ''),
      hash: m[5] === '#' ? '' : (m[5] || ''),
    };
  }

  function URL(url, base) {
    var parsed = _parseUrl(url, base);
    this.protocol = parsed.protocol;
    this.username = parsed.username;
    this.password = parsed.password;
    this.hostname = parsed.hostname;
    this.port = parsed.port;
    this.pathname = parsed.pathname;
    this._search = parsed.search;
    this.hash = parsed.hash;
    var self = this;
    this._searchParams = new URLSearchParams(this._search);
    this._searchParams._onChange = function() {
      var qs = self._searchParams.toString();
      self._search = qs.length > 0 ? '?' + qs : '';
    };
  }
  Object.defineProperties(URL.prototype, {
    host: {
      get: function() { return this.port ? this.hostname + ':' + this.port : this.hostname; },
      enumerable: true,
    },
    origin: {
      get: function() { return this.protocol + '//' + this.host; },
      enumerable: true,
    },
    search: {
      get: function() { return this._search; },
      set: function(val) {
        var s = String(val);
        this._search = s.length > 0 ? (s.startsWith('?') ? s : '?' + s) : '';
        var self = this;
        this._searchParams = new URLSearchParams(this._search);
        this._searchParams._onChange = function() {
          var qs = self._searchParams.toString();
          self._search = qs.length > 0 ? '?' + qs : '';
        };
      },
      enumerable: true,
    },
    searchParams: {
      get: function() { return this._searchParams; },
      enumerable: true,
    },
    href: {
      get: function() {
        var auth = '';
        if (this.username) {
          auth = this.username + (this.password ? ':' + this.password : '') + '@';
        }
        return this.protocol + '//' + auth + this.host + this.pathname + this._search + this.hash;
      },
      enumerable: true,
    },
  });
  URL.prototype.toString = function() { return this.href; };
  URL.prototype.toJSON = function() { return this.href; };

  global.URLSearchParams = URLSearchParams;
  global.URL = URL;

  // --- Fetch Polyfill (Headers, Request, Response, fetch) ---
  if (${enableFetchPolyfill ? 'true' : 'false'}) {
    function Headers(init) {
      this._map = new Map();
      if (init instanceof Headers) {
        init._map.forEach(function(v, k) { this._map.set(k, v); }, this);
      } else if (Array.isArray(init)) {
        for (var i = 0; i < init.length; i++) {
          this.append(init[i][0], init[i][1]);
        }
      } else if (init && typeof init === 'object') {
        var keys = Object.keys(init);
        for (var j = 0; j < keys.length; j++) {
          this.set(keys[j], init[keys[j]]);
        }
      }
    }
    Headers.prototype.append = function(name, value) {
      var k = String(name).toLowerCase();
      var v = String(value);
      this._map.set(k, this._map.has(k) ? this._map.get(k) + ', ' + v : v);
    };
    Headers.prototype.delete = function(name) {
      this._map.delete(String(name).toLowerCase());
    };
    Headers.prototype.get = function(name) {
      var v = this._map.get(String(name).toLowerCase());
      return v === undefined ? null : v;
    };
    Headers.prototype.has = function(name) {
      return this._map.has(String(name).toLowerCase());
    };
    Headers.prototype.set = function(name, value) {
      this._map.set(String(name).toLowerCase(), String(value));
    };
    Headers.prototype.forEach = function(cb, thisArg) {
      this._map.forEach(function(v, k) { cb.call(thisArg, v, k, this); }, this);
    };
    Headers.prototype.entries = function() { return this._map.entries(); };
    Headers.prototype.keys = function() { return this._map.keys(); };
    Headers.prototype.values = function() { return this._map.values(); };
    Headers.prototype[Symbol.iterator] = Headers.prototype.entries;
    Headers.prototype._toPlainObject = function() {
      var obj = {};
      this._map.forEach(function(v, k) { obj[k] = v; });
      return obj;
    };

    function Request(input, init) {
      init = init || {};
      if (input instanceof Request) {
        this.url = input.url;
        this.method = (init.method || input.method || 'GET').toUpperCase();
        this.headers = new Headers(init.headers || input.headers);
        this.body = init.body !== undefined ? init.body : input.body;
      } else {
        this.url = String(input);
        this.method = (init.method || 'GET').toUpperCase();
        this.headers = new Headers(init.headers);
        this.body = init.body !== undefined ? init.body : null;
      }
    }

    function Response(bodyBytes, init) {
      init = init || {};
      this._bytes = bodyBytes instanceof Uint8Array
          ? bodyBytes
          : (typeof bodyBytes === 'string' ? new TextEncoder().encode(bodyBytes) : new Uint8Array(0));
      this.status = init.status !== undefined ? init.status : 200;
      this.statusText = init.statusText || '';
      this.ok = this.status >= 200 && this.status < 300;
      this.url = init.url || '';
      this.headers = new Headers(init.headers);
      this.bodyUsed = false;
    }
    Response.prototype._consumeBytes = function() {
      if (this.bodyUsed) {
        return Promise.reject(new TypeError('Response body has already been consumed'));
      }
      this.bodyUsed = true;
      return Promise.resolve(this._bytes);
    };
    Response.prototype.bytes = function() {
      return this._consumeBytes();
    };
    Response.prototype.arrayBuffer = function() {
      return this._consumeBytes().then(function(b) {
        return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
      });
    };
    Response.prototype.text = function() {
      return this._consumeBytes().then(function(b) {
        return new TextDecoder().decode(b);
      });
    };
    Response.prototype.json = function() {
      return this.text().then(function(t) { return JSON.parse(t); });
    };
    Response.prototype.clone = function() {
      return new Response(new Uint8Array(this._bytes), {
        status: this.status,
        statusText: this.statusText,
        headers: this.headers,
        url: this.url,
      });
    };

    var _nextFetchId = 1;
    var _pendingFetches = new Map();

    global.fetch = function(input, init) {
      var req = input instanceof Request ? new Request(input, init) : new Request(input, init);
      var bodyB64 = null;
      var hasBody = 0;

      if (req.body !== null && req.body !== undefined) {
        hasBody = 1;
        if (req.body instanceof Uint8Array) {
          bodyB64 = _bytesToBase64(req.body);
        } else if (req.body instanceof ArrayBuffer) {
          bodyB64 = _bytesToBase64(new Uint8Array(req.body));
        } else if (ArrayBuffer.isView(req.body)) {
          bodyB64 = _bytesToBase64(new Uint8Array(req.body.buffer, req.body.byteOffset, req.body.byteLength));
        } else if (req.body instanceof URLSearchParams) {
          bodyB64 = _bytesToBase64(new TextEncoder().encode(req.body.toString()));
          if (!req.headers.has('content-type')) {
            req.headers.set('content-type', 'application/x-www-form-urlencoded;charset=UTF-8');
          }
        } else {
          bodyB64 = _bytesToBase64(new TextEncoder().encode(String(req.body)));
        }
      }

      var id = _nextFetchId++;
      var headersJson = JSON.stringify(req.headers._toPlainObject());
      return new Promise(function(resolve, reject) {
        _pendingFetches.set(id, { resolve: resolve, reject: reject });
        global.__qjs_dot_fetch(id, req.url, req.method, headersJson, bodyB64, hasBody);
      });
    };

    global.__qjs_dot_resolve_fetch = function(id, ok, status, statusText, headersJson, bodyB64, url, errorMessage) {
      var pending = _pendingFetches.get(id);
      if (!pending) return;
      _pendingFetches.delete(id);
      if (!ok) {
        pending.reject(new Error(errorMessage || 'Network request failed'));
        return;
      }
      var bytes = bodyB64 ? _base64ToBytes(bodyB64) : new Uint8Array(0);
      var headersObj = headersJson ? JSON.parse(headersJson) : {};
      pending.resolve(new Response(bytes, {
        status: status,
        statusText: statusText || '',
        headers: headersObj,
        url: url || '',
      }));
    };

    global.Headers = Headers;
    global.Request = Request;
    global.Response = Response;
  }
})(globalThis);
''';
}

/// Encodes a Dart value into JSON understood by JS `__qjs_dot_decode`.
String encodeDartValueToJsJson(dynamic value) {
  return jsonEncode(_wrapDartValue(value));
}

dynamic _wrapDartValue(dynamic value) {
  if (value == null || value is bool || value is String) {
    return value;
  }
  if (value is int) {
    return value;
  }
  if (value is double) {
    if (value.isNaN) return const {'__qjs_dot_t': 'n', 'd': 'NaN'};
    if (value == double.infinity) return const {'__qjs_dot_t': 'n', 'd': 'Inf'};
    if (value == double.negativeInfinity) {
      return const {'__qjs_dot_t': 'n', 'd': '-Inf'};
    }
    return value;
  }
  if (value is BigInt) {
    return value.toString();
  }
  if (value is Uint8List) {
    return {'__qjs_dot_t': 'b', 'd': base64Encode(value)};
  }
  if (value is List) {
    return value.map(_wrapDartValue).toList(growable: false);
  }
  if (value is Map) {
    final result = <String, dynamic>{};
    value.forEach((key, val) {
      result[key.toString()] = _wrapDartValue(val);
    });
    return result;
  }
  return value.toString();
}

/// Decodes a JSON envelope produced by JS `__qjs_dot_encode`.
dynamic decodeJsPayload(String? jsonStr) {
  if (jsonStr == null || jsonStr.isEmpty) {
    return null;
  }
  final decoded = jsonDecode(jsonStr);
  if (decoded is Map<String, dynamic> && decoded.containsKey('k')) {
    final kind = decoded['k'];
    final v = decoded['v'];
    switch (kind) {
      case 'n':
        if (v == 'NaN') return double.nan;
        if (v == 'Inf') return double.infinity;
        if (v == '-Inf') return double.negativeInfinity;
        return null;
      case 'i':
        if (v is String) {
          return BigInt.tryParse(v) ?? v;
        }
        return v;
      case 'b':
        if (v is String) {
          return base64Decode(v);
        }
        return Uint8List(0);
      case 'j':
        return _unwrapEnvelopeValue(v);
    }
  }
  return _unwrapEnvelopeValue(decoded);
}

dynamic _unwrapEnvelopeValue(dynamic value) {
  if (value is List) {
    for (var i = 0; i < value.length; i++) {
      value[i] = _unwrapEnvelopeValue(value[i]);
    }
    return value;
  }
  if (value is Map<String, dynamic>) {
    final tag = value['__qjs_dot_t'];
    if (tag == 'b' && value['d'] is String) {
      return base64Decode(value['d'] as String);
    }
    if (tag == 'n') {
      final d = value['d'];
      if (d == 'NaN') return double.nan;
      if (d == 'Inf') return double.infinity;
      if (d == '-Inf') return double.negativeInfinity;
    }
    for (final key in value.keys.toList()) {
      value[key] = _unwrapEnvelopeValue(value[key]);
    }
    return value;
  }
  return value;
}
