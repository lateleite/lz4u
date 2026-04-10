///
/// Internals of LZ4U for handling blocks.
/// May break compatibility at any point, prefer using `lz4u.Frame` or `lz4u.Raw`.
///
const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Writer = std.Io.Writer;

const lz4u = @import("lz4u.zig");
const BlockLengthHeader = lz4u.BlockLengthHeader;
const Token = lz4u.Token;

pub const num_last_literals = 5;
pub const min_match_len = 4;
pub const min_last_match_len = 12;

pub const MakeMode = enum {
    consersative_tokens,
    tokenize_everything,
};

pub const MakeResult = struct {
    read_length: usize,
    block_header: BlockLengthHeader,
};

pub fn make(
    output: *Writer,
    start_offset: usize,
    args: struct {
        input_buffer: []const u8,
        used_input_len: usize,

        max_block_length: usize,
        position_table: *HashTable,
        acceleration: u16,
    },
    comptime mode: MakeMode,
) Writer.Error!MakeResult {
    assert(args.max_block_length >= num_last_literals);

    var i = start_offset;
    const buffered_input = args.input_buffer[0..args.used_input_len];

    const next_data_len = buffered_input.len - i;

    const lit_end = start_offset + @min(next_data_len, args.max_block_length);
    const match_end = lit_end -| min_last_match_len;
    const max_match_output_len = args.max_block_length -| min_last_match_len;

    // hash the first possible value
    // matchAndAddHash() expects it to be there
    if (i + 4 < lit_end) {
        @branchHint(.likely);
        const cur_data = args.input_buffer[i..];
        const cur_seq = mem.readInt(u32, cur_data[0..4], .little);
        defer args.position_table.put(cur_seq, 0);
    }

    var written_length: usize = 0;

    while (i < match_end) {
        const literal_start = i;

        // find a match if possible
        const find_result = matchAndAddHash(.{
            .input_buffer = args.input_buffer,
            .used_input_len = args.used_input_len,
            .position_table = args.position_table,
            .acceleration = args.acceleration,
            .start_i = i,
            .end_i = match_end,
        });

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
        const lit_token_len = try writeToken(output, find_result.literal_len, match.len);
        assert(lit_token_len == expected_lit_token_len);

        // write literals
        try output.writeAll(buffered_input[literal_start..][0..find_result.literal_len]);

        // write match offset
        try output.writeInt(u16, match.offset, .little);

        // write match's length (part of token)
        const match_token_len = try writeMatchLength(output, match.len);
        assert(match_token_len == expected_match_token_len);

        i += find_result.literal_len + match.len;
        written_length = expected_written_length;
    }

    const remain_len = @min(lit_end - i, args.max_block_length - lz4u.max_token_length - num_last_literals);
    const needs_to_emit_final_token = written_length > 0 or mode == .tokenize_everything;

    if (remain_len > 0 and remain_len <= args.max_block_length) {
        const possible_lit_token_len = calcLiteralTokenLength(remain_len) * @intFromBool(needs_to_emit_final_token);
        const possible_final_written = written_length + possible_lit_token_len + remain_len;

        if (possible_final_written <= args.max_block_length) {
            if (needs_to_emit_final_token) {
                // write token if we're in an existing compressed block
                written_length += try writeToken(output, remain_len, 0);
            }

            // write the uncompressable literals
            const remain_buf = buffered_input[i..][0..remain_len];
            try output.writeAll(remain_buf);

            i += remain_len;
            written_length += remain_len;
        }
    }

    return .{
        .read_length = i - start_offset,
        .block_header = .{
            .length = @intCast(written_length),
            .uncompressed = !needs_to_emit_final_token,
        },
    };
}

const MatchResult = struct {
    const Match = struct {
        offset: u16,
        len: usize,
    };

    match: ?Match,
    literal_len: usize,
};

fn matchAndAddHash(args: struct {
    input_buffer: []const u8,
    used_input_len: usize,

    position_table: *HashTable,
    acceleration: u16,

    start_i: usize,
    end_i: usize,
}) MatchResult {
    var step = args.acceleration;
    var search_match_nb = args.acceleration;

    const buffered = args.input_buffer[0..args.used_input_len];
    // we need at least 4 bytes in the buffer to hash
    const absolute_end = @min(args.end_i, args.used_input_len);

    var i = args.start_i;
    while (i < absolute_end) : (i += step) {
        // Adaptive step
        step = search_match_nb >> 6;
        search_match_nb += 1;

        const cur_data = buffered[i..];
        assert(cur_data.len >= @sizeOf(u32));
        const cur_seq = mem.readInt(u32, cur_data[0..4], .little);

        // always set this sequence's position at the end of the loop
        defer args.position_table.put(cur_seq, @intCast(i));

        const match_pos = args.position_table.get(cur_seq);
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

            const max_backwards_len = @min(@min(@min(i - args.start_i, match_pos), max_possible_match_len), available_offset_len);
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
            .literal_len = (i - args.start_i) - back_len,
        };
    }

    return .{
        .match = null,
        .literal_len = i - args.start_i,
    };
}

pub const HashTable = struct {
    const table_size_exponent = 14;
    table: [1 << table_size_exponent]u32,

    const Self = @This();

    pub const empty: Self = .{
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
        return (sequence *% 0x9e3779b1) >> ((min_match_len * 8) - table_size_exponent);
    }
};

