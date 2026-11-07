# bitcpy

An esoteric programming language where your only instruction
is to copy bits from one place to another.

ALL memory (including the program counter and the program itself)
is stored in a single array of bits.
The program you write is the starting state of that memory.
At each step, the instruction at the address of the program counter is executed,
which will copy a slice of bits from one place to another,
and then the program counter is incremented.



# Building and Running

To build the bitcpy interpreter yourself, you will need to install
version 0.17.0 of the [Zig compiler](https://ziglang.org/).
Then, simply run
```bash
zig build -Doptimize=safe
```
This will output the bitcpy executable in `zig-out/bin/bitcpy`.

To run a bitcpy program you can run
```bash
bitcpy examples/hello_world.bitcpy
```

To debug a bitcpy program, it can be helpful to display what instructions
are being ran and what the state of the memory looks like:
```bash
bitcpy --tracecmd --tracemem examples/hello_world.bitcpy
```



# Language Specification

## Syntax

When writing a program, you decide what state the memory should start in.
The bits are written in hexadecimal. But note that these are written
from least significant digit to most significant digit.
For example `89ab` will encode the bits `0001 1001 0101 1101`.
These would be addressed from `0x0` at the very left to `0xf` at the very right.

All the memory that you did not specify will be treated like an infinite array of zeros.
However, this extra memory will only actually be allocated once you write to it.

You can also write comments `[ like this ]`.
Note that nesting square brackets does not work, so in `[ a [ b ] c ]`,
the comment will end after the first `]`, not the second one.

All whitespace is ignored.


## Basic execution

At each iteration of the program, the program counter (`pc`) is read from address `0x00` to `0x20`.
The bits from address `pc` to `pc + 0x60` will encode `source`, `dest`, and `count`
(each being `0x20` bits long).

The bits from `source` to `source + count` are called the "source bits".
The bits from `dest` to `dest + count` are called the "destination bits".
The source bits will be copied into the place of the destination bits.
Specifically, after the instruction is done, the destination bits will be whatever
the source bits were before the instruction.
This is true even if the source bits and destination bits overlap.

After that, the program counter is read again (since it may have been modified by the instruction)
then incremented by `0x60` (the width of a single instruction) and finally written back
to the bits at address `0x00` to `0x20`.


## Syscalls

To perform I/O in bitcpy, you can use syscalls, which are inspired by the Linux syscall ABI.
(They are only **inspired** though, so they don't work in the exact same way,
and all your bitcpy programs will work on any operating system.)

The bits from `0x000` to `0x100` are segmented into 8 integers each of length `0x20`,
named `arg0` to `arg7`. `arg0` is the program counter, so it's not used for syscalls.

Whenever you write at least 1 bit into `arg1`, bitcpy will perform a syscall
where the syscall number is `arg1` and its arguments are `arg2` to `arg7`.
When a syscall returns something, that return value will be written to `arg1`.
Whenever the return value has a `1` in the most significant position (address `0x3f`),
it means that an error occurred. The least significant `0x10` bits represent the error code.

Syscalls will always be done after doing the regular bitcpy instruction,
but before incrementing the program counter.

For all the details of specific syscalls, see the `SyscallNumber` type
in [syscall.zig](src/syscall.zig).

The most important syscalls for a simple program are `read`, `write`, and `exit`.
With them, you can read from file descriptor `0` to read from `stdin`
and write to file descriptor `1` to write to `stdout`.
Then, you can exit with a status of `0` for success, or of `1` for an error.
