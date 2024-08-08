// コードセクションはセクションID、セクションサイズの後、全体の関数の個数が分かり、各関数が続く。
// 関数では、関数サイズの後、関数の詳細が続く。ここでサイズを読み取ることができる。

const std = @import("std");
const io = std.io;

pub const file_path = "./main.wasm";

pub fn main() !void {
    var buf: [5096]u8 = undefined;
    if (readFileAll(file_path, &buf)) |size| {
        try analyzeCodeSection(&buf, size);
    } else |err| {
        std.debug.print("{s}", .{@errorName(err)});
    }
}

test "section size test" {
    const correct_section_size = [_]usize{ 0x23, 0x46, 0x08, 0x00, 0x04, 0x09, 0x13, 0x01, 0x08, 0xea, 0x20, 0x01 };
    var buf: [5096]u8 = undefined;
    var pos: usize = 8;
    if (readFileAll(file_path, &buf)) |size| {
        _ = size;
        for (0..13) |id| {
            if (getSectionSize(&buf, id, pos)) |section| {
                pos += section.size;
                try std.testing.expect(correct_section_size[id - 1] == section.size);
            } else |err| {
                switch (err) {
                    WasmError.SectionNotFound => continue,
                    else => unreachable,
                }
            }
        }
    } else |_| {
        try std.testing.expect(false);
    }
}

pub fn analyzeCodeSection(data: []u8, size: usize) !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    var pos: usize = 8;
    // コードセクションまで読み進める
    for (0..10) |id| {
        if (getSectionSize(data, id, pos)) |section| {
            pos += section.size + 1 + section.byte_width;
        } else |err| {
            switch (err) {
                WasmError.SectionNotFound => {},
                else => unreachable,
            }
        }
    }

    // posはcode sectionのIDを指している
    const section = try getSectionSize(data, 10, pos);
    pos += 1 + section.byte_width; // idとサイズのバイト数分進める

    var tmp = [_]u8{0} ** 4;
    for (data[pos..], 0..) |val, j| {
        tmp[j] = val;
        if (val < 128) {
            pos += j + 1; // code count分進める
            break;
        }
    }
    const cnt = decodeLEB128(&tmp); // 関数の個数
    try stdout.print("{}個のcodeがあります.\n", .{cnt});

    var code: WasmSectionSize = undefined;
    for (0..cnt) |i| {
        code = getCodeSize(data, size, pos);
        pos += code.size + code.byte_width;
        try stdout.print("({:0>2}) size: {} bytes\n", .{ i + 1, code.size });
    }
    try bw.flush();
}

fn getCodeSize(data: []u8, size: usize, pos: usize) WasmSectionSize {
    var code_section = WasmSectionSize{ .size = 0, .byte_width = 0 };
    if (pos + 3 > size) {
        @panic("out of binary data.");
    }
    var tmp = [_]u8{0} ** 4;
    for (data[pos..], 0..) |val, j| {
        tmp[j] = val;
        if (val < 128) {
            code_section.byte_width = j + 1;
            break;
        }
    }
    code_section.size = decodeLEB128(&tmp);
    return code_section;
}

pub const WasmError = error{
    SectionNotFound,
};

const WasmSection = enum(u4) {
    const Self = @This();

    Custom = 0,
    Type = 1,
    Import = 2,
    Function = 3,
    Table = 4,
    Memory = 5,
    Global = 6,
    Export = 7,
    Start = 8,
    Element = 9,
    Code = 10,
    Data = 11,
    DataCount = 12,

    pub fn init(id: usize) Self {
        return @enumFromInt(id);
    }

    pub fn asText(self: WasmSection) []const u8 {
        return switch (self) {
            .Custom => "custom section",
            .Type => "type section",
            .Import => "import section",
            .Function => "function section",
            .Table => "table section",
            .Memory => "memory section",
            .Global => "global section",
            .Export => "export section",
            .Start => "start section",
            .Element => "element section",
            .Code => "code section",
            .Data => "data section",
            .DataCount => "data count section",
        };
    }
};

// Wasmの解析を行う主体となる関数
pub fn analyzeWasm(data: []u8, size: usize) !void {
    _ = size;
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("{s}\t\tWasm version 0x{x}\n\n", .{ file_path, data[4] });

    // wasmのバイナリフォーマットのmagicナンバーやバージョン(8bytes)を省いた位置を初期位置とする
    var pos: usize = 8;
    for (0..13) |id| {
        if (getSectionSize(data, id, pos)) |section_struct| {
            pos += section_struct.size + 1 + section_struct.byte_width;
            try stdout.print("({d:0>2}) {s}\tsize: {d:0>2} bytes\n", .{ id, WasmSection.init(id).asText(), section_struct.size });
        } else |err| {
            switch (err) {
                WasmError.SectionNotFound => {
                    // セクションIDが見つからない場合はサイズ0とする
                    try stdout.print("({d:0>2}) {s}\tsize: {d:0>2} bytes\n", .{ id, WasmSection.init(id).asText(), 0 });
                },
                else => unreachable,
            }
        }
    }
    try bw.flush();
}

pub const WasmSectionSize = struct {
    size: usize,
    byte_width: usize,
};

// idで指定されたセクションのサイズを取得
// wasm binaryではidの次の数値がサイズを表している. 1-4bytes幅で可変長
// posはsection idの位置を想定している
// data: Wasm binary, max: wasm binary size, id: section id (0-12)
// pos: starting position for reading wasm binary
pub fn getSectionSize(data: []u8, id: usize, pos: usize) WasmError!WasmSectionSize {
    var section_size = WasmSectionSize{ .size = 0, .byte_width = 0 };
    if (id == data[pos]) {
        const s = get_section_size: {
            var tmp = [_]u8{0} ** 4;
            for (data[pos + 1 ..], 0..) |val, j| {
                tmp[j] = val;
                if (val < 128) {
                    section_size.byte_width = j + 1;
                    break;
                }
            }
            break :get_section_size &tmp;
        };
        section_size.size = decodeLEB128(@constCast(s));
        return section_size;
    } else {
        return WasmError.SectionNotFound;
    }
    return WasmError.SectionNotFound;
}

// LEB128でエンコーディングされたバイナリをデコードし、数値を返却する
pub fn decodeLEB128(data: []u8) usize {
    var num: usize = undefined;
    var decoded_number: usize = 0;
    for (data, 0..) |value, i| {
        num = value & 0b0111_1111; // 値の下位7bit
        decoded_number |= num << @intCast(i * 7); // 128倍して加える

        if (value >> 7 == 0) {
            // 上位1bitが0ならデコード終了
            break;
        }
    }
    return decoded_number;
}

test "decoding by LEB128" {
    // 0x07以降はデコードされない
    var target = [_]u8{ 0xea, 0x09, 0x07, 0x69 };
    const decoded_number = decodeLEB128(&target);
    try std.testing.expect(decoded_number == 1258);
}

// utils.zig

pub fn readFileAll(path: []const u8, buf: []u8) !usize {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var reader = buf_reader.reader();

    return try reader.readAll(@constCast(buf));
}
