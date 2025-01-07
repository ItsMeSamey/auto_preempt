//! This is to read cpu pressure
//! For more info see https://docs.kernel.org/accounting/psi.html
const std = @import("std");
const ScopedLogger = @import("logging.zig").ScopedLogger;

pub const CpuPressureResultType = struct {
  avg10: u16,
  avg60: u16,
  avg300: u16,
  total: u64,
};

some: CpuPressureResultType,
// NOTE: `full` pressure is reported (as 0) since kernel version 5.13 but actually is undefined in case of CPU

pub const ParseError = error {
  UnexpectedEndOfString,
  WhitespaceNotFount,
  NewlineNotFound,
  InvalidFloatFormat,
} || std.fmt.ParseIntError;

fn assertNumeric(char: u8) ParseError!void {
  if (char < '0' or '9' < char) return ParseError.InvalidFloatFormat;
}

fn parseFloatSkip(data_ptr: *[]const u8, comptime to_skip: anytype) ParseError!u16 {
  const data = data_ptr.*;
  if (data.len < 4 + to_skip.len) return ParseError.UnexpectedEndOfString;
  const scalar = to_skip[0];
  const scalar_error = switch (scalar) {
    ' ' => ParseError.WhitespaceNotFount,
    '\n' => ParseError.NewlineNotFound,
    else => unreachable,
  };

  try assertNumeric(data[0]);
  if (data[1] == '.') {
    // Length assertion already done
    try assertNumeric(data[2]);
    try assertNumeric(data[3]);

    if (data[4] != to_skip[0]) return scalar_error;
    data_ptr.* = data[4 + to_skip.len..];

    return 100 * @as(u16, data[0] - '0') + 10 * @as(u16, data[2] - '0') + @as(u16, data[3] - '0');
  } else if (data[2] == '.') {
    if (data.len < 5 + to_skip.len) return ParseError.UnexpectedEndOfString;
    try assertNumeric(data[1]);
    try assertNumeric(data[3]);
    try assertNumeric(data[4]);

    if (data[5] != to_skip[0]) return scalar_error;
    data_ptr.* = data[5 + to_skip.len..];

    return 1000 * @as(u16, data[0] - '0') + 100 * @as(u16, data[1] - '0') + 10 * @as(u16, data[3] - '0') + @as(u16, data[4] - '0');
  } else if (data[3] == '.') {
    if (data.len < 6 + to_skip.len) return ParseError.UnexpectedEndOfString;
    if (@as(u48, @bitCast(data[0..6].*)) != @as(u48, @bitCast([_]u8{'1', '0', '0', '.', '0', '0'}))) return ParseError.InvalidFloatFormat;

    if (data[6] != to_skip[0]) return scalar_error;
    data_ptr.* = data[6 + to_skip.len..];

    return 100_00;
  } else {
    return ParseError.InvalidFloatFormat;
  }
}

pub fn fromString(immutable_data: []const u8) ParseError!@This() {
  const string_prefix = "xxxx avg10=";
  // Preceding space is intentional
  const string_avg60 = " avg60=";
  const string_avg300 = " avg300=";
  const string_total = " total=";

  var data = immutable_data;
  std.debug.assert(std.mem.eql(u8, "some avg10=", immutable_data[0..string_prefix.len]));

  data = data[string_prefix.len..];
  const some_avg10 = try parseFloatSkip(&data, string_avg60);
  const some_avg60 = try parseFloatSkip(&data, string_avg300);
  const some_avg300 = try parseFloatSkip(&data, string_total);
  const some_total_idx = std.mem.indexOfScalar(u8, data, '\n') orelse return ParseError.UnexpectedEndOfString;
  const some_total = data[0..some_total_idx];

  const retval: @This() = .{
    .some = .{
      .avg10 = some_avg10,
      .avg60 = some_avg60,
      .avg300 = some_avg300,
      .total = try std.fmt.parseInt(u64, some_total, 10),
    },
  };

  ScopedLogger(.cpu_pressure_parse).log(.verbose, "Parsed cpu pressure: {any}", .{retval});
  return retval;
}

test fromString {
  const strings_to_parse = [_][]const u8{(
    \\some avg10=1.11 avg60=2.22 avg300=3.33 total=123
    \\full avg10=0.00 avg60=0.00 avg300=0.00 total=0
    \\
  ), (
    \\some avg10=1.11 avg60=2.22 avg300=3.33 total=123
    \\
  )};

  inline for (strings_to_parse) |s| {
    try std.testing.expectEqual(
      @This(){
        .some = .{
          .avg10 = 111,
          .avg60 = 222,
          .avg300 = 333,
          .total = 123,
        },
      },
      try @This().fromString(s),
    );
  }
}

pub const ReadError = ParseError || std.fs.File.ReadError || std.fs.File.OpenError;
pub fn readCpuPressure() ReadError!@This() {
  var buf: [64]u8 = undefined;
  const read_result = try std.fs.cwd().readFile("/proc/pressure/cpu", &buf);
  return @This().fromString(read_result);
}

pub const Subscription = struct {
  pub const InitError = std.posix.OpenError || std.fs.File.WriteError;
  // Time limit for window_us is 500ms to 10s
  pub fn subscribe(stall_limit_us: u32, window_us: u32) InitError!std.posix.pollfd {
    std.debug.assert(window_us >= 500_000);
    std.debug.assert(window_us <= 10_00_000);
    std.debug.assert(stall_limit_us < window_us);

    const retval: std.posix.pollfd = .{
      .fd = try std.posix.openZ("/proc/pressure/cpu", .{ .ACCMODE = .RDWR, .NONBLOCK = true}, 0),
      .events = std.posix.POLL.PRI,
      .revents = 0,
    };
    errdefer close(retval);

    var buf: [6 + 10 + 10 + 1]u8 = undefined; // 6 for ("some " & " "), 10 for stall_limit_us, 10 for window_us + 1 for '\x00'
    var buf_stream = std.io.fixedBufferStream(@as([]u8, &buf));
    buf_stream.writer().print("some {d} {d}\x00", .{stall_limit_us, window_us}) catch unreachable;
    var file = std.fs.File{ .handle = retval.fd };
    try file.writeAll(buf[0..buf_stream.pos]);
    return retval;
  }

  pub fn close(pollfd: std.posix.pollfd) void {
    std.posix.close(pollfd.fd);
  }

  // can provide a slice or a single item pointer to pollfd struct(s)
  // timeout_ms is in microseconds, 0 means immediate return, negative means infinite wait
  pub fn wait(pollfds: anytype, timeout_ms: i32) std.posix.PollError!usize {
    comptime std.debug.assert(@TypeOf(pollfds) == *std.posix.pollfd or @TypeOf(pollfds) == []std.posix.pollfd);
    var fds: []std.posix.pollfd = undefined;
    if (@TypeOf(pollfds) == []std.posix.pollfd) {
      fds = pollfds;
    } else {
      fds.ptr = @ptrCast(pollfds);
      fds.len = 1;
    }
    return std.posix.poll(fds, timeout_ms);
  }
};

