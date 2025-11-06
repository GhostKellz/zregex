pub const packages = struct {
    pub const @"flare-0.1.1-NK4JaX6MAQBQc-bpbfSy32p6mw3OAU0kV_2L4rhCl_qC" = struct {
        pub const build_root = "/home/chris/.cache/zig/p/flare-0.1.1-NK4JaX6MAQBQc-bpbfSy32p6mw3OAU0kV_2L4rhCl_qC";
        pub const build_zig = @import("flare-0.1.1-NK4JaX6MAQBQc-bpbfSy32p6mw3OAU0kV_2L4rhCl_qC");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"flash-0.3.1-dnj738qSBQDhwSkZ5GoK5IE_aKIjwRGR8730Bgakrkc8" = struct {
        pub const build_root = "/home/chris/.cache/zig/p/flash-0.3.1-dnj738qSBQDhwSkZ5GoK5IE_aKIjwRGR8730Bgakrkc8";
        pub const build_zig = @import("flash-0.3.1-dnj738qSBQDhwSkZ5GoK5IE_aKIjwRGR8730Bgakrkc8");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "zsync", "zsync-0.7.1-KAuhef8qIQApcisOPygXIeE9pC8qzdQL2Jp96JbNQyRm" },
        };
    };
    pub const @"zsync-0.7.1-KAuhef8qIQApcisOPygXIeE9pC8qzdQL2Jp96JbNQyRm" = struct {
        pub const build_root = "/home/chris/.cache/zig/p/zsync-0.7.1-KAuhef8qIQApcisOPygXIeE9pC8qzdQL2Jp96JbNQyRm";
        pub const build_zig = @import("zsync-0.7.1-KAuhef8qIQApcisOPygXIeE9pC8qzdQL2Jp96JbNQyRm");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "flash", "flash-0.3.1-dnj738qSBQDhwSkZ5GoK5IE_aKIjwRGR8730Bgakrkc8" },
    .{ "flare", "flare-0.1.1-NK4JaX6MAQBQc-bpbfSy32p6mw3OAU0kV_2L4rhCl_qC" },
};
