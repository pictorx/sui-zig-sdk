const std = @import("std");
const zroaring = @import("zroaring");
const base58 = @import("base58");
const testing = std.testing;

const AddressLength: u8 = 32;

pub const Address = struct {
    bytes: [AddressLength]u8,

    pub fn new() Address {
        return Address{ .bytes = [_]u8{0} ** AddressLength };
    }

    /// Accepts an optional "0x"/"0X" prefix and hex strings shorter than
    /// the full 64 digits, left-zero-padding them (matches Rust's
    /// hex_address_bytes, which decodes back-to-front into a zeroed buffer).
    pub fn from_hex(self: *Address, hex_str: []const u8) AddressParseError!void {
        if (hex_str.len == 0) return AddressParseError.EmptyInput;

        const hex = if (hex_str.len >= 2 and hex_str[0] == '0' and (hex_str[1] == 'x' or hex_str[1] == 'X'))
            hex_str[2..]
        else
            hex_str;

        if (hex.len > AddressLength * 2) return AddressParseError.InputTooLong;

        self.bytes = [_]u8{0} ** AddressLength;

        var i: usize = hex.len;
        var j: usize = AddressLength;
        while (i >= 2) {
            const hi = hexDigit(hex[i - 2]) orelse return AddressParseError.InvalidHexCharacter;
            const lo = hexDigit(hex[i - 1]) orelse return AddressParseError.InvalidHexCharacter;
            j -= 1;
            self.bytes[j] = (hi << 4) | lo;
            i -= 2;
        }
        if (i == 1) {
            const lo = hexDigit(hex[0]) orelse return AddressParseError.InvalidHexCharacter;
            j -= 1;
            self.bytes[j] = lo;
        }
    }

    pub fn from_bytes(self: *Address, bytes: [AddressLength]u8) void {
        self.bytes = bytes;
    }

    /// buf must be at least HexEncodedLen (66) bytes.
    pub fn to_hex(self: *const Address, buf: []u8) []const u8 {
        const hex = std.fmt.bytesToHex(&self.bytes, .lower);
        buf[0] = '0';
        buf[1] = 'x';
        @memcpy(buf[2 .. 2 + hex.len], &hex);
        return buf[0 .. 2 + hex.len];
    }

    pub fn to_bytes(self: *const Address) [AddressLength]u8 {
        return self.bytes;
    }
};

pub const HexEncodedLen: usize = 2 + @as(usize, AddressLength) * 2;

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub const AddressParseError = error{ EmptyInput, InputTooLong, InvalidHexCharacter };

pub const ByteString = []const u8;
pub const Identifier = struct {
    bytestring: ByteString,

    pub fn init(allocator: std.mem.Allocator, size: usize) !Identifier {
        return .{
            .bytestring = try allocator.alloc(u8, size),
        };
    }

    pub fn init_from_str(allocator: std.mem.Allocator, str: []const u8) !Identifier {
        return .{
            .bytestring = try allocator.dupe(u8, str),
        };
    }

    pub fn deinit(self: *Identifier, allocator: std.mem.Allocator) void {
        allocator.free(self.bytestring);
    }

    pub fn as_str(self: *const Identifier) []const u8 {
        return self.bytestring;
    }
};

const DigestLength: u8 = 32;

pub const Digest = struct {
    bytes: [DigestLength]u8,

    pub fn as_slice(self: *const Digest) []const u8 {
        return &self.bytes;
    }

    pub fn from_base58(src: []const u8) DigestParseError!Digest {
        var dec_buf: [DigestLength]u8 = undefined;
        const decoded = try base58.decode32(&dec_buf, src);
        return Digest{
            .bytes = decoded[0..DigestLength].*,
        };
    }

    /// buf must be at least base58.encodedMaxLen(DigestLength) bytes.
    pub fn to_base58(self: *const Digest, buf: []u8) DigestParseError![]const u8 {
        return base58.encode(buf, &self.bytes);
    }

    pub fn from_bytes(bytes: []const u8) DigestParseError!Digest {
        if (bytes.len != DigestLength) return DigestParseError.InvalidLength;
        return Digest{ .bytes = bytes[0..DigestLength].* };
    }
};

pub const GasCostSummary = struct {
    computation_cost: u64,
    storage_cost: u64,
    storage_rebate: u64,
    non_refundable_storage_fee: u64,

    pub fn gas_used(self: *const GasCostSummary) u64 {
        return self.computation_cost + self.storage_cost;
    }

    pub fn net_gas_usage(self: *const GasCostSummary) i64 {
        const used: i64 = @intCast(self.gas_used());
        const rebate: i64 = @intCast(self.storage_rebate);
        return used - rebate;
    }
};

pub const Version = u64;

