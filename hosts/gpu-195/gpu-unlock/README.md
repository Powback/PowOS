# RTX 3090 unlock on gpu-195

This is the integration of [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock),
pinned at `af28cbbfd3d922a659227ecfb7369adfd924cf03`. It unlocks the FP16/BF16 issue
rate before NVIDIA binds the card. It does not flash the GPU or overclock it.
The requested scope is **both GPUs**, using `gpu_unlock.targets=all`.

The toggle is a next-boot setting. **None of these scripts reboots the host.**
No live `modprobe`, driver unload, GPU reset or service restart is performed.

## Build and enable

Run on gpu-195 in a checkout containing this integration:

```sh
bash hosts/gpu-195/gpu-unlock/build.sh
sudo python3 hosts/gpu-195/gpu-unlock/control.py enable \
  --rpm "$HOME/.cache/powos-gpu-unlock/rpmbuild/RPMS/x86_64/powos-gpu-unlock-1.0.0-1.x86_64.rpm"
python3 hosts/gpu-195/gpu-unlock/control.py status
```

The build uses the target's existing compiler and matching kernel headers. Upstream
firmware inputs and generated payloads are hash-verified, and upstream tests run
before packaging. RPM tooling lives in a disposable rootless Fedora container.
The source, firmware and RPM remain in `~/.cache/powos-gpu-unlock`.

Enable requires administrator authentication. It layers the RPM into rpm-ostree,
enables local initramfs regeneration, verifies the staged image contains the module,
all required firmware and the early-load argument, then sets the both-GPU boot flag.
The running system is unchanged. Reboot only when explicitly requested; voice and
LLM services will be unavailable during that reboot.

Once booted into that deployment, `powos-gpu-unlock status` is installed as a CLI.
Check the journal for successful unlocks of **0000:01:00.0 and 0000:02:00.0**,
both GPUs in `nvidia-smi`, and the pre-existing voice/LLM services. A boot argument
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
The module compiled and all five upstream test suites passed. Hardware activation
and throughput remain unverified until an explicitly authorized reboot.
