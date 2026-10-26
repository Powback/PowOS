# RTX 5090 unlock investigation — 2026-10-26

No working public RTX 5090 tensor-rate unlock was found in the reviewed sources.
PowOS therefore has no Blackwell enable profile. The 3090/4090 enable command
rejects a selected 5090 rather than claiming success when the module skips it.
SSH to our gpu-58 (`192.168.50.58`) timed out during this investigation, so none
of the Blackwell observations below are measurements of our own card.

## Evidence and limits

The Ada fork's [5090 investigation](https://github.com/JustAResearcher/gpu-unlock-ada/issues/12)
reports a readable NVIDIA RM issue-rate getter on desktop GB202, but no successful
unlock. A separate **GB203M laptop** report finds familiar selector addresses while
pre-driver host writes to the selectors and permission gate do not stick. Those
laptop measurements do not establish identical behavior on desktop GB202.

NVIDIA's [firmware extraction source](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/nouveau/extract-firmware-nouveau.py)
emits `bootloader` and signed FMC assets for GB202; Ampere/Ada also have the distinct
`booter_load`/`booter_unload` assets used by the existing unlock. Shared GSP-RM
firmware does not make these early boot paths interchangeable.

NVIDIA's [RM control definitions](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/610.43.03/src/common/sdk/nvidia/inc/ctrl/ctrl2080/ctrl2080gr.h)
label FMLA32 selector value 3 as a 1/8 rate setting. That is **not a measurement
or promise of an 8× whole-GPU/application gain**. Establish what instruction path
the field controls and compare actual instruction/GEMM throughput at matched
clocks and power. A field readback alone cannot establish expected speedup.

## What implementation would require

This is the proposed research sequence, not an available unlock procedure:

1. **Reproduce the baseline on our GB202.** Capture PCI ID, UUID, VBIOS, kernel,
   driver, firmware hashes, clocks/power and the read-only RM getter. Use matched
   instruction probes plus numerical and application tests; keep the original
   results. The pinned Ada repository's `tools/read_sm_rates.py` allocates only
   temporary RM handles and uses the getter, but deliberately supports one GPU
   with an exact UUID. Review its ABI against the installed driver first.
2. **Map the actual early boot and privilege path.** Trace GB202's bootloader,
   FMC/FSP handoff and permission ownership using the corresponding NVIDIA source
   and exact signed assets. Confirm which component can change the effective
   speed selectors. Do not assume Ada's offsets, readout packing, completion
   marker, payload or reset sequence transfers unchanged.
3. **Establish a usable privileged mechanism.** Existing reports have not shown a
   permitted write route. A new, reproducible firmware weakness or an NVIDIA-
   supported mechanism would be needed to cross that barrier. Merely adding PCI
   ID `2b85`, copying Ada's selector values, or patching the userspace getter does
   not implement an unlock. Whether such a mechanism exists is unresolved.
4. **Only then design a GB202 backend.** Require exact chip/firmware admission,
   verified completion and permission readbacks, bounded waits, safe DMA ownership,
   stock NVIDIA handoff, recovery, and failure-path tests. Keep it opt-in until
   repeated cold/warm boot tests and sustained workloads show correct results.
5. **Prove benefit and correctness independently.** Compare matching stock/unlocked
   instruction rates, GEMM, the real serving workload, output hashes/tolerances,
   power and temperature. Require successful driver/service recovery and no new
   Xid errors. Investigate numerical mismatches even when throughput improves.

Firmware research, rather than PowOS packaging, is the unresolved work. There is
no defensible implementation-time estimate before step 3 succeeds. No experimental
register, fuse, VBIOS or firmware writes were attempted on either server.

## What can be done now

On gpu-58 once reachable, collect ordinary read-only inventory:

```sh
uname -r
nvidia-smi --query-gpu=name,uuid,pci.bus_id,pci.device_id,driver_version,vbios_version,power.limit --format=csv
find /usr/lib/firmware/nvidia/gb202 -type f -exec sha256sum {} +
```

Then review the pinned diagnostic getter before running it for that exact UUID.
The generic PowOS GEMM benchmark can capture a 5090 baseline using a suitable
CUDA/PyTorch image, but that does not imply unlock support. Do not install the
Ada module on gpu-58 as a substitute for a Blackwell implementation.