pub const TypeTag = union(enum) {
    u8,
    u16,
    u32,
    u64,
    u128,
    u256,
    bool,
    address,
    signer,
    vector: *TypeTag,
    struct_: *StructTag,

    pub fn to_string(self: *const TypeTag) []const u8 {
        return switch (self.*) {
            .u8 => "u8",
            .u16 => "u16",
            .u32 => "u32",
            .u64 => "u64",
            .u128 => "u128",
            .u256 => "u256",
            .bool => "bool",
            .address => "address",
            .signer => "signer",
            .vector => "vector",
            .struct_ => "struct",
        };
    }

    pub fn to_string_alloc(self: *const TypeTag, allocator: std.mem.Allocator) ![]u8 {
        return switch (self.*) {
            .u8 => allocator.dupe(u8, "u8"),
            .u16 => allocator.dupe(u8, "u16"),
            .u32 => allocator.dupe(u8, "u32"),
            .u64 => allocator.dupe(u8, "u64"),
            .u128 => allocator.dupe(u8, "u128"),
            .u256 => allocator.dupe(u8, "u256"),
            .bool => allocator.dupe(u8, "bool"),
            .address => allocator.dupe(u8, "address"),
            .signer => allocator.dupe(u8, "signer"),
            .vector => |inner| blk: {
                const inner_str = try inner.to_string_alloc(allocator);
                defer allocator.free(inner_str);
                break :blk std.fmt.allocPrint(allocator, "vector<{s}>", .{inner_str});
            },
            .struct_ => |tag| std.fmt.allocPrint(allocator, "{s}::{s}", .{ tag.module.as_str(), tag.name.as_str() }),
        };
    }

    pub fn deinit(self: *TypeTag, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .vector => |inner| {
                inner.deinit(allocator);
                allocator.destroy(inner);
            },
            .struct_ => |tag| {
                tag.deinit();
                allocator.destroy(tag);
            },
            else => {},
        }
    }
};

pub const StructTag = struct {
    address: Address,
    module: Identifier,
    name: Identifier,
    typeParams: std.ArrayList(TypeTag),
    allocator: std.mem.Allocator,

    pub fn init(address: Address, module: Identifier, name: Identifier, allocator: std.mem.Allocator) StructTag {
        return StructTag{
            .address = address,
            .module = module,
            .name = name,
            .typeParams = .empty,
            .allocator = allocator,
        };
    }

    pub fn add(self: *StructTag, item: TypeTag) !void {
        try self.typeParams.append(self.allocator, item);
    }

    pub fn addMany(self: *StructTag, items: []const TypeTag) !void {
        try self.typeParams.appendSlice(self.allocator, items);
    }

    pub fn sui(allocator: std.mem.Allocator) !StructTag {
        var address = Address.new();
        try address.from_hex("0x0000000000000000000000000000000000000000000000000000000000000002");
        const module = try Identifier.init_from_str(allocator, "sui");
        const name = try Identifier.init_from_str(allocator, "SUI");

        return StructTag.init(
            address,
            module,
            name,
            allocator,
        );
    }

    pub fn deinit(self: *StructTag) void {
        self.typeParams.deinit(self.allocator);
        self.module.deinit(self.allocator);
        self.name.deinit(self.allocator);
    }
};

pub const MoveStruct = struct {
    type_: StructTag,
    has_public_transfer: bool,
    version: Version,
    contents: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(type_: StructTag, has_public_transfer: bool, version: Version, allocator: std.mem.Allocator) MoveStruct {
        return MoveStruct{
            .type_ = type_,
            .has_public_transfer = has_public_transfer,
            .version = version,
            .contents = .empty,
            .allocator = allocator,
        };
    }

    pub fn add(self: *MoveStruct, items: []const u8) !void {
        try self.contents.appendSlice(self.allocator, items);
    }

    pub fn deinit(self: *MoveStruct) void {
        self.contents.deinit(self.allocator);
        self.type_.deinit();
    }
};

pub const TypeOrigin = struct {
    module_name: Identifier,
    struct_name: Identifier,
    package: Address,
    allocator: std.mem.Allocator,

    pub fn init(module_name: Identifier, struct_name: Identifier, package: Address, allocator: std.mem.Allocator) TypeOrigin {
        return TypeOrigin{ .module_name = module_name, .struct_name = struct_name, .package = package, .allocator = allocator };
    }

    pub fn deinit(self: *TypeOrigin) void {
        self.module_name.deinit(self.allocator);
        self.struct_name.deinit(self.allocator);
    }
};

pub const UpgradeInfo = struct {
    upgraded_id: Address,
    upgraded_version: Version,

    pub fn new(upgraded_id: Address, upgraded_version: Version) UpgradeInfo {
        return UpgradeInfo{
            .upgraded_id = upgraded_id,
            .upgraded_version = upgraded_version,
        };
    }
};

pub const IdentifierContext = struct {
    pub fn hash(self: @This(), id: Identifier) u64 {
        _ = self;
        return std.hash.Wyhash.hash(0, id.bytestring);
    }
    pub fn eql(self: @This(), a: Identifier, b: Identifier) bool {
        _ = self;
        return std.mem.eql(u8, a.bytestring, b.bytestring);
    }
};

