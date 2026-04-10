const std = @import("std");
const math = std.math;
const assert = std.debug.assert;
const Limit = std.Io.Limit;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const lz4u = @import("../lz4u.zig");
const Token = lz4u.Token;

input: *Reader,
reader: Reader,

max_block_size: u24,
err: ?ReadBlockError,

const Decompress = @This();

const direct_vtable: Reader.VTable = .{
    .stream = streamDirect,
    .rebase = rebaseFallible,
    .discard = discardDirect,
    .readVec = readVec,
};
const indirect_vtable: Reader.VTable = .{
    .stream = streamIndirect,
    .rebase = rebaseFallible,
    .discard = discardIndirect,
    .readVec = readVec,
};

pub fn queryIndirectCapacity(options: Options) usize {
    return lz4u.max_history_len + options.max_block_size * 2;
}

pub const Options = struct {
    max_block_size: u24,
};

pub fn init(input: *Reader, buffer: []u8, options: Options) Decompress {
    if (buffer.len != 0) assert(buffer.len >= queryIndirectCapacity(options));
    return Decompress{
        .reader = .{
            .vtable = if (buffer.len == 0) &direct_vtable else &indirect_vtable,
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        },
        .input = input,
        .max_block_size = options.max_block_size,
        .err = null,
    };
}

fn streamDirect(r: *Reader, w: *Writer, limit: Limit) Reader.StreamError!usize {
    const d: *Decompress = @alignCast(@fieldParentPtr("reader", r));
    return streamFallible(d, w, limit);
}

fn streamIndirect(r: *Reader, w: *Writer, limit: Limit) Reader.StreamError!usize {
    const d: *Decompress = @alignCast(@fieldParentPtr("reader", r));
    _ = limit;
    _ = w;
    return streamIndirectInner(d);
}

fn streamFallible(d: *Decompress, w: *Writer, limit: Limit) Reader.StreamError!usize {
    const bytes_written = readBlock(d, w, limit) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        error.ReadFailed => return error.ReadFailed,
        error.WriteFailed => return error.WriteFailed,
        else => |e| {
            d.err = e;
            return error.ReadFailed;
        },
    };

    return bytes_written;
}

fn rebaseFallible(r: *Reader, capacity: usize) Reader.RebaseError!void {
    rebase(r, capacity);
}

fn rebase(r: *Reader, capacity: usize) void {
    // keep max_history_len in the buffer, in case the frame uses independent blocks
    const history_to_keep = @as(usize, lz4u.max_history_len);

    // ensure the user provided buffer can actually hold any history length we need
    assert(capacity <= r.buffer.len - history_to_keep);
    assert(r.end + capacity > r.buffer.len);

    const discard_n = @min(r.seek, r.end - history_to_keep);
    const keep = r.buffer[discard_n..r.end];
    @memmove(r.buffer[0..keep.len], keep);
    r.end = keep.len;
    r.seek -= discard_n;
}

// this function was added to the (at the time of writing) in development Zig 0.16
// TODO: use Io.Limit.max directly when updating
fn limitMax(a: Limit, b: Limit) Limit {
    if (a == .unlimited or b == .unlimited) {
        return .unlimited;
    }

    return @enumFromInt(@max(@intFromEnum(a), @intFromEnum(b)));
}

// Rebase `d.reader.buffer` as much as needed for a discard limited by `limit`
// Based off https://codeberg.org/ziglang/zig/pulls/30891
fn rebaseForDiscard(d: *Decompress, limit: Limit) void {
    // Number of bytes desired to rebase, always rebase for at least the frame's block max size
    const desire_n = limitMax(limit, Limit.limited(d.max_block_size));
    // Maximum number of bytes possible to rebase
    const max_n = d.reader.buffer.len -| lz4u.max_history_len;
    // Number of bytes to rebase
    const n = desire_n.minInt(max_n);

    // Current buffer free space
    const current_cap = d.reader.buffer.len - d.reader.end;
    if (current_cap < n) {
        rebase(&d.reader, n);
    }
}

fn discardDirect(r: *Reader, limit: Limit) Reader.Error!usize {
    const d: *Decompress = @alignCast(@fieldParentPtr("reader", r));

    if (r.end + lz4u.max_history_len > r.buffer.len) {
        rebaseForDiscard(d, limit);
    }

    var writer: Writer = .{
        .vtable = &.{
            .drain = Writer.Discarding.drain,
            .sendFile = Writer.Discarding.sendFile,
        },
        .buffer = r.buffer,
        .end = r.end,
    };
    defer {
        assert(writer.end != 0);
        r.end = writer.end;
        r.seek = r.end;
    }
    const n = r.stream(&writer, limit) catch |err| switch (err) {
        error.WriteFailed => unreachable,
        error.ReadFailed => return error.ReadFailed,
        error.EndOfStream => return error.EndOfStream,
    };
    assert(n <= @intFromEnum(limit));
    return n;
}

fn discardIndirect(r: *Reader, limit: Limit) Reader.Error!usize {
    const d: *Decompress = @alignCast(@fieldParentPtr("reader", r));
    rebaseForDiscard(d, limit);
    var writer: Writer = .{
        .buffer = r.buffer,
        .end = r.end,
        .vtable = &.{ .drain = Writer.unreachableDrain },
    };
    {
        defer r.end = writer.end;
        _ = streamFallible(d, &writer, .limited(writer.buffer.len - writer.end)) catch |err| switch (err) {
            error.WriteFailed => unreachable,
            else => |e| return e,
        };
    }
    const n = limit.minInt(r.end - r.seek);
    r.seek += n;
    return n;
}

