# Compilation

```sh
zig build-exe main.zig -OReleaseFast -fstrip -fsingle-threaded -fincremental -flto -mno-red-zone
```

# Run

```sh
(nohup ./main 2>&1 > /dev/null)&
```

