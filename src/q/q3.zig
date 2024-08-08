// (2)のコードで関数のサイズを出力した後、続く関数の命令列を解析する。解析の手順としては、まず、命令を読み取り、続く引数を読み取ることを続ける。命令はそれぞれ引数の個数やbytes数が異なるため注意した。その中で、i64.const命令を読み取ったときにi64.const found.と出力するようにした。

const std = @import("std");
const io = std.io;

pub const file_path = "./main.wasm";

pub fn main() !void {
    var buf: [5096]u8 = undefined;
    if (readFileAll(file_path, &buf)) |size| {
        // try analyzeCodeSection(&buf, size);
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
    const cnt = decodeLEB128(&tmp); // codeの数
    try stdout.print("{}個のcodeがあります.\n", .{cnt});

    var code: WasmSectionSize = undefined;
    var first_pos: usize = pos; // code sizeの位置を指している
    for (0..cnt) |i| {
        code = getCodeSize(data, size, pos);
        try stdout.print("({:0>2}) size: {} bytes\n", .{ i + 1, code.size });
        try bw.flush();
        pos += code.byte_width;

        pos += try analyzeCodeFunctions(data, pos);
        try analyzeInstruction(data, pos, first_pos + code.size + code.byte_width - 1);
        pos = first_pos + code.size + code.byte_width;
        first_pos = pos;
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
// posはローカル変数の数の位置を指している
// 進むべきposのバイト数を返す
fn analyzeCodeFunctions(data: []u8, pos: usize) !usize {
    const local_var_cnt = getCodeLocalCounts(data, pos);
    const local_var_width = calcWidth: {
        var cnt = local_var_cnt;
        var i: usize = 1;
        while (cnt > 128) : (i += 1) {
            cnt /= 128;
        }
        break :calcWidth i;
    };
    var func_pos = pos + local_var_width;
    for (0..local_var_cnt) |_| {
        for (data[func_pos..], 1..) |val, j| {
            if (val < 128) {
                func_pos += j; // ローカル変数のサイズのバイト幅だけ進める(最大u32幅)
                break;
            }
        }
        func_pos += 1; // valtype分進める
    }
    return func_pos - pos;
}

fn analyzeInstruction(data: []u8, pos: usize, end_pos: usize) !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    var args_width: usize = 0; //命令の引数の幅
    var nest_block_cnt: usize = 0; //blockの数
    var instr_cnt: usize = 0;
    for (data[pos .. end_pos + 1], pos..end_pos + 1) |instr, i| {
        if (args_width > 0) {
            // 引数はスキップする
            args_width -= 1;
            continue;
        }

        // i64.const命令を検出するだけなのでそれ以外の命令は引数の有無を判定するだけに留める
        // 引数を持たぬものはelseで処理する
        switch (instr) {
            0x02, 0x03, 0x04 => {
                // block命令
                nest_block_cnt += 1;
                switch (data[i + 1]) {
                    0x40 => args_width = 1,
                    0x7E, 0x7D, 0x7C, 0x7B, 0x70, 0x6F => args_width = 1, //valtype
                    else => {
                        //s33
                        const n = data[i + 1 + calcArgsWidth(data, i + 1, 4)];
                        if (n < (2 << 6)) {
                            args_width = calcArgsWidth(data, i + 1, 4);
                        } else if (2 << 6 <= n and n < 2 << 7) {
                            args_width = calcArgsWidth(data, i + 1, 4);
                        } else if (n >= 2 << 7) {
                            args_width = calcArgsWidth(data, i + 1, 4);
                        }
                        args_width = calcArgsWidth(data, i + 1, 4);
                        if (args_width > @ceil(33.0 / 7.0)) {
                            args_width = @ceil(33.0 / 7.0);
                        }
                    },
                }
            },
            0x0B => {
                // End code instruction
                if (nest_block_cnt == 0)
                    break;
                nest_block_cnt -= 1;
            },
            0x0C, 0x0D => args_width = calcArgsWidth(data, i + 1, 4), //br命令
            0x0E => {
                //br_table命令
                args_width = decodeArrayByLEB128(data, i + 1) + 1; // length of vector
                args_width += calcArgsWidth(data, i + 1, 4); // length分のbyte width
                args_width += calcArgsWidth(data, i + args_width + 1, 4); // table index
            },
            0x0F => {
                nest_block_cnt = 0;
            },
            0x10 => args_width = calcArgsWidth(data, i + 1, 4), //call命令
            0x11 => {
                // call_indirect命令
                args_width = calcArgsWidth(data, i + 1, 4);
                args_width += calcArgsWidth(data, i + 1 + args_width, 4);
            },
            0x1A => {},
            0xD0 => args_width = 1, //ref.null命令
            0xD2 => args_width = calcArgsWidth(data, i + 1, 4), //ref.func命令
            0x1C => {
                // select t*命令
                args_width = decodeArrayByLEB128(data, i + 1); // length of vector
                args_width += calcArgsWidth(data, i + 1, 4); // length分のbyte width
            },
            0x20...0x24 => {
                args_width = calcArgsWidth(data, i + 1, 4); //(local|glob1al).(get|set|tee)命令
            },
            0x25, 0x26 => args_width = calcArgsWidth(data, i + 1, 4), //table.(get|set)命令
            0x28...0x3E => {
                // memory (load|store)命令
                // memarg (u32,u32)の処理
                args_width = calcArgsWidth(data, i + 1, 4);
                args_width += calcArgsWidth(data, i + 1 + args_width, 4);
            },
            0x3F, 0x40 => {
                args_width = 1;
            },
            0x41 => args_width = calcArgsWidth(data, i + 1, 4),
            0x43 => {
                args_width = 4;
            },
            0x44 => {
                args_width = 8;
            },
            0x42 => {
                instr_cnt += 1;
                try stdout.print("i64.const found.\n", .{});
                args_width = calcArgsWidth(data, i + 1, 8);
            },
            0x7C => {},
            0xFC => {
                args_width = 1; // prefix分進める
                switch (data[i + 1]) {
                    0...7 => args_width += calcArgsWidth(data, i + 1, 4),
                    8 => {
                        // memory.init命令
                        args_width += calcArgsWidth(data, i + 1 + args_width, 4);
                        args_width += 1; // 0x0の分
                    },
                    9 => {
                        args_width += calcArgsWidth(data, i + 1 + args_width, 4);
                    },
                    10 => {
                        args_width += 2; // 0x00 0x00 の分
                    },
                    11 => {
                        args_width += 1; // 0x0の分
                    },
                    12, 14 => {
                        // table.(init|copy)命令
                        args_width += calcArgsWidth(data, i + 1 + args_width, 4);
                        args_width += calcArgsWidth(data, i + 1 + args_width, 4);
                    },
                    13, 15, 16, 17 => args_width += calcArgsWidth(data, i + 1 + args_width, 4),
                    else => unreachable,
                }
            },
            0xFD => {
                var tmp = [_]u8{0} ** 4;
                for (data[i + 1 ..], 0..) |val, j| {
                    if (val < 128) {
                        tmp[j] = val;
                        break;
                    }
                    tmp[j] = val;
                }

                const prefix = decodeLEB128(&tmp);
                switch (prefix) {
                    0...11 => {
                        args_width = calcArgsWidth(data, i + 1, 4);
                        // memargの処理
                        args_width += calcArgsWidth(data, i + 1 + args_width, 4);
                        args_width += calcArgsWidth(data, i + 1 + args_width, 4);
                    },
                    12, 13 => {
                        args_width = calcArgsWidth(data, i + 1, 4);
                        args_width += 16;
                    },
                    21...34 => {
                        args_width = calcArgsWidth(data, i + 1, 4);
                        args_width += calcArgsWidth(data, i + 1 + args_width, 4);
                    },
                    84...91 => {
                        args_width = calcArgsWidth(data, i + 1, 4);
                        // memargの処理
                        args_width += calcArgsWidth(data, i + 1 + args_width, 4);
                        args_width += calcArgsWidth(data, i + 1 + args_width, 4);
                        // laneidxの処理
                        args_width += calcArgsWidth(data, i + 1 + args_width, 4);
                    },
                    else => args_width = calcArgsWidth(data, i + 1, 4),
                }
            },
            else => {},
        }
    }
    try bw.flush();
}

// leb128でエンコードされたバイト列の幅を求める
fn calcArgsWidth(data: []u8, pos: usize, comptime byte_width: usize) usize {
    var tmp = [_]u8{0} ** byte_width;
    var width: usize = 0;
    for (data[pos .. pos + byte_width], 0..byte_width) |val, j| {
        if (val < 128) {
            tmp[j] = val;
            width = j + 1;
            break;
        }
        tmp[j] = val;
        width = j + 1;
    }
    return width;
}

fn getCodeLocalCounts(data: []u8, pos: usize) usize {
    var tmp = [_]u8{0} ** 4;
    for (data[pos..], 0..) |val, j| {
        tmp[j] = val;
        if (val < 128) {
            break;
        }
    }

    return decodeLEB128(&tmp);
}
pub fn decodeArrayByLEB128(data: []u8, pos: usize) usize {
    var tmp = [_]u8{0} ** 4;
    for (data[pos..], 0..) |val, j| {
        tmp[j] = val;
        if (val < 128) {
            break;
        }
    }

    return decodeLEB128(&tmp);
}