pub const MovePackage = struct {
    id: Address,
    version: Version,
    modules: std.HashMap(Identifier, std.ArrayList(u8), IdentifierContext, std.hash_map.default_max_load_percentage),
    type_origin_table: std.ArrayList(TypeOrigin),
    linkage_table: std.AutoHashMap(Address, UpgradeInfo),
    allocator: std.mem.Allocator,

    pub fn init(id: Address, version: Version, allocator: std.mem.Allocator) MovePackage {
        const modules = std.HashMap(Identifier, std.ArrayList(u8), IdentifierContext, std.hash_map.default_max_load_percentage).init(allocator);
        const linkage_table = std.AutoHashMap(Address, UpgradeInfo).init(allocator);

        return MovePackage{
            .id = id,
            .version = version,
            .modules = modules,
            .type_origin_table = .empty,
            .linkage_table = linkage_table,
            .allocator = allocator,
        };
    }

    pub fn addModule(self: *MovePackage, key: Identifier, value: std.ArrayList(u8)) void {
        try self.modules.put(key, value);
    }
    pub fn removeModule(self: *MovePackage, key: Identifier) !void {
        if (self.modules.fetchRemove(key)) |kv| {
            var k = kv.key;
            var v = kv.value;
            k.deinit(self.allocator);
            v.deinit(self.allocator);
        }
    }
    pub fn addLinkage(self: *MovePackage, key: Address, value: UpgradeInfo) void {
        try self.linkage_table.put(key, value);
    }
    pub fn removeLinkage(self: *MovePackage, key: Address) !void {
        _ = self.linkage_table.remove(key);
    }
    pub fn deinit(self: *MovePackage) void {
        var it = self.modules.iterator();

        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }

        self.modules.deinit();

        for (self.type_origin_table.items) |*origin| {
            origin.deinit();
        }

        self.linkage_table.deinit();
    }
};

pub const ObjectData = union(enum) {
    struct_: MoveStruct,
    package: MovePackage,
};

pub const Owner = union(enum) {
    address: Address,
    object: Address,
    shared: Version,
    immutable,
    consensus_address: struct {
        start_version: Version,
        owner: Address,
    },
};

pub const Object = struct {
    data: ObjectData,
    owner: Owner,
    previous_transaction: Digest,
    storage_rebate: u64,

    pub fn new(data: ObjectData, owner: Owner, previous_transaction: Digest, storage_rebate: u64) Object {
        return Object{
            .data = data,
            .owner = owner,
            .previous_transaction = previous_transaction,
            .storage_rebate = storage_rebate,
        };
    }

    pub fn deinit(self: *Object) void {
        switch (self.data) {
            .struct_ => |*s| s.deinit(),
            .package => |*p| p.deinit(),
        }
    }
};

pub const ObjectReference = struct {
    object_id: Address,
    version: Version,
    digest: Digest,

    pub fn new(object_id: Address, version: Version, digest: Digest) ObjectReference {
        return ObjectReference{
            .object_id = object_id,
            .version = version,
            .digest = digest,
        };
    }
};

pub const Mutability = enum {
    Immutable,
    Mutable,
    NonExclusiveWrite,
};

pub const SharedInput = struct {
    object_id: Address,
    version: u64,
    mutability: Mutability,

    pub fn new(object_id: Address, version: u64, mutability: Mutability) SharedInput {
        return SharedInput{
            .object_id = object_id,
            .version = version,
            .mutability = mutability,
        };
    }
};

pub const Reservation = union(enum) {
    Amount: u64,
};
pub const WithdrawalType = union(enum) {
    Balance: TypeTag,
};
pub const WithdrawFrom = enum {
    Sender,
    Sponsor,
};

pub const FundsWithdrawal = struct {
    reservation: Reservation,
    type_: WithdrawalType,
    source: WithdrawFrom,
};

pub const Argument = union(enum) {
    Gas,
    Input: u16,
    Result: u16,
    NestedResult: struct { a: u16, b: u16 },
};

pub const MoveCall = struct {
    package: Address,
    module: Identifier,
    function: Identifier,
    type_arguments: std.ArrayList(TypeTag),
    arguments: std.ArrayList(Argument),
};

pub const TransferObjects = struct {
    objects: std.ArrayList(Argument),
    address: Argument,
};

pub const SplitCoins = struct {
    coin: Argument,
    amounts: std.ArrayList(Argument),
};

pub const MergeCoins = struct {
    coin: Argument,
    coins_to_merge: std.ArrayList(Argument),
};

pub const Publish = struct {
    modules: std.ArrayList(std.ArrayList(u8)),
    dependencies: std.ArrayList(Address),
};

pub const MakeMoveVector = struct {
    type_: ?TypeTag,
    elements: std.ArrayList(Argument),
};

pub const Upgrade = struct {
    modules: std.ArrayList(std.ArrayList(u8)),
    package: Address,
    ticket: Argument,
};

pub const Command = union(enum) {
    MoveCall: MoveCall,
    TransferObjects: TransferObjects,
    SplitCoins: SplitCoins,
    MergeCoins: MergeCoins,
    Publish: Publish,
    MakeMoveVector: MakeMoveVector,
    Upgrade: Upgrade,
};

