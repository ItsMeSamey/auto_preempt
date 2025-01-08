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

const InstallBinResult = enum {
  newerExists,
  sameExists,
  installed,
  updated,
};
const InstallBinError = std.fs.Dir.AccessError || std.process.Child.RunError || std.fs.Dir.DeleteFileError || std.fs.Dir.CopyFileError;
pub fn installBin() InstallBinError!InstallBinResult {
  const Logger = ScopedLogger(.install_bin);

  Logger.log(.info, "Installing binary as " ++ bin_dest, .{});
  if (try checkExists(bin_dest)) {
    var buf: [1 << 10]u8 = undefined;
    var buf_allocator = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = buf_allocator.allocator();
    const result = try std.process.Child.run(.{
      .allocator = allocator,
      .argv = &[_][]const u8{"", "version"},
      .max_output_bytes = 16,
    });

    blk: {
      if (result.stdout.len < VERSION.len + 1) break :blk; // +1 for newline
      for (0..VERSION.len) |idx| {
        switch (std.math.order(result.stdout[idx], VERSION[idx])) {
          .eq => continue,
          .lt => break :blk,
          .gt => {
            Logger.log(.warn, "Newer version of auto_preempt is already installed", .{});
            return .newerExists;
          },
        }
        Logger.log(.warn, "Same version of auto_preempt is already installed", .{});
        return .sameExists;
      }
    }

    Logger.log(.warn, "An older installation was found, updating", .{});
    try std.fs.deleteFileAbsoluteZ(bin_dest);
    std.fs.copyFileAbsolute("/proc/self/exe", bin_dest, .{}) catch |e| {
      Logger.log(.err, "Old file was deleted but could not install new one !!", .{});
      return e;
    };
    Logger.log(.info, "Updated successfully", .{});
    return .updated;
  }

  Logger.log(.info, "No previous installation found, installing", .{});
  try std.fs.copyFileAbsolute("/proc/self/exe", bin_dest, .{});
  Logger.log(.info, "Successfully installed", .{});
  return .installed;
}

const GetInitNameError = std.fs.File.OpenError || std.fs.File.ReadError;
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

const CreateServiceError = std.fs.File.OpenError || std.fs.File.WriteError;

pub const Systemd = struct {
  const systemd_service_dest = "/etc/systemd/system/auto_preempt.service";
  const service_text =
    \\[Unit]
    \\Description=Automatically put unused cpu cores to sleep
    \\After=multi-user.target
    \\Wants=multi-user.target
    \\
    \\[Service]
    \\Type=simple
    ++ "ExecStart=" ++ bin_dest ++ " start" ++ 
    \\Restart=always
    \\RestartSec=5
    \\TimeoutSec=5
    \\
    \\[Install]
    \\WantedBy=multi-user.target
  ;

  // Install systemd service unchecked
  pub fn install() CreateServiceError!void {
    var file = try std.fs.cwd().createFileZ(systemd_service_dest, .{
      .read = true,
      .exclusive = true,
      .mode = 0o755,
    });
    defer file.close();
    try file.writer().writeAll(service_text);
  }

  pub fn check() std.fs.Dir.AccessError!void {
    const exists = try checkExists(systemd_service_dest);
    ScopedLogger(.systemd_check).log(.debug, "Systemd service {s}", .{if (exists) "exists" else "does not exist"});
    return ;
  }

  pub fn delete() std.fs.Dir.DeleteFileError!void {
    try std.fs.deleteFileAbsoluteZ(systemd_service_dest);
    ScopedLogger(.systemd_delete).log(.debug, "Successfully deleted systemd service", .{});
  }
};

