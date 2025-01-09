const std = @import("std");
const meta = @import("meta.zig");
const ScopedLogger = @import("logging.zig").ScopedLogger;

pub const VERSION = "0.1.0";

const bin_dest = "/usr/bin/auto_preempt";

fn checkExists(comptime path: [*:0]const u8) std.fs.Dir.AccessError!bool {
  std.fs.cwd().accessZ(path, .{}) catch |e| return switch (e) {
    std.fs.Dir.AccessError.FileNotFound => false,
    else => e,
  };

  return true;
}

pub const InstallBinResult = enum {
  newerExists,
  sameExists,
  installed,
  updated,
};
pub const InstallBinError = error{
  BadExitStatus
} || std.fs.Dir.AccessError || std.process.Child.RunError || std.fs.Dir.DeleteFileError || std.fs.Dir.CopyFileError;

pub fn installBin() InstallBinError!InstallBinResult {
  const Logger = ScopedLogger(.install_bin);

  Logger.log(.info, "Installing binary as " ++ bin_dest, .{});
  if (checkExists(bin_dest) catch |e| {
    Logger.log(.err, "Failed to check if binary exists: {s}", .{@errorName(e)});
    return e;
  }) {
    var buf: [1 << 10]u8 = undefined;
    var buf_allocator = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = buf_allocator.allocator();
    const result = std.process.Child.run(.{
      .allocator = allocator,
      .argv = &[_][]const u8{bin_dest, "version"},
      .max_output_bytes = 16,
    }) catch |e| {
      Logger.log(.err, "Failed to run auto_preempt version command: {s}", .{@errorName(e)});
      return e;
    };
    if (result.term.Exited != 0) {
      Logger.log(.err, "Failed to get version of auto_preempt, process exited with status {d}", .{result.term.Exited});
      Logger.log(.info, "Process Stdout: {s}", .{ result.stdout });
      Logger.log(.info, "Process Stderr: {s}", .{ result.stderr });
      return InstallBinError.BadExitStatus;
    }

    const is_older: bool = blk: {
      if (result.stdout.len < VERSION.len + 1) {
        Logger.log(.verbose, "Output of auto_preempt version command shorter, therefore version must be older", .{});
        break :blk true; // +1 for newline
      }
      for (0..VERSION.len) |idx| {
        switch (std.math.order(result.stdout[idx], VERSION[idx])) {
          .eq => continue,
          .lt => break :blk true,
          .gt => {
            Logger.log(.warn, "Newer version of auto_preempt is already installed", .{});
            return .newerExists;
          },
        }
      }
      break :blk false;
    };

    if (is_older) {
      Logger.log(.warn, "An older installation was found, updating", .{});
    } else {
      Logger.log(.warn, "Same version of auto_preempt is installed, overriding", .{});
    }
    std.fs.deleteFileAbsoluteZ(bin_dest) catch |e| {
      Logger.log(.err, "Failed to delete old binary: {s}", .{@errorName(e)});
      return e;
    };
    std.fs.copyFileAbsolute("/proc/self/exe", bin_dest, .{}) catch |e| {
      Logger.log(.err, "Old file was deleted but could not install new one !!", .{});
      return e;
    };
    Logger.log(.info, "Updated successfully", .{});
    return .updated;
  }

  Logger.log(.info, "No previous installation found, installing", .{});
  std.fs.copyFileAbsolute("/proc/self/exe", bin_dest, .{}) catch |e| {
    Logger.log(.err, "Failed to install binary: {s}", .{@errorName(e)});
    return e;
  };
  Logger.log(.info, "Successfully installed", .{});
  return .installed;
}

pub fn uninstallBin() std.fs.Dir.DeleteFileError!void {
  const Logger = ScopedLogger(.uninstall_bin);
  Logger.log(.info, "Deleting " ++ bin_dest, .{});
  std.fs.deleteFileAbsoluteZ(bin_dest) catch |e| switch (e) {
    std.fs.Dir.DeleteFileError.FileNotFound => {
      Logger.log(.warn, "File not found, no-op", .{});
      return;
    },
    else => return e,
  };
  Logger.log(.info, "Successfully deleted " ++ bin_dest, .{});
}