pub const Input = union(enum) {
    Pure: std.ArrayList(u8),
    ImmutableOrOwned: ObjectReference,
    Shared: SharedInput,
    Receiving: ObjectReference,
    FundsWithdrawal: FundsWithdrawal,
};

pub const ProgrammableTransaction = struct {
    inputs: std.ArrayList(Input),
    commands: std.ArrayList(Command),
};

pub const EpochId = u64;
pub const ProtocolVersion = u64;

pub const SystemPackage = struct {
    version: Version,
    modules: std.ArrayList(std.ArrayList(u8)),
    dependecies: std.ArrayList(Address),
};

pub const ChangeEpoch = struct {
    epoch: EpochId,
    protocol_version: ProtocolVersion,
    storage_charge: u64,
    computation_charge: u64,
    non_refundable_storage: u64,
    epoch_start_timestamp_ms: u64,
    system_packages: std.ArrayList(SystemPackage),
};

pub const GenesisObject = struct {
    data: ObjectData,
    owner: Owner,
};

pub const GenesisTransaction = struct {
    objects: std.ArrayList(GenesisObject),
};

pub const CheckpointTimestamp = u64;
pub const ConsensusCommitPrologue = struct {
    epoch: u64,
    round: u64,
    commit_timestamp_ms: CheckpointTimestamp,
};

pub const JwkId = struct {
    iss: []const u8,
    kid: []const u8,
};

pub const Jwk = struct {
    kty: []const u8,
    e: []const u8,
    n: []const u8,
    alg: []const u8,
};

pub const ActiveJwk = struct {
    jwk_id: JwkId,
    jwk: Jwk,
    epoch: u64,
};

pub const AuthenticatorStateUpdate = struct {
    epoch: u64,
    round: u64,
    new_active_jwks: std.ArrayList(ActiveJwk),
    authenticator_obj_initial_shared_version: u64,
};

pub const AuthenticatorStateExpired = struct {
    min_epoch: u64,
    authenticator_object_initial_shared_version: u64,
};

pub const ExecutionTimeObservationKey = union(enum) {
    MoveEntryPoint: struct {
        package: Address,
        module: []const u8,
        function: []const u8,
        type_arguments: std.ArrayList(TypeTag),
    },
};

pub const Bls12381PublicKey = [96]u8;

pub const ValidatorExecutionTimeObservation = struct {
    validator: Bls12381PublicKey,
    duration: std.Io.Duration,
};

pub const ExecutionTimeObservations = union(enum) {
    V1: std.ArrayList(struct { ExecutionTimeObservationKey, std.ArrayList(ValidatorExecutionTimeObservation) }),
};

pub const EndOfEpochTransactionKind = union(enum) {
    ChangeEpoch: ChangeEpoch,
    AuthenticatorStateCreator,
    AuthenticatorStateExpired: AuthenticatorStateExpired,
    RandomnessStateCreate,
    DenyListStateCreate,
    BridgeStateCreate: struct { chain_id: Digest },
    BridgeCommitteeInit: struct { bridge_object_version: u64 },
    StoreExecutionTimeObservations: ExecutionTimeObservations,
    AccumulatorRootCreate,
    CoinRegistryCreate,
    DisplayRegistryCreate,
    AddressAliasStateCreate,
    WriteAccumulatorStorageCost: struct { storage_cost: u64 },
};

pub const RandomnessStateUpdate = struct {
    epoch: u64,
    randomness: u64,
    random_bytes: std.ArrayList(u8),
    randomness_obj_initial_shared_version: u64,
};

pub const ConsensusCommitPrologueV2 = struct {
    epoch: u64,
    round: u64,
    commit_timestamp_ms: CheckpointTimestamp,
    consensus_commit_digest: Digest,
};
pub const VersionAssignment = struct {
    object_id: Address,
    version: Version,
};
pub const CanceledTransaction = struct {
    digest: Digest,
    vector_assignements: std.ArrayList(VersionAssignment),
};
pub const VersionAssignmentV2 = struct {
    object_id: Address,
    start_version: Version,
    version: Version,
};
pub const CanceledTransactionV2 = struct {
    digest: Digest,
    vector_assignements: std.ArrayList(VersionAssignmentV2),
};

pub const ConsensusDeterminedVersionAssignments = union(enum) {
    CanceledTransactions: struct { canceled_transactions: std.ArrayList(CanceledTransaction) },
    CanceledTransactionsV2: struct { canceled_transactions: std.ArrayList(CanceledTransactionV2) },
};
pub const ConsensusCommitPrologueV3 = struct {
    epoch: u64,
    round: u64,
    sub_dag_index: ?u64,
    commit_timestamp_ms: CheckpointTimestamp,
    consensus_commit_digest: Digest,
    consensus_determined_version_assignments: ConsensusDeterminedVersionAssignments,
};
pub const ConsensusCommitPrologueV4 = struct {
    epoch: u64,
    round: u64,
    sub_dag_index: ?u64,
    commit_timestamp_ms: CheckpointTimestamp,
    consensus_commit_digest: Digest,
    consensus_determined_version_assignments: ConsensusDeterminedVersionAssignments,
    additional_state_digest: Digest,
};

