const std = @import("std");

const ChannelList = struct {
    const Channel = struct {
        const PixelType = enum(i32) {
            uint = 0,
            half = 1,
            float = 2,
        };

        name: []u8,
        pixel_type: PixelType,
        p_linear: u8,
        reserved: [3]u8,
        x_sampling: i32,
        y_sampling: i32,
    };

    channels: []Channel,

    fn read(allocator: std.mem.Allocator, bytes: []const u8) !ChannelList {
        var channels = std.ArrayList(Channel).init(allocator);

        const reader = std.io.fixedBufferStream(bytes).reader();
        while (true) {
            const name = try reader.readUntilDelimiterAlloc(allocator, 0, 256);
            if (name.len == 0) break;

            const buffer = try reader.readBytesNoEof(@sizeOf(Channel) - @sizeOf([]u8));

            try channels.append(.{
                .name = name,
                .pixel_type = @intToEnum(Channel.PixelType, @bitCast(i32, buffer[0..@sizeOf(i32)].*)),
                .p_linear = buffer[@sizeOf(i32)],
                .reserved = buffer[@sizeOf(i32) + @sizeOf(u8)..][0..@sizeOf([3]u8)].*,
                .x_sampling = @bitCast(i32, buffer[@sizeOf(i32) + @sizeOf(u8) + @sizeOf([3]u8)..][0..@sizeOf(i32)].*),
                .y_sampling = @bitCast(i32, buffer[@sizeOf(i32) + @sizeOf(u8) + @sizeOf([3]u8) + @sizeOf(i32)..][0..@sizeOf(i32)].*),
            });
        }

        return ChannelList {
            .channels = channels.toOwnedSlice(),
        };
    }

    fn destroy(self: *ChannelList, allocator: std.mem.Allocator) void {
        for (self.channels) |channel| {
            allocator.free(channel.name);
        }

        allocator.free(self.channels);
    }
};

const Compression = enum(u8) {
    no = 0,
    rle = 1,
    zips = 2,
    zip = 3,
    piz = 4,
    pxr24 = 5,
    b44 = 6,
    b44a = 7,

    fn scanLinesPerBlock(self: Compression) u8 {
        return switch (self) {
            .no => 1,
            .rle => 1,
            .zips => 1,
            .zip => 16,
            .piz => 32,
            .pxr24 => 16,
            .b44 => 32,
            .b44a => 32,
        };
    }
};

const String = struct {
    slice: []const u8,

    fn read(allocator: std.mem.Allocator, bytes: []const u8) !String {
        const reader = std.io.fixedBufferStream(bytes).reader();
        const len = try reader.readIntLittle(i32);

        const slice = try allocator.alloc(u8, @intCast(usize, len));

        std.mem.copy(u8, slice, bytes);

        return String {
            .slice = slice,
        };
    }

    fn destroy(self: *String, allocator: std.mem.Allocator) void {
        allocator.free(self.slice);
    }
};

const Box2i = packed struct {
    x_min: i32,
    y_min: i32,
    x_max: i32,
    y_max: i32,
};

const LineOrder = enum(u8) {
    increasing_y,
    decreasing_y,
    random_y,
};

const V2f = packed struct {
    x: f32,
    y: f32,
};

