//! Wasmファイルの読み取りをする
const std = @import("std");
const leb128 = @import("leb128.zig");
const Runtime = @import("runtime.zig").Runtime;
const c = @import("code.zig");
const utils = @import("utils.zig");

// Wasmファイルの読み取りに関する構造体
pub const Wasm = struct {
    runtime: *Runtime,
    data: []u8,
    size: usize,
    pos: usize = 0,

    pub fn init(data: []u8, size: usize) *Wasm {
        return @constCast(&Wasm{
            .data = data,
            .size = size,
            .runtime = Runtime.init(data),
        });
    }

    // secで指定されたセクションまで読み進める
    fn proceedToSection(self: *Wasm, sec: WasmSection) void {
        self.pos = 8;
        if (sec == WasmSection.Type)
            return;

        for (0..@intFromEnum(sec)) |id| {
            if (self.getSize(@enumFromInt(id))) |section| {
                self.pos += section.size + 1 + section.byte_width;
            } else |err| {
                switch (err) {
                    WasmError.SectionNotFound => {},
                    else => unreachable,
                }
            }
        }
    }

    fn proceedToCodeFunc(self: *Wasm) void {
        const local_var_cnt = utils.getValCounts(self.data, self.pos);
        const local_var_width = calcWidth: {
            var cnt = local_var_cnt;
            var i: usize = 1;
            while (cnt > 128) : (i += 1) {
                cnt /= 128;
            }
            break :calcWidth i;
        };
        self.pos += local_var_width;
        for (0..local_var_cnt) |_| {
            for (self.data[self.pos..], 1..) |val, j| {
                if (val < 128) {
                    self.pos += j; // ローカル変数のサイズのバイト幅だけ進める(最大u32幅)
                    break;
                }
            }
            self.pos += 1; // valtype分進める
        }
    }

    // コードセクションを解析する
    pub fn analyzeSection(self: *Wasm, sec: WasmSection) !void {
        self.proceedToSection(sec);

        const section = try self.getSize(sec);
        self.pos += 1 + section.byte_width; // idとサイズのバイト数分進める

        var tmp = [_]u8{0} ** 4;
        for (self.data[self.pos..], 0..) |val, j| {
            tmp[j] = val;
            if (val < 128) {
                self.pos += j + 1; // code count分進める
                break;
            }
        }
        const cnt = leb128.decodeLEB128(&tmp); // codeの数
        std.debug.print("{}個のcodeがあります.\n", .{cnt});

        var code: WasmSectionSize = undefined;
        for (0..cnt) |i| {
            code = c.getCodeSize(self.data, self.size, self.pos);
            std.debug.print("({:0>2}) size: {} bytes\n", .{ i + 1, code.size });
            self.pos += code.byte_width;

            const local_var_cnt = utils.getValCounts(self.data, self.pos);
            const local_var_width = calcWidth: {
                var _cnt = local_var_cnt;
                var j: usize = 1;
                while (_cnt > 128) : (j += 1) {
                    _cnt /= 128;
                }
                break :calcWidth j;
            };
            self.pos += local_var_width;
            for (0..local_var_cnt) |_| {
                for (self.data[self.pos..], 1..) |val, k| {
                    if (val < 128) {
                        self.pos += k; // ローカル変数のサイズのバイト幅だけ進める(最大u32幅)
                        break;
                    }
                }
                self.pos += 1; // valtype分進める
            }

            // try self.runtime.execute(self.data[self.pos..]);
            self.pos += code.size + code.byte_width;
        }
    }

    // コードを実行する
    fn execute(self: *Wasm, cnt: usize) !void {
        var code: WasmSectionSize = undefined;
        var first_pos: usize = self.pos; // code sizeの位置を指している
        std.debug.print("{any}", .{self.data});
        for (0..cnt) |i| {
            code = c.getCodeSize(self.data, self.size, self.pos);
            std.debug.print("({:0>2}) size: {} bytes\n", .{ i + 1, code.size });
            self.pos += code.byte_width;

            self.proceedToCodeFunc();

            try self.runtime.execute(self.pos, first_pos + code.byte_width + code.size - 1);
            self.pos = first_pos + code.size + code.byte_width;
            first_pos = self.pos;
        }
    }

    // セクションサイズなどを計算する
    fn getSize(self: *Wasm, sec: WasmSection) !WasmSectionSize {
        var section_size = WasmSectionSize{ .size = 0, .byte_width = 0 };
        if (@intFromEnum(sec) == self.data[self.pos]) {
            const s = get_section_size: {
                var tmp = [_]u8{0} ** 4;
                for (self.data[self.pos + 1 ..], 0..) |val, j| {
                    tmp[j] = val;
                    if (val < 128) {
                        section_size.byte_width = j + 1;
                        break;
                    }
                }
                break :get_section_size &tmp;
            };
            section_size.size = leb128.decodeLEB128(@constCast(s));
            return section_size;
        } else {
            return WasmError.SectionNotFound;
        }
    }
};

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

// 以下、旧版の関数たち
// 多くがWasm構造体に移植された
// 念の為残しておく
pub fn analyzeWasm(data: []u8, file_path: []const u8) !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("{s}\t\tWasm version 0x{x}\n\n", .{ file_path, data[4] });

    // wasmのバイナリフォーマットのmagicナンバーやバージョン(8 bytes)を省いた位置を初期位置とする
    var pos: usize = 8;
    for (0..13) |id| {
        if (getSectionSize(data, id, pos)) |section_struct| {
            pos += section_struct.size + 1 + section_struct.byte_width;
            try stdout.print("({d:0>2}) {s}\tsize: {d:0>2} bytes\n", .{ id, WasmSection.init(id).asText(), section_struct.size });
        } else |err| {
            switch (err) {
                WasmError.SectionNotFound => {
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
        section_size.size = leb128.decodeLEB128(@constCast(s));
        return section_size;
    } else {
        return WasmError.SectionNotFound;
    }
    return WasmError.SectionNotFound;
}
