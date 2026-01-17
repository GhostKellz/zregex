pub const packages = struct {
    pub const @"flare-0.1.3-NK4JaW-LAQADg6oOX2E6Cg7Uz3reUhwNcD5CB4FVbNo4" = struct {
        pub const build_root = "/home/chris/.cache/zig/p/flare-0.1.3-NK4JaW-LAQADg6oOX2E6Cg7Uz3reUhwNcD5CB4FVbNo4";
        pub const build_zig = @import("flare-0.1.3-NK4JaW-LAQADg6oOX2E6Cg7Uz3reUhwNcD5CB4FVbNo4");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"flash-0.3.2-dnj73xqXBQD9VUfAjBgRYQESldNLyod0kn7Ftz753G6h" = struct {
        pub const build_root = "/home/chris/.cache/zig/p/flash-0.3.2-dnj73xqXBQD9VUfAjBgRYQESldNLyod0kn7Ftz753G6h";
        pub const build_zig = @import("flash-0.3.2-dnj73xqXBQD9VUfAjBgRYQESldNLyod0kn7Ftz753G6h");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "zsync", "zsync-0.7.4-KAuheWHdFgCcdMYVBTrJ-COoDjytZBJB8ikII1hJG7gj" },
        };
    };
    pub const @"zsync-0.7.4-KAuheWHdFgCcdMYVBTrJ-COoDjytZBJB8ikII1hJG7gj" = struct {
        pub const build_root = "/home/chris/.cache/zig/p/zsync-0.7.4-KAuheWHdFgCcdMYVBTrJ-COoDjytZBJB8ikII1hJG7gj";
        pub const build_zig = @import("zsync-0.7.4-KAuheWHdFgCcdMYVBTrJ-COoDjytZBJB8ikII1hJG7gj");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "flash", "flash-0.3.2-dnj73xqXBQD9VUfAjBgRYQESldNLyod0kn7Ftz753G6h" },
    .{ "flare", "flare-0.1.3-NK4JaW-LAQADg6oOX2E6Cg7Uz3reUhwNcD5CB4FVbNo4" },
};
