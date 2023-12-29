const std = @import("std");
const xml = @import("xml.zig");
const commandParser = @import("commandParser.zig");
const component = @import("component.zig");
const Command = @import("Command.zig");
const Device = @import("Device.zig");
const Allocator = std.mem.Allocator;
const Integer = commandParser.Integer;
const Float = commandParser.Float;
const Orientation = component.Orientation;
const Component = component.Component;
const ComponentList = std.ArrayList(Component);
const CommandList = std.ArrayList(Command);
const Capability = Device.Capability;
const CapabilityList = std.ArrayList(Capability);
const ByteList = std.ArrayList(u8);
const IntegerList = std.ArrayList(Integer);
const IdentifierMap = std.StringHashMap(Float);
const NodeList = std.ArrayList(commandParser.Node);

const hidapi = @cImport({
    @cInclude("hidapi/hidapi.h");
});

pub fn main() !void {
    var status: c_int = undefined;

    std.log.info("Initializing hidapi...", .{});

    status = hidapi.hid_init();
    defer status = hidapi.hid_exit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    std.log.info("Reading meta.xml...", .{});

    const file = try std.fs.cwd().openFile("meta.xml", .{});
    defer file.close();

    const buffer = try file.readToEndAlloc(allocator, 4 * 1024);
    defer allocator.free(buffer);

    std.log.info("Parsing XML document...", .{});

    const document = try xml.parse(allocator, buffer);
    defer document.deinit();

    std.log.info("Probing active devices...", .{});

    var children = document.root.elements();
    while (children.next()) |child| {
        if (child.children.len != 1) return error.InvalidDeviceChildrenCount;

        const vendor = try parseNumber(u16, child.getAttribute("vendor").?);
        const product = try parseNumber(u16, child.getAttribute("product").?);
        const path = child.children[0].char_data;

        const hid_devices = hidapi.hid_enumerate(@intCast(vendor), @intCast(product));
        defer hidapi.hid_free_enumeration(hid_devices);

        if (hid_devices == null) return error.HidDeviceNotFound;

        std.log.info("Found device {X}:{X}! Reading {s}...", .{ vendor, product, path });

        const device = try parseDeviceDescriptor(allocator, path);
        defer device.deinit();

        const input = std.io.getStdIn().reader();

        var input_list = ByteList.init(allocator);
        defer input_list.deinit();

        std.log.info("Device: {s} ({s})", .{ device.name, device.id });
        std.log.info("Category: {s}", .{switch (device.category) {
            .headphones => "Headphones",
        }});

        // TODO: Execute "initialize" elements

        for (device.capabilities.items, 0..) |capability, i| {
            std.log.info("[{d}] Capability: {s} ({s})", .{ i, capability.name, capability.id });
        }

        std.log.info("Which capability do you want to control?", .{});
        try input.streamUntilDelimiter(input_list.writer(), '\n', null);

        const capability_index = try std.fmt.parseInt(usize, input_list.items, 10);
        const capability = device.capabilities.items[capability_index];

        const usagepage: c_ushort = @intCast(capability.usagepage);
        const usageid: c_ushort = @intCast(capability.usageid);
        const interface: c_ushort = @intCast(capability.interface);

        var hid_device = hid_devices;
        var hid_path: [*]u8 = undefined;
        var hid_found_path = false;

        while (hid_device != null) {
            const hid_dev = hid_device.*;

            if (hid_dev.usage_page == usagepage and hid_dev.usage == usageid and hid_dev.interface_number == interface) {
                hid_path = hid_dev.path;
                hid_found_path = true;
                break;
            }

            hid_device = hid_dev.next;
        }

        if (!hid_found_path) return error.IncorrectCapabilityDetails;

        const hid_handle = hidapi.hid_open_path(hid_path);
        defer hidapi.hid_close(hid_handle);

        var identifiers = IdentifierMap.init(allocator);
        defer identifiers.deinit();

        for (capability.components.items, 0..) |ui_component, i| {
            switch (ui_component) {
                .slider => |slider| {
                    std.log.info("[{d}] Slider: {s} ({s}) {d} to {d} +{d}", .{ i, slider.name, slider.id, slider.min, slider.max, slider.step });

                    try identifiers.put(slider.id, constructValueFromNode(slider.value.items[0], identifiers));
                },
            }
        }
        std.log.info("[{d}] Save", .{capability.components.items.len});

        while (true) {
            input_list.clearRetainingCapacity();
            std.log.info("Which component do you want to control?", .{});
            try input.streamUntilDelimiter(input_list.writer(), '\n', null);

            const component_index = try std.fmt.parseInt(usize, input_list.items, 10);
            if (component_index == capability.components.items.len) {
                for (capability.commands.items) |command| {
                    var values = try constructValues(allocator, command.data, identifiers);
                    defer values.deinit();

                    while (values.items.len != command.size) try values.append(0x00);

                    switch (command.direction) {
                        .in => unreachable,
                        .out => {
                            switch (command.type) {
                                .raw => _ = hidapi.hid_write(hid_handle, values.items.ptr, command.size),
                                .report => _ = hidapi.hid_send_feature_report(hid_handle, values.items.ptr, command.size),
                            }
                        },
                    }
                }
                return;
            }

            input_list.clearRetainingCapacity();
            std.log.info("Input its new value:", .{});
            try input.streamUntilDelimiter(input_list.writer(), '\n', null);

            const new_value = try std.fmt.parseFloat(Float, input_list.items);
            const ui_component = capability.components.items[component_index];

            switch (ui_component) {
                .slider => |slider| try identifiers.put(slider.id, new_value),
            }
        }
    }
}

