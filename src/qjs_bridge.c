#include "qjs_bridge.h"
#include "quickjs-ng/quickjs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
  #include <windows.h>
#else
  #include <errno.h>
  #include <pthread.h>
  #include <time.h>
#endif

#define QJS_MODULE_WAIT_TIMEOUT_MS 30000

typedef struct QjsModuleEntry {
  char* specifier;
  char* source;
} QjsModuleEntry;

struct QjsEngine {
  JSRuntime* rt;
  JSContext* ctx;
  QjsCallbacks cb;

  int64_t default_timeout_ms;
  int64_t deadline_ms;
  volatile int32_t timed_out;
  volatile int32_t disposed;

  QjsModuleEntry* modules;
  size_t module_count;
  size_t module_capacity;

  int64_t next_module_request_id;
  int64_t pending_module_id;
  int32_t pending_module_done;
  char* pending_module_source;
  char* pending_module_error;

#ifdef _WIN32
  CRITICAL_SECTION lock;
  CONDITION_VARIABLE cond;
  LARGE_INTEGER qpc_freq;
#else
  pthread_mutex_t lock;
  pthread_cond_t cond;
#endif
};

static char* qjs_dup_cstr(const char* s) {
  if (!s) return NULL;
  size_t len = strlen(s);
  char* copy = (char*)malloc(len + 1);
  if (!copy) return NULL;
  memcpy(copy, s, len + 1);
  return copy;
}

static int64_t qjs_monotonic_ms(const QjsEngine* engine) {
#ifdef _WIN32
  LARGE_INTEGER now;
  QueryPerformanceCounter(&now);
  if (engine && engine->qpc_freq.QuadPart > 0) {
    return (int64_t)((now.QuadPart * 1000LL) / engine->qpc_freq.QuadPart);
  }
  return (int64_t)GetTickCount64();
#else
  (void)engine;
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000LL + (int64_t)(ts.tv_nsec / 1000000LL);
#endif
}

static void qjs_arm_deadline(QjsEngine* engine, int64_t timeout_ms) {
  int64_t effective = timeout_ms >= 0 ? timeout_ms : engine->default_timeout_ms;
  engine->timed_out = 0;
  if (effective > 0) {
    engine->deadline_ms = qjs_monotonic_ms(engine) + effective;
  } else {
    engine->deadline_ms = 0;
  }
}

static void qjs_disarm_deadline(QjsEngine* engine) {
  engine->deadline_ms = 0;
}

static int qjs_interrupt_handler(JSContext* ctx, void* opaque) {
  (void)ctx;
  QjsEngine* engine = (QjsEngine*)opaque;
  if (!engine) return 0;
  if (engine->disposed) return 1;
  if (engine->deadline_ms > 0) {
    if (qjs_monotonic_ms(engine) >= engine->deadline_ms) {
      engine->timed_out = 1;
      return 1;
    }
  }
  return 0;
}

static void qjs_init_result(QjsEvalResult* out) {
  if (!out) return;
  memset(out, 0, sizeof(*out));
}

static char* qjs_jsval_to_cstr_dup(JSContext* ctx, JSValueConst val) {
  const char* s = JS_ToCString(ctx, val);
  if (!s) return NULL;
  char* copy = qjs_dup_cstr(s);
  JS_FreeCString(ctx, s);
  return copy;
}

static void qjs_populate_error_from_value(
    QjsEngine* engine,
    JSContext* ctx,
    JSValueConst exc,
    QjsEvalResult* out) {
  out->ok = 0;
  out->pending_async = 0;

  if (engine && engine->timed_out) {
    out->is_timeout = 1;
    out->error_name = qjs_dup_cstr("TimeoutError");
    out->error_message = qjs_dup_cstr("JavaScript execution timed out");
    return;
  }

  if (JS_IsObject(exc)) {
    JSValue name_val = JS_GetPropertyStr(ctx, exc, "name");
    JSValue msg_val = JS_GetPropertyStr(ctx, exc, "message");
    JSValue stack_val = JS_GetPropertyStr(ctx, exc, "stack");

    if (!JS_IsUndefined(name_val) && !JS_IsException(name_val)) {
      out->error_name = qjs_jsval_to_cstr_dup(ctx, name_val);
    }
    if (!JS_IsUndefined(msg_val) && !JS_IsException(msg_val)) {
      out->error_message = qjs_jsval_to_cstr_dup(ctx, msg_val);
    } else {
      out->error_message = qjs_jsval_to_cstr_dup(ctx, exc);
    }
    if (!JS_IsUndefined(stack_val) && !JS_IsException(stack_val)) {
      out->error_stack = qjs_jsval_to_cstr_dup(ctx, stack_val);
    }

    JS_FreeValue(ctx, name_val);
    JS_FreeValue(ctx, msg_val);
    JS_FreeValue(ctx, stack_val);
  } else {
    out->error_name = qjs_dup_cstr("Error");
    out->error_message = qjs_jsval_to_cstr_dup(ctx, exc);
  }

  if (!out->error_name) {
    out->error_name = qjs_dup_cstr("Error");
  }
  if (!out->error_message) {
    out->error_message = qjs_dup_cstr("Unknown JavaScript error");
  }
  if (out->error_message &&
      (strstr(out->error_message, "out of memory") != NULL ||
       strstr(out->error_message, "OutOfMemory") != NULL)) {
    out->is_memory_limit = 1;
  }
}

