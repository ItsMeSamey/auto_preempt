const std = @import("std");
const ScopedLogger = @import("logging.zig").ScopedLogger;

const pid_file = "/run/auto_preempt.pid";

const CheckPidFileExistenceError = error {
  UnexpectedFileSize,
} || std.fs.File.OpenError || std.fs.File.ReadError;
/// Returns pid iff file exists, (process may have been killed by SIGKILL)
fn checkPidFileExistence() CheckPidFileExistenceError!?std.posix.pid_t {
  var file = std.fs.cwd().openFileZ(pid_file, .{}) catch |e| switch (e) {
    error.FileNotFound => {
      ScopedLogger(.check_pid_file_existence).log(.verbose, "No pid file found", .{});
      return null;
    },
    else => return e,
  };
  defer file.close();

  var buf: [@sizeOf(std.posix.pid_t)+1]u8 = undefined;
  const end_index = try file.readAll(&buf);
  if (end_index != @sizeOf(std.posix.pid_t)) return error.UnexpectedFileSize;
  const pid: std.posix.pid_t = @bitCast(buf[0..@sizeOf(std.posix.pid_t)].*);
  ScopedLogger(.check_pid_file_existence).log(.verbose, "Found pid file with pid {d}", .{pid});
  return pid;
}

const CheckProcessExistenceError = CheckPidFileExistenceError || std.posix.AccessError || std.fs.Dir.DeleteFileError;
/// Returns process id iff file and process exists
pub fn getExistingProcessId() CheckProcessExistenceError!?std.posix.pid_t {
  const pid = try checkPidFileExistence() orelse return null;
  var proc_buf: [17]u8 = undefined;
  const name = std.fmt.bufPrint(&proc_buf, "/proc/{d}\x00", .{pid}) catch unreachable;
  ScopedLogger(.get_existing_process_id).log(.verbose, "Checking if {s} exists", .{@as([*:0]const u8, @ptrCast(name.ptr))});
  std.posix.accessZ(@as([*:0]const u8, @ptrCast(name.ptr)), 0) catch |e| switch (e) {
    error.FileNotFound => {
      ScopedLogger(.get_existing_process_id).log(.verbose, "Process {d} not found", .{pid});
      try removePidFile();
      return null;
    },
    else => {
      ScopedLogger(.get_existing_process_id).log(.verbose, "Failed to check if process {d} exists: {s}", .{pid, @errorName(e)});
      return e;
    },
  };

  ScopedLogger(.get_existing_process_id).log(.verbose, "Process {d} exists", .{pid});
  return pid;
}

const CreatePidFileError = error { GetPidFailed } || std.fs.File.OpenError || std.fs.File.WriteError;
// Errors if the pid file already exists
pub fn createPidFile() CreatePidFileError!enum{exists, created} {
  ScopedLogger(.create_pid_file).log(.verbose, "Creating pid file", .{});
  var file = std.fs.cwd().createFileZ(pid_file, .{.read = true, .truncate = false, .exclusive = true}) catch |e| switch (e) {
    error.PathAlreadyExists => {
      ScopedLogger(.create_pid_file).log(.verbose, "Pid file already exists", .{});
      return .exists;
    },
    else => return e,
  };
  defer file.close();

  const pid = std.os.linux.getpid();
  if (pid < 0) return error.GetPidFailed;
  try file.writeAll(std.mem.asBytes(&pid));

  ScopedLogger(.create_pid_file).log(.verbose, "Successfully created pid file with pid {d}", .{pid});
  return .created;
}

/// Does not kill the process, just deletes the file
pub fn removePidFile() std.fs.Dir.DeleteFileError!void {
  ScopedLogger(.remove_pid_file).log(.verbose, "Removing pid file", .{});
  std.fs.cwd().deleteFileZ(pid_file) catch |e| switch (e) {
    error.FileNotFound => {}, // Success anyways
    else => return e,
  };
}

const KillExistingProcessError = std.fs.Dir.DeleteFileError || std.posix.KillError;
pub fn killExistingProcess() !void {
  const pid = try checkPidFileExistence() orelse {
    ScopedLogger(.kill_existing_process).log(.warn, "No process to kill, pid file " ++ pid_file ++ " does not exist", .{});
    return;
  };
  ScopedLogger(.kill_existing_process).log(.info, "Killing process {d}", .{pid});
  std.posix.kill(pid, std.posix.SIG.ILL) catch |e| switch (e) {
    error.ProcessNotFound => {
      ScopedLogger(.kill_existing_process).log(.warn, "Process {d} not found", .{pid});
      return;
    },
    else => return e,
  };
  try removePidFile();
}

pub fn checkProcessExistence() CheckProcessExistenceError!bool {
  return try getExistingProcessId() != null;
}