pub const GetInitNameError = std.fs.File.OpenError || std.fs.File.ReadError;
fn getInitName() GetInitNameError![]u8 {
  const Static = struct {
    var buf = [_]u8{0} ** 16;
    var len: u8 = 0;
  };
  if (Static.len != 0) return Static.buf[0..Static.len];

  var result = try std.fs.cwd().readFile("/proc/1/comm", &Static.buf);
  if (result[result.len - 1] == '\n') result.len -= 1;

  ScopedLogger(.get_init_name).log(.debug, "Detected init system name: {s}", .{result});

  Static.len = @intCast(result.len);
  return result;
}

// Read for systemd service is cached and hence only done once
pub fn isInitSystem(comptime name: []const u8) GetInitNameError!bool {
  const result = try getInitName();
  if (name.len != result.len) return false;
  return meta.asUint(name.len, name) == meta.asUint(name.len, result);
}

const ExecError = error{
  BadExitStatus
} || std.process.Child.SpawnError;
fn exec(comptime argv: []const []const u8) ExecError!void {
  comptime var command: []const u8 = argv[0];
  inline for (1..argv.len) |idx| command = command ++ " " ++ argv[idx];
  ScopedLogger(.exec).log(.debug, "Executing command: {s}", .{command});

  var buf: [1 << 10]u8 = undefined;
  var buf_allocator = std.heap.FixedBufferAllocator.init(&buf);
  const allocator = buf_allocator.allocator();
  var child = std.process.Child.init(argv, allocator);
  const result = try child.spawnAndWait();
  if (result.Exited != 0) return ExecError.BadExitStatus;
}

pub const CreateServiceError = std.fs.File.OpenError || std.fs.File.WriteError;

pub const Systemd = struct {
  const systemd_service_dest = "/etc/systemd/system/auto_preempt.service";
  const systemd_service_name = "auto_preempt.service";
  const service_text =
    \\[Unit]
    \\Description=Automatically put unused cpu cores to sleep
    \\After=multi-user.target
    \\Wants=multi-user.target
    \\
    \\[Service]
    \\Type=simple
    ++ "\nExecStart=" ++ bin_dest ++ " start normal\n" ++
    \\Restart=always
    \\RestartSec=5
    \\TimeoutSec=5
    \\
    \\StandardOutput=journal
    \\StandardError=journal
    \\
    \\[Install]
    \\WantedBy=multi-user.target
  ;

  const Logger = ScopedLogger(.systemd);

  // Install systemd service unchecked
  pub fn install() CreateServiceError!void {
    Logger.log(.info, "Installing systemd service", .{});
    var file = try std.fs.cwd().createFileZ(systemd_service_dest, .{
      .read = true,
      .exclusive = false,
      .mode = 0o755,
    });
    defer file.close();
    try file.writer().writeAll(service_text);
    Logger.log(.info, "Successfully installed systemd service", .{});
  }
  
  pub fn uninstall() std.fs.Dir.DeleteFileError!void {
    Logger.log(.info, "Uninstalling systemd service", .{});
    Logger.log(.debug, "Removing file {s}", .{systemd_service_dest});
    try std.fs.deleteFileAbsoluteZ(systemd_service_dest);
    Logger.log(.info, "Successfully uninstalled systemd service", .{});
  }

  pub fn check() std.fs.Dir.AccessError!bool {
    const exists = try checkExists(systemd_service_dest);
    ScopedLogger(.systemd_check).log(.debug, "Systemd service {s}", .{if (exists) "exists" else "does not exist"});
    return exists;
  }

  pub fn enable() ExecError!void {
    Logger.log(.info, "Enabling systemd service", .{});
    try exec(&[_][]const u8{"systemctl", "enable", systemd_service_name});
    Logger.log(.info, "Successfully enabled systemd service", .{});
  }
  
  pub fn disable() ExecError!void {
    Logger.log(.info, "Disabling systemd service", .{});
    try exec(&[_][]const u8{"systemctl", "disable", systemd_service_name});
    Logger.log(.info, "Successfully disabled systemd service", .{});
  }

  pub fn start() ExecError!void {
    Logger.log(.info, "Starting systemd service", .{});
    try exec(&[_][]const u8{"systemctl", "start", systemd_service_name});
    Logger.log(.info, "Successfully started systemd service", .{});
  }

  pub fn stop() ExecError!void {
    Logger.log(.info, "Stopping systemd service", .{});
    try exec(&[_][]const u8{"systemctl", "stop", systemd_service_name});
    Logger.log(.info, "Successfully stopped systemd service", .{});
  }
};

