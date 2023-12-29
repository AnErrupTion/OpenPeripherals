const std = @import("std");
const component = @import("component.zig");
const Command = @import("Command.zig");
const Allocator = std.mem.Allocator;
const Component = component.Component;
const ComponentList = std.ArrayList(Component);
const CommandList = std.ArrayList(Command);

const Device = @This();

pub const Category = enum {
    headphones,

    pub fn parse(str: []const u8) !Category {
        // zig fmt: off
            return
                if (std.mem.eql(u8, str, "headphones")) .headphones
                else error.InvalidCategory;
            // zig fmt: on
    }
};

pub const Capability = struct {
    id: []u8,
    name: []u8,
    usagepage: u16,
    usageid: u8,
    interface: u8,

    initialization: CommandList,
    components: ComponentList,
    commands: CommandList,
};
const CapabilityList = std.ArrayList(Capability);

allocator: Allocator,

id: []u8,
name: []u8,
category: Category,

initialization: CommandList,
capabilities: CapabilityList,

pub fn deinit(self: Device) void {
    self.allocator.free(self.id);
    self.allocator.free(self.name);

    for (self.initialization.items) |command| {
        self.allocator.free(command.id);

        for (command.data.items) |node| node.deinit(self.allocator);
        command.data.deinit();
    }

    for (self.capabilities.items) |capability| {
        self.allocator.free(capability.id);
        self.allocator.free(capability.name);

        for (capability.initialization.items) |command| {
            self.allocator.free(command.id);

            for (command.data.items) |node| node.deinit(self.allocator);
            command.data.deinit();
        }

        for (capability.components.items) |ui_component| {
            switch (ui_component) {
                .slider => |slider| {
                    self.allocator.free(slider.id);
                    self.allocator.free(slider.name);

                    for (slider.value.items) |node| node.deinit(self.allocator);
                    slider.value.deinit();
                },
            }
        }

        for (capability.commands.items) |command| {
            self.allocator.free(command.id);

            for (command.data.items) |node| node.deinit(self.allocator);
            command.data.deinit();
        }

        capability.initialization.deinit();
        capability.components.deinit();
        capability.commands.deinit();
    }

    self.initialization.deinit();
    self.capabilities.deinit();
}
