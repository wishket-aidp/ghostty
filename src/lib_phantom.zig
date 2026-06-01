// Phantom C API exports.
//
// This file implements the C API declared in
// `include/ghostty/phantom.h`. The functions are referenced from
// `main_c.zig`'s comptime block so that Zig actually emits them in the
// final libghostty static archive.
//
// Phase 1 scope (see docs/superpowers/plans/...phase-0-1.md and
// docs/superpowers/notes/ghostty-research.md):
//   * Real cols/rows/cursor_x/cursor_y are extracted under the
//     renderer_state mutex.
//   * Real cells are extracted via PageList.getCell on the viewport.
//   * exit_state is wired to surface.core_surface.child_exited; exit code
//     extraction is stubbed (always 0) and will be wired in Phase 4.
//   * Event callbacks are stored in a side-table and never fired in
//     Phase 1.
//
// Threading:
//   * Snapshot reads acquire core_surface.renderer_state.mutex.
//   * The sequence side-table and callback side-table use their own
//     std.Thread.Mutex.
//
// Memory:
//   * Snapshots are allocated with std.heap.c_allocator so the caller
//     (Swift side) can hold the pointer across Zig allocator scopes.
//   * Side-table entries leak intentionally when a surface is freed
//     without prior cleanup. The map is keyed by *anyopaque (the C
//     surface handle) so a freed surface leaves a stale entry; we do
//     not dereference it after free.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const assert = std.debug.assert;

const apprt = @import("apprt.zig");
const terminal = @import("terminal/main.zig");
const termio = @import("termio.zig");

const EmbeddedSurface = apprt.embedded.Surface;
const stylepkg = @import("terminal/style.zig");

// ---------------------------------------------------------------------------
// C ABI types matching include/ghostty/phantom.h
// ---------------------------------------------------------------------------

const PHANTOM_CURSOR_BLOCK: u8 = 0;
const PHANTOM_CURSOR_BEAM: u8 = 1;
const PHANTOM_CURSOR_UNDERLINE: u8 = 2;

const PHANTOM_COLOR_DEFAULT: u8 = 0;
const PHANTOM_COLOR_INDEXED: u8 = 1;
const PHANTOM_COLOR_RGB: u8 = 2;

const PHANTOM_ATTR_BOLD: u16 = 0x0001;
const PHANTOM_ATTR_ITALIC: u16 = 0x0002;
const PHANTOM_ATTR_UNDERLINE: u16 = 0x0004;
const PHANTOM_ATTR_STRIKETHROUGH: u16 = 0x0008;
const PHANTOM_ATTR_BLINK: u16 = 0x0010;
const PHANTOM_ATTR_INVERSE: u16 = 0x0020;
const PHANTOM_ATTR_DIM: u16 = 0x0040;
const PHANTOM_ATTR_HIDDEN: u16 = 0x0080;

const PHANTOM_EVENT_BELL: c_int = 1;
const PHANTOM_EVENT_RESIZE: c_int = 2;
const PHANTOM_EVENT_TITLE_CHANGED: c_int = 3;
const PHANTOM_EVENT_PROCESS_EXIT: c_int = 4;

const SnapshotHeader = extern struct {
    cols: u16,
    rows: u16,
    cursor_x: u16,
    cursor_y: u16,
    cursor_style: u8,
    cursor_visible: bool,
    sequence: u64,
};

const SnapshotCell = extern struct {
    codepoint: u32,
    width: u8,
    fg_kind: u8,
    fg_value: u32,
    bg_kind: u8,
    bg_value: u32,
    attrs: u16,
};

// Opaque from C's perspective. C only sees `phantom_snapshot_t*`.
const Snapshot = struct {
    header: SnapshotHeader,
    // Row-major: [row * cols + col]
    cells: []SnapshotCell,

    fn cellAt(self: *const Snapshot, row: u16, col: u16) ?SnapshotCell {
        if (row >= self.header.rows or col >= self.header.cols) return null;
        const idx: usize = @as(usize, row) * @as(usize, self.header.cols) + @as(usize, col);
        return self.cells[idx];
    }
};

