///
/// LZ4 compressor wrapped by an LZ4 Frame, with Zig std.Io support.
/// TODO: dictionary support
///
const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Writer = std.Io.Writer;

const Block = @import("../Block.zig");
const lz4u = @import("../lz4u.zig");
const BlockLengthHeader = lz4u.BlockLengthHeader;

output: *Writer,
writer: Writer,

position_table: Block.HashTable,
cur_history_len: usize,

max_block_size: u24,
acceleration: u16,

const Compress = @This();

pub const Options = struct {
    max_block_size: u24,
    acceleration: u16 = 1,
};

pub fn init(
    output: *Writer,
    buffer: []u8,
    options: Options,
) Compress {
    assert(buffer.len >= lz4u.max_window_len);
    assert(options.max_block_size > 0);
    assert(options.acceleration > 0);

    return Compress{
        .writer = .{
            .buffer = buffer,
            .vtable = &.{
                .drain = drain,
                .flush = flush,
                .rebase = rebase,
            },
        },
        .output = output,
        .position_table = .empty,
        .cur_history_len = 0,
        .acceleration = options.acceleration,
        .max_block_size = options.max_block_size,
    };
}

fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    // if we can't compress the buffered data, then put ourselves in failure state, to avoid losing data.
    errdefer w.* = .failing;

    // There may have not been enough space in the buffer and the write was sent directly here.
    // However, it is required that all data goes through the buffer to keep a history.
    //
    // Additionally, ensuring the buffer is always full ensures there is always a full history
    // after.
    const data_n = w.buffer.len - w.end;
    _ = w.fixedDrain(data, splat) catch {};
    assert(w.end == w.buffer.len);

    try processBuffer(w, 0, 1, .keep_history);
    return data_n;
}

fn flush(w: *Writer) Writer.Error!void {
    errdefer w.* = .failing;
    try processBuffer(w, 0, w.buffer.len, .process_all);
}

fn rebase(w: *Writer, preserve: usize, capacity: usize) Writer.Error!void {
    return processBuffer(w, preserve, capacity, .keep_history);
}

pub fn resetHistory(c: *Compress) void {
    c.cur_history_len = 0;
    c.position_table = .empty;
}

const ProcessBufferMode = enum {
    keep_history,
    process_all,
};

fn processBuffer(
    w: *Writer,
    preserve: usize,
    capacity: usize,
    comptime mode: ProcessBufferMode,
) Writer.Error!void {
    assert(capacity <= w.buffer.len);

    const c: *Compress = @fieldParentPtr("writer", w);
    const buffered = w.buffered();

    const max_block_length = c.max_block_size;
    var i = c.cur_history_len;

    while (i < buffered.len) {
        var position_table: Block.HashTable = .empty;

        const make_res = try Block.make(
            c.output,
            i,
            .{
                .input_buffer = w.buffer,
                .used_input_len = w.end,
                .max_block_length = max_block_length,
                .position_table = &position_table,
                .acceleration = c.acceleration,
            },
            .tokenize_everything,
        );
        if (make_res.read_length == 0)
            break;

        assert(make_res.read_length <= max_block_length);
        assert(make_res.block_header.length <= max_block_length);

        i += make_res.read_length;
    }

    switch (mode) {
        .keep_history => {
            const new_history_length = @min(i, lz4u.max_history_len);
            const history_len_to_keep = lz4u.max_history_len;
            const preserve_start = i -| history_len_to_keep;

            const preserved = buffered[preserve_start..];
            assert(preserved.len >= @max(history_len_to_keep, preserve));
            @memmove(w.buffer[0..preserved.len], preserved);
            w.end = preserved.len;
            c.cur_history_len = new_history_length;
        },
        .process_all => c.resetHistory(),
    }
}
