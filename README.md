# Info

This was a project that I made for an university course and I was pretty proud of it, so I didn't want it be hidden in some private repo for the rest of time.
The git history had to be removed since the old repo also contained other exercices etc. I left [REPORT.md](./REPORT.md) as it has more info about the project.

## Project

If you want to know how the code works I would skip the [main.zig](./src/main.zig) at first, and look at [argparsing.zig](./src/argparsing.zig),
[FSMBuilder.zig](./src/FSMBuilder.zig) and [FSM.zig](./src/FSM.zig).
The hip code can be found at:

- [hip.h](./libs/hip/hip.h)
- [hip.cpp](./libs/hip/hip.cpp).

## Usage

```text
usage: scan [OPTIONS] <signatures.json> [paths...]
       scan [OPTIONS] --stdin <b> <signatures.json>
       scan [OPTIONS] --stdin <s|f> [paths...]

arguments:
  <signatures.json>       Path to the signatures file
  [paths...]              Files or directories to scan

options:
  -i, --stdin <type>      Read from stdin instead of a file
                              s, signatures  - read signatures from stdin
                              b, blob        - read scan target from stdin
                              f, fsm         - read compiled FSM from stdin
                              Note: in s and f mode the signature map isn't available;
                              output will only have the singature id and not whole value

  -e, --export            Compile signatures to FSM and output it to the stdout
                              Note: cannot be combined with scanning, use separately to
                              pre-compile signatures before scanning

  -o, --output <type>     Output format (default: both)
                              l, list   - list matched signatures
                              c, count  - match count
                              b, both   - list and count

  -c, --capacity <num>    GPU list capacity (default: 10)

  -r, --recursive         Scan directories recursively

      --warm-up           Run a GPU warm up, will give more accurate performance metrics.

      --cpu               Run on the CPU instead of the GPU

  -h, --help              Print this help message
```

Example:

```text
scan signatures.json file --capacity 100 --cpu --output c
```

## Testing

You can run the included test with:

```text
zig build test
```

Note that the build option metrics has to be false (Default)! Otherwise tests
will fail!

```text
zig build -Dmetrics=false test
```

You can find the tests at the bottom of [](./src/main.zig "main.zig").

## Building

The project can be build with:

```text
zig build
```

This will build the zig code, but also the hip code and link it together. For
more details check out [](./build.zig "build.zig").

To build and run:

```text
zig build run
```

You can pass arguments to the program with `--`

```text
zig build run -- -h
```

Building with option `-Dmetrics=true`

```text
zig build -Dmetrics=true
```

Will enable the performance metrics, otherwise zig will optimize them away!
example:

```text
FSM BUILD TIME: 4.15117 ms
CPU TIME: 2309.03924 ms
CPU PERF: 0.46502 GB/s
```

## Dependencies

This project depends on zig `0.16.*` compiler, `hipcc` and the system library
`amdhip64`. This project has a flake.nix for those that use nix, it has
everything the project needs.

## LLM Disclosure

`LLM`'s where not used at any point! All research and coding was done by me!
