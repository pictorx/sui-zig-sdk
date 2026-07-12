const std = @import("std");
const MaxUleb128Length = 10;

pub fn uleb128Encode(comptime T: type, value: T, out: *[MaxUleb128Length]u8) []u8 {
    comptime if (@typeInfo(T) != .int) @compileError("ULEB128 only supports integer types, found: " ++ @typeName(T));
    var w: std.Io.Writer = .fixed(out);
    w.writeUleb128(value) catch unreachable;
    return w.buffered();
}

pub fn uleb128Decode(reader: *std.Io.Reader, comptime T: type) !struct { T, usize } {
    comptime if (@typeInfo(T) != .int) @compileError("ULEB128 only supports integer types, found: " ++ @typeName(T));

    var buf: [1]u8 = undefined;
    var raw: u64 = 0;
    var shift: u6 = 0;
    var bytes_read: usize = 0;

    while (bytes_read < MaxUleb128Length) : (bytes_read += 1) {
        reader.readSliceAll(&buf) catch |err| switch (err) {
            error.EndOfStream => return error.UnexpectedEndOfStream,
            else => return err,
        };
        const byte = buf[0];
        const low7: u64 = byte & 0x7F;

        if (shift >= 64 or (low7 << shift) >> shift != low7) {
            return error.Overflow;
        }
        raw |= low7 << shift;

        if (byte & 0x80 == 0) {
            const value = std.math.cast(T, raw) orelse return error.Overflow;
            return .{ value, bytes_read + 1 };
        }
        shift +%= 7; // wrapping: last iteration's value is never used, so it must not panic
    }
    return error.TooManyBytes;
}

pub const TagValue = u8;
pub const tag_value_optional: TagValue = 1 << 0;
pub const tag_value_ignore: TagValue = 1 << 1;

const tag_name = "bcs";

const TagError = error{UnknownTag};

pub fn parseTagValue(tag_str: []const u8) TagError!TagValue {
    var r: TagValue = 0;
    var tag_segs = std.mem.splitSequence(u8, tag_str, ",");
    while (tag_segs.next()) |seg| {
        const seg_ = std.mem.trim(u8, seg, " \t\n\r");
        if (seg_.len == 0) continue;

        if (std.mem.eql(u8, seg_, "optional")) {
            r |= tag_value_optional;
        } else if (std.mem.eql(u8, seg_, "-")) {
            return tag_value_ignore;
        } else {
            return error.UnknownTag;
        }
    }
    return r;
}

pub const Encoder = struct {
    w: *std.Io.Writer,

    pub fn encode(self: *Encoder, v: anytype) anyerror!void {
        const T = @TypeOf(v);

        // Equivalent of Go's Marshaler check: a type can opt out of the
        // generic path by providing its own encode method.
        if (comptime @hasDecl(T, "marshalBCS")) {
            return v.marshalBCS(self);
        }

        switch (@typeInfo(T)) {
            .int => try self.w.writeInt(T, v, .little),
            .bool => try self.w.writeByte(@intFromBool(v)),
            .optional => if (v) |val| {
                try self.w.writeByte(1);
                try self.encode(val);
            } else {
                try self.w.writeByte(0);
            },
            .pointer => |ptr| switch (ptr.size) {
                .one => try self.encode(v.*),
                .slice => if (ptr.child == u8)
                    try self.encodeByteSlice(v)
                else
                    try self.encodeSlice(v),
                else => @compileError("unsupported pointer type for BCS: " ++ @typeName(T)),
            },
            .array => try self.encodeArray(v),
            .@"struct" => try self.encodeStruct(v),
            .@"union" => try self.encodeUnion(v),
            else => @compileError("unsupported type for BCS encoding: " ++ @typeName(T)),
        }
    }

    fn encodeByteSlice(self: *Encoder, b: []const u8) anyerror!void {
        try uleb128Encode(usize, self.w, b.len);
        try self.w.writeAll(b);
    }

    fn encodeSlice(self: *Encoder, v: anytype) anyerror!void {
        try uleb128Encode(usize, self.w, v.len);
        for (v) |item| try self.encode(item);
    }

    fn encodeArray(self: *Encoder, v: anytype) anyerror!void {
        // Fixed-length: no ULEB128 prefix, matches BCS array semantics.
        for (v) |item| try self.encode(item);
    }

    fn encodeStruct(self: *Encoder, v: anytype) anyerror!void {
        const T = @TypeOf(v);
        inline for (std.meta.fields(T)) |field| {
            if (comptime shouldIgnore(T, field.name)) continue;
            try self.encode(@field(v, field.name));
        }
    }

    fn encodeUnion(self: *Encoder, v: anytype) anyerror!void {
        try uleb128Encode(usize, self.w, @intFromEnum(v));
        switch (v) {
            inline else => |payload| try self.encode(payload),
        }
    }
};

