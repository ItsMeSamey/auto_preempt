const std = @import("std");
const meta = @import("meta.zig");
const CpuPressure = @import("cpu_pressure.zig");
const ScopedLogger = @import("logging.zig").ScopedLogger;

const UNKNOWN = "UNKNOWN";
const cpus_dir_name = "/sys/devices/system/cpu/";
const string_online = "online";

// The cpu states
pub const Cpu = struct {
  /// Path to cpu's online file
  /// ends with \x00 (like c strings)
  online_file_name: [16]u8, // "cpu<number>/online", we allow number to be upto 5 digits long (enough for 2^16 cpus)
  /// true iff this cpu has changeable state, else online_file_name is name of the cpu
  has_online_file: bool,
  /// If the cpu is online currently
  online_now: bool,
  /// What the initial state of the cpu was (to restore on exit)
  initital_state: bool,

  pub const DataError = error {
    NoData,
    UnexpectedData,
    UnexpectedDataLength,
  };

  pub const InitError = DataError || std.fs.Dir.OpenError || std.fs.File.OpenError || std.fs.File.ReadError || std.mem.Allocator.Error;

  pub fn init(dir: []const u8) InitError!@This() {
    var cpu_dir = try std.fs.cwd().openDir(dir, .{});
    defer cpu_dir.close();

    var self: @This() = undefined;
    @memcpy(self.online_file_name[0..dir.len], dir);
    self.online_file_name[dir.len] = '/';
    @memcpy(self.online_file_name[dir.len + 1 ..][0..string_online.len], string_online);
    self.online_file_name[dir.len + 1 + string_online.len] = '\x00';

    const online_file_with_error = cpu_dir.openFileZ(string_online, .{});

    if (online_file_with_error == error.FileNotFound) {
      // Cpu can't be offlined (maybe??: https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-devices-system-cpu)
      self.has_online_file = false;
      self.online_now = true;
      self.initital_state = true;
    } else {
      self.has_online_file = true;
      const online_file = try online_file_with_error;
      defer online_file.close();

      var output: [3]u8 = undefined; // 2 because we wanna error if file contains more/less than 1 character
      switch (try online_file.readAll(&output)) {
        0 => return InitError.NoData,
        1 => { // Unexpected but ok
          ScopedLogger(.cpu_online_read).log(.warn, "Unexpected format in online file, no trailing newline", .{});
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

    self.initital_state = self.online_now;
    return self;
  }

  pub const SetOnlineError = std.fs.File.WriteError || std.fs.File.OpenError;
  pub fn setOnlineUnchecked(self: *@This(), online: bool) SetOnlineError!void {
    var online_file = try std.fs.cwd().openFileZ(@ptrCast(&self.online_file_name), .{.mode = .write_only});
    defer online_file.close();
    const prev_state = self.online_now;
    self.online_now = online;
    errdefer self.online_now = prev_state;
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
    if (self.has_online_file) {
      const online_file = try std.fs.cwd().openFileZ(self.onlineFileName(), .{});
      defer online_file.close();

      var output: [3]u8 = undefined; // 3 because we wanna error/warn if file contains more/less than 2 characters 
      switch (try online_file.readAll(&output)) {
        0 => return InitError.NoData,
        1 => { // Unexpected but ok
          ScopedLogger(.cpu_online_read).log(.warn, "Unexpected format in online file, no trailing newline", .{});
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

  pub fn cpuName(self: *const @This()) []const u8 {
    return (&self.online_file_name)[0..std.mem.indexOfScalar(u8, self.online_file_name[0..], '/') orelse unreachable];
  }

  pub fn onlineFileName(self: *const @This()) [*:0]const u8 {
    return @ptrCast(&self.online_file_name);
  }
};

const CpuIndexList = struct {
  list: [*]u16,
  len: u16,
  cap: u16,

  pub fn init(allocator: std.mem.Allocator, len: u16) !@This() {
    const list = try allocator.alloc(u16, len);
    return .{
      .list = list.ptr,
      .len = 0,
      .cap = len,
    };
  }

  pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    allocator.free(self.list[0..self.cap]);
  }

  pub fn append(self: *@This(), cpu: u16) void {
    std.debug.assert(self.len < self.cap);
    self.list[self.len] = cpu;
    self.len += 1;
  }

  pub fn popOrNull(self: *@This()) ?u16 {
    if (self.len == 0) return null;
    self.len -= 1;
    return self.list[self.len];
  }
};

pub const AllCpus = struct {
  cpu_list: []Cpu,
  sleeping_list:  CpuIndexList,
  sleepable_list: CpuIndexList,


  pub const InitError = std.posix.ChangeCurDirError || Cpu.InitError || std.fs.Dir.Iterator.Error || std.fs.Dir.OpenError || std.mem.Allocator.Error;
  pub fn init(allocator: std.mem.Allocator) InitError!@This() {
    const Logger = ScopedLogger(.cpu_list_init);
    var self: @This() = undefined;
    try std.posix.chdirZ(cpus_dir_name);

    // This count is probably higher but we dont really care if its higher
    const cpu_length = std.Thread.getCpuCount() catch 32; // randomly chosen fallback value

    var cpu_list = try std.ArrayList(Cpu).initCapacity(allocator, cpu_length);
    errdefer cpu_list.deinit();

    var cpus_dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer cpus_dir.close();

    var iterator = cpus_dir.iterate();
    while (try iterator.next()) |entry| {
      if (entry.name.len < 4 or meta.arrAsUint(entry.name[0..3].*) != meta.arrAsUint("cpu")) continue;
      const is_numeric = blk: {
        for (entry.name[3..]) |char| {
          if (char < '0' or '9' < char) break :blk false;
        }
        break :blk true;
      };
      if (!is_numeric) continue;

      Logger.log(.debug, "Found {s}", .{entry.name});
      const cpu = try Cpu.init(entry.name);

      if (cpu.has_online_file) {
        Logger.log(.info, "{s} is {s}online", .{ entry.name, if (cpu.online_now) "" else "*NOT* " });
      } else {
        Logger.log(.info, "{s} does NOT support setting online status", .{entry.name});
      }

      try cpu_list.append(cpu);
    }

    self.cpu_list = try cpu_list.toOwnedSlice();
    errdefer allocator.free(self.cpu_list);

    var total_count: usize = 0;
    for (self.cpu_list) |entry| {
      if (entry.has_online_file) {
        total_count += 1;
        Logger.log(.verbose, "Counting cpu {s}", .{entry.cpuName()});
      } else {
        Logger.log(.verbose, "Skipping cpu {s}", .{entry.cpuName()});
      }
    }
    Logger.log(.verbose, "Total state changeable cpus: {d}", .{total_count});

    self.sleeping_list = try CpuIndexList.init(allocator, @intCast(total_count));
    errdefer self.sleeping_list.deinit(allocator);

    self.sleepable_list = try CpuIndexList.init(allocator, @intCast(total_count));
    errdefer self.sleepable_list.deinit(allocator);

    for (0..self.cpu_list.len) |idx| {
      const entry_ptr = &self.cpu_list[idx];
      if (!entry_ptr.has_online_file) continue;
      if (entry_ptr.online_now) {
        self.sleepable_list.append(@intCast(idx));
      } else {
        self.sleeping_list.append(@intCast(idx));
      }
    }

    return self;
  }

  pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.sleeping_list.deinit(allocator);
    self.sleepable_list.deinit(allocator);
    allocator.free(self.cpu_list);
  }

  pub fn regetAllCpuStates(self: *@This()) Cpu.GetStateError!void {
    for (self.cpu_list) |entry| {
      entry.getState();
    }
  }

  pub fn wakeOne(self: *@This()) Cpu.SetOnlineError!void {
    const last = self.sleeping_list.popOrNull() orelse {
      ScopedLogger(.wake_one_cpu).log(.verbose, "No cpu to wake up", .{});
      return;
    };
    ScopedLogger(.wake_one_cpu).log(.debug, "{s} is waking up", .{self.cpu_list[last].cpuName()});
    errdefer self.sleeping_list.append(last);
    try self.cpu_list[last].setOnlineUnchecked(true);
    self.sleepable_list.append(last);
  }

  pub fn sleepOne(self: *@This()) Cpu.SetOnlineError!void {
    const last = self.sleepable_list.popOrNull() orelse {
      ScopedLogger(.sleep_one_cpu).log(.verbose, "No cpu to sleep", .{});
      return;
    };
    ScopedLogger(.sleep_one_cpu).log(.debug, "{s} is going to sleep", .{self.cpu_list[last].cpuName()});
    errdefer self.sleepable_list.append(last);
    try self.cpu_list[last].setOnlineUnchecked(false);
    self.sleeping_list.append(last);
  }

  pub fn restoreCpuState(self: *@This()) Cpu.SetOnlineError!void {
    var return_error: Cpu.SetOnlineError!void = {};
    const Logger = ScopedLogger(.restore_cpu_state);

    Logger.log(.info, "Restoring cpu state", .{});
    for (self.cpu_list) |*entry| {
      if (!entry.has_online_file) {
        Logger.log(.verbose, "Skipping {s}", .{entry.cpuName()});
        continue;
      }
      if (entry.online_now == entry.initital_state) {
        Logger.log(.debug, "State of {s} is already {s}", .{entry.onlineFileName(), if (entry.initital_state) "online" else "offline"});
        continue;
      }
      Logger.log(.debug, "Restoring state of {s} to {s}", .{entry.onlineFileName(), if (entry.initital_state) "online" else "offline"});
      entry.setOnlineUnchecked(entry.initital_state) catch |e| {
        ScopedLogger(.cpu_list).log(
          .err,
          "Failed to restore state of {s} to {s}. Error: {!}",
          .{entry.onlineFileName(), if (entry.initital_state) "online" else "offline", e}
        );
        return_error = e;
      };
    }
    return return_error;
  }

  pub fn setAllState(self: *@This(), online: bool) Cpu.SetOnlineError!void {
    for (self.cpu_list) |*entry| {
      if (!entry.has_online_file) continue;
      try entry.setOnlineChecked(online);
    }
  }

  pub const AdjustSleepingCpusError = Cpu.SetOnlineError || CpuPressure.ReadError;
  pub fn adjustSleepingCpus(self: *@This()) AdjustSleepingCpusError!void {
    const Logger = ScopedLogger(.adjust_sleeping_cpus);
    Logger.log(.verbose, "Adjusting sleeping cpus", .{});
    const newPressure = try CpuPressure.readCpuPressure();
    if (newPressure.some.avg10 > 30_00) {
      Logger.log(.verbose, "Pressure is high, try to wake one cpu", .{});
      try self.wakeOne();
    } else if (newPressure.some.avg10 < 2_00) {
      Logger.log(.verbose, "Pressure is low, put one cpu to sleep", .{});
      try self.sleepOne();
    } else {
      Logger.log(.verbose, "Pressure is normal, no need to adjust", .{});
    }
  }
};

