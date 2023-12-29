const std = @import("std");
const xml = @import("xml.zig");
const Allocator = std.mem.Allocator;

pub const Integer = u8;
pub const Float = f32;
pub const Node = union(enum) {
    integer: Integer,
    float: Float,
    identifier: []u8,
    add: struct {
        lhs: *const Node,
        rhs: *const Node,
    },
    multiply: struct {
        lhs: *const Node,
        rhs: *const Node,
    },

    pub fn deinit(self: Node, allocator: Allocator) void {
        switch (self) {
            .identifier => |identifier| {
                allocator.free(identifier);
            },
            .add => |add| {
                add.lhs.deinit(allocator);
                add.rhs.deinit(allocator);

                allocator.destroy(add.lhs);
                allocator.destroy(add.rhs);
            },
            .multiply => |multiply| {
                multiply.lhs.deinit(allocator);
                multiply.rhs.deinit(allocator);

                allocator.destroy(multiply.lhs);
                allocator.destroy(multiply.rhs);
            },
            else => {},
        }
    }
};
const NodeList = std.ArrayList(Node);

pub const Error = error{IncorrectElementTag} || Allocator.Error || std.fmt.ParseIntError || std.fmt.ParseFloatError;

pub fn parse(allocator: Allocator, command: *xml.Element) !NodeList {
    var nodes = NodeList.init(allocator);
    var elements = command.elements();

    while (elements.next()) |element| {
        const expression = try parseExpression(allocator, element);
        try nodes.append(expression);
    }

    return nodes;
}

fn parseExpression(allocator: Allocator, element: *xml.Element) Error!Node {
    if (parseMultiplyExpression(allocator, element)) |node| {
        return node;
    } else |_| {}

    if (parseAddExpression(allocator, element)) |node| {
        return node;
    } else |_| {}

    if (parseIdentifierExpression(allocator, element)) |node| {
        return node;
    } else |_| {}

    if (parseFloatExpression(element)) |node| {
        return node;
    } else |_| {}

    return try parseIntegerExpression(element);
}

fn parseMultiplyExpression(allocator: Allocator, element: *xml.Element) Error!Node {
    if (!std.mem.eql(u8, element.tag, "mul")) return error.IncorrectElementTag;

    const lhs = try dupeNode(allocator, try parseExpression(allocator, element.children[0].element));
    const rhs = try dupeNode(allocator, try parseExpression(allocator, element.children[1].element));

    return .{ .multiply = .{
        .lhs = lhs,
        .rhs = rhs,
    } };
}

fn parseAddExpression(allocator: Allocator, element: *xml.Element) Error!Node {
    if (!std.mem.eql(u8, element.tag, "add")) return error.IncorrectElementTag;

    const lhs = try dupeNode(allocator, try parseExpression(allocator, element.children[0].element));
    const rhs = try dupeNode(allocator, try parseExpression(allocator, element.children[1].element));

    return .{ .add = .{
        .lhs = lhs,
        .rhs = rhs,
    } };
}

fn parseIdentifierExpression(allocator: Allocator, element: *xml.Element) Error!Node {
    if (!std.mem.eql(u8, element.tag, "ident")) return error.IncorrectElementTag;

    const identifier = try allocator.dupe(u8, element.children[0].char_data);

    return .{ .identifier = identifier };
}

fn parseFloatExpression(element: *xml.Element) Error!Node {
    if (!std.mem.eql(u8, element.tag, "float")) return error.IncorrectElementTag;

    const number = try std.fmt.parseFloat(Float, element.children[0].char_data);

    return .{ .float = number };
}

fn parseIntegerExpression(element: *xml.Element) Error!Node {
    if (!std.mem.eql(u8, element.tag, "int")) return error.IncorrectElementTag;

    const number = try std.fmt.parseInt(Integer, element.children[0].char_data, 0);

    return .{ .integer = number };
}

fn dupeNode(allocator: Allocator, source: Node) Error!*Node {
    const destination = try allocator.create(Node);
    @memcpy(std.mem.asBytes(destination), std.mem.asBytes(&source));
    return destination;
}