static void qjs_extract_pending_exception(QjsEngine* engine, QjsEvalResult* out) {
  JSValue exc = JS_GetException(engine->ctx);
  qjs_populate_error_from_value(engine, engine->ctx, exc, out);
  JS_FreeValue(engine->ctx, exc);
}

static char* qjs_serialize_value(JSContext* ctx, JSValueConst val, int* is_err) {
  *is_err = 0;
  if (JS_IsUndefined(val) || JS_IsNull(val)) {
    return NULL;
  }

  JSValue global = JS_GetGlobalObject(ctx);
  JSValue encoder = JS_GetPropertyStr(ctx, global, "__qjs_dot_encode");
  if (JS_IsFunction(ctx, encoder)) {
    JSValueConst args[1] = { val };
    JSValue encoded = JS_Call(ctx, encoder, JS_UNDEFINED, 1, args);
    JS_FreeValue(ctx, encoder);
    JS_FreeValue(ctx, global);
    if (JS_IsException(encoded)) {
      *is_err = 1;
      return NULL;
    }
    if (JS_IsNull(encoded) || JS_IsUndefined(encoded)) {
      JS_FreeValue(ctx, encoded);
      return NULL;
    }
    char* res = qjs_jsval_to_cstr_dup(ctx, encoded);
    JS_FreeValue(ctx, encoded);
    return res;
  }

  JS_FreeValue(ctx, encoder);
  JS_FreeValue(ctx, global);

  JSValue json_val = JS_JSONStringify(ctx, val, JS_UNDEFINED, JS_UNDEFINED);
  if (JS_IsException(json_val)) {
    *is_err = 1;
    return NULL;
  }
  if (JS_IsUndefined(json_val)) {
    JS_FreeValue(ctx, json_val);
    return NULL;
  }
  char* res = qjs_jsval_to_cstr_dup(ctx, json_val);
  JS_FreeValue(ctx, json_val);
  return res;
}

static int qjs_drain_pending_jobs(QjsEngine* engine, QjsEvalResult* out) {
  JSContext* pctx = NULL;
  int rc;
  while ((rc = JS_ExecutePendingJob(engine->rt, &pctx)) > 0) {
    if (engine->disposed) {
      out->ok = 0;
      out->error_name = qjs_dup_cstr("StateError");
      out->error_message = qjs_dup_cstr("Runtime disposed");
      return -1;
    }
  }
  if (rc < 0) {
    JSContext* err_ctx = pctx ? pctx : engine->ctx;
    JSValue exc = JS_GetException(err_ctx);
    qjs_populate_error_from_value(engine, err_ctx, exc, out);
    JS_FreeValue(err_ctx, exc);
    return -1;
  }
  return 0;
}

static int qjs_attach_async_promise(
    QjsEngine* engine,
    int64_t eval_id,
    JSValueConst promise_or_val,
    JSValueConst resolve_override) {
  JSContext* ctx = engine->ctx;
  JSValue global = JS_GetGlobalObject(ctx);
  JSValue helper = JS_GetPropertyStr(ctx, global, "__qjs_dot_attach_promise");
  if (!JS_IsFunction(ctx, helper)) {
    JS_FreeValue(ctx, helper);
    JS_FreeValue(ctx, global);
    JS_ThrowInternalError(ctx, "__qjs_dot_attach_promise is not registered");
    return -1;
  }

  JSValue id_val = JS_NewInt64(ctx, eval_id);
  JSValueConst args[3] = { id_val, promise_or_val, resolve_override };
  JSValue ret = JS_Call(ctx, helper, JS_UNDEFINED, 3, args);

  JS_FreeValue(ctx, id_val);
  JS_FreeValue(ctx, helper);
  JS_FreeValue(ctx, global);

  if (JS_IsException(ret)) {
    return -1;
  }
  JS_FreeValue(ctx, ret);
  return 0;
}

/* ========================================================================= */
/* Host Intrinsics                                                           */
/* ========================================================================= */

static JSValue qjs_host_console(
    JSContext* ctx,
    JSValueConst this_val,
    int argc,
    JSValueConst* argv) {
  (void)this_val;
  QjsEngine* engine = (QjsEngine*)JS_GetContextOpaque(ctx);
  if (!engine || !engine->cb.on_console || argc < 2) {
    return JS_UNDEFINED;
  }
  int32_t level = 1;
  JS_ToInt32(ctx, &level, argv[0]);
  const char* msg = JS_ToCString(ctx, argv[1]);
  if (msg) {
    engine->cb.on_console(engine->cb.opaque, level, msg);
    JS_FreeCString(ctx, msg);
  }
  return JS_UNDEFINED;
}

static JSValue qjs_host_set_timer(
    JSContext* ctx,
    JSValueConst this_val,
    int argc,
    JSValueConst* argv) {
  (void)this_val;
  QjsEngine* engine = (QjsEngine*)JS_GetContextOpaque(ctx);
  if (!engine || !engine->cb.on_timer_set || argc < 3) {
    return JS_UNDEFINED;
  }
  int64_t timer_id = 0;
  int64_t delay_ms = 0;
  int32_t is_interval = 0;
  JS_ToInt64(ctx, &timer_id, argv[0]);
  JS_ToInt64(ctx, &delay_ms, argv[1]);
  JS_ToInt32(ctx, &is_interval, argv[2]);
  engine->cb.on_timer_set(engine->cb.opaque, timer_id, delay_ms, is_interval);
  return JS_UNDEFINED;
}

