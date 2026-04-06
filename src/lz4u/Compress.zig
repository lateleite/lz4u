///
/// Hash table based LZ4 compressor, with Zig std.Io support.
/// TODO: dictionary support
///
const std = @import("std");
const hash = std.hash;
const Io = std.Io;
const math = std.math;
const mem = std.mem;
const assert = std.debug.assert;
const Limit = Io.Limit;
const Reader = Io.Reader;
const Writer = Io.Writer;

const lz4u = @import("../lz4u.zig");
const BlockLengthHeader = lz4u.BlockLengthHeader;
const BlockMaxSize = lz4u.BlockMaxSize;
const Frame = lz4u.Frame;
const Token = lz4u.Token;

output: *Writer,
writer: Writer,
position_table: HashTable(.default),
frame_hasher: ?hash.XxHash32,
cur_history_len: usize,

block_checksum: bool,
allow_history: bool,
acceleration: u16,
max_block_size: BlockMaxSize,

const Compress = @This();

pub const Options = struct {
    max_block_size: BlockMaxSize,
    should_checksum_frame: bool,
    should_checksum_block: bool,
    independent_blocks: bool,
    acceleration: u16 = 1,
    content_size_hint: ?u64 = null,
};

pub fn queryOutCapacity(options: Options) usize {
    var length: usize = 0;
    length += calcHeaderSize(options);
    length += @sizeOf(BlockLengthHeader); // frame block header
    length += options.max_block_size.toBytes(); // block data
    length += @as(usize, @sizeOf(u32)) * @intFromBool(options.should_checksum_block); // block checksum
    return length;
}

fn calcHeaderSize(options: Options) u16 {
    var result: u16 = 0;
    result += @sizeOf(u32); // magic
    result += @sizeOf(u8); // flg
    result += @sizeOf(u8); // bd
    result += @as(u16, @sizeOf(u64)) * @intFromBool(options.content_size_hint != null); // content size
    result += @sizeOf(u8); // hc
    return result;
}

pub fn init(
    output: *Writer,
    buffer: []u8,
    options: Options,
) !Compress {
    assert(buffer.len >= lz4u.max_window_len);
    assert(output.buffer.len >= queryOutCapacity(options));

    // reserve the memory region that will have the header written to,
    // so it can be hashed later.
    const header_length = calcHeaderSize(options);
    const header_buffer = (try output.writableSliceGreedy(header_length))[0..header_length];

    // write frame header
    try output.writeInt(u32, Frame.MAGIC, .little);
    // write frame header's descriptor
    const flg: u8 = @bitCast(Frame.Flg{
        .dict_id = false,
        .content_chksum = options.should_checksum_frame,
        .content_size = options.content_size_hint != null,
        .block_chksum = options.should_checksum_block,
        .block_indep = options.independent_blocks,
    });
    try output.writeByte(flg);

    const bd: u8 = @bitCast(Frame.Bd{
        .block_max_size = options.max_block_size,
    });
    try output.writeByte(bd);

    if (options.content_size_hint) |content_size_hint| {
        // TODO: validate that the hint is valid at the end of a frame?
        try output.writeInt(u64, content_size_hint, .little);
    }

    // TODO: dictionary IDs

    const header_sum_data = header_buffer[4..][0 .. header_buffer.len - 5];
    const hc: u8 = @truncate(hash.XxHash32.hash(0, header_sum_data) >> 8);
    try output.writeByte(hc);

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
        .frame_hasher = if (options.should_checksum_frame) .init(0) else null,
        .cur_history_len = 0,
        .block_checksum = options.should_checksum_block,
        .acceleration = options.acceleration,
        .allow_history = !options.independent_blocks,
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

    try processBuffer(w, 0, 1, .compress_optimal);
    return data_n;
}

// Compresses as much data as it can right away, even if it's not optimal.
fn flush(w: *Writer) Writer.Error!void {
    errdefer w.* = .failing;
    const c: *Compress = @fieldParentPtr("writer", w);
    try processBuffer(w, 0, w.buffer.len - c.cur_history_len, .compress_all);
}

fn rebase(w: *Writer, preserve: usize, capacity: usize) Writer.Error!void {
    return processBuffer(w, preserve, capacity, .compress_optimal);
}

