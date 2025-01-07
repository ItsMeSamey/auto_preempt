const std = @import("std");
const builtin = @import("builtin");

pub const LoggingLevelEnum = enum(u4) {
  err = 0,
  warn = 1,
  info = 2,
  debug = 3,
  verbose = 4,

  fn string(self: @This()) []const u8 {
    return switch (self) {
      .err => "error",
      .warn => "warn",
      inline else => |s| @tagName(s),
    };
  }
};

pub fn ScopedLogger(comptime scope: @TypeOf(.enum_literal)) type {
  return struct {
    pub fn log(comptime level: LoggingLevelEnum, comptime format: []const u8, args: anytype) void {
      if (@intFromEnum(level) > @intFromEnum(global_logging_level)) return;

      const destination = switch (level) {
        .err, .warn => std.io.getStdErr().writer(),
        else => std.io.getStdOut().writer(),
      };
      var buffered = std.io.bufferedWriter(destination);
      nosuspend {
        buffered.writer().print(level.string() ++ (if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ") ++ format ++ "\n", args) catch {};
        buffered.flush() catch {};
      }
    }
  };
}

pub const global_logging_level: LoggingLevelEnum = switch (builtin.mode) {
  .Debug => .debug,
  .ReleaseSafe => .info,
  .ReleaseFast, .ReleaseSmall => .warn,
};

