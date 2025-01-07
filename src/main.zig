// Build Cmd: zig build-exe main.zig -OReleaseFast -fstrip -fsingle-threaded -fincremental -flto -mno-red-zone
// TODOS's:
//    Wakeup using poll() instead of busy loop
//    register a handler even if we are unexpectedly killed, and restore the original state in this case
const std = @import("std");
const builtin = @import("builtin");

const LoggingLevelEnum = enum(u4) {
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

fn ScopedLogger(comptime scope: @TypeOf(.enum_literal)) type {
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

const global_logging_level: LoggingLevelEnum = switch (builtin.mode) {
  .Debug => .debug,
  .ReleaseSafe => .info,
  .ReleaseFast, .ReleaseSmall => .warn,
};

// This is to read cpu pressure
// For more info see https://docs.kernel.org/accounting/psi.html
// NOTE: `full` pressure is reported (as 0) since kernel version 5.13 but actually is undefined in case of CPU
const CpuPressure = struct {
  some: CpuPressureResultType,

  pub const CpuPressureResultType = struct {
    avg10: u16,
    avg60: u16,
    avg300: u16,
    total: u64,
  };

  pub const ParseError = error {
    UnexpectedEndOfString,
    WhitespaceNotFount,
    NewlineNotFound,
    InvalidFloatFormat,
  } || std.fmt.ParseIntError;

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

  pub const ReadError = ParseError || std.fs.File.ReadError || std.fs.File.OpenError;
  pub fn readCpuPressure() ReadError!@This() {
    var buf: [64]u8 = undefined;

    const read_result = try std.fs.cwd().readFile("/proc/pressure/cpu", &buf);
    return @This().fromString(read_result);
  }

  pub const SubscribeError = error {
    FileOpenError,
    WriteError,
  };
  // Time limit for window_us is 500ms to 10s
  pub fn subscribe(stall_limit_us: u32, window_us: u32) SubscribeError!std.os.linux.pollfd {
    std.debug.assert(window_us > 500_000);
    std.debug.assert(window_us < 10_00_000);
    std.debug.assert(stall_limit_us < window_us);

    const fd_usize = try std.os.linux.open("/proc/pressure/cpu/cpu0/cpufreq/stats", std.os.linux.O{ .ACCMODE = .RDWR, .NONBLOCK = true}, 0);
    const fd = @as(std.os.linux.fd_t, @bitCast(@as(std.meta.Int(.unsigned, @sizeOf(std.os.linux.fd_t)), @truncate(fd_usize))));
    if (fd < 0) return SubscribeError.FileOpenError;
    var retval: std.os.linux.pollfd = undefined;
    retval.fd = fd;
    retval.events = std.os.linux.POLL.PRI;
    retval.revents = 0;
    errdefer closeSubscription(retval);

    var buf: [6 + 10 + 10 + 1]u8 = undefined; // 6 for ("some " & " "), 10 for stall_limit_us, 10 for window_us + 1 for '\x00'
    const buf_count = std.io.fixedBufferStream(@as([]u8, &buf)).writer().print("some {d} {d}\x00", .{stall_limit_us, window_us}) catch unreachable;
    var count: usize = 0;
    while (count < buf_count) count += try std.os.linux.write(fd, &buf, count);
    if (count > buf_count) return SubscribeError.WriteError;
    return retval;
  }

  pub fn closeSubscription(fd: std.os.linux.fd_t) void {
    std.os.linux.close(fd);
  }

  // can provide a slice or a single item pointer to pollfd struct(s)
  // timeout_ms is in microseconds, 0 means immediate return, negative means infinite wait
  const PollError = error { PollError };
  pub fn waitForPressure(pollfds: anytype, timeout_ms: i32) PollError!void {
    comptime std.debug.assert(@TypeOf(pollfds) == *std.os.linux.pollfd or @TypeOf(pollfds) == []std.os.linux.pollfd);
    const len: usize = if (@TypeOf(pollfds) == *std.os.linux.pollfd) 1 else pollfds.len;
    const ptr: [*]std.os.linux.pollfd = if (@TypeOf(pollfds) == *std.os.linux.pollfd) pollfds else pollfds.ptr;
    const result_usize = std.os.linux.poll(ptr, len, timeout_ms);
    const result = @as(c_int, @bitCast(@as(std.meta.Int(.unsigned, @sizeOf(c_int)), @truncate(result_usize))));
    if (result < 0) return PollError.PollError;
  }
};

test CpuPressure {
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
      CpuPressure{
        .some = .{
          .avg10 = 111,
          .avg60 = 222,
          .avg300 = 333,
          .total = 123,
        },
      },
      try CpuPressure.fromString(s),
    );
  }
}

