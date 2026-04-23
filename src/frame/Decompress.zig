const std = @import("std");
const hash = std.hash;
const Io = std.Io;
const math = std.math;
const assert = std.debug.assert;
const Limit = Io.Limit;
const Reader = Io.Reader;
const Writer = Io.Writer;

const Frame = @import("../Frame.zig");
const lz4u = @import("../lz4u.zig");
const BlockLengthHeader = lz4u.BlockLengthHeader;
const Header = Frame.Header;
const Token = lz4u.Token;

input: *Reader,
reader: Reader,
state: State,
err: ?(ReadHeaderError || ReadInFrameError),
verify_checksum: bool,

const Decompress = @This();

const State = union(enum) {
    new_frame,
    in_frame: InFrame,
    skipping_frame: usize,

    const InFrame = struct {
        frame: Header,
        decompressed_size: usize,
        checksum: ?hash.XxHash32,
    };
};

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

pub fn queryInCapacity() usize {
    return lz4u.max_block_size;
}

pub fn queryOutCapacity() usize {
    return lz4u.max_history_len + lz4u.max_block_size;
}

pub const Options = struct {
    verify_checksum: bool = false,
};

pub fn init(input: *Reader, buffer: []u8, options: Options) Decompress {
    if (buffer.len != 0) assert(buffer.len >= lz4u.min_indirect_buffer_len);
    return Decompress{
        .reader = .{
            .vtable = if (buffer.len == 0) &direct_vtable else &indirect_vtable,
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        },
        .input = input,
        .state = .{ .new_frame = {} },
        .err = null,
        .verify_checksum = options.verify_checksum,
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
    const in = d.input;

    state: switch (d.state) {
        .new_frame => {
            const frame = readFrameHeader(in) catch |err| switch (err) {
                error.EndOfStream => {
                    if (in.bufferedLen() != 0) {
                        d.err = error.InvalidMagic;
                        return error.ReadFailed;
                    }
                    return error.EndOfStream;
                },
                else => |e| {
                    d.err = e;
                    return error.ReadFailed;
                },
            };
            d.state = .{
                .in_frame = .{
                    .frame = frame,
                    .decompressed_size = 0,
                    .checksum = if (frame.flg.content_chksum) hash.XxHash32.init(0) else null,
                },
            };
            continue :state d.state;
        },
        .in_frame => |*in_frame| {
            const bytes_written = readInFrame(d, w, limit, in_frame) catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.WriteFailed => return error.WriteFailed,
                else => |e| {
                    d.err = e;
                    return error.ReadFailed;
                },
            };

            // check if there's a frame end mark
            if (try in.peekInt(u32, .little) == 0) {
                in.toss(@sizeOf(u32));

                if (in_frame.checksum) |*content_checksum| {
                    const expected_checksum = try in.takeInt(u32, .little);
                    if (d.verify_checksum) {
                        const final_checksum = content_checksum.final();
                        if (final_checksum != expected_checksum) {
                            d.err = error.FrameInvalidChecksum;
                            return error.ReadFailed;
                        }
                    }
                }

                d.state = .{ .new_frame = {} };
            }

            return bytes_written;
        },
        .skipping_frame => |*remaining| {
            const n = in.discard(.limited(remaining.*)) catch |err| {
                d.err = err;
                return error.ReadFailed;
            };
            remaining.* -= n;
            if (remaining.* == 0) d.state = .new_frame;
            return 0;
        },
    }
}

fn rebaseFallible(r: *Reader, capacity: usize) Reader.RebaseError!void {
    rebase(r, capacity);
}