pub fn finish(c: *Compress) Writer.Error!void {
    defer c.writer = .failing;

    try processBuffer(&c.writer, 0, c.writer.buffer.len - c.cur_history_len, .final_compression);

    //
    // write frame footer
    //
    // end of mark
    try c.output.writeInt(u32, 0, .little);
    // optional content checksum
    if (c.frame_hasher) |*checksum| {
        try c.output.writeInt(u32, checksum.final(), .little);
    }
}

const num_last_literals = 5;
const min_match_len = 4;
const min_last_match_len = 12;
const rebase_reserved_capacity = (lz4u.max_token_length + 1) + num_last_literals;

const ProcessType = enum {
    compress_optimal, // try compressing as many optimized blocks at once, leaving any unoptimizable data in the buffer
    compress_all, // try compressing everything at once, even if it produces unoptimal blocks
    final_compression, // last compression, use all buffered data
};

fn processBuffer(
    w: *Writer,
    preserve: usize,
    capacity: usize,
    comptime process_type: ProcessType,
) Writer.Error!void {
    const c: *Compress = @fieldParentPtr("writer", w);

    if (process_type == .compress_optimal) {
        // we're expecting the buffer to hold at least max_history_len worth of data in the buffer.
        assert(@max(preserve, lz4u.max_history_len) + (capacity + rebase_reserved_capacity) <= w.buffer.len);
        assert(w.end >= lz4u.max_history_len + rebase_reserved_capacity); // Above assert shouldn't
        // fail since rebase is only called when `capacity` is not present. This assertion is
        // important because a full history is required at the end.
    } else {
        assert(preserve == 0 and capacity == w.buffer.len - c.cur_history_len);
    }

    const buffered = w.buffered();

    const start = c.cur_history_len;
    const lit_end: usize = if (process_type == .compress_optimal)
        buffered.len - rebase_reserved_capacity - (preserve -| lz4u.max_history_len)
    else
        buffered.len;

    var i = start;

    while (i < lit_end) {
        if (!c.allow_history)
            c.position_table = .empty;

        const bytes_read = try c.makeBlock(buffered, i);
        if (bytes_read == 0)
            break;

        i += bytes_read;
    }

    switch (process_type) {
        .compress_optimal, .compress_all => {
            const new_history_length = @min(i, lz4u.max_history_len);
            const history_len_to_keep = @as(usize, lz4u.max_history_len) * @intFromBool(c.allow_history);
            const preserve_start = i -| history_len_to_keep;

            const preserved = buffered[preserve_start..];
            assert(preserved.len >= @max(history_len_to_keep, preserve));
            @memmove(w.buffer[0..preserved.len], preserved);
            w.end = preserved.len;
            c.cur_history_len = new_history_length * @intFromBool(c.allow_history);
        },
        .final_compression => {}, // nothing needs to be updated since the writer will become `.failing`
    }
}