const Header = struct {
    const AttributeType = enum {
        chlist,
        string,
        compression,
        box2i,
        line_order,
        float,
        v2f,

        fn fromString(ty: []const u8) AttributeType {
            if (std.mem.eql(u8, ty, "chlist")) {
                return .chlist;
            } else if (std.mem.eql(u8, ty, "string")) {
                return .string;
            } else if (std.mem.eql(u8, ty, "compression")) {
                return .compression;
            } else if (std.mem.eql(u8, ty, "box2i")) {
                return .box2i;
            } else if (std.mem.eql(u8, ty, "lineOrder")) {
                return .line_order;
            } else if (std.mem.eql(u8, ty, "float")) {
                return .float;
            } else if (std.mem.eql(u8, ty, "v2f")) {
                return .v2f;
            } else {
                unreachable; // TODO
            }
        }

        fn fromType(comptime T: type) AttributeType {
            return switch (T) {
                ChannelList => .chlist,
                String => .string,
                Compression => .compression,
                Box2i => .box2i,
                LineOrder => .line_order,
                f32 => .float,
                V2f => .v2f,
                else => @compileError("Unsupported type for attribute type"),
            };
        }
    };

    const Attribute = struct {
        name: []const u8,
        ty: AttributeType,
        value: *anyopaque,

        fn create(ty: AttributeType, allocator: std.mem.Allocator, name: []const u8, reader: std.fs.File.Reader, size: i32) !Attribute {
            return switch (ty) {
                .chlist => try Attribute.createInner(ChannelList, allocator, name, reader, size),
                .string => try Attribute.createInner(String, allocator, name, reader, size),
                .compression => try Attribute.createInner(Compression, allocator, name, reader, size),
                .box2i => try Attribute.createInner(Box2i, allocator, name, reader, size),
                .line_order => try Attribute.createInner(LineOrder, allocator, name, reader, size),
                .float => try Attribute.createInner(f32, allocator, name, reader, size),
                .v2f => try Attribute.createInner(V2f, allocator, name, reader, size),
            };
        }

        fn createInner(comptime T: type, allocator: std.mem.Allocator, name: []const u8, reader: std.fs.File.Reader, size: i32) !Attribute {
            var value = try allocator.create(T);
            value.* = try createInnerInner(T, allocator, reader, size);
            return Attribute {
                .name = name,
                .ty = comptime AttributeType.fromType(T),
                .value = value,
            };
        }

        fn createInnerInner(comptime T: type, allocator: std.mem.Allocator, reader: std.fs.File.Reader, size: i32) !T {
            return switch (@typeInfo(T)) {
                .Enum => try reader.readEnum(T, std.builtin.Endian.Little),
                .Struct => if (@hasDecl(T, "read")) blk: {
                    const bytes = try allocator.alloc(u8, @intCast(usize, size));
                    defer allocator.free(bytes);
                    try reader.readNoEof(bytes);
                    break :blk try T.read(allocator, bytes);
                } else @bitCast(T, try reader.readBytesNoEof(@sizeOf(T))),
                else => @bitCast(T, try reader.readBytesNoEof(@sizeOf(T))),
            };
        }

        fn destroy(self: *Attribute, allocator: std.mem.Allocator) void {
            switch (self.ty) {
                .chlist => self.destroyInner(ChannelList, allocator),
                .string => self.destroyInner(String, allocator),
                .compression => self.destroyInner(Compression, allocator),
                .box2i => self.destroyInner(Box2i, allocator),
                .line_order => self.destroyInner(LineOrder, allocator),
                .float => self.destroyInner(f32, allocator),
                .v2f => self.destroyInner(V2f, allocator),
            }
        }

        fn destroyInner(self: *Attribute, comptime T: type, allocator: std.mem.Allocator) void {
            allocator.free(self.name);

            const val = @ptrCast(*T, @alignCast(@alignOf(T), self.value));
            if (@typeInfo(T) == .Struct and @hasDecl(T, "destroy")) {
                val.destroy(allocator);
            }
            allocator.destroy(val);
        }
    };

    const Attributes = std.MultiArrayList(Attribute);

    const FoundAttributes = struct {
        channels: bool = false,
        compression: bool = false,
        data_window: bool = false,
        display_window: bool = false,
        line_order: bool = false,
        pixel_aspect_ratio: bool = false,
        screen_window_center: bool = false,
        screen_window_width: bool = false,

        fn foundAll(self: FoundAttributes) bool {
            return self.channels and self.compression and self.data_window
                and self.display_window and self.line_order and self.pixel_aspect_ratio
                and self.screen_window_center and self.screen_window_width;
        }
    };

    channels: ChannelList,
    compression: Compression,
    data_window: Box2i,
    display_window: Box2i,
    line_order: LineOrder,
    pixel_aspect_ratio: f32,
    screen_window_center: V2f,
    screen_window_width: f32,

    misc_attributes: Attributes,

    pub fn read(allocator: std.mem.Allocator, reader: std.fs.File.Reader) !Header {
        var self: Header = undefined;
        self.misc_attributes = Attributes {};

        var found_attributes = FoundAttributes {};

        while (true) {
            const attr_name = blk: {
                var buf: [32:0]u8 = undefined;
                const name = try reader.readUntilDelimiter(&buf, 0);
                break :blk name;
            };
            if (attr_name.len == 0) break;

            const attr_type = blk: {
                var buf: [32:0]u8 = undefined;
                const ty = try reader.readUntilDelimiter(&buf, 0);
                break :blk AttributeType.fromString(ty);
            };
            const size = try reader.readIntLittle(i32);

            //std.debug.print("{s}: {any}\n", .{ attr_name, attr_type });
            if (std.mem.eql(u8, attr_name, "channels")) {
                self.channels = try Attribute.createInnerInner(ChannelList, allocator, reader, size);
                std.debug.assert(!found_attributes.channels);
                found_attributes.channels = true;
            } else if (std.mem.eql(u8, attr_name, "compression")) {
                self.compression = try Attribute.createInnerInner(Compression, allocator, reader, size);
                std.debug.assert(!found_attributes.compression);
                found_attributes.compression = true;
            } else if (std.mem.eql(u8, attr_name, "dataWindow")) {
                self.data_window = try Attribute.createInnerInner(Box2i, allocator, reader, size);
                std.debug.assert(!found_attributes.data_window);
                found_attributes.data_window = true;
            } else if (std.mem.eql(u8, attr_name, "displayWindow")) {
                self.display_window = try Attribute.createInnerInner(Box2i, allocator, reader, size);
                std.debug.assert(!found_attributes.display_window);
                found_attributes.display_window = true;
            } else if (std.mem.eql(u8, attr_name, "lineOrder")) {
                self.line_order = try Attribute.createInnerInner(LineOrder, allocator, reader, size);
                std.debug.assert(!found_attributes.line_order);
                found_attributes.line_order = true;
            } else if (std.mem.eql(u8, attr_name, "pixelAspectRatio")) {
                self.pixel_aspect_ratio = try Attribute.createInnerInner(f32, allocator, reader, size);
                std.debug.assert(!found_attributes.pixel_aspect_ratio);
                found_attributes.pixel_aspect_ratio = true;
            } else if (std.mem.eql(u8, attr_name, "screenWindowCenter")) {
                self.screen_window_center = try Attribute.createInnerInner(V2f, allocator, reader, size);
                std.debug.assert(!found_attributes.screen_window_center);
                found_attributes.screen_window_center = true;
            } else if (std.mem.eql(u8, attr_name, "screenWindowWidth")) {
                self.screen_window_width = try Attribute.createInnerInner(f32, allocator, reader, size);
                std.debug.assert(!found_attributes.screen_window_width);
                found_attributes.screen_window_width = true;
            } else {
                const name = try allocator.dupe(u8, attr_name);
                try self.misc_attributes.append(allocator, try Attribute.create(attr_type, allocator, name, reader, size));
            }
        }

        if (!found_attributes.foundAll()) {
            //std.log.warn("{any}\n", .{ found_attributes });
            return error.MissingAttributes;
        }

        return self;
    }

    fn destroy(self: *Header, allocator: std.mem.Allocator) void {
        self.channels.destroy(allocator);

        while (self.misc_attributes.popOrNull()) |*attr| {
            attr.destroy(allocator);
        }

        self.misc_attributes.deinit(allocator);
    }
};