fn readVec(r: *Reader, data: [][]u8) Reader.Error!usize {
    _ = data;
    const d: *Decompress = @alignCast(@fieldParentPtr("reader", r));
    return streamIndirectInner(d);
}

// decompress data to the user provided buffer.
// the user provided buffer can then later be used by Io.Reader.stream to write to the real Io.Writer
fn streamIndirectInner(d: *Decompress) Reader.Error!usize {
    const r = &d.reader;

    const required_out_buffer_length = d.max_block_size * 2;
    assert(required_out_buffer_length <= lz4u.min_indirect_buffer_len);
    if (r.buffer.len - r.end < required_out_buffer_length) rebase(r, required_out_buffer_length);
    assert(r.buffer.len - r.end >= required_out_buffer_length);

    var writer: Writer = .{
        .buffer = r.buffer,
        .end = r.end,
        .vtable = &.{
            .drain = Writer.unreachableDrain,
            .rebase = Writer.unreachableRebase,
        },
    };
    defer r.end = writer.end;
    _ = streamFallible(d, &writer, .limited(writer.buffer.len - writer.end)) catch |err| switch (err) {
        error.WriteFailed => unreachable,
        else => |e| return e,
    };
    return 0;
}

pub const ReadBlockError = error{
    LengthOverflow,
    MatchInvalidOffset,
    MalformedSequence,
} || Reader.StreamError;

fn readBlock(d: *Decompress, w: *Writer, limit: Limit) ReadBlockError!usize {
    const in = d.input;

    var input_length = limit.minInt(in.bufferedLen());
    if (input_length == 0) {
        @branchHint(.unlikely);
        return error.EndOfStream;
    }

    var bytes_written: usize = 0;
    while (input_length > 0) block: {
        const raw_block_len = @min(input_length, d.max_block_size);
        const raw_block_data = try in.peek(raw_block_len);

        const start_write_pos = w.end;
        var block_reader: Reader = .fixed(raw_block_data);

        defer {
            const block_len_read = block_reader.seek;
            in.toss(block_len_read);
            input_length -= block_len_read;
        }

        while (block_reader.seek < block_reader.buffer.len) {
            const token = try block_reader.takeStruct(Token, .little);

            // read literal length
            // if it's larget than 15 then count its following bytes
            const literal_length = blk: {
                var len: usize = token.literal_len;
                if (len >= 15) {
                    len += try readLongLength(&block_reader);
                }
                break :blk len;
            };

            // Ensure the writer keeps history data and keeps block length memory free for us to write.
            const remaining_block_len = block_reader.buffer.len - block_reader.seek;
            _ = try w.writableSliceGreedyPreserve(lz4u.max_history_len, remaining_block_len);

            const write_pos = w.end;

            const out_literals = w.buffer[write_pos..][0..literal_length];
            if (literal_length > 0) {
                @branchHint(.likely);
                try block_reader.readSliceAll(out_literals);
            }
            bytes_written += literal_length;
            w.advance(literal_length);

            // if there's no match data then this block is done
            if (block_reader.seek == block_reader.buffer.len) {
                @branchHint(.unlikely);
                break;
            }

            // NON-STANDARD EXTENSION!
            // reset decoding once a block ends, since zero match offsets are invalid
            const length_written = w.end - start_write_pos;
            if (length_written + lz4u.Block.num_last_literals >= d.max_block_size) {
                @branchHint(.unlikely);
                break :block;
            }

            // match offset can't be 0
            const match_offset = try block_reader.takeInt(u16, .little);
            if (match_offset == 0) {
                @branchHint(.cold);
                return error.MatchInvalidOffset;
            }

            // read match length
            // also if it's larget than 15 then count its following bytes
            const match_length = blk: {
                var len: usize = token.match_len;
                len += 4;
                if (len >= 19) {
                    len += try readLongLength(&block_reader);
                }
                break :blk len;
            };

            if (match_length > w.buffer[write_pos..].len) {
                @branchHint(.cold);
                return error.MalformedSequence;
            }

            const copy_start = math.sub(usize, write_pos + literal_length, match_offset) catch {
                @branchHint(.cold);
                return error.MalformedSequence;
            };

            const matches_source = w.buffer[copy_start..][0..match_length];
            const matches_target = w.buffer[write_pos + literal_length ..][0..match_length];
            // This is not a @memmove; it intentionally repeats patterns
            // caused by iterating one byte at a time.
            for (matches_target, matches_source) |*o, i| o.* = i;

            bytes_written += match_length;
            w.advance(match_length);
        }
    }

    return bytes_written;
}

fn readLongLength(in: *Reader) ReadBlockError!usize {
    var total_len: usize = 0;
    while (true) {
        const b = try in.takeInt(u8, .little);
        total_len = math.add(usize, total_len, b) catch {
            @branchHint(.cold);
            return error.LengthOverflow;
        };
        if (b != 255) {
            break;
        }
    }
    return total_len;
}