fn writeToken(w: *Writer, literal_len: u64, match_len: u64) Writer.Error!usize {
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

fn writeMatchLength(w: *Writer, match_len: u64) Writer.Error!usize {
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

    var input_stream: Writer.Allocating = .init(gpa);
    defer input_stream.deinit();

    var output_stream: Writer.Allocating = .init(gpa);
    defer output_stream.deinit();

    var position_table: HashTable = .empty;

    {
        try input_stream.writer.writeAll("wew\n\n");
        const match_result = matchAndAddHash(.{
            .input_buffer = input_stream.writer.buffer,
            .used_input_len = input_stream.writer.end,
            .position_table = &position_table,
            .acceleration = 1,
            .start_i = 0,
            .end_i = 1,
        });
        try testing.expectEqual(1, match_result.literal_len);
        try testing.expect(match_result.match == null);
    }
    {
        try input_stream.writer.writeAll("wew\n\r");
        const match_result = matchAndAddHash(.{
            .input_buffer = input_stream.writer.buffer,
            .used_input_len = input_stream.writer.end,
            .position_table = &position_table,
            .acceleration = 1,
            .start_i = 5,
            .end_i = 6,
        });
        try testing.expectEqual(0, match_result.literal_len);
        try testing.expectEqual(MatchResult.Match{
            .offset = 5,
            .len = 4,
        }, match_result.match.?);
    }

    {
        try input_stream.writer.writeAll("wewi\n");
        const match_result = matchAndAddHash(.{
            .input_buffer = input_stream.writer.buffer,
            .used_input_len = input_stream.writer.end,
            .position_table = &position_table,
            .acceleration = 1,
            .start_i = 10,
            .end_i = 11,
        });
        try testing.expectEqual(1, match_result.literal_len);
        try testing.expect(match_result.match == null);
    }
    {
        try input_stream.writer.writeAll("wewii\n");
        const match_result = matchAndAddHash(.{
            .input_buffer = input_stream.writer.buffer,
            .used_input_len = input_stream.writer.end,
            .position_table = &position_table,
            .acceleration = 1,
            .start_i = 16,
            .end_i = 18,
        });
        try testing.expectEqual(2, match_result.literal_len);
        try testing.expect(match_result.match == null);
    }

    {
        try input_stream.writer.splatByteAll(0xff, lz4u.max_history_len);
        try input_stream.writer.writeAll("wewi\n");
        const match_result = matchAndAddHash(.{
            .input_buffer = input_stream.writer.buffer,
            .used_input_len = input_stream.writer.end,
            .position_table = &position_table,
            .acceleration = 1,
            .start_i = 8,
            .end_i = 10,
        });
        try testing.expect(match_result.match == null);
    }
}

test "catch up anything before the found match position" {
    const gpa = testing.allocator;

    const plane_scene_txt = @embedFile("testdata/plane_scene.txt");
    const text_excerpt = plane_scene_txt;

    var input_stream: Writer.Allocating = .init(gpa);
    defer input_stream.deinit();

    var output_stream: Writer.Allocating = .init(gpa);
    defer output_stream.deinit();

    var position_table: HashTable = .empty;

    {
        try input_stream.writer.writeAll(text_excerpt);
        const match_result = matchAndAddHash(.{
            .input_buffer = input_stream.writer.buffer,
            .used_input_len = input_stream.writer.end,
            .position_table = &position_table,
            .acceleration = 1,
            .start_i = 0,
            .end_i = lz4u.max_history_len - 12,
        });
        try testing.expectEqual(58, match_result.literal_len);
        try testing.expectEqual(MatchResult.Match{
            .offset = 22,
            .len = 7,
        }, match_result.match.?);
    }
    {
        const match_result = matchAndAddHash(.{
            .input_buffer = input_stream.writer.buffer,
            .used_input_len = input_stream.writer.end,
            .position_table = &position_table,
            .acceleration = 1,
            .start_i = 65,
            .end_i = lz4u.max_history_len - 12,
        });
        try testing.expectEqual(9, match_result.literal_len);
        try testing.expectEqual(MatchResult.Match{
            .offset = 51,
            .len = 5,
        }, match_result.match.?);
    }
    {
        const match_result = matchAndAddHash(.{
            .input_buffer = input_stream.writer.buffer,
            .used_input_len = input_stream.writer.end,
            .position_table = &position_table,
            .acceleration = 1,
            .start_i = 79,
            .end_i = lz4u.max_history_len - 12,
        });
        try testing.expectEqual(0, match_result.literal_len);
        try testing.expectEqual(MatchResult.Match{
            .offset = 32,
            .len = 18,
        }, match_result.match.?);
    }
    {
        const match_result = matchAndAddHash(.{
            .input_buffer = input_stream.writer.buffer,
            .used_input_len = input_stream.writer.end,
            .position_table = &position_table,
            .acceleration = 1,
            .start_i = 97,
            .end_i = lz4u.max_history_len - 12,
        });
        try testing.expectEqual(105, match_result.literal_len);
        try testing.expectEqual(MatchResult.Match{
            .offset = 30,
            .len = 6,
        }, match_result.match.?);
    }
}
