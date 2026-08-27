# bignum-div-burnikel

[![C/ASM CI](https://github.com/kirill-bayborodov/bignum-div-burnikel/actions/workflows/ci.yml/badge.svg)](https://github.com/kirill-bayborodov/bignum-div-burnikel/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/v/release/kirill-bayborodov/bignum-div-burnikel?label=release)](https://github.com/kirill-bayborodov/bignum-div-burnikel/releases/latest)

`bignum-div-burnikel` is a C11/x86-64 YASM module that computes quotient and remainder for fixed-capacity unsigned `bignum_t` values. The production path uses a block-recursive Burnikel--Ziegler decomposition under the System V AMD64 ABI. Inputs are validated before publication and both caller-owned outputs remain unchanged on error.

The module is a production component of the `bignum-lib` family and preserves its build, test, distribution, benchmark and documentation conventions.

## Distribution

The required `bignum-core` component is included as a Git submodule at `libs/bignum-core`. The Makefile links only the dependencies declared by this repository and does not require unrelated arithmetic modules.

| Component | Expected location | Purpose |
|---|---|---|
| `bignum-core` | `libs/bignum-core` | Defines `bignum_t`, `BIGNUM_CAPACITY`, and common primitives |
| `benchmark-framework v1.0.0` | `libs/benchmark-framework/dist` | Pinned C11 distribution with public header, static library, matrix/statistics tools, profiles, and documentation |

Clone the repository with its submodule:

```bash
git clone --recurse-submodules https://github.com/kirill-bayborodov/bignum-div-burnikel.git
cd bignum-template
```

For an existing clone, initialize all submodules with:

```bash
git submodule update --init --recursive
```

Before running benchmark targets, ensure that `libs/benchmark-framework/dist` contains `benchmark_framework.h`, `libbenchmark_framework.a`, and the matrix/statistics tools.

## Features

- **Production ASM path:** x86-64 YASM implementation for the System V AMD64 ABI.
- **Explicit API status:** the public API exposes `bignum_div_burnikel_status_t` rather than reusing a generic core status type.
- **Block-recursive division:** high and low word blocks are divided recursively, then the partial remainder is combined with the lower block.
- **Transactional outputs:** validation and arithmetic complete before quotient and remainder are published.
- **Normalized representation:** successful operations update `len` and remove leading zero words.
- **Deterministic verification:** unit, boundary, extended, multithreaded, and integration-runner tests are included.
- **Reproducible benchmarks:** ST and MT runners accept deterministic seeds, report data fingerprints and checksums, and support legacy and parameterized workloads.
- **Pinned C11 benchmark framework:** CI installs the latest successful public `v1.0.0` distribution under `libs/benchmark-framework/dist`; the project consumes its public header, static library, matrix/statistics tools, profiles, and documentation as a library artifact.
- **Bignum domain adapter:** `benchmarks/adapter/` maps generic transport fields to bignum-specific `blocks-*` and operand-length semantics without relabelling them as unrelated operations.
- **Template benchmark protocol:** successful runners print a machine-readable `benchmark=...` line immediately before `Benchmark finished.`.
- **Perf workflow:** Makefile targets provide sampling, repeated counter measurements, cloud-compatible software-event measurements, and report retention.

## Dependencies

| Dependency | Purpose |
|---|---|
| `make` | Build, test, lint, benchmark, and distribution targets |
| `gcc` | C compilation and linking |
| `yasm` | x86-64 assembly compilation |
| `cppcheck` | Static analysis |
| `perf` | Performance counters and sampling profiles |
| `taskset` | CPU-affinity control for benchmarks |
| `valgrind` | Helgrind race-detection target |
| `pthread` | Multithreaded tests and benchmarks |

The cloud benchmark target expects a `perf` binary compatible with the running kernel. In the current container workflow, this binary is configured by the `PERF` Makefile variable and is typically installed at `/usr/local/bin/perf`.

## API

The public API is declared in `include/bignum_div_burnikel.h` and computes both quotient and remainder:

```c
typedef enum bignum_div_burnikel_status {
    BIGNUM_DIV_BURNIKEL_OK = 0,
    BIGNUM_DIV_BURNIKEL_ERR_NULL_PTR = -1,
    BIGNUM_DIV_BURNIKEL_ERR_DIVISION_BY_ZERO = -2,
    BIGNUM_DIV_BURNIKEL_ERR_BUFFER_OVERLAP = -3,
    BIGNUM_DIV_BURNIKEL_ERR_BAD_LENGTH = -4,
    BIGNUM_DIV_BURNIKEL_ERR_OVERFLOW = -5
} bignum_div_burnikel_status_t;

bignum_div_burnikel_status_t bignum_div_burnikel(
    const bignum_t *dividend,
    const bignum_t *divisor,
    bignum_t *quotient,
    bignum_t *remainder);
```

### Contract

| Condition | Return value | Result |
|---|---|---|
| Any required pointer is `NULL` | `BIGNUM_DIV_BURNIKEL_ERR_NULL_PTR` | No object is dereferenced and outputs remain unchanged |
| Valid non-zero divisor and representable operands | `BIGNUM_DIV_BURNIKEL_OK` | Quotient and remainder are normalized and committed |
| `divisor` represents zero | `BIGNUM_DIV_BURNIKEL_ERR_DIVISION_BY_ZERO` | Both outputs remain unchanged |
| Invalid pointer, length, or output overlap | Named `BIGNUM_DIV_BURNIKEL_ERR_*` status | Both outputs remain unchanged |

The operation is thread-safe when independent threads use non-overlapping objects. It does not modify either input and commits quotient/remainder only after successful completion.

For example:

```c
#include <stdint.h>
#include "bignum_div_burnikel.h"

typedef enum {
    APPLICATION_STATUS_SUCCESS = 0,
    APPLICATION_STATUS_DIVISION_ERROR = 1
} application_status_t;

application_status_t divide_value(const bignum_t *dividend,
                                  const bignum_t *divisor,
                                  bignum_t *quotient,
                                  bignum_t *remainder)
{
    bignum_div_burnikel_status_t status =
        bignum_div_burnikel(dividend, divisor, quotient, remainder);

    return status == BIGNUM_DIV_BURNIKEL_OK
        ? APPLICATION_STATUS_SUCCESS
        : APPLICATION_STATUS_DIVISION_ERROR;
}
```

## Build and test

Build the release object and source submodules:

```bash
make build CONFIG=release
```

The production object is generated at:

```text
build/bignum_div_burnikel.o
```

Run the deterministic, extended, multithreaded, and integration-runner suite:

```bash
make test CONFIG=release
```

The expected summary is:

```text
=== Summary: 0 / 5 failed ===
```

Run static analysis and the documentation quality gate:

```bash
make lint
doxygen docs/Doxyfile
```

The versioned `docs/Doxyfile` generates HTML under `build/docs/html/`, enables Graphviz dependency graphs, treats warnings as errors, and filters YASM comments without attempting to parse assembly instructions as C.

Run the sanitizer and race-detection targets:

```bash
make clean
make test_sanitize SAN=address CONFIG=debug

make clean
make test_sanitize SAN=undefined CONFIG=debug

make clean
make test_helgrind CONFIG=debug
```

The test files are organized as follows:

| File | Scope |
|---|---|
| `tests/test_bignum_div_burnikel.c` | Deterministic API, contract, and boundary tests |
| `tests/test_bignum_div_burnikel_extra.c` | Extended state, preservation, and boundary checks |
| `tests/test_bignum_div_burnikel_mt.c` | Concurrent independent-object checks |
| `tests/test_bignum_div_burnikel_runner.c` | Distribution integration smoke test |
| `tests/benchmark_adapter/test_bignum_div_burnikel_benchmark_adapter.c` | C11 transport mapping, validation, deterministic initialization, operation, and checksum tests |

## Benchmarks

The active benchmark sources are:

```text
benchmarks/bench_bignum_div_burnikel.c
benchmarks/bench_bignum_div_burnikel_mt.c
```

Each successful run reports the selected mode, seed, input fingerprint, checksum, successful-call count, elapsed time, and nanoseconds per call. Its final two lines follow this stable protocol:

```text
benchmark=bignum_div_burnikel_st ... elapsed_seconds=<seconds> ns_per_call=<nanoseconds>
Benchmark finished.
```

The MT runner uses `benchmark=bignum_div_burnikel_mt`. The trailing marker is the success condition checked by the Makefile; it must remain after the machine-readable line.

| Mode | Input pattern | Purpose |
|---|---|---|
| `all_zero` | Every input `bignum_t` is zero; the quotient/remainder operation receives zero-valued operands | Measures the zero-value fast path |
| `all_nonzero` | Inputs are populated through `BIGNUM_CAPACITY` words with nonzero top words | Measures the normal nonzero blocks path |
| `mixed` | Alternating zero and nonzero input rows | Measures a mixed workload and branch behavior |

### Single-thread CLI

```text
bin/bench_bignum_div_burnikel \
  [--data-mode all_zero|all_nonzero|mixed] \
  [--input-kind zero|nonzero|mixed] \
  [--operation-kind blocks-zero|blocks-bit|blocks-word|blocks-combined|blocks-random|blocks-mixed] \
  [--measure-mode end-to-end|kernel-only] \
  [--size-profile one|quarter|half|variable|near-capacity] \
  [--capacity-profile normal|near-capacity] \
  [--iterations N] [--warmup N] [--data-count N] [--seed N]
```

`--data-mode` preserves the three legacy scenarios. The independent `--input-kind`, `--operation-kind`, and `--size-profile` parameters select a custom profile and report `data_mode=custom`. `operation_kind` is a generic transport name, but the bignum adapter accepts only documented `blocks-*` vocabulary and maps it to the actual bignum blocks path.

| Variable | Default | Meaning |
|---|---:|---|
| `BENCH_ITERATIONS` | `2000000000` | Number of ST calls; must be positive |
| `BENCH_WARMUP` | `10000` | Calls completed before the timed ST interval |
| `BENCH_DATA_COUNT` | `4096` | Size of the pre-generated immutable data pool |
| `BENCH_SEED` | `0x9E3779B97F4A7C15` | Seed for deterministic pre-generated data |
| `BENCH_INPUT_KIND` | `nonzero` | `zero`, `nonzero`, or `mixed` input profile |
| `BENCH_OPERATION_KIND` | `blocks-random` | `blocks-zero`, `blocks-bit`, `blocks-word`, `blocks-combined`, `blocks-random`, or `blocks-mixed` bignum operation transport value |
| `BENCH_MEASURE_MODE` | `end-to-end` | `end-to-end` includes per-call preparation; `kernel-only` excludes workspace restoration from the accumulated interval |
| `BENCH_SIZE_PROFILE` | `variable` | `one`, `quarter`, `half`, `variable`, or `near-capacity` bignum operand-length profile |
| `BENCH_CAPACITY_PROFILE` | `normal` | `normal` or `near-capacity`; the latter creates a valid boundary operand without intentionally measuring overflow handling |

CLI options override the corresponding environment variables. Example controlled ST comparison:

```bash
./bin/bench_bignum_div_burnikel \
  --input-kind nonzero --operation-kind blocks-combined --size-profile half \
  --measure-mode end-to-end \
  --iterations 1000000 --warmup 10000 --data-count 4096 \
  --seed 123456789

./bin/bench_bignum_div_burnikel \
  --input-kind nonzero --operation-kind blocks-combined --size-profile half \
  --measure-mode kernel-only \
  --iterations 1000000 --warmup 10000 --data-count 4096 \
  --seed 123456789
```

### Multithread CLI

```text
bin/bench_bignum_div_burnikel_mt \
  [--threads N] [--total-iterations N] \
  [--data-mode all_zero|all_nonzero|mixed] \
  [--input-kind zero|nonzero|mixed] \
  [--operation-kind blocks-zero|blocks-bit|blocks-word|blocks-combined|blocks-random|blocks-mixed] \
  [--measure-mode end-to-end|kernel-only] \
  [--size-profile one|quarter|half|variable|near-capacity] \
  [--capacity-profile normal|near-capacity] \
  [--warmup N] [--data-count N] [--seed N]
```

MT workers are created once, complete warm-up before the timed interval, then synchronize through barriers. `kernel-only` reports the longest per-worker accumulated operation interval, excluding the restoration copy before each batch; `end-to-end` reports wall-clock time from the synchronized release through all workers' completion.

| Variable | Default | Meaning |
|---|---:|---|
| `BENCH_MT_TOTAL_ITERATIONS` | `3200000000` | Total work across all threads; must be positive and divisible by the thread count |
| `BENCH_MT_THREADS` | `2` | Number of benchmark worker threads; must be positive |
| `BENCH_WARMUP` | `10000` | Warm-up calls per worker before the measured interval |
| `BENCH_DATA_COUNT` | `4096` | Size of the shared immutable data pool |
| `BENCH_SEED` | `0x9E3779B97F4A7C15` | Seed for deterministic pre-generated data |
| `BENCH_INPUT_KIND` | `nonzero` | `zero`, `nonzero`, or `mixed` input profile |
| `BENCH_OPERATION_KIND` | `blocks-random` | `blocks-zero`, `blocks-bit`, `blocks-word`, `blocks-combined`, `blocks-random`, or `blocks-mixed` bignum operation transport value |
| `BENCH_MEASURE_MODE` | `end-to-end` | `end-to-end` or `kernel-only` measurement mode |
| `BENCH_SIZE_PROFILE` | `variable` | `one`, `quarter`, `half`, `variable`, or `near-capacity` bignum operand-length profile |
| `BENCH_CAPACITY_PROFILE` | `normal` | `normal` or `near-capacity` boundary profile |

For a fair one-thread/two-thread comparison, keep the total work and seed constant:

```bash
./bin/bench_bignum_div_burnikel_mt \
  --threads 1 \
  --total-iterations 3200000000 \
  --data-mode mixed

./bin/bench_bignum_div_burnikel_mt \
  --threads 2 \
  --total-iterations 3200000000 \
  --data-mode mixed
```

The reusable benchmark implementation is the public `v1.0.0` flat distribution under `libs/benchmark-framework/dist`. The project-local ST and MT sources include `benchmark_framework.h` and link `libbenchmark_framework.a`; matrix/statistics tools are consumed from `dist/tools/`. The adapter validates bignum vocabulary, constructs deterministic `bignum_t` records, chooses representable operand blocks, and maps `bignum_div_burnikel_status_t` to the named framework callback status.

## Perf workflow

Use the cloud-compatible target when hardware PMU events are unavailable:

```bash
make bench_cl CONFIG=release \
  REPORT_NAME=baseline \
  PERF_RUNS=7
```

`bench_cl` uses `task-clock`, `context-switches`, `cpu-migrations`, and `page-faults`. It does not create raw `perf.data` profiles and requires the kernel-compatible binary configured by `PERF`.

On a host that supports the default hardware events, run the full ST/MT workflow for all three modes:

```bash
make bench_full CONFIG=release \
  REPORT_NAME=baseline \
  PERF_RUNS=7 \
  KEEP_PERF=1
```

For targeted repeated measurements:

```bash
make bench_stat_st CONFIG=release \
  REPORT_NAME=baseline_st_mixed \
  DATA_MODE=mixed \
  PERF_RUNS=7

make bench_stat_mt CONFIG=release \
  REPORT_NAME=baseline_mt_mixed \
  DATA_MODE=mixed \
  MT_THREADS=2 \
  MT_CPU_LIST=0-1 \
  MT_TOTAL_ITERATIONS=3200000000 \
  PERF_RUNS=7
```

Reports are written to `benchmarks/reports/`. With `KEEP_PERF=1`, record-mode raw profiles are retained as `.perf.data` files. Keep `CONFIG`, `PERF_RUNS`, `DATA_MODE`, seed, thread count, CPU affinity, and total iterations constant when comparing implementations.

### Parameterized JSON matrix and regression gate

`bench_matrix` invokes the pinned C11 `bench_matrix` and `benchmark_stats` tools directly, without Python or hardware PMU events. The default `benchmarks/profiles/bignum_div_burnikel_full.json` covers zero, one-word, multi-word and mixed operand cases, one/quarter/half/variable operand lengths, and safe near-capacity cases. `benchmarks/profiles/bignum_div_burnikel_standard.json` is the shorter bignum-specific smoke manifest and can be selected through `BENCH_MATRIX_PROFILE`. Each JSON manifest has a companion how-to document with its exact vocabulary and baseline workflow.

```bash
make bench_matrix CONFIG=release \
  REPORT_NAME=baseline \
  BENCH_MATRIX_REPETITIONS=7 \
  BENCH_MATRIX_ITERATIONS=200000000 \
  BENCH_MATRIX_MT_TOTAL_ITERATIONS=320000000 \
  MT_THREADS=2
```

The target writes `benchmarks/reports/baseline_matrix.json` and `benchmarks/reports/baseline_matrix_summary.json`. The raw artifact preserves host metadata, the manifest hash, commands, stdout/stderr, and parsed protocol values. The summary stores robust per-profile ST/MT statistics: median, mean, sample standard deviation, and MAD.

To compare a candidate with a reviewed baseline, pass the reference JSON explicitly. The target rejects absent/extra profile IDs and fails only when candidate median `ns_per_call` is both above the configured percentage threshold and above the baseline MAD noise floor.

```bash
make bench_matrix CONFIG=release \
  REPORT_NAME=candidate \
  BENCH_BASELINE=benchmarks/reports/baseline_matrix.json \
  BENCH_REGRESSION_THRESHOLD_PCT=5
```

Do not replace a baseline automatically. Create it from a reviewed reproducible run with stable host topology, CPU affinity, compiler version, workload settings, and source revision.

For a short cloud smoke test, combine the documented environment variables with the Makefile target:

```bash
BENCH_ITERATIONS=100000 \
BENCH_MT_TOTAL_ITERATIONS=100000 \
BENCH_SEED=123456789 \
make bench_cl CONFIG=release REPORT_NAME=smoke PERF_RUNS=1 \
  MT_TOTAL_ITERATIONS=100000
```

## Installation and distribution

Build the object-file distribution:

```bash
make install CONFIG=release
```

Build the single-header and static-library distribution:

```bash
make dist CONFIG=release
```

Remove generated artifacts:

```bash
make clean
```

## Linking the object file

For development builds, first compile the module and its source dependencies:

```bash
make build CONFIG=release
```

Then link your application with the component object and the required include paths:

```bash
gcc your_app.c \
  build/bignum_div_burnikel.o \
  -I./include \
  -I./libs/bignum-core/include \
  -o your_app \
  -no-pie
```

If the application requires symbols from the template dependency graph, prefer the distribution created by `make dist CONFIG=release` and link the resulting static library with the corresponding component libraries.

## Contributing

Contributions should preserve the public C/ASM contract, update deterministic and multithreaded tests when behavior changes, and run at least:

```bash
make test CONFIG=release
make lint
```

Performance changes should include reproducible benchmark parameters, matching ST/MT evidence, and a comparison that uses the same mode, seed, total work, thread count, CPU affinity, and counter configuration.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
