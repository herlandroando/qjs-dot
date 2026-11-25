#ifndef QJS_DOT_BRIDGE_H
#define QJS_DOT_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
  #if defined(DART_SHARED_LIB) || defined(QJS_DOT_BUILD)
    #define QJS_DOT_EXPORT __declspec(dllexport)
  #else
    #define QJS_DOT_EXPORT __declspec(dllimport)
  #endif
#else
  #define QJS_DOT_EXPORT __attribute__((visibility("default")))
#endif

typedef struct QjsEngine QjsEngine;

typedef struct QjsEvalResult {
  int32_t ok;
  int32_t pending_async;
  int32_t is_timeout;
  int32_t is_memory_limit;
  char* value_json;
  char* error_name;
  char* error_message;
  char* error_stack;
} QjsEvalResult;

typedef struct QjsMemoryUsage {
  int64_t malloc_size;
  int64_t malloc_limit;
  int64_t memory_used_size;
  int64_t malloc_count;
  int64_t memory_used_count;
  int64_t atom_count;
  int64_t str_count;
  int64_t obj_count;
  int64_t js_func_count;
  int64_t binary_object_count;
  int64_t binary_object_size;
} QjsMemoryUsage;

typedef void (*QjsConsoleCallback)(
    void* opaque,
    int32_t level,
    const char* message);

typedef void (*QjsTimerSetCallback)(
    void* opaque,
    int64_t timer_id,
    int64_t delay_ms,
    int32_t is_interval);

typedef void (*QjsTimerClearCallback)(
    void* opaque,
    int64_t timer_id);

typedef void (*QjsPostMessageCallback)(
    void* opaque,
    int64_t request_id,
    const char* channel,
    const char* payload_json);

typedef void (*QjsFetchCallback)(
    void* opaque,
    int64_t request_id,
    const char* url,
    const char* method,
    const char* headers_json,
    const char* body_base64,
    int32_t has_body);

typedef void (*QjsEvalSettledCallback)(
    void* opaque,
    int64_t eval_id,
    int32_t ok,
    const char* value_json,
    const char* error_name,
    const char* error_message,
    const char* error_stack);

typedef void (*QjsModuleRequestCallback)(
    void* opaque,
    int64_t request_id,
    const char* specifier,
    const char* referrer);

typedef struct QjsCallbacks {
  void* opaque;
  QjsConsoleCallback on_console;
  QjsTimerSetCallback on_timer_set;
  QjsTimerClearCallback on_timer_clear;
  QjsPostMessageCallback on_post_message;
  QjsFetchCallback on_fetch;
  QjsEvalSettledCallback on_eval_settled;
  QjsModuleRequestCallback on_module_request;
} QjsCallbacks;

QJS_DOT_EXPORT QjsEngine* qjs_dot_create(
    uint64_t memory_limit_bytes,
    uint64_t max_stack_size_bytes,
    int64_t default_timeout_ms,
    const QjsCallbacks* callbacks);

QJS_DOT_EXPORT void qjs_dot_destroy(QjsEngine* engine);

QJS_DOT_EXPORT void qjs_dot_set_memory_limit(
    QjsEngine* engine,
    uint64_t memory_limit_bytes);

QJS_DOT_EXPORT void qjs_dot_set_timeout_ms(
    QjsEngine* engine,
    int64_t timeout_ms);

QJS_DOT_EXPORT int32_t qjs_dot_eval(
    QjsEngine* engine,
    const char* code,
    const char* filename,
    int32_t is_module,
    int64_t async_eval_id,
    int64_t timeout_ms,
    QjsEvalResult* out_result);

QJS_DOT_EXPORT int32_t qjs_dot_execute_pending_jobs(
    QjsEngine* engine,
    int64_t timeout_ms,
    QjsEvalResult* out_result);

QJS_DOT_EXPORT int32_t qjs_dot_register_module(
    QjsEngine* engine,
    const char* specifier,
    const char* source);

QJS_DOT_EXPORT int32_t qjs_dot_unregister_module(
    QjsEngine* engine,
    const char* specifier);

QJS_DOT_EXPORT void qjs_dot_complete_module_load(
    QjsEngine* engine,
    int64_t request_id,
    const char* source,
    const char* error);

QJS_DOT_EXPORT void qjs_dot_cancel_module_wait(QjsEngine* engine);

QJS_DOT_EXPORT void qjs_dot_memory_usage(
    QjsEngine* engine,
    QjsMemoryUsage* out_usage);

QJS_DOT_EXPORT void qjs_dot_free_result(QjsEvalResult* result);

#ifdef __cplusplus
}
#endif

#endif /* QJS_DOT_BRIDGE_H */