static JSValue qjs_host_clear_timer(
    JSContext* ctx,
    JSValueConst this_val,
    int argc,
    JSValueConst* argv) {
  (void)this_val;
  QjsEngine* engine = (QjsEngine*)JS_GetContextOpaque(ctx);
  if (!engine || !engine->cb.on_timer_clear || argc < 1) {
    return JS_UNDEFINED;
  }
  int64_t timer_id = 0;
  JS_ToInt64(ctx, &timer_id, argv[0]);
  engine->cb.on_timer_clear(engine->cb.opaque, timer_id);
  return JS_UNDEFINED;
}

static JSValue qjs_host_post_message(
    JSContext* ctx,
    JSValueConst this_val,
    int argc,
    JSValueConst* argv) {
  (void)this_val;
  QjsEngine* engine = (QjsEngine*)JS_GetContextOpaque(ctx);
  if (!engine || !engine->cb.on_post_message || argc < 3) {
    return JS_UNDEFINED;
  }
  int64_t request_id = 0;
  JS_ToInt64(ctx, &request_id, argv[0]);
  const char* channel = JS_ToCString(ctx, argv[1]);
  const char* payload = JS_ToCString(ctx, argv[2]);
  if (channel) {
    engine->cb.on_post_message(
        engine->cb.opaque,
        request_id,
        channel,
        payload ? payload : "null");
  }
  if (channel) JS_FreeCString(ctx, channel);
  if (payload) JS_FreeCString(ctx, payload);
  return JS_UNDEFINED;
}

static JSValue qjs_host_fetch(
    JSContext* ctx,
    JSValueConst this_val,
    int argc,
    JSValueConst* argv) {
  (void)this_val;
  QjsEngine* engine = (QjsEngine*)JS_GetContextOpaque(ctx);
  if (!engine || !engine->cb.on_fetch || argc < 6) {
    return JS_UNDEFINED;
  }
  int64_t request_id = 0;
  int32_t has_body = 0;
  JS_ToInt64(ctx, &request_id, argv[0]);
  const char* url = JS_ToCString(ctx, argv[1]);
  const char* method = JS_ToCString(ctx, argv[2]);
  const char* headers = JS_ToCString(ctx, argv[3]);
  const char* body_b64 = JS_IsNull(argv[4]) || JS_IsUndefined(argv[4])
      ? NULL
      : JS_ToCString(ctx, argv[4]);
  JS_ToInt32(ctx, &has_body, argv[5]);

  if (url && method) {
    engine->cb.on_fetch(
        engine->cb.opaque,
        request_id,
        url,
        method,
        headers ? headers : "{}",
        body_b64 ? body_b64 : "",
        has_body);
  }

  if (url) JS_FreeCString(ctx, url);
  if (method) JS_FreeCString(ctx, method);
  if (headers) JS_FreeCString(ctx, headers);
  if (body_b64) JS_FreeCString(ctx, body_b64);
  return JS_UNDEFINED;
}

static JSValue qjs_host_eval_settled(
    JSContext* ctx,
    JSValueConst this_val,
    int argc,
    JSValueConst* argv) {
  (void)this_val;
  QjsEngine* engine = (QjsEngine*)JS_GetContextOpaque(ctx);
  if (!engine || !engine->cb.on_eval_settled || argc < 6) {
    return JS_UNDEFINED;
  }
  int64_t eval_id = 0;
  int32_t ok = 0;
  JS_ToInt64(ctx, &eval_id, argv[0]);
  JS_ToInt32(ctx, &ok, argv[1]);

  const char* value_json = JS_IsNull(argv[2]) || JS_IsUndefined(argv[2])
      ? NULL
      : JS_ToCString(ctx, argv[2]);
  const char* err_name = JS_IsNull(argv[3]) || JS_IsUndefined(argv[3])
      ? NULL
      : JS_ToCString(ctx, argv[3]);
  const char* err_msg = JS_IsNull(argv[4]) || JS_IsUndefined(argv[4])
      ? NULL
      : JS_ToCString(ctx, argv[4]);
  const char* err_stack = JS_IsNull(argv[5]) || JS_IsUndefined(argv[5])
      ? NULL
      : JS_ToCString(ctx, argv[5]);

  engine->cb.on_eval_settled(
      engine->cb.opaque,
      eval_id,
      ok,
      value_json,
      err_name,
      err_msg,
      err_stack);

  if (value_json) JS_FreeCString(ctx, value_json);
  if (err_name) JS_FreeCString(ctx, err_name);
  if (err_msg) JS_FreeCString(ctx, err_msg);
  if (err_stack) JS_FreeCString(ctx, err_stack);
  return JS_UNDEFINED;
}