// The cpu states
const Cpu = struct {
  online_file_name: ?[*:0]const u8,
  online_now: bool,
  initital_state: bool,

  pub const DataError = error {
    NoData,
    UnexpectedData,
    UnexpectedDataLength,
  };

  pub const InitError = DataError || std.fs.Dir.OpenError || std.fs.File.OpenError || std.fs.File.ReadError || std.mem.Allocator.Error;
  const string_online = "online";

  pub fn init(allocator: std.mem.Allocator, dir: []const u8) InitError!@This() {
    var cpu_dir = try std.fs.cwd().openDir(dir, .{});
    defer cpu_dir.close();

    var self: @This() = undefined;
    const online_file_with_error = cpu_dir.openFile(string_online, .{});

    if (online_file_with_error == error.FileNotFound) {
      self.online_file_name = null;
      // Cpu can't be offlined (maybe??: https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-devices-system-cpu)
      self.online_now = true;
    } else {
      const online_file = try online_file_with_error;
      defer online_file.close();

      var output: [3]u8 = undefined; // 2 because we wanna error if file contains more/less than 1 character
      switch (try online_file.readAll(&output)) {
        0 => return InitError.NoData,
        1 => { // Unexpected but ok
          ScopedLogger(.cpu_online_read).log(.debug, "Unexpected format in online file, no trailing newline", .{});
        },
        2 => { // expected
          if (output[1] != '\n') return InitError.UnexpectedData;
        },
        else => return InitError.UnexpectedDataLength,
      }

      const online_file_path = try std.fs.path.joinZ(allocator, &[_][]const u8{dir, string_online});
      errdefer allocator.free(online_file_path);

      self.online_file_name = online_file_path.ptr;
      self.online_now = switch(output[0]) {
        '0' => false,
        '1' => true,
        else => return InitError.UnexpectedData,
      };
    }

    self.initital_state = self.online_now;
    return self;
  }

  pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    if (self.online_file_name) |name| {
      allocator.free(std.mem.sliceTo(name, '\x00'));
    }
  }

  pub const SetOnlineError = std.fs.File.WriteError || std.fs.File.OpenError;

  pub fn setOnlineUnchecked(self: *@This(), online: bool) SetOnlineError!void {
    var online_file = try std.fs.cwd().openFileZ(self.online_file_name.?, .{.mode = .write_only});
    defer online_file.close();
    if (online) {
      try online_file.writeAll(&[_]u8{'1'});
    } else {
      try online_file.writeAll(&[_]u8{'0'});
    }
  }

  // Doesnt do unnecessary write if we are already in the desired state
  pub fn setOnlineChecked(self: *@This(), online: bool) SetOnlineError!void {
    if (self.online_now == online) return;
    return self.setOnlineUnchecked(online);
  }

  pub const GetStateError = DataError || std.fs.File.WriteError;

  pub fn getState(self: *@This()) GetStateError!void {
    if (self.online_file_name) |online_file_name| {
      const online_file = try std.fs.cwd().openFile(online_file_name, .{});
      defer online_file.close();

      var output: [3]u8 = undefined; // 2 because we wanna error if file contains more/less than 1 character
      switch (try online_file.readAll(&output)) {
        0 => return InitError.NoData,
        1 => { // Unexpected but ok
          ScopedLogger(.cpu_online_read).log(.debug, "Unexpected format in online file, no trailing newline", .{});
        },
        2 => { // expected
          if (output[1] != '\n') return InitError.UnexpectedData;
        },
        else => return InitError.UnexpectedDataLength,
      }

      self.online_now = switch(output[0]) {
        '0' => false,
        '1' => true,
        else => return InitError.UnexpectedData,
      };
    }
  }
};

