#!/usr/bin/env python3
"""Stage an RTX 3090/4090 boot toggle. Never reboot or touch a running GPU."""
import argparse
import json
import os
import re
from pathlib import Path
import shlex
import subprocess
import sys

PACKAGE = 'powos-gpu-unlock'
PROFILE_FILE = Path(__file__).with_name('profiles.json')
if not PROFILE_FILE.is_file():
    PROFILE_FILE = Path('/usr/share/powos/gpu-unlock/profiles.json')
PROFILES = json.loads(PROFILE_FILE.read_text())


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def change(*args):
    print('+', shlex.join(args), flush=True)
    subprocess.run(args, check=True)


def targets(cmdline):
    return [arg for arg in shlex.split(cmdline) if arg.startswith('gpu_unlock.targets=')]


def karg_changes(current, enabled, selection='all'):
    old = targets(current)
    desired = ['gpu_unlock.targets=' + selection] if enabled else []
    if old == desired:
        return []
    flags = ['--delete-if-present=' + arg for arg in dict.fromkeys(old)]
    if enabled:
        flags.append('--append=' + desired[0])
    return flags


def gpu_devices(root=Path('/sys/bus/pci/devices')):
    return {p.name: (p / 'device').read_text().strip().lower() for p in root.iterdir()
            if (p / 'vendor').read_text().strip() == '0x10de'
            and (p / 'class').read_text().strip().startswith('0x03')}


def validate_selection(profile, selection, devices):
    if selection == 'all':
        chosen = list(devices)
    else:
        chosen = selection.lower().split(',')
        if any(not re.fullmatch(r'[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]', p) for p in chosen):
            raise ValueError('Use all or full PCI addresses, e.g. 0000:01:00.0; never mix them')
        if len(set(chosen)) != len(chosen):
            raise ValueError('Duplicate PCI targets')
    if not chosen:
        raise ValueError('No NVIDIA display GPUs found')
    for pci in chosen:
        if pci not in devices or devices[pci] not in PROFILES[profile]['devices']:
            raise ValueError(f'{pci} ({devices.get(pci, "absent")}) is unsupported by the {profile} profile. '
                             'PowOS supports desktop RTX 3090/4090 only; RTX 5090/Blackwell and experimental Ada IDs are not enabled.')
    return selection.lower(), chosen


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


def check_profile(deployment, profile):
    metadata = deployment_root(deployment) / 'usr/share/powos/gpu-unlock'
    if (metadata / 'profile').read_text().strip() != profile or (
            metadata / 'upstream-revision').read_text().strip() != PROFILES[profile]['revision']:
        raise RuntimeError('Staged module profile/revision differs from the requested build; refusing activation')


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
    parser.add_argument('--rpm', type=Path, help='Built RPM for first install or a profile update; otherwise use the deployed package')
    parser.add_argument('--targets', default='all', help='all (default) or comma-separated full PCI addresses')
    args = parser.parse_args()
    if args.action == 'status':
        status()
        return
    if os.geteuid() != 0:
        parser.error('Run enable/disable with sudo on the server. Neither command reboots.')
    if args.action == 'enable':
        deployments = json.loads(run('rpm-ostree', 'status', '--json'))['deployments']
        pending = deployments[0]
        kernel = os.uname().release
        rpm = None
        if args.rpm:
            if not args.rpm.is_file():
                parser.error('RPM file does not exist')
            rpm = str(args.rpm.resolve())
            if run('rpm', '-qp', '--qf', '%{NAME}', rpm) != PACKAGE:
                parser.error('Not a PowOS GPU unlock package')
            provides = run('rpm', '-qp', '--provides', rpm).splitlines()
            profiles = [p for p in PROFILES if 'powos-gpu-unlock-profile-' + p in provides]
            if len(profiles) != 1:
                parser.error('RPM has no unambiguous GPU profile; rebuild with the current build.sh')
            profile = profiles[0]
            if 'kernel-core-uname-r = ' + kernel not in run('rpm', '-qp', '--requires', rpm).splitlines():
                parser.error('RPM does not match the running kernel')
        else:
            metadata = deployment_root(pending) / 'usr/share/powos/gpu-unlock'
            if not (metadata / 'profile').is_file():
                parser.error('First-time setup needs --rpm <built package>; subsequent toggles need no path')
            profile = (metadata / 'profile').read_text().strip()
            if profile not in PROFILES or (metadata / 'kernel').read_text().strip() != kernel:
                parser.error('Deployed package has an unknown profile or different kernel; rebuild first')
            check_profile(pending, profile)
        try:
            args.targets, chosen = validate_selection(profile, args.targets, gpu_devices())
        except ValueError as exc:
            parser.error(str(exc))
        print('Profile:', profile, 'PCI targets:', ', '.join(chosen))
        if 'SecureBoot enabled' in run('mokutil', '--sb-state'):
            parser.error('Unsigned module: Secure Boot must be handled before enabling')
        if not pending.get('booted') and not any(PACKAGE in p for p in pending.get('requested-local-packages', [])):
            parser.error('Another deployment is pending; resolve it before staging GPU unlock')
        # Replace a previously layered variant in one deployment transaction.
        if rpm:
            replacement = ['--uninstall=' + PACKAGE] if any(
                PACKAGE in p for p in pending.get('requested-local-packages', [])) else []
            change('rpm-ostree', 'install', '--idempotent', *replacement, rpm)
        if not pending.get('regenerate-initramfs'):
            change('rpm-ostree', 'initramfs', '--enable')
        pending = json.loads(run('rpm-ostree', 'status', '--json'))['deployments'][0]
        check_image(pending, kernel)
        check_profile(pending, profile)
    flags = karg_changes(run('rpm-ostree', 'kargs'), args.action == 'enable', args.targets)
    if flags:
        change('rpm-ostree', 'kargs', *flags)
    expected = ['gpu_unlock.targets=' + args.targets] if args.action == 'enable' else []
    if targets(run('rpm-ostree', 'kargs')) != expected:
        raise RuntimeError('Next-boot targets did not match the requested setting')
    print('Next boot: ' + ('unlock ' + args.targets if expected else 'unlock OFF'))
    print('No reboot performed. Running GPUs are unchanged.')


if __name__ == '__main__':
    try:
        main()
    except (subprocess.CalledProcessError, RuntimeError) as exc:
        print('ERROR:', exc, file=sys.stderr)
        sys.exit(1)
