const std = @import("std");
const CpuPressure = @import("cpu_pressure.zig");
const ScopedLogger = @import("logging.zig").ScopedLogger;

// The cpu states
pub const Cpu = struct {
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

pub const AllCpus = struct {
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
        ScopedLogger(.cpu_list).log(.info, "{s} does NOT support setting online status", .{entry.name});
      } else {
        ScopedLogger(.cpu_list).log(.info, "{s} is {s}online", .{ entry.name, if (cpu.online_now) "" else "*NOT* " });
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

    for (self.cpu_list) |*cpu| cpu.deinit(allocator);
    allocator.free(self.cpu_list);
  }

  pub fn regetAllCpuStates(self: *@This()) Cpu.GetStateError!void {
    for (self.cpu_list) |entry| {
      entry.getState();
    }
  }

  pub fn wakeOne(self: *@This()) Cpu.SetOnlineError!void {
    const last = self.sleeping_list.popOrNull() orelse return;
    ScopedLogger(.all_cpus).log(.debug, "wake 1 cpu", .{});
    errdefer self.sleeping_list.appendAssumeCapacity(last);
    try last.setOnlineUnchecked(true);
    self.sleepable_list.appendAssumeCapacity(last);
  }

  pub fn sleepOne(self: *@This()) Cpu.SetOnlineError!void {
    const last = self.sleepable_list.popOrNull() orelse return;
    ScopedLogger(.all_cpus).log(.debug, "sleep 1 cpu", .{});
    errdefer self.sleepable_list.appendAssumeCapacity(last);
    try last.setOnlineUnchecked(false);
    self.sleeping_list.appendAssumeCapacity(last);
  }

  pub fn restoreCpuState(self: *@This()) Cpu.SetOnlineError!void {
    var return_error: Cpu.SetOnlineError!void = {};
    const Logger = ScopedLogger(.restore_cpu_state);
    for (self.cpu_list) |*entry| {
      if (entry.online_file_name == null) continue;
      Logger.log(.debug, "Restoring state of {s} to {s}", .{entry.online_file_name.?, if (entry.initital_state) "online" else "offline"});
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

  pub fn setAllState(self: *@This(), online: bool) Cpu.SetOnlineError!void {
    for (self.cpu_list) |*entry| {
      if (entry.online_file_name == null) continue;
      try entry.setOnlineChecked(online);
    }
  }

  pub const AdjustSleepingCpusError = Cpu.SetOnlineError || CpuPressure.ReadError;
  pub fn adjustSleepingCpus(self: *@This()) AdjustSleepingCpusError!void {
    const newPressure = try CpuPressure.readCpuPressure();
    if (newPressure.some.avg10 > 30_00) {
      try self.wakeOne();
    } else if (newPressure.some.avg10 < 2_00) {
      try self.sleepOne();
    }
  }
};