pub fn newEncoder(w: *std.Io.Writer) Encoder {
    return .{ .w = w };
}

pub const Decoder = struct {
    r: *std.Io.Reader,
    allocator: std.mem.Allocator,

    pub fn decode(self: *Decoder, comptime T: type) anyerror!T {
        // Equivalent of Go's Unmarshaler check.
        if (comptime @hasDecl(T, "unmarshalBCS")) {
            return T.unmarshalBCS(self);
        }

        switch (@typeInfo(T)) {
            .bool => return (try self.r.takeByte()) != 0,
            .int => return try self.r.takeInt(T, .little),
            .optional => |opt| {
                const present = try self.r.takeByte();
                if (present == 0) return null;
                return try self.decode(opt.child);
            },
            .array => |arr| return try self.decodeArray(T, arr),
            .@"struct" => return try self.decodeStruct(T),
            .@"union" => return try self.decodeUnion(T),
            .pointer => |ptr| {
                if (ptr.size != .slice) @compileError("only slices are supported for BCS: " ++ @typeName(T));
                if (ptr.child == u8) return try self.decodeByteSlice();
                return try self.decodeSlice(ptr.child);
            },
            else => @compileError("unsupported type for BCS decoding: " ++ @typeName(T)),
        }
    }

    fn decodeArray(self: *Decoder, comptime T: type, comptime info: std.builtin.Type.Array) anyerror!T {
        var out: T = undefined;
        if (info.child == u8) {
            try self.r.readSliceAll(&out); // fixed-length, no ULEB128 prefix
        } else {
            for (&out) |*slot| slot.* = try self.decode(info.child);
        }
        return out;
    }

    // Caller owns the returned memory.
    fn decodeByteSlice(self: *Decoder) anyerror![]u8 {
        const size, _ = try uleb128Decode(self.r, usize);
        const buf = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(buf);
        try self.r.readSliceAll(buf);
        return buf;
    }

    // Caller owns the returned memory.
    fn decodeSlice(self: *Decoder, comptime Elem: type) anyerror![]Elem {
        const size, _ = try uleb128Decode(self.r, usize);
        const out = try self.allocator.alloc(Elem, size);
        errdefer self.allocator.free(out);
        for (out) |*slot| slot.* = try self.decode(Elem);
        return out;
    }

    fn decodeStruct(self: *Decoder, comptime T: type) anyerror!T {
        // Zero-init first so ignored fields end up in a sane default state
        // instead of `undefined` garbage (mirrors Go's zero-valued struct).
        var out: T = std.mem.zeroes(T);
        inline for (std.meta.fields(T)) |field| {
            if (comptime shouldIgnore(T, field.name)) continue;
            @field(out, field.name) = try self.decode(field.type);
        }
        return out;
    }

    // BCS enum: ULEB128 variant index, then that variant's payload.
    fn decodeUnion(self: *Decoder, comptime T: type) anyerror!T {
        const idx, _ = try uleb128Decode(self.r, usize);
        inline for (std.meta.fields(T), 0..) |field, i| {
            if (i == idx) {
                const payload = try self.decode(field.type);
                return @unionInit(T, field.name, payload);
            }
        }
        return error.UnknownEnumVariant;
    }
};

fn shouldIgnore(comptime T: type, comptime name: []const u8) bool {
    if (!@hasDecl(T, "bcs_ignore")) return false;
    inline for (T.bcs_ignore) |ignored| {
        if (comptime std.mem.eql(u8, ignored, name)) return true;
    }
    return false;
}

pub fn unmarshal(allocator: std.mem.Allocator, data: []const u8, comptime T: type) anyerror!T {
    var reader: std.Io.Reader = .fixed(data);
    var dec = Decoder{ .r = &reader, .allocator = allocator };
    return dec.decode(T);
}
