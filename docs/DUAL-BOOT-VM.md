# Reciprocal VMs: run your other OS without rebooting

The goal: dual-boot Windows and PowOS on bare metal, and from *either* one, boot
the *other* as a VM off the **same physical partition** — no second copy, no
reboot for a quick cross-OS task.

```
        bare metal boot                     run the other as a VM
   ┌──────────────────────┐          ┌──────────────────────────────┐
   │  PowOS (this repo)    │  ──────► │  Windows guest (KVM/QEMU)     │
   │                       │          │  boots the real Windows disk  │
   ├──────────────────────┤          ├──────────────────────────────┤
   │  Windows              │  ──────► │  PowOS guest (VirtualBox/     │
   │                       │          │  VMware, raw partition)       │
   └──────────────────────┘          └──────────────────────────────┘
```

## Non-negotiable safety rules

1. **Never run a guest whose partitions the host has mounted read-write.** Booting
   an OS that's also live on the host = filesystem corruption. `powos vm` refuses
   to launch a disk with mounted partitions; do the same by hand on the Windows side.
2. **Disable Windows Fast Startup + hibernation permanently** (`powercfg.exe /hibernate off`).
   A hibernated Windows booted in a VM corrupts on resume.
3. **Ideally keep Windows and PowOS on separate disks.** Passing a whole disk that
   also holds the *other* OS gives the guest write access to both.
4. **Activation:** Windows sees VM vs. bare-metal as two hardware profiles and may
   re-check activation. A digital licence tied to your Microsoft account absorbs this.
5. **Sharing files while a guest runs:** use a network share (Samba/NFS) or virtiofs —
   NOT a partition mounted by both host and guest at once.

## Direction A — PowOS host → Windows guest (built in)

```bash
powos vm status                 # is Windows detected? is its disk safe to boot?
sudo powos vm windows --dry-run # print the plan + qemu command, launch nothing
sudo powos vm windows           # boot Windows as a KVM guest (after confirmation)
sudo powos vm windows --ram 16G --cpus 8
sudo powos vm windows --gpu     # advanced: GPU passthrough (needs 2 GPUs + IOMMU)
```

`powos vm windows` passes the physical Windows disk to a UEFI (OVMF) KVM guest
using AHCI (Windows has native drivers). Requires `qemu-kvm` and `edk2-ovmf`.

**Gaming in the guest** needs GPU passthrough: a second GPU bound to `vfio-pci`,
IOMMU enabled on the kernel cmdline (`intel_iommu=on` / `amd_iommu=on`), and the
GPU's PCI address wired into the VM. `--gpu` scaffolds the qemu device but the
PCI binding is host-specific — this is an advanced, opt-in path.

## Direction B — Windows host → PowOS guest (manual, Windows side)

PowOS can't run on Windows to set this up for you; do it from Windows with
VirtualBox or VMware Workstation, pointing the VM at the raw PowOS partition.

**VirtualBox** (raw disk VMDK):
```powershell
# Find the disk number in Disk Management, then (as Administrator):
VBoxManage internalcommands createrawvmdk -filename powos.vmdk -rawdisk \\.\PhysicalDrive1
# Create a new VM: type Linux/Other Linux 64-bit, EFI enabled, attach powos.vmdk.
```

**VMware Workstation:** New VM → "Use a physical disk" → select the PowOS disk →
enable UEFI firmware in VM settings.

PowOS tolerates the bare-metal↔VM hardware swap well: its Chameleon Boot detects
virtualization and applies the `virtual` profile automatically. Boot the VM off
its real partition and it comes up in VM mode; boot bare metal and it's native.

## Why not "live Windows" or "PowOS builds Windows"?

PowOS can't build, bundle, or live-boot Windows — Windows install media is
Microsoft's proprietary WIM, and Windows To Go is deprecated. Windows always
comes from a normal Microsoft install; PowOS coexists with and virtualizes it.
