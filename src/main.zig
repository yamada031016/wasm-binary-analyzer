const std = @import("std");
const io = std.io;
const utils = @import("utils.zig");
const wasm = @import("wasm.zig");
const Runtime = @import("runtime.zig").Runtime;

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} [Wasm binary]\n", .{args[0]});
        std.os.linux.exit(1);
    }
    const file_path = args[1];

    if (!utils.isWasmFile(file_path)) {
        std.debug.print("wrong file format: {s}\n", .{std.fs.path.extension(file_path)});
        std.os.linux.exit(1);
    }

    var buf: [4096]u8 = undefined;
    if (utils.readFileAll(file_path, &buf)) |size| {
        var Wasm = wasm.Wasm.init(&buf, size);
        try Wasm.analyzeSection(.Export);
    } else |err| {
        std.debug.print("{s}", .{@errorName(err)});
    }
}

test "section size test" {
    const file_path = "../main.wasm";
    const correct_section_size = [_]usize{ 0x23, 0x46, 0x08, 0x00, 0x04, 0x09, 0x13, 0x01, 0x08, 0xea, 0x20, 0x01 };
    var buf: [5096]u8 = undefined;
    var pos: usize = 8;
    if (utils.readFileAll(file_path, &buf)) |size| {
        for (0..13) |id| {
            if (wasm.getSectionSize(&buf, size, id, pos)) |section| {
                pos += section.size;
                try std.testing.expect(correct_section_size[id - 1] == section.size);
            } else |err| {
                switch (err) {
                    wasm.WasmError.SectionNotFound => continue,
                    else => unreachable,
                }
            }
        }
    } else |_| {
        try std.testing.expect(false);
    }
}