static void qjs_register_intrinsics(JSContext* ctx) {
  JSValue global = JS_GetGlobalObject(ctx);
  JS_SetPropertyStr(
      ctx,
      global,
      "__qjs_dot_console",
      JS_NewCFunction(ctx, qjs_host_console, "__qjs_dot_console", 2));
  JS_SetPropertyStr(
      ctx,
      global,
      "__qjs_dot_set_timer",
      JS_NewCFunction(ctx, qjs_host_set_timer, "__qjs_dot_set_timer", 3));
  JS_SetPropertyStr(
      ctx,
      global,
      "__qjs_dot_clear_timer",
      JS_NewCFunction(ctx, qjs_host_clear_timer, "__qjs_dot_clear_timer", 1));
  JS_SetPropertyStr(
      ctx,
      global,
      "__qjs_dot_post_message",
      JS_NewCFunction(ctx, qjs_host_post_message, "__qjs_dot_post_message", 3));
  JS_SetPropertyStr(
      ctx,
      global,
      "__qjs_dot_fetch",
      JS_NewCFunction(ctx, qjs_host_fetch, "__qjs_dot_fetch", 6));
  JS_SetPropertyStr(
      ctx,
      global,
      "__qjs_dot_eval_settled",
      JS_NewCFunction(ctx, qjs_host_eval_settled, "__qjs_dot_eval_settled", 6));
  JS_FreeValue(ctx, global);
}

/* ========================================================================= */
/* ES Module Registry, Specifier Normalization & Async Condvar Loader        */
/* ========================================================================= */

static const char* qjs_find_registered_module(
    const QjsEngine* engine,
    const char* specifier) {
  for (size_t i = 0; i < engine->module_count; i++) {
    if (strcmp(engine->modules[i].specifier, specifier) == 0) {
      return engine->modules[i].source;
    }
  }
  return NULL;
}

static char* qjs_module_normalize(
    JSContext* ctx,
    const char* module_base_name,
    const char* module_name,
    void* opaque) {
  (void)opaque;
  if (!module_name) {
    return js_strdup(ctx, "");
  }

  /* Keep non-relative specifiers (bare or scheme-prefixed) untouched. */
  int is_rel = (strcmp(module_name, ".") == 0 ||
                strcmp(module_name, "..") == 0 ||
                strncmp(module_name, "./", 2) == 0 ||
                strncmp(module_name, "../", 3) == 0);
  if (!is_rel) {
    return js_strdup(ctx, module_name);
  }

  size_t base_len = module_base_name ? strlen(module_base_name) : 0;
  size_t name_len = strlen(module_name);
  char* combined = (char*)malloc(base_len + name_len + 4);
  if (!combined) {
    JS_ThrowOutOfMemory(ctx);
    return NULL;
  }

  const char* slash = module_base_name ? strrchr(module_base_name, '/') : NULL;
  int leading_slash = (module_base_name && module_base_name[0] == '/');
  if (slash) {
    size_t dir_len = (size_t)(slash - module_base_name + 1);
    memcpy(combined, module_base_name, dir_len);
    memcpy(combined + dir_len, module_name, name_len + 1);
  } else {
    memcpy(combined, module_name, name_len + 1);
  }

  /* Collapse POSIX path segments in place. */
  size_t cap = 16;
  char** parts = (char**)malloc(cap * sizeof(char*));
  if (!parts) {
    free(combined);
    JS_ThrowOutOfMemory(ctx);
    return NULL;
  }
  size_t count = 0;

  char* cursor = combined;
  while (*cursor != '\0') {
    while (*cursor == '/') cursor++;
    if (*cursor == '\0') break;
    char* seg_start = cursor;
    while (*cursor != '\0' && *cursor != '/') cursor++;
    size_t seg_len = (size_t)(cursor - seg_start);
    if (*cursor == '/') {
      *cursor = '\0';
      cursor++;
    }
    if (seg_len == 1 && seg_start[0] == '.') {
      continue;
    }
    if (seg_len == 2 && seg_start[0] == '.' && seg_start[1] == '.') {
      if (count > 0 && strcmp(parts[count - 1], "..") != 0) {
        count--;
      } else if (!leading_slash) {
        if (count == cap) {
          cap *= 2;
          char** grown = (char**)realloc(parts, cap * sizeof(char*));
          if (!grown) {
            free(parts);
            free(combined);
            JS_ThrowOutOfMemory(ctx);
            return NULL;
          }
          parts = grown;
        }
        parts[count++] = seg_start;
      }
      continue;
    }
    if (count == cap) {
      cap *= 2;
      char** grown = (char**)realloc(parts, cap * sizeof(char*));
      if (!grown) {
        free(parts);
        free(combined);
        JS_ThrowOutOfMemory(ctx);
        return NULL;
      }
      parts = grown;
    }
    parts[count++] = seg_start;
  }

  size_t out_len = leading_slash ? 1 : 0;
  for (size_t i = 0; i < count; i++) {
    out_len += strlen(parts[i]) + (i + 1 < count ? 1 : 0);
  }
  char* out = (char*)js_malloc(ctx, out_len + 2);
  if (!out) {
    free(parts);
    free(combined);
    return NULL;
  }

  size_t pos = 0;
  if (leading_slash) {
    out[pos++] = '/';
  }
  for (size_t i = 0; i < count; i++) {
    size_t plen = strlen(parts[i]);
    memcpy(out + pos, parts[i], plen);
    pos += plen;
    if (i + 1 < count) {
      out[pos++] = '/';
    }
  }
  out[pos] = '\0';

  free(parts);
  free(combined);
  return out;
}

