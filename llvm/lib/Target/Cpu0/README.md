# LLVM Cpu0 backend

This tutorial is based on LLVM 15.0.7

Reference:
- [Jonathan2251/lbd](https://github.com/Jonathan2251/lbd)
- [P2Tree/LLVM_for_cpu0](https://github.com/P2Tree/LLVM_for_cpu0)

## How to build

```shell
$ mkdir build && cd build
$ cmake -G Ninja -DCMAKE_BUILD_TYPE=Debug -DLLVM_TARGETS_TO_BUILD=Cpu0 ../llvm
$ ninja
```

After building, we can try the llc command to see Cpu0 Targets:

```
$ build/bin/llc --version
LLVM (http://llvm.org/):
  LLVM version 15.0.7
  DEBUG build with assertions.
  Default target: x86_64-unknown-linux-gnu
  Host CPU: znver2

  Registered Targets:
    cpu0   - Cpu0 (32-bit big endian)
    cpu0el - Cpu0el (32-bit little endian)
```

## Testing

Lit-based regression tests live in `llvm/test/CodeGen/Cpu0/`. Each test file is named after the
tutorial chapter it covers (e.g. `ch4-1-arithmetic.ll` for Chapter 4). Tests are written in LLVM
IR with `; RUN:` and `; CHECK:` directives (FileCheck).

To run all Cpu0 tests:

```shell
$ build/bin/llvm-lit llvm/test/CodeGen/Cpu0/
```

To add a new test, create a `.ll` file under `llvm/test/CodeGen/Cpu0/` with a `; RUN:` line
invoking `llc` and `; CHECK:` lines matching the expected assembly output. Use `volatile` loads
and stores to prevent constant folding.
