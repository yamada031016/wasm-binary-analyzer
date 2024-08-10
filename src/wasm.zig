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

        switch(sec) {
            .Memory => {
                const cnt = self.calcLEB128Data();
                std.debug.print("Memory section size: {}.\nMemory Number: {}\n", .{section.size, cnt});
                for (0..cnt) |_| {
                    const mem_min_size = self.calcLEB128Data();
                    const mem_max_size = self.calcLEB128Data();
                    std.debug.print("Memory size: {} to {}\n", .{mem_min_size, mem_max_size});
                }
            },
            .Import => {
                const import_count = self.calcLEB128Data();
                std.debug.print("Section size: {}.\nNumber of imports: {}\n", .{section.size, import_count});
                for (0..import_count) |_| {
                    const module_name_length = self.calcLEB128Data();
                    const module_name = name:{
                        var tmp:[32]u8 = undefined;
                        for (self.data[self.pos..self.pos+module_name_length], 0..) |char, i| {
                            tmp[i] = char;
                            self.pos+=1;
                        }
                    break :name &tmp;
                    };
                    const target_name_length = self.calcLEB128Data();
                    const target_name = name:{
                        var tmp:[32]u8 = undefined;
                        for (self.data[self.pos..self.pos+target_name_length], 0..) |char, i| {
                            tmp[i] = char;
                            self.pos+=1;
                        }
                    break :name &tmp;
                    };
                    std.debug.print("{s}.{s}\n", .{module_name, target_name});
                    const target_section = self.calcLEB128Data();
                    const target_section_id = self.calcLEB128Data();
                    std.debug.print("{s}[{}]\n", .{WasmSection.init(target_section+1).asText(), target_section_id});
                }
            },
            .Export => {
                const export_count = self.calcLEB128Data();
                std.debug.print("Section size: {}.\nNumber of imports: {}\n", .{section.size, export_count});
                for (0..export_count) |_| {
                    const export_name_length = self.calcLEB128Data();
                    const export_name = name:{
                        var tmp:[32]u8 = undefined;
                        for (self.data[self.pos..self.pos+export_name_length], 0..) |char, i| {
                            tmp[i] = char;
                            self.pos+=1;
                        }
                    break :name &tmp;
                    };
                    std.debug.print("{s}\n", .{export_name});
                    const target_section = self.calcLEB128Data();
                    const target_section_id = self.calcLEB128Data();
                    std.debug.print("{s}[{}]\n", .{WasmSection.init(target_section+1).asText(), target_section_id});
                }

            },
            .Code => {
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

            },
            else => {},
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

    fn calcLEB128Data(self: *Wasm) usize {
        var tmp = [_]u8{0} ** 4;
        for (self.data[self.pos..], 0..) |val, j| {
            tmp[j] = val;
            if (val < 128) {
                self.pos += j + 1; // code count分進める
                break;
            }
        }
        return leb128.decodeLEB128(&tmp); // codeの数
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

pub const WasmSectionSize = struct {
    size: usize,
    byte_width: usize,
};