pub const TransactionKind = union(enum) {
    ProgrammableTransaction: ProgrammableTransaction,
    ChangeEpoch: ChangeEpoch,
    Genesis: GenesisTransaction,
    ConsensusCommitPrologue: ConsensusCommitPrologue,
    AuthenticatorStateUpdate: AuthenticatorStateUpdate,
    EndOfEpoch: std.ArrayList(EndOfEpochTransactionKind),
    RandomnessStateUpdate: RandomnessStateUpdate,
    ConsensusCommitPrologueV2: ConsensusCommitPrologueV2,
    ConsensusCommitPrologueV3: ConsensusCommitPrologueV3,
    ConsensusCommitPrologueV4: ConsensusCommitPrologueV4,
    ProgrammableSystemTransaction: ProgrammableTransaction,
};

pub const TransactionExpiration = union(enum) {
    None,
    Epoch: EpochId,
    ValidDuring: struct {
        min_epoch: ?EpochId,
        max_epoch: ?EpochId,
        min_timestamp: ?u64,
        max_timestamp: ?u64,
        chain: Digest,
        nonce: u32,
    },
};

pub const GasPayment = struct {
    objects: std.ArrayList(ObjectReference),
    owner: Address,
    price: u64,
    budget: u64,
};

pub const Transaction = struct {
    kind: TransactionKind,
    sender: Address,
    gas_payment: GasPayment,
    expiration: TransactionExpiration,
};

pub const Ed25519Signature = [64]u8;
pub const Ed25519PublicKey = [32]u8;
pub const Secp256k1Signature = [64]u8;
pub const Secp256k1PublicKey = [33]u8;
pub const Secp256r1Signature = [64]u8;
pub const Secp256r1PublicKey = [33]u8;

pub const SimpleSignature = union(enum) {
    Ed25519: struct {
        signature: Ed25519Signature,
        public_key: Ed25519PublicKey,
    },
    Secp256k1: struct {
        signature: Secp256k1Signature,
        public_key: Secp256k1PublicKey,
    },
    Secp256r1: struct {
        signature: Secp256r1Signature,
        public_key: Secp256r1PublicKey,
    },
};

pub const CircomG1 = [3]Bn254FieldElement;
pub const CircomG2 = [3][2]Bn254FieldElement;

pub const ZkLoginProof = struct {
    a: CircomG1,
    b: CircomG2,
    c: CircomG1,
};

const JwtHeader = struct {
    alg: []const u8,
    kid: []const u8,
    typ: ?[]const u8,
};

pub const ZkLoginClaim = struct {
    value: []const u8,
    index_mod_4: u8,
};

pub const ZkLoginInputs = struct {
    proof_points: ZkLoginProof,
    iss_base64_details: ZkLoginClaim,
    header_base64: []const u8,

    jwt_header: JwtHeader,
    jwk_id: JwkId,
    public_identifier: ZkLoginPublicIdentifier,
};

pub const ZkLoginAuthenticator = struct {
    inputs: ZkLoginInputs,
    max_epoch: EpochId,
    signature: SimpleSignature,
};

pub const PasskeyAuthenticator = struct {
    public_key: Secp256r1PublicKey,
    signature: Secp256r1Signature,
    challenge: std.ArrayList(u8),
    authenticator_data: std.ArrayList(u8),
    client_data_json: []const u8,
};

pub const MultisigMemberSignature = union(enum) {
    Ed25519: Ed25519Signature,
    Secp256k1: Secp256k1Signature,
    Secp256r1: Secp256r1Signature,
    ZkLogin: ZkLoginAuthenticator,
    Passkey: PasskeyAuthenticator,
};
pub const BitmapUnit = u16;
pub const Bitmap = zroaring.Bitmap;
pub const Bn254FieldElement = [32]u8;

pub const ZkLoginPublicIdentifier = struct {
    iss: []const u8,
    address_seed: Bn254FieldElement,
};

pub const PasskeyPublicKey = Secp256r1PublicKey;

pub const MultisigMemberPublicKey = union(enum) {
    Ed25519: Ed25519PublicKey,
    Secp256k1: Secp256k1PublicKey,
    Secp256r1: Secp256r1PublicKey,
    ZkLogin: ZkLoginPublicIdentifier,
    Passkey: PasskeyPublicKey,
};

pub const WeightUnit = u8;
pub const ThresholdUnit = u16;

pub const MultisigMember = struct {
    public_key: MultisigMemberPublicKey,
    weight: WeightUnit,
};

pub const MultisigCommittee = struct {
    members: std.ArrayList(MultisigMember),
    threshold: ThresholdUnit,
};

pub const MultisigAggregatedSignature = struct {
    signatures: std.ArrayList(MultisigMemberSignature),
    bitmap: BitmapUnit,
    legacy_bitmap: ?Bitmap,
    committee: MultisigCommittee,
};