fn makeBlock(c: *Compress, buffered: []const u8, start_offset: usize) Writer.Error!usize {
    const max_block_length = c.max_block_size.toBytes();

    var i = start_offset;

    const next_data_len = buffered.len - i;
    const lit_end = start_offset + @min(next_data_len, max_block_length);

    // reserve space for block's length
    // TODO: use lz4's worse case calculation
    const dst_block_len =
        @sizeOf(BlockLengthHeader) +
        max_block_length +
        (@intFromBool(c.block_checksum) * @as(usize, @sizeOf(u32)));
    const dst_block_data = try c.output.writableSliceGreedy(dst_block_len);
    c.output.advance(@sizeOf(BlockLengthHeader));

    const match_end = lit_end -| min_last_match_len;
    const max_match_output_len = max_block_length -| min_last_match_len;

    // hash the first possible value
    // matchAndAddHash() expects it to be there
    if (i + 4 < lit_end) {
        @branchHint(.likely);
        const cur_data = c.writer.buffer[i..];
        const cur_seq = mem.readInt(u32, cur_data[0..4], .little);
        defer c.position_table.put(cur_seq, 0);
    }

    var written_length: usize = 0;

    while (i < match_end) {
        const literal_start = i;

        // find a match if possible
        const find_result = c.matchAndAddHash(i, match_end);

        const match =
            find_result.match orelse
            break;

        if (literal_start + find_result.literal_len + match.len + min_last_match_len >= match_end)
            break;

        const expected_lit_token_len = calcLiteralTokenLength(find_result.literal_len);
        const expected_match_token_len = calcMatchTokenLength(match.len);
        const expected_written_length =
            written_length +
            expected_lit_token_len +
            find_result.literal_len +
            @sizeOf(u16) +
            expected_match_token_len;
        if (expected_written_length >= max_match_output_len)
            break;

        // write token
        const lit_token_len = try writeToken(c.output, find_result.literal_len, match.len);
        assert(lit_token_len == expected_lit_token_len);

        // write literals
        try c.output.writeAll(buffered[literal_start..][0..find_result.literal_len]);

        // write match offset
        try c.output.writeInt(u16, match.offset, .little);

        // write match's length (part of token)
        const match_token_len = try writeMatchLength(c.output, match.len);
        assert(match_token_len == expected_match_token_len);

        i += find_result.literal_len + match.len;
        written_length = expected_written_length;
    }

    const remain_len = lit_end - i;
    const did_compress_blocks = written_length > 0;

    if (remain_len > 0 and written_length + remain_len <= max_block_length) {
        const possible_lit_token_len = calcLiteralTokenLength(remain_len) * @intFromBool(did_compress_blocks);
        const possible_final_written = written_length + possible_lit_token_len + remain_len;

        if (possible_final_written < max_block_length) {
            if (did_compress_blocks) {
                // write token if we're in an existing compressed block
                written_length += try writeToken(c.output, remain_len, 0);
            }

            // write the uncompressable literals
            const remain_buf = buffered[i..][0..remain_len];
            try c.output.writeAll(remain_buf);

            i += remain_len;
            written_length += remain_len;
        }
    }

    // write the block header in the previously reserved region
    const block_len_header: BlockLengthHeader = .{
        .length = @intCast(written_length),
        .uncompressed = !did_compress_blocks,
    };
    mem.writeInt(u32, dst_block_data[0..4], @bitCast(block_len_header), .little);

    if (c.block_checksum) {
        // block checksum must use the block data directly, both compressed and uncompressed
        const dst_written = dst_block_data[4..][0..block_len_header.length];
        const block_hash = hash.XxHash32.hash(0, dst_written);
        try c.output.writeInt(u32, block_hash, .little);
    }

    if (c.frame_hasher) |*hasher| {
        // frame checksum must use decompressed data
        hasher.update(buffered[start_offset..i]);
    }

    return i - start_offset;
}

const MatchResult = struct {
    pub const Match = struct {
        offset: u16,
        len: usize,
    };

    match: ?Match,
    literal_len: usize,
};

fn matchAndAddHash(c: *Compress, start_i: usize, end_i: usize) MatchResult {
    var step = c.acceleration;
    var search_match_nb = c.acceleration;

    // we need at least 4 bytes in the buffer to hash
    const absolute_end = @min(end_i, c.writer.end);

    const buffered = c.writer.buffered();

    var i = start_i;
    while (i < absolute_end) : (i += step) {
        // Adaptive step
        step = search_match_nb >> 6;
        search_match_nb += 1;

        const cur_data = buffered[i..];
        assert(cur_data.len >= @sizeOf(u32));
        const cur_seq = mem.readInt(u32, cur_data[0..4], .little);

        // always set this sequence's position at the end of the loop
        defer c.position_table.put(cur_seq, @intCast(i));

        const match_pos = c.position_table.get(cur_seq);
        if (match_pos >= i or match_pos + lz4u.max_match_length < i)
            continue;

        const match_data = buffered[match_pos..];
        const possible_max_len = @min(lz4u.max_match_length, @min(cur_data.len, match_data.len));

        // find how long the match is
        const match_len = res: {
            for (
                cur_data[0..possible_max_len],
                match_data[0..possible_max_len],
                0..,
            ) |cur, m, cur_len| {
                if (cur != m)
                    break :res cur_len;
            }
            break :res possible_max_len;
        };

        if (match_len < min_match_len)
            continue;

        const match_offset = i - match_pos;
        assert(match_offset <= lz4u.max_match_length);

        // go backwards and see if there's any previous matching bytes we missed
        const back_len = res: {
            if (match_len > lz4u.max_match_length) {
                break :res 0;
            }

            const max_possible_match_len = lz4u.max_match_length - match_len;
            const available_offset_len = lz4u.max_match_length - match_offset;

            const max_backwards_len = @min(@min(@min(i - start_i, match_pos), max_possible_match_len), available_offset_len);
            if (max_backwards_len <= 0) {
                @branchHint(.likely);
                break :res 0;
            }

            var length: usize = 0;
            for (1..max_backwards_len) |offset| {
                const current_byte = buffered[i - offset];
                const match_byte = buffered[match_pos - offset];
                if (current_byte != match_byte) {
                    @branchHint(.likely);
                    break;
                }
                length += 1;
            }

            break :res length;
        };

        const final_match_offset = match_offset;
        assert(final_match_offset <= lz4u.max_match_length);

        const final_match_len = match_len + back_len;
        assert(final_match_len <= lz4u.max_match_length);

        return .{
            .match = .{
                .offset = @intCast(final_match_offset),
                .len = final_match_len,
            },
            .literal_len = (i - start_i) - back_len,
        };
    }

    return .{
        .match = null,
        .literal_len = i - start_i,
    };
}