const AllCpus = struct {
  cpu_list: []Cpu,
  sleeping_list: std.ArrayListUnmanaged(*Cpu),
  sleepable_list: std.ArrayListUnmanaged(*Cpu),

  const cpus_dir_name = "/sys/devices/system/cpu/";

  // std.fs.Dir.IteratorError is not marked pub !!
  const IteratorError = error {
      AccessDenied,
      SystemResources,
      InvalidUtf8,
  } || std.posix.UnexpectedError;
  pub const InitError = Cpu.InitError || IteratorError || std.fs.Dir.OpenError || std.mem.Allocator.Error;

  pub fn init(allocator: std.mem.Allocator) InitError!@This() {
    var self: @This() = undefined;

    // This count is probably higher but we dont really care if its higher
    const cpu_length = std.Thread.getCpuCount() catch 32; // randomly chosen fallback value

    var cpu_list = try std.ArrayList(Cpu).initCapacity(allocator, cpu_length);
    errdefer cpu_list.deinit();

    var cpus_dir = try std.fs.cwd().openDir(cpus_dir_name, .{ .iterate = true });
    defer cpus_dir.close();

    var iterator = cpus_dir.iterate();
    while (try iterator.next()) |entry| {
      if (entry.name.len < 4 or @as(u24, @bitCast(entry.name[0..3].*)) != @as(u24, @bitCast([3]u8{'c', 'p', 'u'}))) continue;
      const is_numeric = blk: {
        for (entry.name[3..]) |char| {
          if (char < '0' or '9' < char) break :blk false;
        }
        break :blk true;
      };
      if (!is_numeric) continue;

      ScopedLogger(.cpu_list).log(.info, "Found {s}", .{entry.name});

      const this_cpu_dir_name = try std.fs.path.join(allocator, &[_][]const u8{cpus_dir_name, entry.name});
      defer allocator.free(this_cpu_dir_name);

      const cpu = try Cpu.init(allocator, this_cpu_dir_name);

      if (cpu.online_file_name == null) {
        ScopedLogger(.cpu_list).log(.info, "Setting status of {s} is not supported", .{entry.name});
      } else {
        ScopedLogger(.cpu_list).log(.info, "Cpu {s} is {s}online", .{ entry.name, if (cpu.online_now) "" else "*NOT* " });
      }

      try cpu_list.append(cpu);
    }

    self.cpu_list = try cpu_list.toOwnedSlice();
    errdefer allocator.free(self.cpu_list);
    self.sleeping_list = .{};
    self.sleepable_list = .{};

    var total_count: usize = 0;
    for (self.cpu_list) |entry| {
      if (entry.online_file_name != null) total_count += 1;
    }

    try self.sleeping_list.ensureTotalCapacityPrecise(allocator, total_count);
    errdefer self.sleeping_list.deinit(allocator);

    try self.sleepable_list.ensureTotalCapacityPrecise(allocator, total_count);
    errdefer self.sleepable_list.deinit(allocator);

    for (0..self.cpu_list.len) |idx| {
      const entry_ptr = &self.cpu_list[idx];
      if (entry_ptr.online_file_name == null) continue;
      if (entry_ptr.online_now) {
        self.sleepable_list.appendAssumeCapacity(entry_ptr);
      } else {
        self.sleeping_list.appendAssumeCapacity(entry_ptr);
      }
    }

    return self;
  }

  pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.sleeping_list.deinit(allocator);
    self.sleepable_list.deinit(allocator);

    for (self.cpu_list) |cpu| cpu.deinit(allocator);
    allocator.free(self.cpu_list);
  }

  pub fn regetAllCpuStates(self: *@This()) Cpu.GetStateError!void {
    for (self.cpu_list) |entry| {
      entry.getState();
    }
  }

  pub fn wakeOne(self: *@This()) Cpu.SetOnlineError!void {
    const last = self.sleeping_list.popOrNull() orelse return;
    errdefer self.sleeping_list.appendAssumeCapacity(last);
    try last.setOnlineUnchecked(true);
    self.sleepable_list.appendAssumeCapacity(last);
  }

  pub fn sleepOne(self: *@This()) Cpu.SetOnlineError!void {
    const last = self.sleepable_list.popOrNull() orelse return;
    errdefer self.sleepable_list.appendAssumeCapacity(last);
    try last.setOnlineUnchecked(false);
    self.sleeping_list.appendAssumeCapacity(last);
  }

  pub fn restoreCpuState(self: *@This()) Cpu.SetOnlineError!void {
    var return_error: Cpu.SetOnlineError!void = {};
    for (self.cpu_list) |entry| {
      if (entry.online_file_name == null) continue;
      if (entry.online_now == entry.initital_state) continue;
      entry.setOnlineUnchecked(entry.initital_state) catch |e| {
        ScopedLogger(.cpu_list).log(
          .err,
          "Failed to restore state of {s} to {s}. Error: {!}",
          .{entry.online_file_name.?, if (entry.initital_state) "online" else "offline", e}
        );
        return_error = e;
      };
    }
    return return_error;
  }

  // pub const AdjustSleepingCpusError = Cpu.SetOnlineError || CpuPressure.ReadError;
  // pub fn adjustSleepingCpus(self: *@This()) AdjustSleepingCpusError!void {
  //   const newPressure = try CpuPressure.readCpuPressure();
  //   if (newPressure.some.avg10 > 30_00) {
  //     std.debug.print("Wake 1\n", .{});
  //     try self.wakeOne();
  //   } else if (newPressure.some.avg10 < 2_00) {
  //     std.debug.print("Sleep 1\n", .{});
  //     try self.sleepOne();
  //   }
  // }
};

