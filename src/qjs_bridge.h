/**
 * @file qjs_bridge.h
 * @brief Native C ABI bridging Dart FFI (`qjs_dot`) to QuickJS-ng (`v0.18.0`).
 *
 * ## Threading & Ownership Model
 * - A `QjsEngine*` is bound to the single Dart Worker Isolate thread that
 *   created it via `qjs_dot_create()`. All evaluation, job draining, module
 *   registration, and destruction calls must run on that same thread.
 * - **Cross-thread exceptions:** `qjs_dot_complete_module_load()` and
 *   `qjs_dot_cancel_module_wait()` are internally synchronized with a mutex and
 *   condition variable so the host isolate can wake a worker thread blocked in
 *   dynamic ES module resolution.
 * - Every `QjsEvalResult` populated by `qjs_dot_eval()` or
 *   `qjs_dot_execute_pending_jobs()` owns heap-allocated C strings and must be
 *   released with `qjs_dot_free_result()`.
 */

#ifndef QJS_DOT_BRIDGE_H
#define QJS_DOT_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Symbol export/visibility macro for shared-library builds. */
#if defined(_WIN32)
  #if defined(DART_SHARED_LIB) || defined(QJS_DOT_BUILD)
    #define QJS_DOT_EXPORT __declspec(dllexport)
  #else
    #define QJS_DOT_EXPORT __declspec(dllimport)
  #endif
#else
  #define QJS_DOT_EXPORT __attribute__((visibility("default")))
#endif

/** Opaque handle owning a QuickJS-ng `JSRuntime`, `JSContext`, and bridge state. */
typedef struct QjsEngine QjsEngine;

/**
 * @brief Result of evaluating a script, ES module, or draining pending jobs.
 *
 * Caller must release owned string fields by calling `qjs_dot_free_result()`.
 */
typedef struct QjsEvalResult {
  /** Non-zero (1) on success (including deferred async); 0 on error. */
  int32_t ok;
  /** Non-zero (1) if an async Promise/thenable is pending `on_eval_settled`. */
  int32_t pending_async;
  /** Non-zero (1) if evaluation was aborted by the synchronous deadline. */
  int32_t is_timeout;
  /** Non-zero (1) if evaluation failed due to the runtime memory limit. */
  int32_t is_memory_limit;
  /** Heap-allocated JSON wire envelope (`__qjs_dot_encode`), or NULL for null/undefined. */
  char* value_json;
  /** Heap-allocated JS error name when `ok == 0`, or NULL on success. */
  char* error_name;
  /** Heap-allocated JS error message when `ok == 0`, or NULL on success. */
  char* error_message;
  /** Heap-allocated JS stack trace when available, or NULL. */
  char* error_stack;
} QjsEvalResult;

/**
 * @brief Snapshot of QuickJS-ng heap statistics (`JSMemoryUsage`).
 */
typedef struct QjsMemoryUsage {
  int64_t malloc_size;         /**< Total bytes allocated via JS runtime allocator. */
  int64_t malloc_limit;        /**< Configured heap limit in bytes (0 = unlimited). */
  int64_t memory_used_size;    /**< Bytes actively used by live JS objects. */
  int64_t malloc_count;        /**< Active allocator block count. */
  int64_t memory_used_count;   /**< Live object allocation count. */
  int64_t atom_count;          /**< Interned atom count. */
  int64_t str_count;           /**< Live JS string count. */
  int64_t obj_count;           /**< Live JS object count. */
  int64_t js_func_count;       /**< Live JS function count. */
  int64_t binary_object_count; /**< Live ArrayBuffer / TypedArray count. */
  int64_t binary_object_size;  /**< Total bytes held by binary objects. */
} QjsMemoryUsage;

/**
 * @brief Callback invoked when JS calls `__qjs_dot_console(level, message)`.
 * @param opaque User pointer from `QjsCallbacks.opaque`.
 * @param level Severity index (`0`=debug, `1`=log, `2`=info, `3`=warn, `4`=error).
 * @param message Null-terminated UTF-8 string (valid only during the call).
 */
typedef void (*QjsConsoleCallback)(
    void* opaque,
    int32_t level,
    const char* message);

/**
 * @brief Callback invoked when JS schedules `setTimeout` or `setInterval`.
 * @param opaque User pointer from `QjsCallbacks.opaque`.
 * @param timer_id Unique JS-assigned timer identifier.
 * @param delay_ms Delay or interval duration in milliseconds.
 * @param is_interval Non-zero for `setInterval`, 0 for `setTimeout`.
 */