fn parseDeviceDescriptor(allocator: Allocator, path: []const u8) !Device {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const buffer = try file.readToEndAlloc(allocator, 16 * 1024);
    defer allocator.free(buffer);

    std.log.info("Parsing XML document...", .{});

    const document = try xml.parse(allocator, buffer);
    defer document.deinit();

    std.log.info("Parsing device descriptor...", .{});

    const device_id = try allocator.dupe(u8, document.root.getAttribute("id").?);
    const device_name = try allocator.dupe(u8, document.root.getAttribute("name").?);
    const device_category = try Device.Category.parse(document.root.getAttribute("category").?);

    var device_initialization = CommandList.init(allocator);
    var device_capabilities = CapabilityList.init(allocator);

    var children = document.root.elements();
    while (children.next()) |child| {
        if (try parseElement(Command, allocator, child, &device_initialization, "initialize", &[_][]const u8{"command"})) continue;

        if (!std.mem.eql(u8, child.tag, "capability")) return error.TagNotCapability;

        const capability_id = try allocator.dupe(u8, child.getAttribute("id").?);
        const capability_name = try allocator.dupe(u8, child.getAttribute("name").?);
        const capability_usagepage = try parseNumber(u16, child.getAttribute("usagepage").?);
        const capability_usageid = try parseNumber(u8, child.getAttribute("usageid").?);
        const capability_interface = try parseNumber(u8, child.getAttribute("interface").?);

        var capability_initialization = CommandList.init(allocator);
        var capability_components = ComponentList.init(allocator);
        var capability_commands = CommandList.init(allocator);

        var capability_children = child.elements();
        while (capability_children.next()) |capability_child| {
            if (try parseElement(Command, allocator, capability_child, &capability_initialization, "initialize", &[_][]const u8{"command"})) continue;
            if (try parseElement(Component, allocator, capability_child, &capability_components, "ui", &[_][]const u8{"slider"})) continue;
            if (try parseElement(Command, allocator, capability_child, &capability_commands, "save", &[_][]const u8{"command"})) continue;

            return error.InvalidTagInCapability;
        }

        try device_capabilities.append(.{
            .id = capability_id,
            .name = capability_name,
            .usagepage = capability_usagepage,
            .usageid = capability_usageid,
            .interface = capability_interface,
            .initialization = capability_initialization,
            .components = capability_components,
            .commands = capability_commands,
        });
    }

    return .{
        .allocator = allocator,
        .id = device_id,
        .name = device_name,
        .category = device_category,
        .initialization = device_initialization,
        .capabilities = device_capabilities,
    };
}