pub const UserSignature = union(enum) {
    Simple: SimpleSignature,
    Multisig: MultisigAggregatedSignature,
    ZkLogin: ZkLoginAuthenticator,
    Passkey: PasskeyAuthenticator,
};

pub const SignedTransaction = struct {
    transaction: Transaction,
    signatures: std.ArrayList(UserSignature),
};

pub const MoveLocation = struct {
    package: Address,
    module: Identifier,
    function: u16,
    instruction: u16,
    function_name: ?Identifier,
};

pub const CommandArgumentError = union(enum) {
    TypeMismatch,
    InvalidBcsBytes,
    InvalidUsageOfPureArgument,
    InvalidArgumentToPrivateEntryFunction,
    IndexOutOfBounds: struct { index: u16 },
    SecondaryIndexOutOfBounds: struct { result: u16, subresult: u16 },
    InvalidResultArity: struct { result: u16 },
    InvalidGasCoinUsage,
    InvalidValueUsage,
    InvalidObjectByValue,
    InvalidObjectByMutRef,
    ConsensusObjectOperationNotAllowed,
    InvalidArgumentArity,
    InvalidTransferObject,
    InvalidMakeMoveVecNonObjectArgument,
    ArgumentWithoutValue,
    CannotMoveBorrowedValue,
    CannotWriteToExtendedReference,
    InvalidReferenceArgument,
};

pub const TypeArgumentError = enum {
    TypeNotFound,
    ConstraintNotSatisfied,
};

pub const PackageUpgradeError = union(enum) {
    UnableToFetchPackage: struct { package_id: Address },
    NotAPackage: struct { object_id: Address },
    IncompatibleUpgrade,
    DigestDoesNotMatch: struct { digest: Digest },
    UnknownUpgradePolicy: struct { policy: u8 },
    PackageIdDoesNotMatch: struct {
        package_id: Address,
        ticket_id: Address,
    },
};

pub const ExecutionError = union(enum) {
    InsufficientGas,
    InvalidGasObject,
    InvariantViolation,
    FeatureNotYetSupported,
    ObjectTooBig: struct {
        object_size: u64,
        max_object_size: u64,
    },
    PackageTooBig: struct {
        object_size: u64,
        max_object_size: u64,
    },
    CircularObjectOwnership: struct { object: Address },
    InsufficientCoinBalance,
    CoinBalanceOverflow,
    PublishErrorNonZeroAddress,
    SuiMoveVerificationError,
    MovePrimitiveRuntimeError: struct { location: ?MoveLocation },
    MoveAbort: struct { location: MoveLocation, code: u64 },
    VmVerificationOrDeserializationError,
    VmInvariantViolation,
    FunctionNotFound,
    ArityMismatch,
    TypeArityMismatch,
    NonEntryFunctionInvoked,
    CommandArgumentError: struct {
        argument: u16,
        kind: CommandArgumentError,
    },
    TypeArgumentError: struct {
        type_argument: u16,
        kind: TypeArgumentError,
    },
    UnusedValueWithoutDrop: struct { result: u16, subresult: u16 },
    InvalidPublicFunctionReturnType: struct { index: u16 },
    InvalidTransferObject,
    EffectsTooLarge: struct { current_size: u64, max_size: u64 },
    PublishUpgradeMissingDependency,
    PublishUpgradeDependencyDowngrade,
    PackageUpgradeError: struct { kind: PackageUpgradeError },
    WrittenObjectsTooLarge: struct {
        object_size: u64,
        max_object_size: u64,
    },
    CertificateDenied,
    SuiMoveVerificationTimedout,
    ConsensusObjectOperationNotAllowed,
    InputObjectDeleted,
    ExecutionCanceledDueToConsensusObjectCongestion: struct {
        congested_objects: std.ArrayList(Address),
    },
    AddressDeniedForCoin: struct { address: Address, coin_type: []const u8 },
    CoinTypeGlobalPause: struct { coin_type: []const u8 },
    ExecutionCanceledDueToRandomnessUnavailable,
    MoveVectorElemTooBig: struct {
        value_size: u64,
        max_scaled_size: u64,
    },
    MoveRawValueTooBig: struct {
        value_size: u64,
        max_scaled_size: u64,
    },
    InvalidLinkage,
    InsufficientFundsForWithdraw,
    NonExclusiveWriteInputObjectModified: struct { object: Address },
};

pub const ExecutionStatus = union(enum) {
    Success,
    Failure: struct {
        error_: ExecutionError,
        command: ?u64,
    },
};

pub const ModifiedAtVersion = struct {
    object_id: Address,
    version: Version,
};

pub const ObjectReferenceWithOwner = struct {
    reference: ObjectReference,
    owner: Owner,
};

