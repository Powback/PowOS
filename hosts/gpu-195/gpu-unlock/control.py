#!/usr/bin/env python3
"""Stage the both-GPU boot toggle. Never reboot or touch a running GPU."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

PACKAGE = 'powos-gpu-unlock'
TARGET = 'gpu_unlock.targets=all'


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def change(*args):
    print('+', shlex.join(args), flush=True)
    subprocess.run(args, check=True)


def targets(cmdline):
    return [arg for arg in shlex.split(cmdline) if arg.startswith('gpu_unlock.targets=')]


def karg_changes(current, enabled):
    old = targets(current)
    desired = [TARGET] if enabled else []
    if old == desired:
        return []
    flags = ['--delete-if-present=' + arg for arg in dict.fromkeys(old)]
    if enabled:
        flags.append('--append=' + TARGET)
    return flags


def deployment_root(deployment):
    return Path('/sysroot/ostree/deploy') / deployment['osname'] / 'deploy' / (
        deployment['checksum'] + '.' + str(deployment['serial']))


def check_image(deployment, kernel):
    root = deployment_root(deployment)
    image = root / 'usr/lib/modules' / kernel / 'initramfs.img'
    contents = run('lsinitrd', str(image))
    if 'gpu_unlock.ko' not in contents:
        raise RuntimeError('Staged initramfs is missing gpu_unlock; do not activate.')
    module = root / 'usr/lib/modules' / kernel / 'extra/gpu_unlock.ko'
    for firmware in run('modinfo', '-F', 'firmware', str(module)).splitlines():
        if firmware not in contents:
            raise RuntimeError('Staged initramfs is missing firmware: ' + firmware)
    if 'rd.driver.pre=gpu_unlock' not in run('lsinitrd', '-f', 'etc/cmdline.d/20-force_drivers.conf', str(image)):
        raise RuntimeError('Staged initramfs does not force gpu_unlock before normal driver probing.')
    print('Verified staged initramfs: module, all firmware, and early driver loading.')


def status():
    print('Running boot targets:', ', '.join(targets(Path('/proc/cmdline').read_text())) or 'off')
    print('Next boot targets:', ', '.join(targets(run('rpm-ostree', 'kargs'))) or 'off')
    print('A boot argument is intent, not proof of a successful unlock.')
    change('nvidia-smi', '--query-gpu=index,name,pci.bus_id,driver_version', '--format=csv')
    log = run('journalctl', '-k', '-b', '--no-pager')
    lines = [line for line in log.splitlines() if 'gpu_unlock' in line]
    print('\n'.join(lines[-60:]) or 'No gpu_unlock messages in the readable boot journal.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['status', 'enable', 'disable'])
    parser.add_argument('--rpm', type=Path, help='Built RPM (required for enable)')
    args = parser.parse_args()
    if args.action == 'status':
        status()
        return
    if os.geteuid() != 0:
        parser.error('Run enable/disable with sudo on the server. Neither command reboots.')
    if args.action == 'enable':
        if not args.rpm or not args.rpm.is_file():
            parser.error('enable requires --rpm /absolute/path/to/package.rpm')
        rpm = str(args.rpm.resolve())
        if run('rpm', '-qp', '--qf', '%{NAME}', rpm) != PACKAGE:
            parser.error('Not a PowOS GPU unlock package')
        kernel = os.uname().release
        if 'kernel-core-uname-r = ' + kernel not in run('rpm', '-qp', '--requires', rpm).splitlines():
            parser.error('RPM does not match the running kernel')
        if 'SecureBoot enabled' in run('mokutil', '--sb-state'):
            parser.error('Unsigned module: Secure Boot must be handled before enabling')
        deployments = json.loads(run('rpm-ostree', 'status', '--json'))['deployments']
        pending = deployments[0]
        if not pending.get('booted') and not any(PACKAGE in p for p in pending.get('requested-local-packages', [])):
            parser.error('Another deployment is pending; resolve it before staging GPU unlock')
        change('rpm-ostree', 'install', '--idempotent', rpm)
        change('rpm-ostree', 'initramfs', '--enable')
        pending = json.loads(run('rpm-ostree', 'status', '--json'))['deployments'][0]
        check_image(pending, kernel)
    flags = karg_changes(run('rpm-ostree', 'kargs'), args.action == 'enable')
    if flags:
        change('rpm-ostree', 'kargs', *flags)
    expected = [TARGET] if args.action == 'enable' else []
    if targets(run('rpm-ostree', 'kargs')) != expected:
        raise RuntimeError('Next-boot targets did not match the requested setting')
    print('Next boot: ' + ('unlock BOTH GPUs' if expected else 'unlock OFF'))
    print('No reboot performed. Running GPUs are unchanged.')


if __name__ == '__main__':
    try:
        main()
    except (subprocess.CalledProcessError, RuntimeError) as exc:
        print('ERROR:', exc, file=sys.stderr)
        sys.exit(1)
