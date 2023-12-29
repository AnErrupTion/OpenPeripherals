const std = @import("std");
const commandParser = @import("commandParser.zig");
const NodeList = std.ArrayList(commandParser.Node);

pub const Direction = enum {
    in,
    out,

    pub fn parse(str: []const u8) !Direction {
        // zig fmt: off
        return
            if (std.mem.eql(u8, str, "in")) .in
            else if (std.mem.eql(u8, str, "out")) .out
            else error.InvalidDirection;
        // zig fmt: on
    }
};

pub const Type = enum {
    raw,
    report,

    pub fn parse(str: []const u8) !Type {
        // zig fmt: off
        return
            if (std.mem.eql(u8, str, "raw")) .raw
            else if (std.mem.eql(u8, str, "report")) .report
            else error.InvalidType;
        // zig fmt: on
    }
};

id: []u8,
direction: Direction,
type: Type,
size: usize,

data: NodeList,
