#!/usr/bin/env python3
"""Short dense-GEMM before/after measurement; never changes clocks or services."""
import argparse
import gc
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import time


def snapshot():
    fields = 'uuid,name,pci.bus_id,driver_version,pstate,clocks.sm,clocks.mem,power.limit,power.draw,temperature.gpu,utilization.gpu,memory.used'
    return subprocess.check_output(['nvidia-smi', '--query-gpu=' + fields, '--format=csv'], text=True).strip()


def measure(args):
    free, busy = map(int, subprocess.check_output([
        'nvidia-smi', '-i', str(args.gpu), '--query-gpu=memory.free,utilization.gpu',
        '--format=csv,noheader,nounits'], text=True).strip().split(','))
    if free < 2048 or busy > 15:
        raise SystemExit(f'GPU{args.gpu} is busy or lacks headroom ({free} MiB free, {busy}% busy). Retry when idle; no service was stopped.')
    # Set before importing torch / creating a CUDA context.
    os.environ['CUBLAS_WORKSPACE_CONFIG'] = ':4096:8'
    os.environ['CUDA_DEVICE_ORDER'] = 'PCI_BUS_ID'
    os.environ['CUDA_VISIBLE_DEVICES'] = str(args.gpu)
    import torch
    torch.set_num_threads(2)
    torch.use_deterministic_algorithms(True)
    torch.cuda.set_device(0)
    torch.backends.cuda.matmul.allow_fp16_reduced_precision_reduction = False
    torch.backends.cuda.matmul.allow_bf16_reduced_precision_reduction = False
    props = torch.cuda.get_device_properties(0)
    report = {
        'schema': 1, 'label': args.label, 'timestamp': time.time(),
        'kernel': os.uname().release,
        'boot_id': Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
        'torch': torch.__version__, 'cuda': torch.version.cuda,
        'gpu': args.gpu, 'name': props.name, 'uuid': str(props.uuid),
        'driver': subprocess.check_output(['nvidia-smi', '--query-gpu=driver_version', '--format=csv,noheader'], text=True).splitlines()[args.gpu],
        'n': args.size, 'samples': args.samples, 'warmups': 3, 'seed': 1953090,
        'before': snapshot(), 'results': {},
    }
    for name, dtype in [('fp16', torch.float16), ('bf16', torch.bfloat16), ('tf32', torch.float32)]:
        torch.backends.cuda.matmul.allow_tf32 = name == 'tf32'
        torch.manual_seed(report['seed'])
        torch.cuda.manual_seed_all(report['seed'])
        n = args.size
        a = torch.randn((n, n), dtype=dtype, device='cuda')
        b = torch.randn((n, n), dtype=dtype, device='cuda')
        out = torch.empty_like(a)
        for _ in range(report['warmups']):
            torch.mm(a, b, out=out)
        torch.cuda.synchronize()
        times = []
        for _ in range(args.samples):
            begin, end = torch.cuda.Event(enable_timing=True), torch.cuda.Event(enable_timing=True)
            begin.record()
            torch.mm(a, b, out=out)
            end.record()
            end.synchronize()
            times.append(begin.elapsed_time(end))
        # Independent FP64 CPU reference for a small, spread-out subset.
        indices = torch.linspace(0, n - 1, 16, device='cuda').long()
        reference = a[indices, :].double().cpu() @ b[:, indices].double().cpu()
        actual = out[indices[:, None], indices[None, :]].double().cpu()
        error = (actual - reference).abs()
        normalized_error = (error.max() / reference.abs().max().clamp_min(1)).item()
        # BF16 output rounding dominates; use a per-mode bound relative to reference peak.
        tolerance = {'fp16': 0.002, 'bf16': 0.01, 'tf32': 0.002}[name]
        # Hash the full output to compare the same deterministic calculation after reboot.
        digest = hashlib.sha256(out.cpu().contiguous().view(torch.uint8).numpy().tobytes()).hexdigest()
        median = statistics.median(times)
        report['results'][name] = {
            'milliseconds': times, 'median_ms': median,
            'tflops': 2 * n ** 3 / (median / 1000) / 1e12,
            'output_sha256': digest, 'normalized_max_error': normalized_error,
            'correct': bool(torch.isfinite(actual).all().item() and normalized_error <= tolerance),
            'telemetry': snapshot(),
        }
        print(f"GPU{args.gpu} {name}: {report['results'][name]['tflops']:.2f} TFLOPS, error={normalized_error:.6g}", flush=True)
        del a, b, out, reference, actual, error
        gc.collect()
        torch.cuda.empty_cache()
    report['after'] = snapshot()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    if not all(r['correct'] for r in report['results'].values()):
        raise SystemExit('FAIL: numerical correctness check; results saved')


def compare(before, after):
    for key in ['schema', 'kernel', 'torch', 'cuda', 'uuid', 'driver', 'n', 'samples', 'warmups', 'seed']:
        if before[key] != after[key]:
            raise ValueError('Cannot compare: mismatched ' + key)
    if before['boot_id'] == after['boot_id']:
        raise ValueError('Both runs are from the same boot; this is not a post-reboot verification')
    print('Numerical results and median throughput (review saved telemetry for load/clock differences):')
    for mode in ['fp16', 'bf16', 'tf32']:
        a, b = before['results'][mode], after['results'][mode]
        if not a['correct'] or not b['correct'] or a['output_sha256'] != b['output_sha256']:
            raise ValueError('Correctness/fingerprint mismatch for ' + mode + '; investigate before accepting the unlock')
        print(f"{mode}: {a['tflops']:.2f} -> {b['tflops']:.2f} TFLOPS ({(b['tflops']/a['tflops']-1)*100:+.1f}%), identical output")
    print('Also require successful gpu_unlock boot logs for both PCI addresses and healthy services.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    bench = sub.add_parser('run')
    bench.add_argument('--gpu', type=int, choices=[0, 1], required=True)
    bench.add_argument('--label', choices=['before', 'after'], required=True)
    bench.add_argument('--output', type=Path, required=True)
    bench.add_argument('--size', type=int, default=8192)
    bench.add_argument('--samples', type=int, default=5)
    diff = sub.add_parser('compare')
    diff.add_argument('before', type=Path)
    diff.add_argument('after', type=Path)
    args = parser.parse_args()
    if args.command == 'run':
        if not 256 <= args.size <= 8192 or not 3 <= args.samples <= 20:
            parser.error('Use size 256..8192 and 3..20 samples')
        measure(args)
    else:
        compare(json.loads(args.before.read_text()), json.loads(args.after.read_text()))


if __name__ == '__main__':
    main()