static JSModuleDef* qjs_module_loader(
    JSContext* ctx,
    const char* module_name,
    void* opaque) {
  QjsEngine* engine = (QjsEngine*)opaque;
  if (!engine || !module_name) {
    JS_ThrowReferenceError(ctx, "Invalid module request");
    return NULL;
  }

  const char* registered = qjs_find_registered_module(engine, module_name);
  char* dynamic_source = NULL;
  char* dynamic_error = NULL;
  const char* source_to_compile = registered;

  if (!source_to_compile && engine->cb.on_module_request && !engine->disposed) {
    int64_t saved_deadline = engine->deadline_ms;
    int64_t remaining_ms = 0;
    if (saved_deadline > 0) {
      remaining_ms = saved_deadline - qjs_monotonic_ms(engine);
      if (remaining_ms < 1) remaining_ms = 1;
    }
    /* Pause CPU deadline while waiting on external Dart moduleLoader. */
    engine->deadline_ms = 0;

    int64_t req_id = 0;
#ifdef _WIN32
    EnterCriticalSection(&engine->lock);
    req_id = ++engine->next_module_request_id;
    engine->pending_module_id = req_id;
    engine->pending_module_done = 0;
    free(engine->pending_module_source);
    free(engine->pending_module_error);
    engine->pending_module_source = NULL;
    engine->pending_module_error = NULL;
    LeaveCriticalSection(&engine->lock);

    engine->cb.on_module_request(engine->cb.opaque, req_id, module_name, "");

    EnterCriticalSection(&engine->lock);
    while (!engine->pending_module_done && !engine->disposed) {
      if (!SleepConditionVariableCS(
              &engine->cond,
              &engine->lock,
              QJS_MODULE_WAIT_TIMEOUT_MS)) {
        break;
      }
    }
    if (engine->pending_module_done) {
      dynamic_source = engine->pending_module_source;
      dynamic_error = engine->pending_module_error;
      engine->pending_module_source = NULL;
      engine->pending_module_error = NULL;
    } else if (!engine->disposed) {
      dynamic_error = qjs_dup_cstr("Module loader timed out");
    }
    engine->pending_module_id = 0;
    LeaveCriticalSection(&engine->lock);
#else
    pthread_mutex_lock(&engine->lock);
    req_id = ++engine->next_module_request_id;
    engine->pending_module_id = req_id;
    engine->pending_module_done = 0;
    free(engine->pending_module_source);
    free(engine->pending_module_error);
    engine->pending_module_source = NULL;
    engine->pending_module_error = NULL;
    pthread_mutex_unlock(&engine->lock);

    engine->cb.on_module_request(engine->cb.opaque, req_id, module_name, "");

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += QJS_MODULE_WAIT_TIMEOUT_MS / 1000;
    ts.tv_nsec += (QJS_MODULE_WAIT_TIMEOUT_MS % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) {
      ts.tv_sec += 1;
      ts.tv_nsec -= 1000000000L;
    }

    pthread_mutex_lock(&engine->lock);
    while (!engine->pending_module_done && !engine->disposed) {
      int rc = pthread_cond_timedwait(&engine->cond, &engine->lock, &ts);
      if (rc == ETIMEDOUT) {
        break;
      }
    }
    if (engine->pending_module_done) {
      dynamic_source = engine->pending_module_source;
      dynamic_error = engine->pending_module_error;
      engine->pending_module_source = NULL;
      engine->pending_module_error = NULL;
    } else if (!engine->disposed) {
      dynamic_error = qjs_dup_cstr("Module loader timed out");
    }
    engine->pending_module_id = 0;
    pthread_mutex_unlock(&engine->lock);
#endif

    if (remaining_ms > 0) {
      engine->deadline_ms = qjs_monotonic_ms(engine) + remaining_ms;
    }

    if (engine->disposed) {
      free(dynamic_source);
      free(dynamic_error);
      JS_ThrowReferenceError(ctx, "Runtime disposed while loading module: %s", module_name);
      return NULL;
    }

    if (dynamic_error) {
      JS_ThrowReferenceError(ctx, "%s", dynamic_error);
      free(dynamic_source);
      free(dynamic_error);
      return NULL;
    }

    source_to_compile = dynamic_source;
  }

  if (!source_to_compile) {
    free(dynamic_source);
    free(dynamic_error);
    JS_ThrowReferenceError(ctx, "Module not found: %s", module_name);
    return NULL;
  }

  JSValue func_val = JS_Eval(
      ctx,
      source_to_compile,
      strlen(source_to_compile),
      module_name,
      JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);

  free(dynamic_source);
  free(dynamic_error);

  if (JS_IsException(func_val)) {
    return NULL;
  }

  if (!JS_IsModule(func_val)) {
    JS_FreeValue(ctx, func_val);
    JS_ThrowInternalError(ctx, "Compiled value is not a module: %s", module_name);
    return NULL;
  }

  return (JSModuleDef*)JS_VALUE_GET_PTR(func_val);
}

/* ========================================================================= */
/* Public C API                                                              */
/* ========================================================================= */

