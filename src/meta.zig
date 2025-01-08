const std = @import("std");
const builtin = @import("builtin");

fn IntType(len: comptime_int, sliceType: type) type {
  const actualType = std.meta.Elem(switch (@typeInfo(sliceType)) {
    .pointer => |ptr| if (ptr.size == .One) ptr.child else sliceType,
    else => sliceType,
  });
  return std.meta.Int(.unsigned, len * @sizeOf(actualType) * 8);
}

pub fn asUint(comptime len: comptime_int, slice: anytype) IntType(len, @TypeOf(slice)) {
  const pointer, const childType = switch (@typeInfo(@TypeOf(slice))) {
    .pointer => |info| switch (info.size) {
      .One => .{slice, @typeInfo(info.child).array.child}, // pointer to an array
      .Slice => .{slice.ptr, info.child}, // slice
      .Many, .C => .{slice, info.child}, // many pointer
    },
    .array => |info| .{&slice, info.child},
    else => @compileError("Expected a slice or array pointer or array"),
  };
  const nonSentianlPtr: [*]const childType = pointer;
  return @bitCast(nonSentianlPtr[0..len].*);
}

pub fn arrAsUint(array: anytype) IntType(array.len, @TypeOf(array)) {
  return asUint(array.len, array);
}