// Callback function pointer type matching phantom_event_cb.
const EventCb = ?*const fn (
    surface: ?*anyopaque,
    event: *const anyopaque,
    userdata: ?*anyopaque,
) callconv(.c) void;

// ---------------------------------------------------------------------------
// Side tables
// ---------------------------------------------------------------------------

const SeqEntry = struct {
    seq: u64,
};

const CbEntry = struct {
    cb: EventCb,
    userdata: ?*anyopaque,
};

const SurfaceKey = *anyopaque;

const SeqMap = std.AutoHashMapUnmanaged(SurfaceKey, SeqEntry);
const CbMap = std.AutoHashMapUnmanaged(SurfaceKey, CbEntry);

var g_mutex: std.Thread.Mutex = .{};
var g_seq_map: SeqMap = .{};
var g_cb_map: CbMap = .{};

fn seqFor(surface: SurfaceKey) u64 {
    g_mutex.lock();
    defer g_mutex.unlock();
    const e = g_seq_map.get(surface) orelse SeqEntry{ .seq = 0 };
    return e.seq;
}

fn bumpSeq(surface: SurfaceKey) u64 {
    g_mutex.lock();
    defer g_mutex.unlock();
    const gop = g_seq_map.getOrPut(std.heap.c_allocator, surface) catch {
        // If we cannot allocate, return 0 — the caller should still treat
        // it as a valid (if degenerate) sequence.
        return 0;
    };
    if (!gop.found_existing) gop.value_ptr.* = .{ .seq = 0 };
    gop.value_ptr.seq +%= 1;
    return gop.value_ptr.seq;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn mapCursorStyle(s: terminal.CursorStyle) u8 {
    return switch (s) {
        .block, .block_hollow => PHANTOM_CURSOR_BLOCK,
        .bar => PHANTOM_CURSOR_BEAM,
        .underline => PHANTOM_CURSOR_UNDERLINE,
    };
}

fn rgbToU32(rgb: anytype) u32 {
    // Packs as 0x00RRGGBB.
    const r: u32 = @as(u32, rgb.r) << 16;
    const g: u32 = @as(u32, rgb.g) << 8;
    const b: u32 = @as(u32, rgb.b);
    return r | g | b;
}

fn styleAttrs(style_val: stylepkg.Style) u16 {
    var bits: u16 = 0;
    if (style_val.flags.bold) bits |= PHANTOM_ATTR_BOLD;
    if (style_val.flags.italic) bits |= PHANTOM_ATTR_ITALIC;
    if (style_val.flags.underline != .none) bits |= PHANTOM_ATTR_UNDERLINE;
    if (style_val.flags.strikethrough) bits |= PHANTOM_ATTR_STRIKETHROUGH;
    if (style_val.flags.blink) bits |= PHANTOM_ATTR_BLINK;
    if (style_val.flags.inverse) bits |= PHANTOM_ATTR_INVERSE;
    if (style_val.flags.faint) bits |= PHANTOM_ATTR_DIM;
    if (style_val.flags.invisible) bits |= PHANTOM_ATTR_HIDDEN;
    return bits;
}

fn colorToKindValue(c: stylepkg.Style.Color) struct { kind: u8, value: u32 } {
    return switch (c) {
        .none => .{ .kind = PHANTOM_COLOR_DEFAULT, .value = 0 },
        .palette => |p| .{ .kind = PHANTOM_COLOR_INDEXED, .value = @as(u32, p) },
        .rgb => |rgb| .{ .kind = PHANTOM_COLOR_RGB, .value = rgbToU32(rgb) },
    };
}

fn cellWidth(wide: terminal.page.Cell.Wide) u8 {
    return switch (wide) {
        .narrow => 1,
        .wide => 2,
        // Tail/head spacers are part of a wide character but render as
        // width 1 (they're the second cell or wrap-spacer).
        .spacer_tail, .spacer_head => 1,
    };
}

fn captureSnapshot(surface: *EmbeddedSurface, sequence: u64) ?*Snapshot {
    const core = &surface.core_surface;

    core.renderer_state.mutex.lock();
    defer core.renderer_state.mutex.unlock();

    const t = core.renderer_state.terminal;
    const screen = t.screens.active;
    const cols: u16 = screen.pages.cols;
    const rows: u16 = screen.pages.rows;

    const total: usize = @as(usize, cols) * @as(usize, rows);
    const alloc = std.heap.c_allocator;

    const snap = alloc.create(Snapshot) catch return null;
    errdefer alloc.destroy(snap);

    const cells = alloc.alloc(SnapshotCell, total) catch {
        alloc.destroy(snap);
        return null;
    };
    errdefer alloc.free(cells);

    // Zero-init cells as a safe default.
    for (cells) |*c| {
        c.* = .{
            .codepoint = 0,
            .width = 1,
            .fg_kind = PHANTOM_COLOR_DEFAULT,
            .fg_value = 0,
            .bg_kind = PHANTOM_COLOR_DEFAULT,
            .bg_value = 0,
            .attrs = 0,
        };
    }

    // Fill the cell grid from the viewport. Using getCell is "slow" by
    // upstream comment but for typical terminal sizes (80x24..400x100)
    // it's fine for Phase 1.
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        var col: u16 = 0;
        while (col < cols) : (col += 1) {
            const pl_cell = screen.pages.getCell(.{
                .viewport = .{ .x = col, .y = row },
            }) orelse continue;

            const out_idx: usize = @as(usize, row) * @as(usize, cols) + @as(usize, col);
            const cp_val: u32 = switch (pl_cell.cell.content_tag) {
                .codepoint, .codepoint_grapheme => @as(u32, pl_cell.cell.content.codepoint),
                .bg_color_palette, .bg_color_rgb => 0,
            };

            const w = cellWidth(pl_cell.cell.wide);

            // Style: only look it up if non-default.
            var fg_kind: u8 = PHANTOM_COLOR_DEFAULT;
            var fg_value: u32 = 0;
            var bg_kind: u8 = PHANTOM_COLOR_DEFAULT;
            var bg_value: u32 = 0;
            var attrs: u16 = 0;

            // Cells that carry a background-only color use the content
            // union directly rather than a style.
            switch (pl_cell.cell.content_tag) {
                .bg_color_palette => {
                    bg_kind = PHANTOM_COLOR_INDEXED;
                    bg_value = @as(u32, pl_cell.cell.content.color_palette);
                },
                .bg_color_rgb => {
                    bg_kind = PHANTOM_COLOR_RGB;
                    bg_value = rgbToU32(pl_cell.cell.content.color_rgb);
                },
                else => {},
            }

            if (pl_cell.cell.style_id != stylepkg.default_id) {
                const style_val = pl_cell.style();
                attrs = styleAttrs(style_val);
                const fg = colorToKindValue(style_val.fg_color);
                if (fg.kind != PHANTOM_COLOR_DEFAULT) {
                    fg_kind = fg.kind;
                    fg_value = fg.value;
                }
                // Background from style only overrides if the content
                // didn't already provide a bg color.
                if (bg_kind == PHANTOM_COLOR_DEFAULT) {
                    const bg = colorToKindValue(style_val.bg_color);
                    bg_kind = bg.kind;
                    bg_value = bg.value;
                }
            }

            cells[out_idx] = .{
                .codepoint = cp_val,
                .width = w,
                .fg_kind = fg_kind,
                .fg_value = fg_value,
                .bg_kind = bg_kind,
                .bg_value = bg_value,
                .attrs = attrs,
            };
        }
    }

    const cursor_visible = t.modes.get(.cursor_visible);

    snap.* = .{
        .header = .{
            .cols = cols,
            .rows = rows,
            .cursor_x = screen.cursor.x,
            .cursor_y = screen.cursor.y,
            .cursor_style = mapCursorStyle(screen.cursor.cursor_style),
            .cursor_visible = cursor_visible,
            .sequence = sequence,
        },
        .cells = cells,
    };

    return snap;
}