QJS_DOT_EXPORT QjsEngine* qjs_dot_create(
    uint64_t memory_limit_bytes,
    uint64_t max_stack_size_bytes,
    int64_t default_timeout_ms,
    const QjsCallbacks* callbacks) {
  QjsEngine* engine = (QjsEngine*)calloc(1, sizeof(QjsEngine));
  if (!engine) return NULL;

#ifdef _WIN32
  InitializeCriticalSection(&engine->lock);
  InitializeConditionVariable(&engine->cond);
  QueryPerformanceFrequency(&engine->qpc_freq);
#else
  pthread_mutex_init(&engine->lock, NULL);
  pthread_cond_init(&engine->cond, NULL);
#endif

  if (callbacks) {
    engine->cb = *callbacks;
  }
  engine->default_timeout_ms = default_timeout_ms;

  engine->rt = JS_NewRuntime();
  if (!engine->rt) {
    qjs_dot_destroy(engine);
    return NULL;
  }

  if (memory_limit_bytes > 0) {
    JS_SetMemoryLimit(engine->rt, (size_t)memory_limit_bytes);
  }
  if (max_stack_size_bytes > 0) {
    JS_SetMaxStackSize(engine->rt, (size_t)max_stack_size_bytes);
  }

  JS_SetInterruptHandler(engine->rt, qjs_interrupt_handler, engine);
  JS_SetModuleLoaderFunc(engine->rt, qjs_module_normalize, qjs_module_loader, engine);

  engine->ctx = JS_NewContext(engine->rt);
  if (!engine->ctx) {
    qjs_dot_destroy(engine);
    return NULL;
  }

  JS_SetContextOpaque(engine->ctx, engine);
  qjs_register_intrinsics(engine->ctx);
  return engine;
}

QJS_DOT_EXPORT void qjs_dot_destroy(QjsEngine* engine) {
  if (!engine) return;

  qjs_dot_cancel_module_wait(engine);

  if (engine->ctx) {
    JS_FreeContext(engine->ctx);
    engine->ctx = NULL;
  }
  if (engine->rt) {
    JS_FreeRuntime(engine->rt);
    engine->rt = NULL;
  }

  for (size_t i = 0; i < engine->module_count; i++) {
    free(engine->modules[i].specifier);
    free(engine->modules[i].source);
  }
  free(engine->modules);
  free(engine->pending_module_source);
  free(engine->pending_module_error);

#ifdef _WIN32
  DeleteCriticalSection(&engine->lock);
#else
  pthread_cond_destroy(&engine->cond);
  pthread_mutex_destroy(&engine->lock);
#endif

  free(engine);
}

QJS_DOT_EXPORT void qjs_dot_set_memory_limit(
    QjsEngine* engine,
    uint64_t memory_limit_bytes) {
  if (!engine || !engine->rt) return;
  JS_SetMemoryLimit(engine->rt, (size_t)memory_limit_bytes);
}

QJS_DOT_EXPORT void qjs_dot_set_timeout_ms(
    QjsEngine* engine,
    int64_t timeout_ms) {
  if (!engine) return;
  engine->default_timeout_ms = timeout_ms;
}

