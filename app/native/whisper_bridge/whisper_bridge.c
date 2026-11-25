/*
 * Ownsemble's bridge to whisper.cpp 1.9.5 (plan 10 I2d); see whisper_bridge.h.
 *
 * The whisper.cpp libraries come with a model bundle the app downloads on
 * first use, so they are not linked: ow_load opens them from the bundle's
 * folder and looks the functions up by name. Their types come from the
 * pinned whisper.h, so the structs passed by value have whisper.cpp's own
 * layout. ow_load still checks whisper_version() and the defaults that
 * whisper_full_default_params fills in (the checks of gigaam_app's
 * whisper_cpp.check_layout), so a library of another version is refused
 * instead of misread.
 *
 * Built on Windows (MSVC). The POSIX branch is written for the Linux and
 * Android builds but not compiled yet.
 */
#include "whisper_bridge.h"

#include <math.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "whisper.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
typedef HMODULE ow_library;
#define OW_THREAD_LOCAL __declspec(thread)
/* The C runtime's terminate handler (C linkage in the UCRT; eh.h is C++
 * only). ggml-base installs its own one when it loads, see load_locked. */
typedef void(__cdecl *ow_terminate_handler)(void);
__declspec(dllimport) ow_terminate_handler __cdecl _get_terminate(void);
__declspec(dllimport) ow_terminate_handler __cdecl set_terminate(
    ow_terminate_handler handler);
#else
#include <dlfcn.h>
#include <pthread.h>
typedef void *ow_library;
#define OW_THREAD_LOCAL __thread
#endif

#define OW_PINNED_VERSION "1.9.5"

/* ------------------------------------------------------------ the functions
 * One pointer type per whisper.cpp / ggml function the bridge calls, in the
 * signatures of the pinned headers. */

typedef const char *(*fn_whisper_version)(void);
typedef const char *(*fn_whisper_print_system_info)(void);
typedef void (*fn_whisper_log_set)(ggml_log_callback, void *);
typedef struct whisper_context_params (*fn_whisper_context_default_params)(
    void);
typedef struct whisper_full_params (*fn_whisper_full_default_params)(
    enum whisper_sampling_strategy);
typedef struct whisper_context *(*fn_whisper_init_from_file_with_params)(
    const char *, struct whisper_context_params);
typedef struct whisper_context *(*fn_whisper_init_with_params)(
    struct whisper_model_loader *, struct whisper_context_params);
typedef void (*fn_whisper_free)(struct whisper_context *);
typedef int (*fn_whisper_full)(struct whisper_context *,
                               struct whisper_full_params, const float *, int);
typedef int (*fn_whisper_full_n_segments)(struct whisper_context *);
typedef int (*fn_whisper_full_lang_id)(struct whisper_context *);
typedef int (*fn_whisper_full_n_tokens)(struct whisper_context *, int);
typedef const char *(*fn_whisper_full_get_token_text)(struct whisper_context *,
                                                      int, int);
typedef whisper_token_data (*fn_whisper_full_get_token_data)(
    struct whisper_context *, int, int);
typedef whisper_token (*fn_whisper_token_eot)(struct whisper_context *);
typedef int (*fn_whisper_lang_id)(const char *);
typedef const char *(*fn_whisper_lang_str)(int);
typedef void (*fn_ggml_log_set)(ggml_log_callback, void *);
typedef void (*fn_ggml_backend_load_all_from_path)(const char *);
typedef size_t (*fn_ggml_backend_reg_count)(void);
typedef ggml_backend_reg_t (*fn_ggml_backend_reg_get)(size_t);
typedef const char *(*fn_ggml_backend_reg_name)(ggml_backend_reg_t);
typedef size_t (*fn_ggml_backend_dev_count)(void);
typedef ggml_backend_dev_t (*fn_ggml_backend_dev_get)(size_t);
typedef enum ggml_backend_dev_type (*fn_ggml_backend_dev_type)(
    ggml_backend_dev_t);