fn rebase(r: *Reader, capacity: usize) void {
    const d: *Decompress = @alignCast(@fieldParentPtr("reader", r));

    const needs_history = switch (d.state) {
        .in_frame => |in| !in.frame.flg.block_indep,
        else => false,
    };
    // keep max_history_len in the buffer, in case the frame uses independent blocks
    const history_to_keep = @as(usize, lz4u.max_history_len) * @intFromBool(needs_history);

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
    const block_max_size = switch (d.state) {
        .in_frame => |in| in.frame.bd.block_max_size,
        else => .@"64KB", // use the smallest block max size if we're in a funny state
    };

    // Number of bytes desired to rebase, always rebase for at least the frame's block max size
    const desire_n = limitMax(limit, Limit.limited(block_max_size.toBytes()));
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

    const required_out_buffer_length = lz4u.max_history_len + lz4u.max_block_size;
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

pub const ReadHeaderError = error{
    InvalidMagic,
    UnknownVersion,
    InvalidChecksum,
} || Reader.Error;

pub fn readFrameHeader(reader: *Reader) ReadHeaderError!Header {
    const magic = try reader.takeInt(u32, .little);
    if (magic != Header.MAGIC) {
        return error.InvalidMagic;
    }

    var checksum = hash.XxHash32.init(0);

    const flg = try reader.takeStruct(Header.Flg, .little);
    if (flg.version != 1) {
        return error.UnknownVersion;
    }
    hash.autoHash(&checksum, @as(u8, @bitCast(flg)));

    const bd = try reader.takeStruct(Header.Bd, .little);
    hash.autoHash(&checksum, @as(u8, @bitCast(bd)));

    const content_size = if (flg.content_size) res: {
        const val = try reader.takeInt(u64, .little);
        hash.autoHash(&checksum, val);
        break :res val;
    } else null;
    const dict_id = if (flg.dict_id) res: {
        const val = try reader.takeInt(u32, .little);
        hash.autoHash(&checksum, val);
        break :res val;
    } else null;

    const hc = try reader.takeInt(u8, .little);
    const actual_hc: u8 = @truncate(checksum.final() >> 8);
    if (hc != actual_hc) {
        return error.InvalidChecksum;
    }

    return Header{
        .flg = flg,
        .bd = bd,
        .content_size = content_size,
        .dict_id = dict_id,
    };
}

pub const ReadInFrameError = error{
    LengthOverflow,
    BlockInvalidChecksum,
    InvalidBlockMaxSize,
    InputBufferTooSmall,

    MatchInvalidOffset,
    MalformedSequence,

    FrameInvalidChecksum,
    FrameBadOutSize,
} || Reader.StreamError;

fn readInFrame(d: *Decompress, w: *Writer, limit: Limit, state: *State.InFrame) ReadInFrameError!usize {
    const in = d.input;

    const block = try in.takeStruct(BlockLengthHeader, .little);
    const block_size = block.length;
    const frame_block_size_max = state.frame.bd.block_max_size.toBytes();

    if (block_size > frame_block_size_max) {
        @branchHint(.cold);
        return error.InvalidBlockMaxSize;
    }
    if (block_size > @intFromEnum(limit)) {
        @branchHint(.cold);
        return error.InputBufferTooSmall;
    }

    const raw_block_data = try in.take(block_size);

    const block_checksum: ?u32 =
        if (d.verify_checksum and state.frame.flg.block_chksum)
            hash.XxHash32.hash(0, raw_block_data)
        else
            null;
    var content_hasher = state.checksum;

    var bytes_written: usize = 0;
    if (block.uncompressed) {
        @branchHint(.unlikely);

        const dest = try w.writableSlice(block_size);
        @memcpy(dest, raw_block_data);

        if (content_hasher) |*hasher| {
            hasher.update(dest);
        }

        bytes_written += block_size;
    } else {
        var block_reader: Io.Reader = .fixed(raw_block_data);

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
            const remaining_block_len = frame_block_size_max - bytes_written;
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
                // last checksum
                if (content_hasher) |*hasher| {
                    hasher.update(w.buffer[write_pos..][0..literal_length]);
                }
                break;
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

            if (content_hasher) |*hasher| {
                const length_written = literal_length + match_length;
                hasher.update(w.buffer[write_pos..][0..length_written]);
            }

            bytes_written += match_length;
            w.advance(match_length);
        }
    }

    state.checksum = content_hasher;

    if (state.frame.flg.block_chksum) {
        const expected_block_sum = try in.takeInt(u32, .little);
        if (block_checksum) |actual_sum| {
            if (expected_block_sum != actual_sum) {
                return error.BlockInvalidChecksum;
            }
        }
    }

    state.decompressed_size += bytes_written;

    if (state.frame.content_size) |content_size| {
        if (content_size != state.decompressed_size) {
            return error.FrameBadOutSize;
        }
    }

    return bytes_written;
}

fn readLongLength(in: *Reader) ReadInFrameError!usize {
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
