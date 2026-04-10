///
/// LZ4 compressor wrapped by an LZ4 Frame, with Zig std.Io support.
/// TODO: dictionary support
///
const std = @import("std");
const hash = std.hash;
const mem = std.mem;
const assert = std.debug.assert;
const Writer = std.Io.Writer;

const Block = @import("../Block.zig");
const Frame = @import("../Frame.zig");
const lz4u = @import("../lz4u.zig");
const BlockLengthHeader = lz4u.BlockLengthHeader;
const BlockMaxSize = Frame.BlockMaxSize;
const Header = Frame.Header;

output: *Writer,
writer: Writer,

position_table: Block.HashTable,
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
    assert(options.acceleration > 0);

    // reserve the memory region that will have the header written to,
    // so it can be hashed later.
    const header_length = calcHeaderSize(options);
    const header_buffer = (try output.writableSliceGreedy(header_length))[0..header_length];

    // write frame header
    try output.writeInt(u32, Header.MAGIC, .little);
    // write frame header's descriptor
    const flg: u8 = @bitCast(Header.Flg{
        .dict_id = false,
        .content_chksum = options.should_checksum_frame,
        .content_size = options.content_size_hint != null,
        .block_chksum = options.should_checksum_block,
        .block_indep = options.independent_blocks,
    });
    try output.writeByte(flg);

    const bd: u8 = @bitCast(Header.Bd{
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

    const max_block_length = c.max_block_size.toBytes();
    var i = start;

    while (i < lit_end) {
        if (!c.allow_history)
            c.position_table = .empty;

        // reserve space for block's length
        // TODO: use lz4's worse case calculation
        const dst_block_len =
            @sizeOf(BlockLengthHeader) +
            max_block_length +
            (@intFromBool(c.block_checksum) * @as(usize, @sizeOf(u32)));
        const dst_block_data = try c.output.writableSliceGreedy(dst_block_len);
        c.output.advance(@sizeOf(BlockLengthHeader));

        const make_res = try Block.make(
            c.output,
            i,
            .{
                .input_buffer = w.buffer,
                .used_input_len = w.end,
                .max_block_length = max_block_length,
                .position_table = &c.position_table,
                .acceleration = c.acceleration,
            },
            .consersative_tokens,
        );
        if (make_res.read_length == 0)
            break;

        // write the block header in the previously reserved region
        mem.writeInt(u32, dst_block_data[0..4], @bitCast(make_res.block_header), .little);

        if (c.block_checksum) {
            // block checksum must use the block data directly, both compressed and uncompressed
            const dst_written = dst_block_data[4..][0..make_res.block_header.length];
            const block_hash = hash.XxHash32.hash(0, dst_written);
            try c.output.writeInt(u32, block_hash, .little);
        }

        if (c.frame_hasher) |*hasher| {
            // frame checksum must use decompressed data
            hasher.update(buffered[i..][0..make_res.read_length]);
        }

        i += make_res.read_length;
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