typedef const char *(*fn_ggml_backend_dev_description)(ggml_backend_dev_t);

typedef struct {
  fn_whisper_version whisper_version;
  fn_whisper_print_system_info whisper_print_system_info;
  fn_whisper_log_set whisper_log_set;
  fn_whisper_context_default_params whisper_context_default_params;
  fn_whisper_full_default_params whisper_full_default_params;
  fn_whisper_init_from_file_with_params whisper_init_from_file_with_params;
  fn_whisper_init_with_params whisper_init_with_params;
  fn_whisper_free whisper_free;
  fn_whisper_full whisper_full;
  fn_whisper_full_n_segments whisper_full_n_segments;
  fn_whisper_full_lang_id whisper_full_lang_id;
  fn_whisper_full_n_tokens whisper_full_n_tokens;
  fn_whisper_full_get_token_text whisper_full_get_token_text;
  fn_whisper_full_get_token_data whisper_full_get_token_data;
  fn_whisper_token_eot whisper_token_eot;
  fn_whisper_lang_id whisper_lang_id;
  fn_whisper_lang_str whisper_lang_str;
  fn_ggml_log_set ggml_log_set;
  fn_ggml_backend_load_all_from_path ggml_backend_load_all_from_path;
  fn_ggml_backend_reg_count ggml_backend_reg_count;
  fn_ggml_backend_reg_get ggml_backend_reg_get;
  fn_ggml_backend_reg_name ggml_backend_reg_name;
  fn_ggml_backend_dev_count ggml_backend_dev_count;
  fn_ggml_backend_dev_get ggml_backend_dev_get;
  fn_ggml_backend_dev_type ggml_backend_dev_type;
  fn_ggml_backend_dev_description ggml_backend_dev_description;
} function_table;

/* The functions, filled in only once ow_load has checked everything. */
static function_table w;

/* The folder the libraries were loaded from ("" while not loaded). */
static char loaded_dir[4096];

/* ------------------------------------------------------------ errors and log */

static OW_THREAD_LOCAL char last_error[2048];

static void set_error(const char *format, ...) {
  va_list args;
  va_start(args, format);
  vsnprintf(last_error, sizeof last_error, format, args);
  va_end(args);
}

/* The last error lines whisper.cpp and ggml logged, for error messages.
 * Log lines may come from ggml's worker threads, so the ring is locked. */
#define LOG_LINES 6
#define LOG_LINE_SIZE 320
static char log_ring[LOG_LINES][LOG_LINE_SIZE];
static int log_next;
static int log_count;
static int log_to_stderr;
static int last_level;

#ifdef _WIN32
static SRWLOCK log_lock = SRWLOCK_INIT;
static void lock_log(void) { AcquireSRWLockExclusive(&log_lock); }
static void unlock_log(void) { ReleaseSRWLockExclusive(&log_lock); }
/* ow_load runs one call at a time (two workers could start together). */
static SRWLOCK load_lock = SRWLOCK_INIT;
static void lock_load(void) { AcquireSRWLockExclusive(&load_lock); }
static void unlock_load(void) { ReleaseSRWLockExclusive(&load_lock); }
#else
static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;
static void lock_log(void) { pthread_mutex_lock(&log_lock); }
static void unlock_log(void) { pthread_mutex_unlock(&log_lock); }
static pthread_mutex_t load_lock = PTHREAD_MUTEX_INITIALIZER;
static void lock_load(void) { pthread_mutex_lock(&load_lock); }
static void unlock_load(void) { pthread_mutex_unlock(&load_lock); }
#endif

