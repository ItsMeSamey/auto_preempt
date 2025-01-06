const std = @import("std");
const builtin = @import("builtin");

const LoggingLevelEnum = enum {
  Verbose,
  Debug,
  Info,
  Warn,
  Error,
};

const CpuPressure = struct {
  some: CpuPressureResultType,
  full: CpuPressureResultType,

  pub const CpuPressureResultType = struct {
    avg10: f32,
    avg60: f32,
    avg300: f32,
    total: u64,
  };

  pub const ParseError = error {
    UnexpectedEndOfString,
    WhitespaceNotFount,
    NewlineNotFound,
  } || std.fmt.ParseFloatError || std.fmt.ParseIntError;

  pub fn fromString(immutable_data: []const u8) ParseError!@This() {
    const string_prefix = "xxxx avg10=";
    // Preceding space is intentional
    const string_avg60 = " avg60=";
    const string_avg300 = " avg300=";
    const string_total = " total=";

    var data = immutable_data;
    std.debug.assert(std.mem.eql(u8, "some avg10=", immutable_data[0..string_prefix.len]));

    data = data[string_prefix.len..];
    const some_avg10  = try splitTillSkip(&data, string_avg60);
    const some_avg60  = try splitTillSkip(&data, string_avg300);
    const some_avg300 = try splitTillSkip(&data, string_total);
    const some_total  = try splitTillSkip(&data, "\nfull avg10=");

    const full_avg10  = try splitTillSkip(&data, string_avg60);
    const full_avg60  = try splitTillSkip(&data, string_avg300);
    const full_avg300 = try splitTillSkip(&data, string_total);
    const full_total  = try splitTillSkip(&data, "\n");

    std.debug.print("some_avg10 = `{s}`, some_avg60 = `{s}`, some_avg300 = `{s}`. some_total = `{s}`\n", .{some_avg10, some_avg60, some_avg300, some_total});
    std.debug.print("full_avg10 = `{s}`, full_avg60 = `{s}`, full_avg300 = `{s}`. full_total = `{s}`\n", .{full_avg10, full_avg60, full_avg300, full_total});

    const retval: @This() = .{
      .some = .{
        .avg10  = try std.fmt.parseFloat(f32, some_avg10),
        .avg60  = try std.fmt.parseFloat(f32, some_avg60),
        .avg300 = try std.fmt.parseFloat(f32, some_avg300),
        .total  = try std.fmt.parseInt(u64, some_total, 10),
      },
      .full = .{
        .avg10  = try std.fmt.parseFloat(f32, full_avg10),
        .avg60  = try std.fmt.parseFloat(f32, full_avg60),
        .avg300 = try std.fmt.parseFloat(f32, full_avg300),
        .total  = try std.fmt.parseInt(u64, full_total, 10),
      },
    };

    std.debug.print("{}\n", .{ retval });
    return retval;
  }

  fn splitTillSkip(data_ptr: *[]const u8, comptime to_skip: anytype) ![]const u8 {
    const scalar = to_skip[0];
    const ind = std.mem.indexOfScalar(u8, data_ptr.*, scalar) orelse return switch (scalar) {
      ' ' => ParseError.WhitespaceNotFount,
      '\n' => ParseError.NewlineNotFound,
      else => unreachable,
    };

    // std.debug.assert(std.meta.eql(data_ptr.*[ind..][0..to_skip.len], to_skip));
    std.testing.expectEqualStrings(data_ptr.*[ind..][0..to_skip.len], to_skip) catch unreachable;

    const retval = data_ptr.*[0..ind];
    data_ptr.* = data_ptr.*[ind+to_skip.len..];
    return retval;
  }

  pub const ReadCpuPressureError = ParseError || std.fs.File.ReadError || std.fs.File.OpenError;
  pub fn readCpuPressure() ReadCpuPressureError!@This() {
    var buf: [128]u8 = undefined;

    const read_result = try std.fs.cwd().readFile("/proc/pressure/cpu", &buf);
    return @This().fromString(read_result);
  }
};

