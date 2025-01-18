const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const filename = std.mem.span(std.os.argv[1]);
    const program_file = try std.fs.cwd().openFile(filename, .{});
    defer program_file.close();

    const program = try program_file.readToEndAlloc(allocator, 0xFFFF);
    const bytecode = try generate_bytecode(allocator, program);
    defer bytecode.deinit();

    const suffix = ".bin";
    const bytecode_filename = try allocator.alloc(u8, filename.len + suffix.len);
    defer allocator.free(bytecode_filename);

    @memcpy(bytecode_filename[0..filename.len], filename);
    @memcpy(bytecode_filename[filename.len..], suffix);

    try save_bytecode(bytecode_filename, bytecode.items);
    try execute_bytecode(bytecode.items);
}

const stdout = std.io.getStdOut().writer();
const stdin = std.io.getStdIn().reader();

fn write_handler(tape_ptr: *u8) callconv(.C) void {
    stdout.writeByte(tape_ptr.*) catch unreachable;
}

fn read_handler(tape_ptr: *u8) callconv(.C) void {
    tape_ptr.* = stdin.readByte() catch unreachable;
}

fn generate_bytecode(allocator: std.mem.Allocator, instructions: []const u8) !std.ArrayList(u8) {
    var code = std.ArrayList(u8).init(allocator);
    var loop_start = std.ArrayList(usize).init(allocator);
    var loop_end = std.ArrayList(usize).init(allocator);

    const amount = 1;

    // rdi -> tape pointer
    // rsi -> write function address
    // rdx -> read function address

    for (instructions) |instruction| {
        switch (instruction) {
            '+' => try code.appendSlice(&.{
                0x80, 0x07, amount, // add byte ptr [rdi], amount
            }),
            '-' => try code.appendSlice(&.{
                0x80, 0x2F, amount, // sub byte ptr [rdi], amount
            }),
            '>' => try code.appendSlice(&.{
                0x48, 0x83, 0xC7, amount, // add rdi, amount
            }),
            '<' => try code.appendSlice(&.{
                0x48, 0x83, 0xEF, amount, // sub rdi, amount
            }),
            '.' => try code.appendSlice(&.{
                0x57, // push rdi
                0x56, // push rsi
                0x52, // push rdx
                0xFF, 0xD6, // call rsi
                0x5A, // pop rdx
                0x5E, // pop rsi
                0x5F, // pop rdi
            }),
            ',' => try code.appendSlice(&.{
                0x57, // push rdi
                0x56, // push rsi
                0x52, // push rdx
                0xFF, 0xD2, // call rdx
                0x5A, // pop rdx
                0x5E, // pop rsi
                0x5F, // pop rdi
            }),
            '[' => {
                try loop_start.append(code.items.len);
                try code.appendSlice(&.{
                    0x80, 0x3F, 0x00, // cmp byte ptr [rdi], 0
                    0x0F, 0x84, 0x00, 0x00, 0x00, 0x00, // jz rel32
                });
            },
            ']' => {
                try loop_end.append(code.items.len);
                try code.appendSlice(&.{
                    0x80, 0x3F, 0x00, // cmp byte ptr [rdi], 0
                    0x0F, 0x85, 0x00, 0x00, 0x00, 0x00, // jnz rel32
                });
            },
            else => {},
        }
    }

    try code.append(0xC3); // ret

    std.debug.assert(loop_start.items.len == loop_end.items.len);

    for (loop_start.items, loop_end.items) |start_index, end_index| {
        const loop_start_jump_index = start_index + 3;
        const loop_end_jump_index = end_index + 3;

        const relative_end_offset: u32 = @truncate(end_index - loop_start_jump_index - 6);
        write_u32(code.items, loop_start_jump_index + 2, relative_end_offset);

        const relative_start_offset: u32 = @truncate(start_index -% loop_end_jump_index -% 6);
        write_u32(code.items, loop_end_jump_index + 2, relative_start_offset);
    }

    return code;
}

fn write_u32(code: []u8, offset: usize, value: u32) void {
    code[offset + 3] = @truncate(value >> 24);
    code[offset + 2] = @truncate(value >> 16);
    code[offset + 1] = @truncate(value >> 8);
    code[offset + 0] = @truncate(value);
}

fn execute_bytecode(code: []u8) !void {
    const protection = std.posix.PROT.WRITE | std.posix.PROT.READ | std.posix.PROT.EXEC;
    const flags = .{ .ANONYMOUS = true, .TYPE = .PRIVATE };

    const page_buffer = try std.posix.mmap(null, code.len, protection, flags, -1, 0);
    defer std.posix.munmap(page_buffer);

    @memcpy(page_buffer, code);

    var tape = std.mem.zeroes([30000]u8);

    const execute_code: *const fn (
        tape_ptr: *const u8,
        write_fn: *const fn (*u8) callconv(.C) void,
        read_fn: *const fn (*u8) callconv(.C) void,
    ) callconv(.C) void = @ptrCast(page_buffer.ptr);

    execute_code(@ptrCast(&tape), &write_handler, &read_handler);
}

fn save_bytecode(filename: []u8, code: []u8) !void {
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();

    _ = try file.write(code);
}