static void on_log(enum ggml_log_level level, const char *text,
                   void *user_data) {
  (void)user_data;
  if (text == NULL) return;
  if (log_to_stderr) fputs(text, stderr);
  lock_log();
  /* GGML_LOG_LEVEL_CONT continues the line before, at that line's level. */
  int effective = level == GGML_LOG_LEVEL_CONT ? last_level : (int)level;
  if (level != GGML_LOG_LEVEL_CONT) last_level = (int)level;
  if (effective == GGML_LOG_LEVEL_ERROR) {
    if (level == GGML_LOG_LEVEL_CONT && log_count > 0) {
      char *line = log_ring[(log_next + LOG_LINES - 1) % LOG_LINES];
      size_t used = strlen(line);
      snprintf(line + used, LOG_LINE_SIZE - used, "%s", text);
    } else {
      snprintf(log_ring[log_next], LOG_LINE_SIZE, "%s", text);
      log_next = (log_next + 1) % LOG_LINES;
      if (log_count < LOG_LINES) log_count++;
    }
  }
  unlock_log();
}

/* The logged error lines, oldest first, joined by "; " (newlines dropped). */
static void recent_errors(char *out, size_t size) {
  out[0] = 0;
  lock_log();
  size_t used = 0;
  for (int i = 0; i < log_count; i++) {
    const char *line =
        log_ring[(log_next + LOG_LINES - log_count + i) % LOG_LINES];
    for (const char *c = line; *c && used + 3 < size; c++) {
      if (*c == '\n' || *c == '\r') continue;
      out[used++] = *c;
    }
    if (i + 1 < log_count && used + 3 < size) {
      out[used++] = ';';
      out[used++] = ' ';
    }
  }
  out[used] = 0;
  log_count = 0;
  unlock_log();
  if (used == 0) snprintf(out, size, "no details");
}

/* ------------------------------------------------------------ libraries */

#ifdef _WIN32
/* UTF-8 to a new UTF-16 string (free it), or NULL. */
static wchar_t *widen(const char *text) {
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1,
                                  NULL, 0);
  if (count <= 0) return NULL;
  wchar_t *wide = (wchar_t *)malloc(sizeof(wchar_t) * (size_t)count);
  if (wide == NULL) return NULL;
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, wide, count);
  return wide;
}
#endif

/* Opens dir/name; on failure sets the error and gives NULL. On Windows the
 * libraries it needs are searched in its own folder and the system's, not
 * on PATH, so a developer's other ggml build cannot be picked up. */
