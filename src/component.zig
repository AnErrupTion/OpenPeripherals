const std = @import("std");
const commandParser = @import("commandParser.zig");
const NodeList = std.ArrayList(commandParser.Node);

pub const Orientation = enum {
    horizontal,
    vertical,

    pub fn parse(str: []const u8) !Orientation {
        // zig fmt: off
        return
            if (std.mem.eql(u8, str, "horizontal")) .horizontal
            else if (std.mem.eql(u8, str, "vertical")) .vertical
            else error.InvalidOrientation;
        // zig fmt: on
    }
};
pub const Slider = struct {
    id: []u8,
    name: []u8,
    orientation: Orientation,
    min: f32,
    max: f32,
    step: f32,

    value: NodeList,
};
pub const Component = union(enum) {
    slider: Slider,
};