const HashTableOptions = struct {
    table_size_exponent: u8,

    const default: HashTableOptions = .{
        .table_size_exponent = 14,
    };
};

fn HashTable(options: HashTableOptions) type {
    return struct {
        table: [1 << options.table_size_exponent]u32,

        const Self = @This();

        const empty: Self = .{
            .table = @splat(0),
        };

        pub fn get(self: Self, sequence: u32) u32 {
            const hash_val = hashFunc(sequence);
            return self.table[hash_val];
        }

        pub fn put(self: *Self, sequence: u32, pos: u32) void {
            const hash_val = hashFunc(sequence);
            self.table[hash_val] = pos;
        }

        fn hashFunc(sequence: u32) u32 {
            return (sequence *% 0x9e3779b1) >> ((min_match_len * 8) - options.table_size_exponent);
        }
    };
}

fn writeToken(w: *Io.Writer, literal_len: u64, match_len: u64) Writer.Error!usize {
    assert(match_len == 0 or match_len >= min_match_len);
    var num_bytes_written: usize = 0;

    const token = Token{
        .literal_len = @min(literal_len, 15),
        .match_len = if (match_len >= min_match_len)
            @min(match_len - min_match_len, 15)
        else
            0,
    };
    try w.writeByte(@bitCast(token));
    num_bytes_written += 1;

    if (literal_len >= 15) {
        var remain_literal_len = literal_len - token.literal_len;
        while (remain_literal_len >= 255) {
            try w.writeByte(255);
            num_bytes_written += 1;
            remain_literal_len -= 255;
        }

        try w.writeByte(@intCast(remain_literal_len));
        num_bytes_written += 1;
    }

    return num_bytes_written;
}

fn calcLiteralTokenLength(length: u64) usize {
    var num_bytes_written: usize = 1;
    const length_in_token = @min(length, 15);

    if (length >= 15) {
        var remain_len = length - length_in_token;
        while (remain_len >= 255) {
            num_bytes_written += 1;
            remain_len -= 255;
        }

        num_bytes_written += 1;
    }

    return num_bytes_written;
}

fn writeMatchLength(w: *Io.Writer, match_len: u64) Writer.Error!usize {
    assert(match_len >= min_match_len);
    var num_bytes_written: usize = 0;

    const actual_match_len = match_len - min_match_len;
    const token_match_len = @min(actual_match_len, 15);

    if (actual_match_len >= 15) {
        var remain_len = actual_match_len - token_match_len;
        while (remain_len >= 255) {
            try w.writeByte(255);
            num_bytes_written += 1;
            remain_len -= 255;
        }

        try w.writeByte(@intCast(remain_len));
        num_bytes_written += 1;
    }

    return num_bytes_written;
}

fn calcMatchTokenLength(match_len: u64) usize {
    assert(match_len >= min_match_len);
    var num_bytes_written: usize = 0;

    const actual_match_len = match_len - min_match_len;
    const token_match_len = @min(actual_match_len, 15);

    if (actual_match_len >= 15) {
        var remain_len = actual_match_len - token_match_len;
        while (remain_len >= 255) {
            num_bytes_written += 1;
            remain_len -= 255;
        }

        num_bytes_written += 1;
    }

    return num_bytes_written;
}

