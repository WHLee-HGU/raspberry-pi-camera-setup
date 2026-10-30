#!/usr/bin/env bash
# Pi 5 / Raspberry Pi OS Bookworm: inspect cameras or set ONE camera on CAM0.
# No package installation, network changes, or automatic reboot.
set -euo pipefail
command -v python3 >/dev/null || { echo 'python3 is required.' >&2; exit 1; }
python3 - "$@" <<'PY'
import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

MODES = ('auto', 'imx708', 'imx219', 'ov5647')
# Deliberately limited to the reviewed classroom image. Unknown HAT/vendor
# overlays might own CSI/I2C resources, so automatic mutation must stop.
NONCAMERA_OVERLAYS = frozenset(('vc4-kms-v3d', 'dwc2', 'disable-bt'))


class ConfigError(RuntimeError):
    pass


def sync_directory(directory):
    if os.name != 'posix':
        return
    fd = os.open(directory, os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def validate_platform(root):
    board = root/'sys/firmware/devicetree/base/model'
    if not board.is_file() or not board.read_bytes().rstrip(b'\0').startswith(b'Raspberry Pi 5'):
        raise ConfigError('This script supports Raspberry Pi 5 only.')
    # Follow Debian's standard /etc/os-release -> ../usr/lib/os-release link.
    release = (root/'etc/os-release').read_text(encoding='utf-8')
    if not re.search(r'^VERSION_CODENAME=[\"\']?bookworm[\"\']?\s*$', release, re.M):
        raise ConfigError('This classroom script supports Raspberry Pi OS Bookworm only.')


def inspect_config(root):
    validate_platform(root)
    path = root/'boot/firmware/config.txt'
    if path.is_symlink() or not path.is_file():
        raise ConfigError('Expected a regular /boot/firmware/config.txt.')
    original = path.read_bytes()
    if original.startswith(b'\xef\xbb\xbf') or b'\r' in original or b'\0' in original:
        raise ConfigError('config.txt must use UTF-8 without BOM and Unix LF line endings.')
    lines = original.decode('utf-8').splitlines(keepends=True)
    automatic = []
    sensors = []
    section = last_section = '[all]'
    for number, line in enumerate(lines):
        active = line.split('#', 1)[0].strip()
        if not active:
            continue
        if re.match(r'^include\s+', active):
            raise ConfigError('Included configuration requires manual review; no changes were made.')
        if active.startswith('['):
            if not re.fullmatch(r'\[[^\]]+\]', active):
                raise ConfigError('Unexpected conditional section.')
            section = last_section = active
            continue
        match = re.fullmatch(r'(\s*camera_auto_detect\s*=\s*)([01])([ \t]*(?:#.*)?)', line.rstrip('\n'))
        if match:
            automatic.append((number, section, match))
        elif active.startswith('camera_auto_detect'):
            raise ConfigError('Unexpected camera_auto_detect setting.')
        overlay = re.fullmatch(r'dtoverlay\s*=\s*(.*)', active)
        if overlay:
            parts = [s.strip() for s in overlay[1].split(',')]
            if parts[0] in MODES[1:]:
                if parts[1:] not in ([], ['cam0'], ['cam1']):
                    raise ConfigError('Unknown or parameterised camera overlay requires manual review.')
                sensors.append((number, section, parts))
            elif parts[0] not in NONCAMERA_OVERLAYS:
                raise ConfigError('An unrecognised overlay requires manual review before automatic changes.')
    if len(automatic) != 1 or automatic[0][1] != '[all]':
        raise ConfigError('Expected exactly one unconditional camera_auto_detect setting.')
    if last_section != '[all]':
        raise ConfigError('The final config section must be [all].')
    if len(sensors)>1 or (sensors and sensors[0][1]!='[all]'):
        raise ConfigError('Multiple or conditional camera overlays require manual review.')
    return path, original, lines, automatic[0], sensors


def plan(root, mode):
    if mode not in MODES:
        raise ConfigError('Choose auto, imx708, imx219, or ov5647.')
    path, original, lines, automatic, sensors = inspect_config(root)
    if mode!='auto' and not (root/f'boot/firmware/overlays/{mode}.dtbo').is_file():
        raise ConfigError('The selected sensor overlay is not installed.')
    wanted_auto = '1' if mode=='auto' else '0'
    wanted_parts = None if mode=='auto' else [mode, 'cam0']
    already = automatic[2].group(2)==wanted_auto and (
        not sensors if mode=='auto' else bool(sensors) and sensors[0][2]==wanted_parts)
    if already:
        return path, original, original
    index, _, match = automatic
    ending = '\n' if lines[index].endswith('\n') else ''
    lines[index] = match.group(1)+wanted_auto+match.group(3)+ending
    if sensors:
        number, _, _ = sensors[0]
        old = lines[number].rstrip('\n')
        lines[number] = '# camera-setup previous: '+old.lstrip()+'\n'
    updated = ''.join(lines)
    if mode!='auto':
        if updated and not updated.endswith('\n'):
            updated += '\n'
        updated += '\n# One camera on physical CAM/DISP0\ndtoverlay='+mode+',cam0\n'
    return path, original, updated.encode('utf-8')


def configure(root, mode, dry_run=False):
    path, original, updated = plan(root, mode)
    if original==updated:
        return {'status':'ALREADY_CONFIGURED', 'changed':False, 'backup':None}
    if dry_run:
        return {'status':'READY', 'changed':False, 'backup':None}
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:8]
    backup = path.with_name('config.txt.before-camera-setup-'+stamp+'.bak')
    backup_owned = False
    try:
        with backup.open('xb') as handle:
            backup_owned = True
            handle.write(original);handle.flush();os.fsync(handle.fileno())
        if backup.read_bytes()!=original:
            raise ConfigError('Backup verification failed; original configuration was not changed.')
    except Exception:
        if backup_owned:
            backup.unlink(missing_ok=True)
        raise
    temporary = None
    committed = False
    try:
        with tempfile.NamedTemporaryFile('wb',dir=path.parent,prefix='config-camera-setup-',delete=False) as handle:
            temporary=Path(handle.name)
            handle.write(updated);handle.flush();os.fsync(handle.fileno())
        # FAT has mount-controlled permissions; never chmod/chown its files.
        if path.read_bytes()!=original:
            raise ConfigError('config.txt changed during preparation; refusing to overwrite it.')
        os.replace(temporary,path);committed=True;temporary=None
        sync_directory(path.parent)
        if path.read_bytes()!=updated:
            raise ConfigError('Configuration readback failed.')
    except Exception:
        if committed:
            with path.open('wb') as handle:
                handle.write(original);handle.flush();os.fsync(handle.fileno())
            sync_directory(path.parent)
        raise
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return {'status':'CONFIGURED', 'changed':True, 'backup':str(backup)}


