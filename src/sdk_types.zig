const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const AddressLength: u8 = 32;

pub const Address = struct {
    // allocator: std.mem.Allocator,
    bytes: [AddressLength]u8,

    pub fn new() Address {
        //const bytes: []u8 = try allocator.alloc(u8, AddressLength);
        const bytes: [AddressLength]u8 = undefined;

        return Address{
            .bytes = bytes,
        };
    }
    pub fn from_hex(self: *Address, hexStr: []const u8) !void {
        assert(hexStr[0] == '0');
        assert(hexStr[1] == 'x');

        if (hexStr.len == 0) {
            return AddressParserError.EmptyInput;
        }
        if (hexStr.len > 66) {
            return AddressParserError.InputTooLong;
        }

        _ = std.fmt.hexToBytes(self.bytes[0..], hexStr[2..]) catch |err| {
            return err;
        };
    }
    pub fn from_bytes(self: *Address, bytes: [AddressLength]u8) void {
        self.bytes = bytes;
    }
    pub fn to_hex(self: *Address) []const u8 {
        const hexStr = "0x" ++ std.fmt.bytesToHex(&self.bytes, .lower);
        return hexStr;
    }

    pub fn to_bytes(self: *Address) [AddressLength]u8 {
        return self.bytes;
    }
};

pub const AddressParserError = error{ EmptyInput, InputTooLong, InvalidHexCharacter };

test "Address" {
    var address = Address.new();
    const a = "0x0000000000000000000000000000000000000000000000000000000000000002";
    try address.from_hex(a);
    try testing.expect(address.bytes.len == AddressLength);
    const b = address.to_hex();
    try testing.expectEqualStrings(b, a);
}

// pub const HexDecodeError = enum([]u8) { EmptyInput = "input hex string must be non-empty", InputTooLong = "input hex string is too long for address", InvalidHexCharacter = "input hex string has wrong character" };