// ---------------------------------------------------------------------------
// Exported C API
// ---------------------------------------------------------------------------

pub export fn phantom_surface_snapshot_seq(surface: ?*anyopaque) callconv(.c) u64 {
    const key = surface orelse return 0;
    return seqFor(key);
}

pub export fn phantom_surface_snapshot(surface: ?*anyopaque) callconv(.c) ?*Snapshot {
    const handle = surface orelse return null;
    const seq = bumpSeq(handle);
    const surf: *EmbeddedSurface = @ptrCast(@alignCast(handle));
    return captureSnapshot(surf, seq);
}

pub export fn phantom_surface_snapshot_if_changed(
    surface: ?*anyopaque,
    last_sequence: u64,
) callconv(.c) ?*Snapshot {
    const handle = surface orelse return null;
    const current = seqFor(handle);
    if (current != 0 and last_sequence >= current) return null;
    const seq = bumpSeq(handle);
    const surf: *EmbeddedSurface = @ptrCast(@alignCast(handle));
    return captureSnapshot(surf, seq);
}

pub export fn phantom_snapshot_header(
    snapshot: ?*Snapshot,
    out_header: ?*SnapshotHeader,
) callconv(.c) void {
    const s = snapshot orelse return;
    const out = out_header orelse return;
    out.* = s.header;
}

