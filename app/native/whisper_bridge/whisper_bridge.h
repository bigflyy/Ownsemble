/*
 * Ownsemble's bridge to whisper.cpp 1.9.5 (plan 10 I2d).
 *
 * whisper.cpp's API passes its parameter structs by value and calls back
 * into the caller to ask whether to stop. Dart cannot run a callback that
 * a native thread makes in the middle of a call, and a by-value struct
 * mirrored field by field in Dart breaks silently when a field moves. So
 * this small library is compiled against whisper.cpp's own pinned header
 * (whisper.cpp-1.9.5/include/whisper.h beside this file) and gives Dart
 * plain functions with pointers and numbers only:
 *
 *   ow_load       loads ggml-base, ggml and whisper from the model bundle's
 *                 folder at run time (the app starts without them) and the
 *                 CPU backends found there; checks the version and defaults
 *   ow_open       loads a ggml model file (UTF-8 path)
 *   ow_transcribe greedy decoding of one chunk, nothing carried over from
 *                 the chunk before; stops inside the call when the int32 at
 *                 the cancel address becomes non-zero
 *   ow_token      the text tokens of the last result: raw bytes (a token may
 *                 hold part of a UTF-8 character), times in 10 ms steps and
 *                 the token's probability
 *
 * One ow_context is used by one thread at a time. Error details of the last
 * failed call are in ow_error().
 */
#ifndef OWNSEMBLE_WHISPER_BRIDGE_H
#define OWNSEMBLE_WHISPER_BRIDGE_H

#include <stdint.h>

#ifdef _WIN32
#define OW_API __declspec(dllexport)
#else
#define OW_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Raised when the functions below change; the Dart side refuses another. */
#define OW_BRIDGE_VERSION 1

/* ow_transcribe's results besides whisper_full's own negative codes. */
#define OW_OK 0
#define OW_CANCELLED 1
#define OW_NOT_LOADED -100
#define OW_BAD_ARGUMENT -101
#define OW_OUT_OF_MEMORY -102

typedef struct ow_context ow_context;

OW_API int ow_bridge_version(void);

/* Loads the libraries from lib_dir (UTF-8). 0 on success (also when they
 * are already loaded from the same folder), else a negative code and
 * ow_error() says why. Loading from a second folder is refused. */
OW_API int ow_load(const char *lib_dir);

/* The last error of this library (or "" if none), UTF-8. */
OW_API const char *ow_error(void);

/* whisper_version() and whisper_print_system_info(); "" before ow_load. */
OW_API const char *ow_whisper_version(void);
OW_API const char *ow_system_info(void);

/* The registered ggml backends ("CPU", ...). */
OW_API int ow_backend_count(void);
OW_API const char *ow_backend_name(int index);

/* Loads the model on the CPU, flash attention on (as gigaam_app). NULL on
 * failure (ow_error() has whisper.cpp's last error lines). */
OW_API ow_context *ow_open(const char *model_path);
OW_API void ow_close(ow_context *context);

/* 1 if Whisper knows the language code ("ru", "en", ...). */
OW_API int ow_is_language(const char *code);

/* Recognises count samples (16 kHz mono float, up to 30 s). language is a
 * code or "auto"; threads the CPU threads; cancel the address of an int32
 * that another thread sets to stop (may be NULL). OW_OK, OW_CANCELLED, or
 * an error code (whisper_full's negative result or one of the above). */
OW_API int ow_transcribe(ow_context *context, const float *samples, int count,
                         const char *language, int threads,
                         const volatile int32_t *cancel);

/* The language of the last result ("" if none). */
OW_API const char *ow_language(ow_context *context);

/* Text tokens of the last result (special tokens left out), over all
 * segments in order. */
OW_API int ow_token_count(ow_context *context);

/* Token index: its bytes (not 0-terminated) and length, start and end in
 * 10 ms steps, probability. 0 on success, -1 for a bad index. */
OW_API int ow_token(ow_context *context, int index, const uint8_t **bytes,
                    int32_t *length, int64_t *t0, int64_t *t1,
                    float *probability);

#ifdef __cplusplus
}
#endif

#endif