static ow_library open_library(const char *dir, const char *name) {
  char path[4400];
  snprintf(path, sizeof path, "%s/%s", dir, name);
#ifdef _WIN32
  for (char *c = path; *c; c++) {
    if (*c == '/') *c = '\\';
  }
  wchar_t *wide = widen(path);
  if (wide == NULL) {
    set_error("not a UTF-8 path: %s", path);
    return NULL;
  }
  /* LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR takes only an absolute path (a
   * relative one fails with error 87). */
  DWORD size = GetFullPathNameW(wide, 0, NULL, NULL);
  wchar_t *full = size ? (wchar_t *)malloc(sizeof(wchar_t) * size) : NULL;
  if (full == NULL || GetFullPathNameW(wide, size, full, NULL) == 0) {
    free(full);
    free(wide);
    set_error("could not resolve the path %s", path);
    return NULL;
  }
  free(wide);
  HMODULE library = LoadLibraryExW(
      full, NULL,
      LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
  DWORD code = GetLastError();
  free(full);
  if (library == NULL) set_error("could not load %s (error %lu)", path, code);
  return library;
#else
  void *library = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
  if (library == NULL) set_error("could not load %s: %s", path, dlerror());
  return library;
#endif
}

static void *find(ow_library library, const char *name) {
#ifdef _WIN32
  return (void *)GetProcAddress(library, name);
#else
  return dlsym(library, name);
#endif
}

static void close_library(ow_library library) {
  if (library == NULL) return;
#ifdef _WIN32
  FreeLibrary(library);
#else
  dlclose(library);
#endif
}

/* Looks NAME up in the first library that has it, into table->NAME. */
#define BIND(field, ...)                                                    \
  do {                                                                      \
    ow_library from[] = {__VA_ARGS__};                                      \
    void *found = NULL;                                                     \
    for (size_t i = 0; i < sizeof from / sizeof from[0] && !found; i++)     \
      found = find(from[i], #field);                                        \
    if (!found) {                                                           \
      set_error("%s is not exported by the whisper.cpp libraries", #field); \
      return -2;                                                            \
    }                                                                       \
    memcpy(&table->field, &found, sizeof found);                            \
  } while (0)

static int close_to(float value, float expected) {
  return fabsf(value - expected) <= 1e-6f;
}

/* gigaam_app's whisper_cpp.check_layout: the defaults whisper.cpp 1.9.5
 * sets (src/whisper.cpp), spread from the first field to the last. */
static int defaults_match(const struct whisper_full_params *p) {
  return p->strategy == WHISPER_SAMPLING_GREEDY && p->n_max_text_ctx == 16384 &&
         p->no_context && p->print_progress && p->print_timestamps &&
         !p->token_timestamps && close_to(p->thold_pt, 0.01f) &&
         close_to(p->thold_ptsum, 0.01f) && p->language != NULL &&
         strcmp(p->language, "en") == 0 && p->suppress_blank &&
         !p->suppress_nst && close_to(p->max_initial_ts, 1.0f) &&
         close_to(p->length_penalty, -1.0f) &&
         close_to(p->temperature_inc, 0.2f) &&
         close_to(p->entropy_thold, 2.4f) &&
         close_to(p->logprob_thold, -1.0f) &&
         close_to(p->no_speech_thold, 0.6f) && p->greedy.best_of == 5 &&
         p->beam_search.beam_size == -1 &&
         close_to(p->beam_search.patience, -1.0f) &&
         close_to(p->grammar_penalty, 100.0f) && !p->vad &&
         close_to(p->vad_params.threshold, 0.5f) &&
         p->vad_params.min_speech_duration_ms == 250 &&
         p->vad_params.min_silence_duration_ms == 100 &&
         p->vad_params.speech_pad_ms == 30 &&
         close_to(p->vad_params.samples_overlap, 0.1f);
}

static int bind_all(function_table *table, ow_library base, ow_library ggml,
                    ow_library whisper) {
  BIND(whisper_version, whisper);
  BIND(whisper_print_system_info, whisper);
  BIND(whisper_log_set, whisper);
  BIND(whisper_context_default_params, whisper);
  BIND(whisper_full_default_params, whisper);
  BIND(whisper_init_from_file_with_params, whisper);
  BIND(whisper_init_with_params, whisper);
  BIND(whisper_free, whisper);
  BIND(whisper_full, whisper);
  BIND(whisper_full_n_segments, whisper);
  BIND(whisper_full_lang_id, whisper);
  BIND(whisper_full_n_tokens, whisper);
  BIND(whisper_full_get_token_text, whisper);
  BIND(whisper_full_get_token_data, whisper);
  BIND(whisper_token_eot, whisper);
  BIND(whisper_lang_id, whisper);
  BIND(whisper_lang_str, whisper);
  /* ggml's functions are split between ggml (the backend registry) and
   * ggml-base (tensors, logging). */
  BIND(ggml_log_set, ggml, base);
  BIND(ggml_backend_load_all_from_path, ggml, base);
  BIND(ggml_backend_reg_count, ggml, base);
  BIND(ggml_backend_reg_get, ggml, base);
  BIND(ggml_backend_reg_name, ggml, base);
  BIND(ggml_backend_dev_count, ggml, base);
  BIND(ggml_backend_dev_get, ggml, base);
  BIND(ggml_backend_dev_type, ggml, base);
  BIND(ggml_backend_dev_description, ggml, base);
  return 0;
}

OW_API int ow_bridge_version(void) { return OW_BRIDGE_VERSION; }

/* ow_load's work, with the load lock held. Everything is checked with the
 * functions in a local table; w and loaded_dir are set only at the end. On
 * any failure the libraries opened so far are closed again (in reverse
 * order), so a damaged bundle is not kept locked and can be repaired and
 * loaded again in the same run. */
static int load_locked(const char *lib_dir) {
  if (loaded_dir[0]) {
    if (strcmp(loaded_dir, lib_dir) == 0) return 0;
    set_error("whisper.cpp is already loaded from %s", loaded_dir);
    return -3;
  }
  const char *show = getenv("OWNSEMBLE_WHISPER_LOG");
  log_to_stderr = show != NULL && strcmp(show, "1") == 0;
#ifdef _WIN32
  const char *names[3] = {"ggml-base.dll", "ggml.dll", "whisper.dll"};
#else
  const char *names[3] = {"libggml-base.so", "libggml.so", "libwhisper.so"};
#endif
  /* In the order the loader needs them: whisper needs both ggml libraries,
   * and the backends ggml loads next need ggml-base already in memory. */
  ow_library base = NULL, ggml = NULL, whisper = NULL;
  function_table table;
  memset(&table, 0, sizeof table);
  int result = -1;
  const char *version = NULL;
  struct whisper_full_params defaults;
#ifdef _WIN32
  /* ggml-base's static initialiser replaces the terminate handler with its
   * own function and asserts it was not already its own. Unloading the DLL
   * after a failure would leave the handler pointing into freed code, and
   * the next load in this thread would hit that assert and abort the app
   * (plan 10 I2i1, found when a failed load was followed by a good one). */
  ow_terminate_handler terminate_before = _get_terminate();
#endif
  base = open_library(lib_dir, names[0]);
  if (base == NULL) goto fail;
  ggml = open_library(lib_dir, names[1]);
  if (ggml == NULL) goto fail;
  whisper = open_library(lib_dir, names[2]);
  if (whisper == NULL) goto fail;
  result = bind_all(&table, base, ggml, whisper);
  if (result != 0) goto fail;
  version = table.whisper_version();
  if (version == NULL || strcmp(version, OW_PINNED_VERSION) != 0) {
    set_error("whisper.cpp in %s is version %s, this app needs %s", lib_dir,
              version ? version : "?", OW_PINNED_VERSION);
    result = -4;
    goto fail;
  }
  defaults = table.whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  if (!defaults_match(&defaults)) {
    set_error("whisper.cpp in %s does not have the defaults of version %s",
              lib_dir, OW_PINNED_VERSION);
    result = -5;
    goto fail;
  }
  table.whisper_log_set(on_log, NULL);
  table.ggml_log_set(on_log, NULL);
  table.ggml_backend_load_all_from_path(lib_dir);
  if (table.ggml_backend_reg_count() == 0) {
    char details[1024];
    recent_errors(details, sizeof details);
    set_error("no ggml backend could be loaded from %s: %s", lib_dir, details);
    result = -6;
    goto fail;
  }
  w = table;
  snprintf(loaded_dir, sizeof loaded_dir, "%s", lib_dir);
  last_error[0] = 0;
  return 0;

fail:
  if (table.whisper_log_set) table.whisper_log_set(NULL, NULL);
  if (table.ggml_log_set) table.ggml_log_set(NULL, NULL);
  close_library(whisper);
  close_library(ggml);
  if (base != NULL) {
    close_library(base);
#ifdef _WIN32
    set_terminate(terminate_before);
#endif
  }
  return result;
}

OW_API int ow_load(const char *lib_dir) {
  if (lib_dir == NULL || lib_dir[0] == 0 ||
      strlen(lib_dir) >= sizeof loaded_dir) {
    set_error("no library folder given");
    return OW_BAD_ARGUMENT;
  }
  lock_load();
  int result = load_locked(lib_dir);
  unlock_load();
  return result;
}

OW_API const char *ow_error(void) { return last_error; }

static int loaded(void) { return loaded_dir[0] != 0; }

OW_API const char *ow_whisper_version(void) {
  return loaded() ? w.whisper_version() : "";
}

OW_API const char *ow_system_info(void) {
  return loaded() ? w.whisper_print_system_info() : "";
}

OW_API int ow_backend_count(void) {
  return loaded() ? (int)w.ggml_backend_reg_count() : 0;
}

OW_API const char *ow_backend_name(int index) {
  if (!loaded() || index < 0 || index >= ow_backend_count()) return "";
  return w.ggml_backend_reg_name(w.ggml_backend_reg_get((size_t)index));
}

/* The extra backend folder loaded by ow_load_backends ("" while none). */
static char backends_dir[4096];

OW_API int ow_load_backends(const char *dir) {
  if (!loaded()) {
    set_error("whisper.cpp is not loaded");
    return OW_BAD_ARGUMENT;
  }
  if (dir == NULL || dir[0] == 0 || strlen(dir) >= sizeof backends_dir) {
    set_error("no backend folder given");
    return OW_BAD_ARGUMENT;
  }
  lock_load();
  int result = 0;
  if (backends_dir[0] == 0) {
    size_t before = w.ggml_backend_reg_count();
    /* The folder form takes UTF-8 (ggml_backend_load reads a path in the
     * ANSI code page); it loads each ggml-<backend>.dll found there. */
    w.ggml_backend_load_all_from_path(dir);
    if (w.ggml_backend_reg_count() == before) {
      char details[1024];
      recent_errors(details, sizeof details);
      set_error("no ggml backend could be loaded from %s: %s", dir, details);
      result = -6;
    } else {
      snprintf(backends_dir, sizeof backends_dir, "%s", dir);
    }
  } else if (strcmp(backends_dir, dir) != 0) {
    set_error("backends are already loaded from %s", backends_dir);
    result = -3;
  }
  unlock_load();
  return result;
}

/* The ggml device of the gpu-th GPU, counted as whisper.cpp 1.9.5's
 * whisper_backend_init_gpu counts gpu_device: discrete and integrated GPUs
 * in ggml's device order. NULL if there is no such GPU. */
static ggml_backend_dev_t gpu_device(int gpu) {
  if (!loaded() || gpu < 0) return NULL;
  int seen = 0;
  for (size_t i = 0; i < w.ggml_backend_dev_count(); i++) {
    ggml_backend_dev_t device = w.ggml_backend_dev_get(i);
    enum ggml_backend_dev_type type = w.ggml_backend_dev_type(device);
    if (type == GGML_BACKEND_DEVICE_TYPE_GPU ||
        type == GGML_BACKEND_DEVICE_TYPE_IGPU) {
      if (seen == gpu) return device;
      seen++;
    }
  }
  return NULL;
}

OW_API int ow_gpu_count(void) {
  int count = 0;
  while (gpu_device(count) != NULL) count++;
  return count;
}

OW_API const char *ow_gpu_name(int gpu) {
  ggml_backend_dev_t device = gpu_device(gpu);
  return device ? w.ggml_backend_dev_description(device) : "";
}

OW_API int ow_gpu_integrated(int gpu) {
  ggml_backend_dev_t device = gpu_device(gpu);
  return device != NULL &&
         w.ggml_backend_dev_type(device) == GGML_BACKEND_DEVICE_TYPE_IGPU;
}

OW_API int ow_is_language(const char *code) {
  return loaded() && code != NULL && w.whisper_lang_id(code) >= 0;
}

/* ------------------------------------------------------------ a model */

typedef struct {
  int32_t offset; /* into bytes */
  int32_t length;
  int64_t t0;
  int64_t t1;
  float probability;
} ow_token_record;

struct ow_context {
  struct whisper_context *whisper;
  whisper_token eot;
  ow_token_record *tokens;
  int token_count;
  int token_capacity;
  uint8_t *bytes;
  int32_t byte_count;
  int32_t byte_capacity;
  char language[16];
};

#ifdef _WIN32
/* The model file read through _wfopen: whisper.cpp's own file loader turns
 * the UTF-8 path into wchar_t with codecvt_utf8, which cannot hold a
 * character outside the BMP (an emoji in a user name) on Windows. The same
 * reads as its loader; only the file is opened differently. */
static size_t file_read(void *context, void *output, size_t size) {
  return fread(output, 1, size, (FILE *)context);
}
static bool file_eof(void *context) { return feof((FILE *)context) != 0; }
static void file_close(void *context) { (void)context; }

static struct whisper_context *open_model(
    const char *path, struct whisper_context_params params) {
  wchar_t *wide = widen(path);
  if (wide == NULL) {
    set_error("not a UTF-8 path: %s", path);
    return NULL;
  }
  FILE *file = _wfopen(wide, L"rb");
  free(wide);
  if (file == NULL) {
    set_error("could not open %s", path);
    return NULL;
  }
  struct whisper_model_loader loader = {file, file_read, file_eof, file_close};
  struct whisper_context *context = w.whisper_init_with_params(&loader, params);
  fclose(file);
  return context;
}
#else
static struct whisper_context *open_model(
    const char *path, struct whisper_context_params params) {
  return w.whisper_init_from_file_with_params(path, params);
}
#endif

OW_API ow_context *ow_open(const char *model_path) {
  return ow_open_on(model_path, -1);
}

OW_API ow_context *ow_open_on(const char *model_path, int gpu) {
  if (!loaded()) {
    set_error("whisper.cpp is not loaded");
    return NULL;
  }
  if (model_path == NULL) {
    set_error("no model path given");
    return NULL;
  }
  /* whisper.cpp quietly falls back to the CPU when it finds no such GPU;
   * a GPU asked for must be there. */
  if (gpu >= 0 && gpu_device(gpu) == NULL) {
    set_error("no GPU %d among the loaded ggml backends", gpu);
    return NULL;
  }
  ow_context *context = (ow_context *)calloc(1, sizeof *context);
  if (context == NULL) {
    set_error("out of memory");
    return NULL;
  }
  /* As gigaam_app's whisper_cpp.Context: flash attention on, the other
   * fields whisper.cpp's defaults; the GPU only when one is asked for. */
  struct whisper_context_params params = w.whisper_context_default_params();
  params.use_gpu = gpu >= 0;
  params.gpu_device = gpu >= 0 ? gpu : 0;
  params.flash_attn = true;
  last_error[0] = 0;
  context->whisper = open_model(model_path, params);
  if (context->whisper == NULL) {
    if (last_error[0]) {
      free(context);
      return NULL;
    }
    char details[1024];
    recent_errors(details, sizeof details);
    set_error("whisper.cpp could not load %s: %s", model_path, details);
    free(context);
    return NULL;
  }
  context->eot = w.whisper_token_eot(context->whisper);
  return context;
}

OW_API void ow_close(ow_context *context) {
  if (context == NULL) return;
  if (context->whisper != NULL) w.whisper_free(context->whisper);
  free(context->tokens);
  free(context->bytes);
  free(context);
}

/* ggml_abort_callback: true stops whisper_full at its next check (after
 * each graph node on the CPU, and between the encoder and decoder steps). */
static bool should_abort(void *data) {
  return *(const volatile int32_t *)data != 0;
}

static int add_token(ow_context *context, const char *text,
                     const whisper_token_data *data) {
  size_t length = text ? strlen(text) : 0;
  if (length > (size_t)(INT32_MAX - context->byte_count)) return 0;
  if (context->token_count == context->token_capacity) {
    int capacity = context->token_capacity ? context->token_capacity * 2 : 256;
    void *grown =
        realloc(context->tokens, sizeof(ow_token_record) * (size_t)capacity);
    if (grown == NULL) return 0;
    context->tokens = (ow_token_record *)grown;
    context->token_capacity = capacity;
  }
  if ((size_t)context->byte_count + length > (size_t)context->byte_capacity) {
    size_t capacity = context->byte_capacity ? context->byte_capacity : 4096;
    while (capacity < (size_t)context->byte_count + length) capacity *= 2;
    if (capacity > INT32_MAX) capacity = INT32_MAX;
    void *grown = realloc(context->bytes, capacity);
    if (grown == NULL) return 0;
    context->bytes = (uint8_t *)grown;
    context->byte_capacity = (int32_t)capacity;
  }
  ow_token_record *record = &context->tokens[context->token_count++];
  record->offset = context->byte_count;
  record->length = (int32_t)length;
  record->t0 = data->t0;
  record->t1 = data->t1;
  record->probability = data->p;
  if (length) memcpy(context->bytes + context->byte_count, text, length);
  context->byte_count += (int32_t)length;
  return 1;
}

OW_API int ow_transcribe(ow_context *context, const float *samples, int count,
                         const char *language, int threads,
                         const volatile int32_t *cancel) {
  if (!loaded()) {
    set_error("whisper.cpp is not loaded");
    return OW_NOT_LOADED;
  }
  if (context == NULL || context->whisper == NULL || samples == NULL ||
      count <= 0 || threads <= 0) {
    set_error("bad arguments to ow_transcribe");
    return OW_BAD_ARGUMENT;
  }
  context->token_count = 0;
  context->byte_count = 0;
  context->language[0] = 0;
  /* gigaam_app's whisper_cpp.Context.transcribe: greedy with whisper.cpp's
   * fallback to higher temperatures, nothing carried over (no_context), no
   * prompt, token times, non-speech tokens suppressed. */
  struct whisper_full_params params =
      w.whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  params.n_threads = threads;
  params.no_context = true;
  params.print_progress = false;
  params.print_timestamps = false;
  params.print_realtime = false;
  params.token_timestamps = true;
  params.language = language && language[0] ? language : "auto";
  params.suppress_nst = true;
  if (cancel != NULL) {
    params.abort_callback = should_abort;
    params.abort_callback_user_data = (void *)cancel;
  }
  int result = w.whisper_full(context->whisper, params, samples, count);
  if (cancel != NULL && *cancel != 0) return OW_CANCELLED;
  if (result != 0) {
    char details[1024];
    recent_errors(details, sizeof details);
    set_error("whisper_full failed (%d): %s", result, details);
    return result;
  }
  const char *found =
      w.whisper_lang_str(w.whisper_full_lang_id(context->whisper));
  snprintf(context->language, sizeof context->language, "%s",
           found ? found : "");
  int segments = w.whisper_full_n_segments(context->whisper);
  for (int segment = 0; segment < segments; segment++) {
    int tokens = w.whisper_full_n_tokens(context->whisper, segment);
    for (int index = 0; index < tokens; index++) {
      whisper_token_data data =
          w.whisper_full_get_token_data(context->whisper, segment, index);
      /* Special tokens: end of text, language, timestamps, ... */
      if (data.id >= context->eot) continue;
      const char *text =
          w.whisper_full_get_token_text(context->whisper, segment, index);
      if (!add_token(context, text, &data)) {
        context->token_count = 0;
        context->byte_count = 0;
        set_error("out of memory");
        return OW_OUT_OF_MEMORY;
      }
    }
  }
  return OW_OK;
}

OW_API const char *ow_language(ow_context *context) {
  return context ? context->language : "";
}

OW_API int ow_token_count(ow_context *context) {
  return context ? context->token_count : 0;
}

OW_API int ow_token(ow_context *context, int index, const uint8_t **bytes,
                    int32_t *length, int64_t *t0, int64_t *t1,
                    float *probability) {
  if (context == NULL || index < 0 || index >= context->token_count) return -1;
  const ow_token_record *record = &context->tokens[index];
  if (bytes) *bytes = context->bytes + record->offset;
  if (length) *length = record->length;
  if (t0) *t0 = record->t0;
  if (t1) *t1 = record->t1;
  if (probability) *probability = record->probability;
  return 0;
}