test CpuPressure {
  const string_to_parse = (
    \\some avg10=1.11 avg60=2.22 avg300=3.33 total=123
    \\full avg10=4.44 avg60=5.55 avg300=6.66 total=456
    \\
  );

  try std.testing.expectEqual(
    CpuPressure{
      .some = .{
        .avg10 = 1.11,
        .avg60 = 2.22,
        .avg300 = 3.33,
        .total = 123,
      },
      .full = .{
        .avg10 = 4.44,
        .avg60 = 5.55,
        .avg300 = 6.66,
        .total = 456,
      }
    },
    try CpuPressure.fromString(string_to_parse),
  );
}

const DebugBool = struct {
  state: if (builtin.mode == .Debug) bool else void = if (builtin.mode == .Debug) false else .{},

  pub fn set(self: *@This()) void {
    if (builtin.mode == .Debug) {
      self.state = true;
    }
  }
  pub fn unset(self: *@This()) void {
    if (builtin.mode == .Debug) {
      self.state = false;
    }
  }
};

const Cpu = struct {
  dir_name: []const u8,
  // Trur if online file exists (if this cpu can be offlined)
  online_file_name: ?[]const u8,
  online_now: bool,

  cpufreq: CpuFreq = .{},

  freed: DebugBool = .{},

  // TODO: Maybe implement this
  const CpuFreq = struct{};

  pub const DataError = error {
    UnexpectedData,
    UnexpectedDataLength,
  };

  pub const InitError = DataError || std.fs.File.OpenError || std.fs.File.ReadError || std.mem.Allocator.Error;

  pub fn init(allocator: std.mem.Allocator, dir: []const u8, cpu_dir: std.fs.Dir) InitError!@This() {
    var self: @This() = undefined;
    const online_file_with_error = cpu_dir.openFile("online", .{});

    if (online_file_with_error == error.FileNotFound) {
      self.dir_name = try allocator.dupe(u8, dir);
      errdefer allocator.free(self.dir_name);

      self.online_file_name = null;
      // TODO: Figure out if this needs to be changed
      self.online_now = true;
    } else {
      const online_file = try online_file_with_error;
      defer online_file.close();

      var output: [2]u8 = undefined; // 2 because we wanna error if file contains more/less than 1 character
      if (try online_file.readAll(&output) != 1) return InitError.UnexpectedDataLength;

      const online_file_path = try std.fs.path.join(allocator, &[_][]const u8{dir, "online"});
      errdefer allocator.free(online_file_path);

      self.dir_name = online_file_path[0..dir.len];
      self.online_file_name = online_file_path;
      self.online_now = switch(output[0]) {
        '0' => false,
        '1' => true,
        else => return InitError.UnexpectedData,
      };
    }

    return self;
  }

  pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    std.debug.assert(self.freed.state == false);
    defer self.freed.set();

    if (self.online_file_name) |name| {
      allocator.free(name);
    } else {
      allocator.free(self.dir_name);
    }
  }

  pub const SetOnlineError = std.fs.File.WriteError || std.fs.File.OpenError;

  pub fn setOnlineUnchecked(self: *@This(), online: bool) SetOnlineError!void {
    std.debug.assert(self.freed.state == false);
    std.debug.assert(self.online_file_name != null);

    var online_file = try std.fs.cwd().openFile(self.online_file_name.?, .{.mode = .write_only});
    defer online_file.close();
    if (online) {
      try online_file.writeAll(&[_]u8{'1'});
    } else {
      try online_file.writeAll(&[_]u8{'0'});
    }

    if (builtin.mode == .Debug) {
    }
  }

  pub fn setOnline(self: *@This(), online: bool) SetOnlineError!void {
    std.debug.assert(self.freed.state == false);
    std.debug.assert(self.online_file_name != null);

    if (self.online_now == online) return;
    return self.setOnlineUnchecked(online);
  }

  pub const GetStateError = DataError || std.fs.File.WriteError;

  pub fn getState(self: *@This()) GetStateError!void {
    if (self.online_file_name) |online_file_name| {
      const online_file = try std.fs.cwd().openFile(online_file_name, .{});
      defer online_file.close();

      var output: [2]u8 = undefined; // 2 because we wanna error if file contains more/less than 1 character
      if (try online_file.readAll(&output) != 1) return InitError.UnexpectedDataLength;

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

  freed: DebugBool = .{},

  const cpus_dir_name = "/sys/devices/system/cpu/";


  // std.fs.Dir.IteratorError is not marked pub !!
  const IteratorError = error{
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
      if (entry.name.len < 3 or entry.name[0..3] != ("cpu")[0..3]) continue;
      const remaining_name = entry.name[3..];
      const is_numeric = blk: {
        for (remaining_name) |char| {
          if (char < '0' or '9' < char) break :blk false;
        }
        break :blk true;
      };
      if (!is_numeric) continue;

      const this_cpu_dir_name = try std.fs.path.join(allocator, &[_][]const u8{cpus_dir_name, entry.name});
      defer allocator.free(this_cpu_dir_name);

      var this_cpu_dir = try cpus_dir.openDir(entry.name, .{});
      defer this_cpu_dir.close();

      try cpu_list.append(try Cpu.init(allocator, this_cpu_dir_name, this_cpu_dir));
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
    std.debug.assert(self.freed.state == false);
    self.freed.set();

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

  pub const AdjustSleepingCpusError = Cpu.SetOnlineError || CpuPressure.ReadCpuPressureError;
  pub fn adjustSleepingCpus(self: *@This()) AdjustSleepingCpusError!void {
    const newPressure = try CpuPressure.readCpuPressure();
    if (newPressure.full.avg10 > 15) {
      std.debug.print("Wake 2\n", .{});
      try self.wakeOne();
      try self.wakeOne();
    } else if (newPressure.some.avg10 > 30) {
      std.debug.print("Wake 1\n", .{});
      try self.wakeOne();
    } else if (newPressure.some.avg10 < 0.1) {
      std.debug.print("Sleep 2\n", .{});
      try self.sleepOne();
      try self.sleepOne();
    } else if (newPressure.some.avg10 < 5) {
      std.debug.print("Sleep 1\n", .{});
      try self.sleepOne();
    }
  }

  fn wakeOne(self: *@This()) Cpu.SetOnlineError!void {
    const last = self.sleeping_list.popOrNull() orelse return;
    errdefer self.sleeping_list.appendAssumeCapacity(last);
    try last.setOnlineUnchecked(true);
    self.sleepable_list.appendAssumeCapacity(last);
  }

  fn sleepOne(self: *@This()) Cpu.SetOnlineError!void {
    const last = self.sleepable_list.popOrNull() orelse return;
    errdefer self.sleepable_list.appendAssumeCapacity(last);
    try last.setOnlineUnchecked(false);
    self.sleeping_list.appendAssumeCapacity(last);
  }
};


pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  defer {
    const leaks = gpa.deinit();
    if (leaks == .leak) {
      @panic("A memory leak detected");
    }
  }
  const allocator = gpa.allocator();

  var all: AllCpus = try AllCpus.init(allocator);
  defer all.deinit(allocator);

  while (true) {
    all.adjustSleepingCpus() catch |e| {
      std.debug.print("An Error occurred {!}\n", .{ e });
    };
    std.time.sleep(1 * std.time.ns_per_s);
  }
}

// var stdout_buffer: std.io.BufferedWriter(1 << 12, std.fs.File.Writer) = undefined;
//
// fn init() void {
//   const stdout_file = std.io.getStdOut().writer();
//   stdout_buffer = std.io.bufferedWriter(stdout_file);
//   stdout = stdout_buffer.writer();
// }
//
// var stdout: @TypeOf(stdout_buffer).Writer = undefined;
// // var allocator: std.mem.Allocator = undefined;

test {
  std.testing.refAllDeclsRecursive(@This());
}