QJS_DOT_EXPORT int32_t qjs_dot_eval(
    QjsEngine* engine,
    const char* code,
    const char* filename,
    int32_t is_module,
    int64_t async_eval_id,
    int64_t timeout_ms,
    QjsEvalResult* out_result) {
  if (!out_result) return -1;
  qjs_init_result(out_result);

  if (!engine || !engine->ctx || !code || engine->disposed) {
    out_result->ok = 0;
    out_result->error_name = qjs_dup_cstr("StateError");
    out_result->error_message = qjs_dup_cstr("Runtime is unavailable or disposed");
    return -1;
  }

  const char* fname = (filename && filename[0] != '\0') ? filename : "<eval>";
  qjs_arm_deadline(engine, timeout_ms);

  JSContext* ctx = engine->ctx;
  size_t code_len = strlen(code);

  if (is_module) {
    JSValue mod_val = JS_Eval(
        ctx,
        code,
        code_len,
        fname,
        JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    if (JS_IsException(mod_val)) {
      qjs_extract_pending_exception(engine, out_result);
      qjs_disarm_deadline(engine);
      return -1;
    }

    JSModuleDef* mod = (JSModuleDef*)JS_VALUE_GET_PTR(mod_val);
    JSValue eval_promise = JS_EvalFunction(ctx, mod_val);
    if (JS_IsException(eval_promise)) {
      qjs_extract_pending_exception(engine, out_result);
      qjs_disarm_deadline(engine);
      return -1;
    }

    if (qjs_drain_pending_jobs(engine, out_result) < 0) {
      JS_FreeValue(ctx, eval_promise);
      qjs_disarm_deadline(engine);
      return -1;
    }

    JSPromiseStateEnum pstate = JS_PromiseState(ctx, eval_promise);
    if (pstate == JS_PROMISE_REJECTED) {
      JSValue reason = JS_PromiseResult(ctx, eval_promise);
      qjs_populate_error_from_value(engine, ctx, reason, out_result);
      JS_FreeValue(ctx, reason);
      JS_FreeValue(ctx, eval_promise);
      qjs_disarm_deadline(engine);
      return -1;
    }

    JSValue ns = JS_GetModuleNamespace(ctx, mod);
    if (JS_IsException(ns)) {
      JS_FreeValue(ctx, eval_promise);
      qjs_extract_pending_exception(engine, out_result);
      qjs_disarm_deadline(engine);
      return -1;
    }

    if (pstate == JS_PROMISE_FULFILLED || pstate == JS_PROMISE_NOT_A_PROMISE) {
      int ser_err = 0;
      out_result->value_json = qjs_serialize_value(ctx, ns, &ser_err);
      JS_FreeValue(ctx, ns);
      JS_FreeValue(ctx, eval_promise);
      if (ser_err) {
        qjs_extract_pending_exception(engine, out_result);
        qjs_disarm_deadline(engine);
        return -1;
      }
      out_result->ok = 1;
      out_result->pending_async = 0;
      qjs_disarm_deadline(engine);
      return 0;
    }

    if (async_eval_id > 0) {
      if (qjs_attach_async_promise(engine, async_eval_id, eval_promise, ns) < 0) {
        JS_FreeValue(ctx, ns);
        JS_FreeValue(ctx, eval_promise);
        qjs_extract_pending_exception(engine, out_result);
        qjs_disarm_deadline(engine);
        return -1;
      }
      JS_FreeValue(ctx, ns);
      JS_FreeValue(ctx, eval_promise);
      out_result->ok = 1;
      out_result->pending_async = 1;
      qjs_disarm_deadline(engine);
      return 0;
    }

    JS_FreeValue(ctx, ns);
    JS_FreeValue(ctx, eval_promise);
    out_result->ok = 0;
    out_result->error_name = qjs_dup_cstr("StateError");
    out_result->error_message = qjs_dup_cstr("Module evaluation is async");
    qjs_disarm_deadline(engine);
    return -1;
  }

  /* Script evaluation (sync or async) */
  JSValue val = JS_Eval(ctx, code, code_len, fname, JS_EVAL_TYPE_GLOBAL);
  if (JS_IsException(val)) {
    qjs_extract_pending_exception(engine, out_result);
    qjs_disarm_deadline(engine);
    return -1;
  }

  if (qjs_drain_pending_jobs(engine, out_result) < 0) {
    JS_FreeValue(ctx, val);
    qjs_disarm_deadline(engine);
    return -1;
  }

  if (async_eval_id > 0) {
    if (JS_IsPromise(val)) {
      JSPromiseStateEnum pstate = JS_PromiseState(ctx, val);
      if (pstate == JS_PROMISE_FULFILLED) {
        JSValue resolved = JS_PromiseResult(ctx, val);
        JS_FreeValue(ctx, val);
        int ser_err = 0;
        out_result->value_json = qjs_serialize_value(ctx, resolved, &ser_err);
        JS_FreeValue(ctx, resolved);
        if (ser_err) {
          qjs_extract_pending_exception(engine, out_result);
          qjs_disarm_deadline(engine);
          return -1;
        }
        out_result->ok = 1;
        out_result->pending_async = 0;
        qjs_disarm_deadline(engine);
        return 0;
      }
      if (pstate == JS_PROMISE_REJECTED) {
        JSValue reason = JS_PromiseResult(ctx, val);
        qjs_populate_error_from_value(engine, ctx, reason, out_result);
        JS_FreeValue(ctx, reason);
        JS_FreeValue(ctx, val);
        qjs_disarm_deadline(engine);
        return -1;
      }
      if (qjs_attach_async_promise(engine, async_eval_id, val, JS_UNDEFINED) < 0) {
        JS_FreeValue(ctx, val);
        qjs_extract_pending_exception(engine, out_result);
        qjs_disarm_deadline(engine);
        return -1;
      }
      JS_FreeValue(ctx, val);
      out_result->ok = 1;
      out_result->pending_async = 1;
      qjs_disarm_deadline(engine);
      return 0;
    }

    /* Check custom thenables */
    if (JS_IsObject(val)) {
      JSValue then_prop = JS_GetPropertyStr(ctx, val, "then");
      int is_thenable = JS_IsFunction(ctx, then_prop);
      JS_FreeValue(ctx, then_prop);
      if (is_thenable) {
        if (qjs_attach_async_promise(engine, async_eval_id, val, JS_UNDEFINED) < 0) {
          JS_FreeValue(ctx, val);
          qjs_extract_pending_exception(engine, out_result);
          qjs_disarm_deadline(engine);
          return -1;
        }
        JS_FreeValue(ctx, val);
        if (qjs_drain_pending_jobs(engine, out_result) < 0) {
          qjs_disarm_deadline(engine);
          return -1;
        }
        out_result->ok = 1;
        out_result->pending_async = 1;
        qjs_disarm_deadline(engine);
        return 0;
      }
    }
  }

  int ser_err = 0;
  out_result->value_json = qjs_serialize_value(ctx, val, &ser_err);
  JS_FreeValue(ctx, val);
  if (ser_err) {
    qjs_extract_pending_exception(engine, out_result);
    qjs_disarm_deadline(engine);
    return -1;
  }

  out_result->ok = 1;
  out_result->pending_async = 0;
  qjs_disarm_deadline(engine);
  return 0;
}

QJS_DOT_EXPORT int32_t qjs_dot_execute_pending_jobs(
    QjsEngine* engine,
    int64_t timeout_ms,
    QjsEvalResult* out_result) {
  if (!out_result) return -1;
  qjs_init_result(out_result);

  if (!engine || !engine->rt || engine->disposed) {
    out_result->ok = 0;
    return -1;
  }

  qjs_arm_deadline(engine, timeout_ms);
  int rc = qjs_drain_pending_jobs(engine, out_result);
  qjs_disarm_deadline(engine);
  if (rc < 0) {
    return -1;
  }
  out_result->ok = 1;
  return 0;
}

QJS_DOT_EXPORT int32_t qjs_dot_register_module(
    QjsEngine* engine,
    const char* specifier,
    const char* source) {
  if (!engine || !specifier || !source) return -1;

  for (size_t i = 0; i < engine->module_count; i++) {
    if (strcmp(engine->modules[i].specifier, specifier) == 0) {
      char* next_source = qjs_dup_cstr(source);
      if (!next_source) return -1;
      free(engine->modules[i].source);
      engine->modules[i].source = next_source;
      return 0;
    }
  }

  if (engine->module_count == engine->module_capacity) {
    size_t next_cap = engine->module_capacity == 0 ? 8 : engine->module_capacity * 2;
    QjsModuleEntry* grown = (QjsModuleEntry*)realloc(
        engine->modules,
        next_cap * sizeof(QjsModuleEntry));
    if (!grown) return -1;
    engine->modules = grown;
    engine->module_capacity = next_cap;
  }

  char* spec_copy = qjs_dup_cstr(specifier);
  char* src_copy = qjs_dup_cstr(source);
  if (!spec_copy || !src_copy) {
    free(spec_copy);
    free(src_copy);
    return -1;
  }

  engine->modules[engine->module_count].specifier = spec_copy;
  engine->modules[engine->module_count].source = src_copy;
  engine->module_count++;
  return 0;
}

QJS_DOT_EXPORT int32_t qjs_dot_unregister_module(
    QjsEngine* engine,
    const char* specifier) {
  if (!engine || !specifier) return -1;
  for (size_t i = 0; i < engine->module_count; i++) {
    if (strcmp(engine->modules[i].specifier, specifier) == 0) {
      free(engine->modules[i].specifier);
      free(engine->modules[i].source);
      if (i + 1 < engine->module_count) {
        engine->modules[i] = engine->modules[engine->module_count - 1];
      }
      engine->module_count--;
      return 0;
    }
  }
  return 0;
}

QJS_DOT_EXPORT void qjs_dot_complete_module_load(
    QjsEngine* engine,
    int64_t request_id,
    const char* source,
    const char* error) {
  if (!engine) return;
#ifdef _WIN32
  EnterCriticalSection(&engine->lock);
  if (engine->pending_module_id == request_id) {
    free(engine->pending_module_source);
    free(engine->pending_module_error);
    engine->pending_module_source = source ? qjs_dup_cstr(source) : NULL;
    engine->pending_module_error = error ? qjs_dup_cstr(error) : NULL;
    engine->pending_module_done = 1;
    WakeAllConditionVariable(&engine->cond);
  }
  LeaveCriticalSection(&engine->lock);
#else
  pthread_mutex_lock(&engine->lock);
  if (engine->pending_module_id == request_id) {
    free(engine->pending_module_source);
    free(engine->pending_module_error);
    engine->pending_module_source = source ? qjs_dup_cstr(source) : NULL;
    engine->pending_module_error = error ? qjs_dup_cstr(error) : NULL;
    engine->pending_module_done = 1;
    pthread_cond_broadcast(&engine->cond);
  }
  pthread_mutex_unlock(&engine->lock);
#endif
}

QJS_DOT_EXPORT void qjs_dot_cancel_module_wait(QjsEngine* engine) {
  if (!engine) return;
#ifdef _WIN32
  EnterCriticalSection(&engine->lock);
  engine->disposed = 1;
  WakeAllConditionVariable(&engine->cond);
  LeaveCriticalSection(&engine->lock);
#else
  pthread_mutex_lock(&engine->lock);
  engine->disposed = 1;
  pthread_cond_broadcast(&engine->cond);
  pthread_mutex_unlock(&engine->lock);
#endif
}

QJS_DOT_EXPORT void qjs_dot_memory_usage(
    QjsEngine* engine,
    QjsMemoryUsage* out_usage) {
  if (!out_usage) return;
  memset(out_usage, 0, sizeof(*out_usage));
  if (!engine || !engine->rt) return;

  JSMemoryUsage s;
  JS_ComputeMemoryUsage(engine->rt, &s);
  out_usage->malloc_size = s.malloc_size;
  out_usage->malloc_limit = s.malloc_limit;
  out_usage->memory_used_size = s.memory_used_size;
  out_usage->malloc_count = s.malloc_count;
  out_usage->memory_used_count = s.memory_used_count;
  out_usage->atom_count = s.atom_count;
  out_usage->str_count = s.str_count;
  out_usage->obj_count = s.obj_count;
  out_usage->js_func_count = s.js_func_count;
  out_usage->binary_object_count = s.binary_object_count;
  out_usage->binary_object_size = s.binary_object_size;
}

QJS_DOT_EXPORT void qjs_dot_free_result(QjsEvalResult* result) {
  if (!result) return;
  free(result->value_json);
  free(result->error_name);
  free(result->error_message);
  free(result->error_stack);
  memset(result, 0, sizeof(*result));
}