pub const TransactionEffectsV1 = struct {
    status: ExecutionStatus,
    epoch: EpochId,
    gas_used: GasCostSummary,
    modified_at_versions: std.ArrayList(ModifiedAtVersion),
    consensus_objects: std.ArrayList(ObjectReference),
    transaction_digest: Digest,
    created: std.ArrayList(ObjectReferenceWithOwner),
    mutated: std.ArrayList(ObjectReferenceWithOwner),
    unwrapped: std.ArrayList(ObjectReferenceWithOwner),
    deleted: std.ArrayList(ObjectReference),
    unwrapped_then_deleted: std.ArrayList(ObjectReference),
    wrapped: std.ArrayList(ObjectReference),
    gas_object: ObjectReferenceWithOwner,
    events_digest: ?Digest,
    dependencies: std.ArrayList(Digest),
};

pub const ObjectIn = union(enum) {
    NotExist,
    Exist: struct {
        version: Version,
        digest: Digest,
        owner: Owner,
    },
};

pub const AccumulatorOperation = enum {
    Merge,
    Split,
};
pub const AccumulatorValue = union(enum) {
    Integer: u64,

    IntegerTuple: struct { u64, u64 },

    EventDigest: std.ArrayList(struct { u64, Digest }),
};

pub const AccumulatorWrite = struct {
    address: Address,
    type_: TypeTag,
    operation: AccumulatorOperation,
    value: AccumulatorValue,
};

pub const ObjectOut = union(enum) {
    NotExist,
    ObjectWrite: struct { digest: Digest, owner: Owner },
    PackageWrite: struct { version: Version, digest: Digest },
    AccumulatorWrite: AccumulatorWrite,
};

pub const IdOperation = enum {
    None,
    Created,
    Deleted,
};

pub const ChangedObject = struct {
    object_id: Address,
    input_state: ObjectIn,
    output_state: ObjectOut,
    id_operation: IdOperation,
};

pub const UnchangedConsensusKind = union(enum) {
    ReadOnlyRoot: struct { version: Version, digest: Digest },
    MutateDeleted: struct { version: Version },
    ReadDeleted: struct { version: Version },
    Canceled: struct { version: Version },
    PerEpochConfig,
};

pub const UnchangedConsensusObject = struct {
    object_id: Address,
    kind: UnchangedConsensusKind,
};

pub const TransactionEffectsV2 = struct {
    status: ExecutionStatus,
    epoch: EpochId,
    gas_used: GasCostSummary,
    transaction_digest: Digest,
    gas_object_index: ?u32,
    events_digest: std.ArrayList(Digest),
    dependencies: std.ArrayList(Digest),
    lamport_version: Version,
    changed_objects: std.ArrayList(ChangedObject),
    unchanged_consensus_objects: std.ArrayList(UnchangedConsensusObject),
    auxiliary_data_digest: ?Digest,
};

pub const TransactionEffects = union(enum) {
    V1: TransactionEffectsV1,
    V2: TransactionEffectsV2,
};

pub const Event = struct {
    package_id: Address,
    module: Identifier,
    sender: Address,
    type_: StructTag,
    contents: std.ArrayList(u8),
};

pub const TransactionEvents = std.ArrayList(Event);
pub const Bls12381Signature = [48]u8;

pub const ValidatorAggregatedSignature = struct {
    epoch: EpochId,
    signature: Bls12381Signature,
    bitmap: Bitmap,
};

pub const StakeUnit = u64;

pub const ValidatorCommitteeMember = struct {
    public_key: Bls12381PublicKey,
    stake: StakeUnit,
};

pub const BalanceChange = struct {
    address: Address,
    coin_type: TypeTag,
    amount: i128,
};

pub const Coin = struct {
    coin_type: TypeTag,
    id: Address,
    balance: u64,
};

pub const Hasher = std.crypto.hash.blake2.Blake2b256;

pub const CheckpointCommitment = union(enum) {
    EcmhLiveObjectSet: struct { digest: Digest },
    CheckpointArtifacts: struct { digest: Digest },
};

pub const CheckpointTransactionInfo = struct {
    transaction: Digest,
    effects: Digest,
    signatures: std.ArrayList(struct { UserSignature, ?u64 }),
};

pub const CheckpointContents = struct {
    version: usize,
    transactions: std.ArrayList(CheckpointTransactionInfo),
};

pub const CheckpointSequenceNumber = u64;

pub const EndOfEpochData = struct {
    next_epoch_committee: std.ArrayList(ValidatorCommitteeMember),
    next_epoch_protocol_version: ProtocolVersion,
    epoch_commitments: std.ArrayList(CheckpointCommitment),
};

pub const CheckpointSummary = struct {
    epoch: EpochId,
    sequence_number: CheckpointSequenceNumber,
    network_total_transactions: u64,
    content_digest: Digest,
    previous_digest: ?Digest,
    epoch_rolling_gas_cost_summary: GasCostSummary,
    timestamp_ms: CheckpointTimestamp,
    checkpoint_commitments: std.ArrayList(CheckpointCommitment),
    end_of_epoch_data: ?EndOfEpochData,
    version_specific_data: std.ArrayList(u8),
};

pub const SignedCheckpointSummary = struct {
    checkpoint: CheckpointSummary,
    signature: ValidatorAggregatedSignature,
};

pub const CheckpointData = struct {
    checkpoint_summary: SignedCheckpointSummary,
    checkpoint_contents: CheckpointContents,
    transactions: std.ArrayList(CheckpointTransactionInfo),
};