const testing = std.testing;

test "match and add hash" {
    const gpa = testing.allocator;

    const compress_options: Compress.Options = .{
        .max_block_size = .@"256KB",
        .should_checksum_frame = true,
        .should_checksum_block = true,
        .independent_blocks = true,
        .acceleration = 1,
    };

    var output_stream: Io.Writer.Allocating = try .initCapacity(gpa, Compress.queryOutCapacity(compress_options));
    defer output_stream.deinit();

    const window_buf = try gpa.alloc(u8, lz4u.max_window_len);
    defer gpa.free(window_buf);

    var compressor: Compress = try .init(&output_stream.writer, window_buf, compress_options);

    {
        try compressor.writer.writeAll("wew\n\n");
        const match_result = compressor.matchAndAddHash(0, 1);
        try testing.expectEqual(1, match_result.literal_len);
        try testing.expect(match_result.match == null);
    }
    {
        try compressor.writer.writeAll("wew\n\r");
        const match_result = compressor.matchAndAddHash(5, 6);
        try testing.expectEqual(0, match_result.literal_len);
        try testing.expectEqual(Compress.MatchResult.Match{
            .offset = 5,
            .len = 4,
        }, match_result.match.?);
    }

    {
        try compressor.writer.writeAll("wewi\n");
        const match_result = compressor.matchAndAddHash(10, 11);
        try testing.expectEqual(1, match_result.literal_len);
        try testing.expect(match_result.match == null);
    }
    {
        try compressor.writer.writeAll("wewii\n");
        const match_result = compressor.matchAndAddHash(16, 18);
        try testing.expectEqual(2, match_result.literal_len);
        try testing.expect(match_result.match == null);
    }

    {
        try compressor.writer.splatByteAll(0xff, lz4u.max_history_len);
        try compressor.writer.writeAll("wewi\n");
        const match_result = compressor.matchAndAddHash(8, 10);
        try testing.expect(match_result.match == null);
    }
}

test "catch up anything before the found match position" {
    const gpa = testing.allocator;

    const compress_options: Compress.Options = .{
        .max_block_size = .@"256KB",
        .should_checksum_frame = true,
        .should_checksum_block = false,
        .independent_blocks = true,
        .acceleration = 1,
    };

    const plane_scene_txt = @embedFile("../testdata/plane_scene.txt");
    const text_excerpt = plane_scene_txt;

    var output_stream: Io.Writer.Allocating = try .initCapacity(gpa, Compress.queryOutCapacity(compress_options));
    defer output_stream.deinit();

    const window_buf = try gpa.alloc(u8, lz4u.max_window_len);
    defer gpa.free(window_buf);

    var compressor: Compress = try .init(&output_stream.writer, window_buf, compress_options);

    {
        try compressor.writer.writeAll(text_excerpt);
        const match_result = compressor.matchAndAddHash(0, lz4u.max_history_len - 12);
        try testing.expectEqual(112, match_result.literal_len);
        try testing.expectEqual(Compress.MatchResult.Match{
            .offset = 26,
            .len = 5,
        }, match_result.match.?);
    }
    {
        const match_result = compressor.matchAndAddHash(65, lz4u.max_history_len - 12);
        try testing.expectEqual(47, match_result.literal_len);
        try testing.expectEqual(Compress.MatchResult.Match{
            .offset = 26,
            .len = 5,
        }, match_result.match.?);
    }
    {
        const match_result = compressor.matchAndAddHash(79, lz4u.max_history_len - 12);
        try testing.expectEqual(33, match_result.literal_len);
        try testing.expectEqual(Compress.MatchResult.Match{
            .offset = 26,
            .len = 5,
        }, match_result.match.?);
    }
    {
        const match_result = compressor.matchAndAddHash(97, lz4u.max_history_len - 12);
        try testing.expectEqual(15, match_result.literal_len);
        try testing.expectEqual(Compress.MatchResult.Match{
            .offset = 26,
            .len = 5,
        }, match_result.match.?);
    }
}
