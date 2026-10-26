# RTX 3090 / RTX 4090 unlock on PowOS

This is the integration of [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock),
pinned at `af28cbbfd3d922a659227ecfb7369adfd924cf03`. It unlocks the FP16/BF16 issue
rate before NVIDIA binds the card. It does not flash the GPU or overclock it.
The default Ampere profile remains pinned to that source. On gpu-195 the requested
scope is **both 3090s**, using `gpu_unlock.targets=all`.

The explicit **Ada profile** uses [JustAResearcher/gpu-unlock-ada](https://github.com/JustAResearcher/gpu-unlock-ada)
at `a63cf8060f10ef94d29aa0aeaad37b7cf499dac0` (1.1.1). It adds the desktop
RTX 4090 (`10de:2684`) and retains RTX 3090 (`10de:2204`). PowOS deliberately
does not expose the fork's experimental flags for 4090 D, Laptop, or other Ada
cards. RTX 5090/Blackwell remains unsupported; see [the research note](../../../docs/GPU-UNLOCK-BLACKWELL.md).

These are alternative builds of the **same package/module**, not two modules to
install together. Selecting `ada` does not update an installed Ampere package.
The Ada module has no suspend/resume re-unlock notifier at this pinned revision;
validate again after power-state transitions rather than assuming it stays unlocked.

The toggle is a next-boot setting. **None of these scripts reboots the host.**
No live `modprobe`, driver unload, GPU reset or service restart is performed.

## Build and enable

Run on gpu-195 in a checkout containing this integration:

```sh
bash hosts/gpu-195/gpu-unlock/build.sh ampere
sudo python3 hosts/gpu-195/gpu-unlock/control.py enable \
  --rpm "$HOME/.cache/powos-gpu-unlock/ampere/rpmbuild/RPMS/x86_64/powos-gpu-unlock-1.0.0-2.x86_64.rpm"
python3 hosts/gpu-195/gpu-unlock/control.py status
```

For a desktop RTX 4090 host, build **on that host** against its kernel headers:

```sh
bash hosts/gpu-195/gpu-unlock/build.sh ada
sudo python3 hosts/gpu-195/gpu-unlock/control.py enable \
  --rpm "$HOME/.cache/powos-gpu-unlock/ada/rpmbuild/RPMS/x86_64/powos-gpu-unlock-1.1.1-1.x86_64.rpm"
```

To select one card, add `--targets <full PCI address from lspci -D>`.
`all` checks every NVIDIA display GPU present and refuses if any is unsupported.
On a mixed 4090/5090 host, explicitly select the 4090; the 5090 is never enabled.
The CLI checks the profile recorded in the RPM, not a user-supplied architecture flag.

The build uses the target's existing compiler and matching kernel headers. Upstream
firmware inputs and generated payloads are hash-verified, and upstream tests run
before packaging. RPM tooling lives in a disposable rootless Fedora container.
The source, firmware and RPM remain in `~/.cache/powos-gpu-unlock/<profile>`;
the hash-verified download cache is shared, but generated assets and payloads are
isolated by profile/revision. Older 1.0.0-1 artifacts stay untouched in the original
`rpmbuild/` directory; rebuild to use the new PCI/profile checks.

Enable requires administrator authentication. It layers the RPM into rpm-ostree,
enables local initramfs regeneration, verifies the staged image contains the module,
all required firmware and the early-load argument, then sets the selected boot targets.
The running system is unchanged. Reboot only when explicitly requested; voice and
LLM services will be unavailable during that reboot.

Once booted into that deployment, `powos-gpu-unlock status` is installed as a CLI.
Check the journal for successful unlocks of the selected PCI addresses (on .195,
**0000:01:00.0 and 0000:02:00.0**), GPUs in `nvidia-smi`, and the pre-existing voice/LLM services. A boot argument
alone does not prove successful unlock. Compare workload benchmarks on each GPU
before claiming a performance improvement; generation may remain memory-bound.

## Before/after benchmark

```sh
bash hosts/gpu-195/gpu-unlock/bench.sh before
# Only after a separately authorized reboot:
bash hosts/gpu-195/gpu-unlock/bench.sh after
```

Runs each GPU sequentially in a short-lived container using the same recorded
local LLM image ID. No service is stopped and no clock or power setting changes.
GPU indices are discovered rather than assuming two cards; optional trailing indices
select a subset, e.g. `bench.sh before 0`. CUDA selects each card by UUID to avoid
PCI-order/index mismatches. On another host, set `GPU_UNLOCK_BENCH_IMAGE` to a local
image containing CUDA-enabled PyTorch compatible with the card; its immutable ID is
recorded with the first baseline. The default remains `localhost/llm-pool:latest`.
Results are under `~/.cache/powos-gpu-unlock/bench/`. Each mode measures an
8192-square GEMM with three warmups and five timed samples. FP16/BF16 reduced
precision reductions are disabled; TF32 is explicitly enabled for the FP32 case.
An independent FP64 CPU reference checks 256 spread-out output elements, and a
full-output hash must match across boots. Comparison rejects different cards,
software versions or benchmark settings, and requires a different boot ID.
Runs refuse to start with less than 2 GiB free or over 15% GPU activity. Rerunning
the same label keeps existing results and retries missing cards, using the same
image. Archive the benchmark directory to deliberately take a fresh baseline.
Telemetry records clocks, power, temperature, utilization and memory use. Review
it for competing workloads; a speedup alone is not proof of successful unlock.

## Disable and recovery

```sh
sudo powos-gpu-unlock disable
# Before the first boot, use the checkout's control.py disable instead.
```

This removes all `gpu_unlock.targets` arguments for the next boot. It does not
change the running GPUs. To recover from a failed boot, remove that argument in
the bootloader editor or select the previous ostree deployment. To remove the
package, disable first, then `sudo rpm-ostree uninstall powos-gpu-unlock`.

## Kernel updates and limits

This package deliberately requires the exact `kernel-core-uname-r` it was built
against. Rebuild it for a new kernel, or remove it before updating the OS. Do not
force RPM dependency checks or assume a module for an old kernel remains usable.
The integration does not depend on upstream's DKMS post-transaction hooks, which
are unsuitable as proof of a working module in an ostree deployment.

The unsigned module requires Secure Boot handling; enable refuses when Secure
Boot is enabled. On 2026-10-26, the target ran kernel
`7.2.9-ogc3.1.fc44.x86_64`, NVIDIA `615.78.08`, with Secure Boot disabled.
Both profiles compile for that kernel. Ampere's five upstream tests pass. Ada's
`test-full` runs 31 tests: 28 pass, including real-asset transactions for GA102
and AD102; three optional debug-decoder tests skip without PyCryptodome.
This is a build/package validation on the 3090 server, **not a local RTX 4090
hardware test**. Hardware activation and throughput remain unverified until an
explicitly authorized reboot on each intended host.