pub const CheckpointTransaction = struct {
    transaction: SignedTransaction,
    effects: TransactionEffects,
    events: ?TransactionEvents,
    input_objects: std.ArrayList(Object),
    output_objects: std.ArrayList(Object),
};

pub const IntentScope = enum(usize) {
    TransactionData = 0,
    TransactionEffects = 1,
    CheckpointSummary = 2,
    PersonalMessage = 3,
    SenderSignedTransaction = 4,
    ProofOfPossession = 5,
    HeaderDigest = 6,
    BridgeEventUnused = 7,
    ConsensusBlock = 8,
};

pub const IntentVersion = enum(usize) {
    V0 = 0,
};

pub const IntentAppId = enum(usize) {
    Sui = 0,
    Narwhal = 1,
    Consensus = 2,
};

pub const Intent = struct {
    scope: IntentScope,
    version: IntentVersion,
    app_id: IntentAppId,
};

pub const InvalidZkLoginAuthenticatorError = []const u8;
pub const DigestParseError = base58.Base58Error || error{InvalidLength};
pub const SigningDigest = [32]u8;

pub const SignedTransactionWithIntentMessage = struct {};

pub const ObjectType = union(enum) {
    Package,
    Struct: StructTag,
};

pub const PersonalMessage = std.ArrayList(u8);
pub const Bn254FieldElementParseError = error{
    Empty,
    InvalidDigit,
    PosOverflow,
    NegOverflow,
    Zero,
};

pub const ValidatorCommittee = struct {
    epoch: EpochId,
    members: std.ArrayList(ValidatorCommitteeMember),
};

pub const ValidatorSignature = struct {
    epoch: EpochId,
    public_key: Bls12381PublicKey,
    signature: Bls12381Signature,
};

pub const TypeParseError = struct {
    source: []const u8,
    message: ?[]const u8,
};

pub const SignatureScheme = enum(u8) {
    Ed25519 = 0x00,
    Secp256k1 = 0x01,
    Secp256r1 = 0x02,
    Multisig = 0x03,
    Bls12381 = 0x04, // This is currently not supported for user addresses
    ZkLogin = 0x05,
    Passkey = 0x06,
};

pub const InvalidSignatureScheme = u8;

const DerivedAddressIter = struct {
    primary: ?Address,
    extra: ?Address,
};

const HashingIntent = enum(u8) {
    ChildObjectId = 0xf0,
    RegularObjectId = 0xf1,
};

const SerializedTypeTagVariant = enum(usize) {
    Bool = 0,
    U8 = 1,
    U64 = 2,
    U128 = 3,
    Address = 4,
    Signer = 5,
    Vector = 6,
    Struct = 7,
    U16 = 8,
    U32 = 9,
    U256 = 10,
};

const TypeTagVisitor = struct {};

const BinaryStructTagRef = struct {
    address: Address,
    module: Identifier,
    name: Identifier,
    type_params: TypeTag,
};

const BinaryStructTag = struct {
    address: Address,
    module: Identifier,
    name: Identifier,
    type_params: std.ArrayList(TypeTag),
};

const ReadableAddress = struct {};
const ReadableDigest = struct {};

test "Address" {
    var address = Address.new();
    const a = "0x0000000000000000000000000000000000000000000000000000000000000002";
    try address.from_hex(a);
    try testing.expect(address.bytes.len == AddressLength);
    var hex_buf: [HexEncodedLen]u8 = undefined;
    const b = address.to_hex(&hex_buf);
    try testing.expectEqualStrings(a, b);
}

test "Identifier" {
    const testingAlloc = testing.allocator;
    var identifier = try Identifier.init(testingAlloc, 32);
    defer identifier.deinit(testingAlloc);
    try testing.expectEqual(@as(usize, 32), identifier.bytestring.len);

    const str = "Hello";
    var identifier_str = try Identifier.init_from_str(testingAlloc, str);
    defer identifier_str.deinit(testingAlloc);
    try testing.expectEqual(@as(usize, str.len), identifier_str.bytestring.len);

    try testing.expectEqualStrings(str, identifier_str.as_str());
}

test "Digest" {
    const digestStr = "BibaSN532CJH8vLJVcaDp7bQkG6S5K2gRvMKGJjisr6M";
    const digest = try Digest.from_base58(digestStr);

    var encode_buf: [base58.encodedMaxLen(DigestLength)]u8 = undefined;
    const encoded = try digest.to_base58(&encode_buf);

    try testing.expectEqualStrings(digestStr, encoded);
}

test "GasCostSummary" {
    const gas_cost = GasCostSummary{
        .computation_cost = 100,
        .non_refundable_storage_fee = 20,
        .storage_cost = 5,
        .storage_rebate = 4,
    };

    try testing.expect(gas_cost.gas_used() == 105);
}
// pub const HexDecodeError = enum([]u8) { EmptyInput = "input hex string must be non-empty", InputTooLong = "input hex string is too long for address", InvalidHexCharacter = "input hex string has wrong character" };
