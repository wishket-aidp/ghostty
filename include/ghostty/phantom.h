// Phantom-specific C API additions to Ghostty.
//
// This header is part of the Phantom fork of Ghostty (wishket-aidp/ghostty).
// It exposes snapshot extraction, event callbacks, and process-exit reporting
// that the Phantom remote-control layer (PhantomBridge SPM target) requires.
//
// Implementation lives in src/lib_phantom.zig.
//
// Threading: see per-function notes. In general, snapshot reads acquire
// Surface's renderer_state mutex and copy state into a fresh allocation, so
// the resulting `phantom_snapshot_t*` is owned by the caller and safe to
// read from any thread until phantom_snapshot_free is called.

#ifndef PHANTOM_H
#define PHANTOM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "../ghostty.h"

#ifdef __cplusplus
extern "C" {
#endif

// =============================================================================
// Snapshot Export
// =============================================================================

typedef struct phantom_snapshot phantom_snapshot_t;

// Cursor style values used by phantom_snapshot_header_t.cursor_style.
#define PHANTOM_CURSOR_BLOCK     0
#define PHANTOM_CURSOR_BEAM      1
#define PHANTOM_CURSOR_UNDERLINE 2

typedef struct {
    uint16_t cols;
    uint16_t rows;
    uint16_t cursor_x;
    uint16_t cursor_y;
    uint8_t  cursor_style;       // PHANTOM_CURSOR_*
    bool     cursor_visible;
    uint64_t sequence;           // monotonic per-surface counter
} phantom_snapshot_header_t;

// Color kind values for phantom_cell_t.fg_kind / bg_kind.
#define PHANTOM_COLOR_DEFAULT 0
#define PHANTOM_COLOR_INDEXED 1
#define PHANTOM_COLOR_RGB     2

typedef struct {
    uint32_t codepoint;          // UTF-32, first codepoint of grapheme cluster
    uint8_t  width;              // 1 (narrow) or 2 (wide)
    uint8_t  fg_kind;            // PHANTOM_COLOR_*
    uint32_t fg_value;           // palette index (0-255) or packed 0x00RRGGBB
    uint8_t  bg_kind;
    uint32_t bg_value;
    uint16_t attrs;              // bitset, see PHANTOM_ATTR_*
} phantom_cell_t;

#define PHANTOM_ATTR_BOLD          0x0001
#define PHANTOM_ATTR_ITALIC        0x0002
#define PHANTOM_ATTR_UNDERLINE     0x0004
#define PHANTOM_ATTR_STRIKETHROUGH 0x0008
#define PHANTOM_ATTR_BLINK         0x0010
#define PHANTOM_ATTR_INVERSE       0x0020
#define PHANTOM_ATTR_DIM           0x0040
#define PHANTOM_ATTR_HIDDEN        0x0080

// Returns the current sequence counter for the surface without allocating
// a snapshot. Cheap to call. Use this to detect changes between polls.
//
// Thread-safe: takes a small mutex internally.
uint64_t phantom_surface_snapshot_seq(ghostty_surface_t surface);

// Captures a snapshot if and only if the surface's sequence counter has
// advanced past `last_sequence`. Returns NULL when there is no change.
//
// On success the caller owns the returned pointer and must call
// phantom_snapshot_free when done.
//
// Thread-safe: acquires the surface's renderer_state mutex.
phantom_snapshot_t* phantom_surface_snapshot_if_changed(
    ghostty_surface_t surface,
    uint64_t last_sequence
);

// Captures a snapshot unconditionally. Use this for the initial sync.
// Caller owns the returned pointer.
//
// Thread-safe: acquires the surface's renderer_state mutex.
phantom_snapshot_t* phantom_surface_snapshot(ghostty_surface_t surface);

// Writes raw bytes directly to the surface's PTY, verbatim — as if produced
// by the local keyboard. Unlike ghostty_surface_text (clipboard-paste path,
// which brackets the bytes so a trailing "\r" does not submit), these bytes
// are delivered as-is. Use for the submit Enter after a bracketed-paste body.
// MUST be called on the app's main thread.
void phantom_surface_send_text(ghostty_surface_t surface, const char* ptr, size_t len);

// Remote-input wrappers use primitive ABI fields so PhantomBridge can resolve
// them dynamically without reproducing Ghostty's C structs in Swift.
// keycode uses USB HID usage page 0x07; mouse coordinates use terminal cells.
// All functions must be called on the app's main thread.
bool phantom_surface_key(
    ghostty_surface_t surface,
    uint8_t action,
    uint32_t mods,
    uint32_t keycode,
    const char* text
);
void phantom_surface_mouse_pos(
    ghostty_surface_t surface,
    double cell_x,
    double cell_y,
    uint32_t mods
);
bool phantom_surface_mouse_button(
    ghostty_surface_t surface,
    uint8_t action,
    uint8_t button,
    uint32_t mods
);
void phantom_surface_mouse_scroll(
    ghostty_surface_t surface,
    double delta_x,
    double delta_y
);
void phantom_surface_set_focus(ghostty_surface_t surface, bool focused);

void phantom_snapshot_header(
    phantom_snapshot_t* snapshot,
    phantom_snapshot_header_t* out_header
);

// Reads cell at (row, col). Returns false if out of bounds.
bool phantom_snapshot_cell(
    phantom_snapshot_t* snapshot,
    uint16_t row,
    uint16_t col,
    phantom_cell_t* out_cell
);

void phantom_snapshot_free(phantom_snapshot_t* snapshot);

// =============================================================================
// Process Exit State
// =============================================================================

// Reports whether the surface's child process has exited and, if so, the
// exit code. Returns true if exited, false if still running (or surface
// is not associated with a child process).
//
// This bridges the gap where Ghostty fires an "exit" action that the macOS
// Swift handler currently leaves unimplemented; Phantom needs the exit code
// for PushEngine ProcessExitTrigger.
//
// Thread-safe.
bool phantom_surface_get_exit_state(
    ghostty_surface_t surface,
    int32_t* out_exit_code
);

// =============================================================================
// Event Callbacks
// =============================================================================

typedef enum {
    PHANTOM_EVENT_BELL          = 1,
    PHANTOM_EVENT_RESIZE        = 2,
    PHANTOM_EVENT_TITLE_CHANGED = 3,
    PHANTOM_EVENT_PROCESS_EXIT  = 4
} phantom_event_kind_t;

typedef struct {
    phantom_event_kind_t kind;
    union {
        struct { uint16_t cols; uint16_t rows; } resize;
        struct { const char* str; size_t len; } title;
        struct { int32_t code; } exit;
        struct { uint8_t reserved; } bell;
    } data;
} phantom_event_t;

typedef void (*phantom_event_cb)(
    ghostty_surface_t surface,
    const phantom_event_t* event,
    void* userdata
);

// Registers (or replaces) a per-surface event callback. Pass NULL to
// deregister. The callback fires from Ghostty's main thread or render
// thread depending on event type; treat the callback as untrusted-thread.
void phantom_surface_set_event_cb(
    ghostty_surface_t surface,
    phantom_event_cb callback,
    void* userdata
);

// Resizes the surface to an exact CELL grid (cols x rows), converting to
// pixels internally via the surface's current cell metrics. Unlike
// ghostty_surface_set_size (pixels), this lets remote callers work in
// terminal coordinates. MUST be called on the app's main thread.
void phantom_surface_set_grid_size(ghostty_surface_t surface, uint16_t cols, uint16_t rows);

#ifdef __cplusplus
}
#endif

#endif // PHANTOM_H