fn parseElement(
    comptime T: type,
    allocator: Allocator,
    element: *xml.Element,
    list: *std.ArrayList(T),
    tag: []const u8,
    child_tags: []const []const u8,
) !bool {
    if (list.items.len != 0 or !std.mem.eql(u8, element.tag, tag)) return false;

    var children = element.elements();
    while (children.next()) |child| {
        var index: usize = 0;
        var found = false;

        for (0..child_tags.len) |i| {
            if (std.mem.eql(u8, child.tag, child_tags[i])) {
                index = i;
                found = true;
                break;
            }
        }

        if (!found) continue;

        // zig fmt: off
        const item = switch (T) {
            Command => try parseCommand(allocator, child),
            Component => if (index == 0) try parseSliderComponent(allocator, child)
                            else return error.UnknownComponent,
            else => return error.UnsupportedType,
        };
        // zig fmt: on

        try list.append(item);
    }

    return true;
}

fn parseCommand(allocator: Allocator, command: *xml.Element) !Command {
    const command_id = try allocator.dupe(u8, command.getAttribute("id").?);
    const command_direction = try Command.Direction.parse(command.getAttribute("direction").?);
    const command_type = try Command.Type.parse(command.getAttribute("type").?);
    const command_size = try parseNumber(usize, command.getAttribute("size").?);
    const command_data = try commandParser.parse(allocator, command);

    return .{
        .id = command_id,
        .direction = command_direction,
        .type = command_type,
        .size = command_size,
        .data = command_data,
    };
}

fn parseSliderComponent(allocator: Allocator, command: *xml.Element) !Component {
    const slider_id = try allocator.dupe(u8, command.getAttribute("id").?);
    const slider_name = try allocator.dupe(u8, command.getAttribute("name").?);
    const slider_orientation = try Orientation.parse(command.getAttribute("orientation").?);
    const slider_min = try parseNumber(f32, command.getAttribute("min").?);
    const slider_max = try parseNumber(f32, command.getAttribute("max").?);
    const slider_step = try parseNumber(f32, command.getAttribute("step").?);
    const slider_value = try commandParser.parse(allocator, command);

    if (slider_value.items.len != 1) return error.IncorrectSliderValueCount;

    return .{ .slider = .{
        .id = slider_id,
        .name = slider_name,
        .orientation = slider_orientation,
        .min = slider_min,
        .max = slider_max,
        .step = slider_step,
        .value = slider_value,
    } };
}

fn parseNumber(comptime T: type, str: []const u8) !T {
    return switch (@typeInfo(T)) {
        .Float => std.fmt.parseFloat(T, str),
        .Int => std.fmt.parseInt(T, str, 0),
        else => error.InvalidType,
    };
}

fn printHidApiError(handle: ?*hidapi.hid_device) void {
    std.debug.print("HID Error: ", .{});
    const err = hidapi.hid_error(handle);

    var index: usize = 0;
    var current = err[index];
    while (current != 0) : (current = err[index]) {
        std.debug.print("{c}", .{@as(u8, @intCast(current))});
        index += 1;
    }

    std.debug.print("\n", .{});
}

fn constructValues(allocator: Allocator, nodes: NodeList, identifiers: IdentifierMap) !IntegerList {
    var list = IntegerList.init(allocator);

    for (nodes.items) |node| {
        try list.append(@intFromFloat(constructValueFromNode(node, identifiers)));
    }

    return list;
}

fn constructValueFromNode(node: commandParser.Node, identifiers: IdentifierMap) Float {
    return switch (node) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .identifier => |identifier| identifiers.get(identifier).?,
        .add => |add| constructValueFromNode(add.lhs.*, identifiers) + constructValueFromNode(add.rhs.*, identifiers),
        .multiply => |multiply| constructValueFromNode(multiply.lhs.*, identifiers) + constructValueFromNode(multiply.rhs.*, identifiers),
    };
}
