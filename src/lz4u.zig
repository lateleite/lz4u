pub const Frame = @import("Frame.zig");
pub const Raw = @import("Raw.zig");
pub const Block = @import("Block.zig");

pub const max_history_len = 64 * 1024;
pub const max_window_len = max_history_len * 2;
pub const max_block_size = Frame.BlockMaxSize.@"4MB".toBytes();
pub const min_indirect_buffer_len = (max_history_len * 2) + max_block_size;

pub const min_token_length = 3;
pub const max_token_length = 258;
pub const max_match_length = 65335;

pub const Token = packed struct(u8) {
    match_len: u4,
    literal_len: u4,
};

pub const BlockLengthHeader = packed struct(u32) {
    length: u31,
    uncompressed: bool,
};

test {
    _ = &Frame;
    _ = &Raw;
    _ = &Block;
}