typedef void (*QjsTimerSetCallback)(
    void* opaque,
    int64_t timer_id,
    int64_t delay_ms,
    int32_t is_interval);

/**
 * @brief Callback invoked when JS cancels a timer (`clearTimeout`/`clearInterval`).
 */
typedef void (*QjsTimerClearCallback)(
    void* opaque,
    int64_t timer_id);

/**
 * @brief Callback invoked when JS calls `sendMessage(channel, payload)`.
 * @param request_id Monotonic request ID used to resolve the JS Promise later.
 * @param channel Non-empty null-terminated channel name.
 * @param payload_json Sanitized JSON payload string (`"null"` if omitted).
 */
typedef void (*QjsPostMessageCallback)(
    void* opaque,
    int64_t request_id,
    const char* channel,
    const char* payload_json);

/**
 * @brief Callback invoked when JS calls `fetch(input, init)`.
 * @param request_id Monotonic fetch ID used to resolve the JS Promise later.
 * @param url Target request URL.
 * @param method Uppercase HTTP method.
 * @param headers_json JSON object mapping lowercase header names to values.
 * @param body_base64 Base64-encoded request body (empty string if `has_body == 0`).
 * @param has_body Non-zero when a request body is present.
 */
typedef void (*QjsFetchCallback)(
    void* opaque,
    int64_t request_id,
    const char* url,
    const char* method,
    const char* headers_json,
    const char* body_base64,
    int32_t has_body);

/**
 * @brief Callback invoked when an async `eval_id` Promise settles in JS.
 * @param eval_id Asynchronous evaluation ID passed to `qjs_dot_eval()`.
 * @param ok Non-zero (1) if fulfilled, 0 if rejected.
 * @param value_json Encoded JSON payload when `ok != 0`, or NULL.
 * @param error_name Error name when `ok == 0`, or NULL.
 * @param error_message Error message when `ok == 0`, or NULL.
 * @param error_stack Stack trace when `ok == 0`, or NULL.
 */
typedef void (*QjsEvalSettledCallback)(
    void* opaque,
    int64_t eval_id,
    int32_t ok,
    const char* value_json,
    const char* error_name,
    const char* error_message,
    const char* error_stack);

/**
 * @brief Callback invoked when an ES module `import` misses the static registry.
 *
 * The calling worker thread blocks on an internal condition variable until
 * the host invokes `qjs_dot_complete_module_load()` or `qjs_dot_cancel_module_wait()`,
 * or until the 30-second wait timeout expires.
 */
typedef void (*QjsModuleRequestCallback)(
    void* opaque,
    int64_t request_id,
    const char* specifier,
    const char* referrer);

/**
 * @brief Host callback table registered with `qjs_dot_create()`.
 *
 * The struct is copied by value into `QjsEngine`; any NULL function pointer
 * disables that capability.
 */
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

/**
 * @brief Creates and initializes a new `QjsEngine` instance.
 *
 * @param memory_limit_bytes Heap limit in bytes (`0` disables limit).
 * @param max_stack_size_bytes Max JS call stack in bytes (`0` keeps default).
 * @param default_timeout_ms Default CPU interrupt timeout in ms (`<= 0` disables).
 * @param callbacks Optional host callback table (copied by value).
 * @return Newly allocated engine handle, or NULL on allocation failure.
 */
QJS_DOT_EXPORT QjsEngine* qjs_dot_create(
    uint64_t memory_limit_bytes,
    uint64_t max_stack_size_bytes,
    int64_t default_timeout_ms,
    const QjsCallbacks* callbacks);

/**
 * @brief Cancels any pending module wait and destroys the `QjsEngine`.
 * @param engine Engine to destroy (no-op if NULL).
 */
QJS_DOT_EXPORT void qjs_dot_destroy(QjsEngine* engine);

/**
 * @brief Updates the QuickJS-ng heap memory limit at runtime.
 * @param engine Target engine.
 * @param memory_limit_bytes New limit in bytes (`0` disables limit).
 */
QJS_DOT_EXPORT void qjs_dot_set_memory_limit(
    QjsEngine* engine,
    uint64_t memory_limit_bytes);

/**
 * @brief Updates the engine's default synchronous timeout in milliseconds.
 * @param engine Target engine.
 * @param timeout_ms Timeout in milliseconds (`<= 0` disables default timeout).
 */