def camera_report(root):
    validate_platform(root)
    try:
        path, _, _, automatic, sensors = inspect_config(root)
        print('Camera auto-detection:', automatic[2].group(2))
        print('Explicit sensor overlay:', ','.join(sensors[0][2]) if sensors else '(none)')
    except ConfigError as exc:
        # Read-only enumeration remains useful for unsupported camera setups.
        print('Configuration requires manual review before changes:', str(exc))
    parent = ''
    for relative in ('__symbols__/i2c_csi_dsi0', 'aliases/i2c10'):
        node=root/'sys/firmware/devicetree/base'/relative
        if node.is_file():
            parent=node.read_bytes().decode().rstrip('\0');break
    program=shutil.which('rpicam-hello')
    if not program:
        print('rpicam-hello is missing; no camera enumeration was attempted.')
        return
    result=subprocess.run([program,'--list-cameras'],capture_output=True,text=True,timeout=12)
    if result.returncode:
        print('Camera enumeration exit code:',result.returncode)
    text=result.stdout+'\n'+result.stderr
    pattern=r'^\s*(\d+)\s*:\s*(\S+)\s+\[.*?\]\s+\((/[^\r\n]+)\)\s*$'
    cameras=[]
    for match in re.finditer(pattern,text,re.M):
        identifier=match[3]
        normalized=identifier[len('/base'):] if identifier.startswith('/base/') else identifier
        port='CAM/DISP0' if parent and normalized.startswith(parent.rstrip('/')+'/') else 'other/unknown'
        cameras.append((match[1],match[2],port))
    for index,model,port in cameras:
        print(f'Detected: model={model}, software_index={index}, physical_port={port}')
    if not cameras:
        print('No camera enumerated. Check model, cable, and settings; this does not install vendor drivers.')
    print('Enumeration only; actual image capture was not tested by --check.')


def main():
    parser=argparse.ArgumentParser(description='Pi 5 Bookworm camera inspection or single-CAM0 setup. Never reboots automatically.')
    parser.add_argument('mode',nargs='?',choices=MODES,help='auto or a supported sensor model; omitted means read-only check')
    parser.add_argument('--check',action='store_true',help='Read-only inspection; with mode, validate the requested configuration without applying')
    args=parser.parse_args()
    if sys.platform!='linux':
        parser.error('Run this script on the Raspberry Pi, not on Windows.')
    checking=args.check or args.mode is None
    if not checking and os.geteuid()!=0:
        parser.error('Use sudo for changes, e.g. sudo bash camera-setup.sh imx708')
    try:
        if checking:
            camera_report(Path('/'))
            if args.mode:
                result=configure(Path('/'),args.mode,dry_run=True)
                print('Requested configuration:',args.mode,'RESULT:',result['status'])
            print('Read-only: no settings changed.')
            return 0
        result=configure(Path('/'),args.mode)
    except (ConfigError,OSError,UnicodeError,subprocess.TimeoutExpired) as exc:
        print('ERROR:',str(exc),file=sys.stderr);return 1
    print('RESULT:',result['status'],'; selected mode:',args.mode)
    if args.mode=='auto':
        print('camera_auto_detect=1; known explicit sensor overlay disabled.')
    else:
        print('camera_auto_detect=0; dtoverlay='+args.mode+',cam0 under [all]')
    if result['backup']:
        print('Exact original backup:',result['backup'])
    if result['changed']:
        print('Apply on next boot: sudo reboot')
    else:
        print('No duplicate settings or backup were added.')
    print('After reboot: bash camera-setup.sh --check')
    return 0


if __name__=='__main__':
    sys.exit(main())
PY