pub const MakeOomUnkillableError = std.fs.File.OpenError || std.fs.File.WriteError;
pub fn makeOomUnkillable() MakeOomUnkillableError!void {
  var file = try std.fs.cwd().openFileZ("/proc/self/oom_score_adj", .{ .mode = .write_only });
  defer file.close();
  try file.writeAll("-1000\n");
}

pub fn registerSignalHandlers() void {
  const handle_killaction: std.os.linux.Sigaction = .{
    .handler = .{
      .handler = struct {
        fn handler(signal: i32) callconv(.C) void {
          const Logger = ScopedLogger(.signal_handler);

          Logger.log(.warn, "Caught signal {s}", .{@tagName(@as(std.os.linux.SIG, @enumFromInt(signal)))});
          allCpus.restoreCpuState() catch |e| {
            Logger.log(.err, "Cpu state restore failed with error: {!}", .{e});
            Logger.log(.warn, "Exiting", .{});
            std.os.linux.exit(1);
          };
          std.os.linux.exit(0);
        }
      }.handler,
    },
    .flags = 0, // std.os.linux.SA.
    .mask = std.os.linux.filled_sigset, // Block all signals
  };
  const killers = [_]std.os.linux.SIG{
    .HUP,
    .INT,
    .QUIT,
    .ILL,
    .TRAP,
    .ABRT,
    .IOT,
    .BUS,
    .FPE,
    .SEGV,
    .PIPE,
    .TERM,
    .STOP,
    .XCPU,
    .STKFLT,
  };
  inline for (killers) |signal| {
    switch (std.posix.errno(std.os.linux.sigaction(signal, &handle_killaction, null))) {
      .SUCCESS => {},
      // Programmer Error, invalid signal passed to siaction
      .INVAL => unreachable,
      else => unreachable,
    }
  }

  const ignore_action: std.os.linux.Sigaction = .{
    .handler = .{
      .handler = std.os.linux.SIG.IGN,
      .flags = 0,
      .mask = std.os.linux.empty_sigset,
    }
  };
  const ignorables = [_]std.os.linux.SIG{
    .TSTP,
  };
  inline for (ignorables) |signal| {
    switch (std.posix.errno(std.os.linux.sigaction(signal, &ignore_action, null))) {
      .SUCCESS => {},
      // Programmer Error, invalid signal passed to siaction
      .INVAL => unreachable,
      else => unreachable,
    }
  }
}

var allCpus: AllCpus = undefined;

pub fn main() !void {
  try makeOomUnkillable();

  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  defer {
    const leaks = gpa.deinit();
    if (leaks == .leak) {
      @panic("Memory leak detected");
    }
  }
  const allocator = gpa.allocator();

  allCpus = try AllCpus.init(allocator);
  registerSignalHandlers();
  defer allCpus.deinit(allocator);

  while (true) {
    allCpus.adjustSleepingCpus() catch |e| {
      std.debug.print("An Error occurred {!}\n", .{ e });
    };
    std.time.sleep(10 * std.time.ns_per_s);
  }
}

test {
  std.testing.refAllDeclsRecursive(@This());
}