QJS_DOT_EXPORT void qjs_dot_set_timeout_ms(
    QjsEngine* engine,
    int64_t timeout_ms);

/**
 * @brief Evaluates JavaScript source code or an ES module and drains microtasks.
 *
 * @param engine Target engine.
 * @param code Null-terminated UTF-8 JavaScript source code.
 * @param filename Virtual filename for stack traces and relative module resolution.
 * @param is_module Non-zero to evaluate as an ES module; 0 for classic script.
 * @param async_eval_id Positive ID to enable Promise/thenable tracking via
 *   `on_eval_settled`, or `0` for synchronous-only evaluation.
 * @param timeout_ms Per-call timeout override (`< 0` inherits default, `0` disables,
 *   `> 0` sets explicit ms deadline).
 * @param out_result Output struct populated by the call (caller must free with
 *   `qjs_dot_free_result()`).
 * @return `0` on success (including `out_result->pending_async == 1`), `-1` on error.
 */
QJS_DOT_EXPORT int32_t qjs_dot_eval(
    QjsEngine* engine,
    const char* code,
    const char* filename,
    int32_t is_module,
    int64_t async_eval_id,
    int64_t timeout_ms,
    QjsEvalResult* out_result);

/**
 * @brief Drains all queued QuickJS-ng microtask/Promise jobs.
 *
 * @param engine Target engine.
 * @param timeout_ms Per-call timeout override (`< 0` inherits default, `0` disables).
 * @param out_result Output struct populated on error (must be freed with
 *   `qjs_dot_free_result()`).
 * @return `0` if all jobs completed without unhandled exceptions, `-1` on error.
 */
QJS_DOT_EXPORT int32_t qjs_dot_execute_pending_jobs(
    QjsEngine* engine,
    int64_t timeout_ms,
    QjsEvalResult* out_result);

/**
 * @brief Registers or replaces an ES module source string in the static registry.
 *
 * @param engine Target engine.
 * @param specifier Normalized module specifier.
 * @param source Null-terminated UTF-8 ES module source code.
 * @return `0` on success, `-1` on invalid arguments or allocation failure.
 */
QJS_DOT_EXPORT int32_t qjs_dot_register_module(
    QjsEngine* engine,
    const char* specifier,
    const char* source);

/**
 * @brief Removes a module specifier from the static registry.
 *
 * @param engine Target engine.
 * @param specifier Module specifier to remove.
 * @return `0` on success (including if not found), `-1` on invalid arguments.
 */
QJS_DOT_EXPORT int32_t qjs_dot_unregister_module(
    QjsEngine* engine,
    const char* specifier);

/**
 * @brief Supplies the result of a dynamic `QjsModuleRequestCallback` and wakes
 *        the blocked worker thread.
 *
 * Thread-safe: intended to be called from the Dart host isolate.
 *
 * @param engine Target engine.
 * @param request_id Matching `request_id` from `QjsModuleRequestCallback`.
 * @param source Module UTF-8 source code, or NULL if loading failed.
 * @param error Error message if loading failed, or NULL on success.
 */
QJS_DOT_EXPORT void qjs_dot_complete_module_load(
    QjsEngine* engine,
    int64_t request_id,
    const char* source,
    const char* error);

/**
 * @brief Marks the engine as disposed and wakes any blocked module load wait.
 *
 * Thread-safe: call from the host isolate before sending dispose to the worker
 * isolate so a waiting `qjs_module_loader` unblocks immediately.
 *
 * @param engine Target engine.
 */
QJS_DOT_EXPORT void qjs_dot_cancel_module_wait(QjsEngine* engine);

/**
 * @brief Computes a snapshot of QuickJS-ng heap and object memory usage.
 *
 * @param engine Target engine.
 * @param out_usage Output struct populated with current runtime statistics.
 */
QJS_DOT_EXPORT void qjs_dot_memory_usage(
    QjsEngine* engine,
    QjsMemoryUsage* out_usage);

/**
 * @brief Frees all heap-allocated strings inside [result] and zeroes it.
 *
 * @param result Result struct to clean up (no-op if NULL).
 */
QJS_DOT_EXPORT void qjs_dot_free_result(QjsEvalResult* result);

#ifdef __cplusplus
}
#endif

#endif /* QJS_DOT_BRIDGE_H */