pub export fn phantom_snapshot_cell(
    snapshot: ?*Snapshot,
    row: u16,
    col: u16,
    out_cell: ?*SnapshotCell,
) callconv(.c) bool {
    const s = snapshot orelse return false;
    const out = out_cell orelse return false;
    const c = s.cellAt(row, col) orelse return false;
    out.* = c;
    return true;
}

pub export fn phantom_snapshot_free(snapshot: ?*Snapshot) callconv(.c) void {
    const s = snapshot orelse return;
    const alloc = std.heap.c_allocator;
    alloc.free(s.cells);
    alloc.destroy(s);
}

pub export fn phantom_surface_get_exit_state(
    surface: ?*anyopaque,
    out_exit_code: ?*i32,
) callconv(.c) bool {
    const handle = surface orelse return false;
    const surf: *EmbeddedSurface = @ptrCast(@alignCast(handle));
    if (!surf.core_surface.child_exited) return false;
    // Exit code extraction is wired in Phase 4. For now, report 0.
    if (out_exit_code) |p| p.* = 0;
    return true;
}

pub export fn phantom_surface_set_event_cb(
    surface: ?*anyopaque,
    callback: EventCb,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const key = surface orelse return;
    g_mutex.lock();
    defer g_mutex.unlock();

    if (callback == null) {
        _ = g_cb_map.remove(key);
        return;
    }

    g_cb_map.put(std.heap.c_allocator, key, .{
        .cb = callback,
        .userdata = userdata,
    }) catch {
        // If we can't allocate the entry, the callback simply won't fire.
        // Phase 1 doesn't fire callbacks anyway.
        return;
    };
}

// ---------------------------------------------------------------------------
// Input — raw PTY write
// ---------------------------------------------------------------------------

// Write raw bytes straight to the surface's PTY, exactly as if they had been
// produced by the local keyboard. Unlike `ghostty_surface_text` (which routes
// through the clipboard-paste path and therefore wraps the bytes in bracketed
// paste — so a trailing "\r" is inserted as literal newline content instead of
// submitting the line), this delivers the bytes verbatim. PhantomBridge uses
// it for the submit Enter after pasting a (possibly multi-line) message body
// via `ghostty_surface_text`, so Claude Code et al. receive the multi-line
// content as one bracketed paste and then a real Enter to send it.
//
// MUST be called on the app's main thread (same constraint as every other
// libghostty surface mutation).
pub export fn phantom_surface_send_text(
    surface: ?*anyopaque,
    ptr: [*]const u8,
    len: usize,
) callconv(.c) void {
    const handle = surface orelse return;
    if (len == 0) return;
    const surf: *EmbeddedSurface = @ptrCast(@alignCast(handle));
    const core = &surf.core_surface;
    const msg = termio.Message.writeReq(core.alloc, ptr[0..len]) catch return;
    core.io.queueMessage(msg, .unlocked);
}

// Suppress unused-constant warnings when builds are aggressive about them.
comptime {
    _ = PHANTOM_EVENT_BELL;
    _ = PHANTOM_EVENT_RESIZE;
    _ = PHANTOM_EVENT_TITLE_CHANGED;
    _ = PHANTOM_EVENT_PROCESS_EXIT;
    _ = builtin.is_test;
    _ = assert;
    _ = Allocator;
}