const OffsetTable = struct {
    table: []const u64,

    fn read(allocator: std.mem.Allocator, header: Header, reader: std.fs.File.Reader) !OffsetTable {
        const data_height = header.data_window.y_max - header.data_window.y_min;
        if (data_height < 0) return error.InvalidImage;
        const table_size = @intCast(u32, data_height) / header.compression.scanLinesPerBlock();

        var table = try allocator.alloc(u64, table_size);

        for (table) |*entry| {
            entry.* = try reader.readIntLittle(u64);
        }

        return OffsetTable {
            .table = table,
        };
    }

    fn destroy(self: *OffsetTable, allocator: std.mem.Allocator) void {
        allocator.free(self.table);
    }
};

const Error = error {
    BadMagicNumber,
    Unimplemented,
};

pub const Image = struct {
    const Version = packed struct {
        version: u8,
        flags: u24,
    };

    magic: i32,
    version: Version,
    header: Header,
    offset_table: OffsetTable,

    pub fn fromFile(allocator: std.mem.Allocator, file: std.fs.File) !Image {
        const reader = file.reader();

        const buffer = try reader.readBytesNoEof(@sizeOf(i32) + @sizeOf(Version));

        // component one
        const magic = @bitCast(i32, buffer[0..@sizeOf(i32)].*);
        if (magic != 20000630) return Error.BadMagicNumber;

        // component two
        const version = @bitCast(Version, buffer[@sizeOf(i32)..buffer.len].*);
        if (version.flags != 0) return Error.Unimplemented; // don't support any other for now

        // component three
        const header = try Header.read(allocator, reader);

        // component four
        const offset_table = try OffsetTable.read(allocator, header, reader);

        return Image {
            .magic = magic,
            .version = version,
            .header = header,
            .offset_table = offset_table,
        };
    }

    pub fn destroy(self: *Image, allocator: std.mem.Allocator) void {
        self.header.destroy(allocator);
        self.offset_table.destroy(allocator);
    }
};

test "basic" {
    const file = try std.fs.cwd().openFile("test.exr", .{});
    defer file.close();

    var image = try Image.fromFile(std.testing.allocator, file);
    defer image.destroy(std.testing.allocator);
}

