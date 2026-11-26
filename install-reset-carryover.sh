#!/usr/bin/env bash
# KVM_BW_MANAGER_BOOTSTRAP_V2
set -euo pipefail
umask 077
if [[ ! -x /usr/bin/python3 ]]; then
    echo 'Python 3.9+ is required at /usr/bin/python3.' >&2
    if command -v apt-get >/dev/null; then
        echo 'Run: apt-get update && apt-get install -y python3 cron curl ca-certificates coreutils bash' >&2
    elif command -v dnf >/dev/null; then
        echo 'Run: dnf install -y python3 cronie curl ca-certificates coreutils bash' >&2
    fi
    exit 1
fi
/usr/bin/python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,9) else "Python 3.9 or later is required.")'
stage_dir="$(mktemp -d /tmp/kvm-bw.XXXXXX)"
cleanup() {
    for filename in reset_carryover.py bridge.php carryover_manager.py test_reset_carryover.py test_carryover_manager.py; do
        rm -f -- "$stage_dir/$filename"
    done
    rmdir -- "$stage_dir" 2>/dev/null || true
}
trap cleanup EXIT
if [[ $# -gt 0 ]]; then
    case "$1" in
      --minimum-one-gb) shift; set -- install --policy minimum-1gb "$@" ;;
      --hold-under-one-gb) shift; set -- install --policy hold "$@" ;;
    esac
fi
cat > "$stage_dir/reset_carryover.py" <<'RC_CORE'
#!/usr/bin/env python3
"""All counter decreases are resets. Only the panel quota may be edited."""
import argparse
import copy
from datetime import datetime
from decimal import Decimal
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

STATE_DIR = Path('/var/lib/reset-carryover')
PHP = '/usr/local/emps/bin/php'
BRIDGE = '/opt/reset-carryover/bridge.php'
ABSENT_RETENTION = 30 * 86400


def amount(value):
    n = Decimal(str(value))
    if not n.is_finite() or n < 0:
        raise ValueError('Invalid traffic amount')
    return int((n * 100).to_integral_value())


def baseline(vm, now, reserve=0):
    limit = amount(vm['limit'])
    if limit % 100:
        raise ValueError('Non-integer panel quota; refusing to round an operator edit')
    return dict(name=vm['name'], uuid=vm['uuid'], limit=limit,
                used=amount(vm['used']), at=now, reserve=reserve,
                hold=None, pending=None, resets=0)


def decide(old, vm, now, policy='minimum-1gb'):
    fresh = baseline(vm, now, old['reserve'] if old else 0)
    if old is None:
        return 'enrolled', fresh, None
    old = copy.deepcopy(old)
    fresh['resets'] = old['resets']
    if old['name'] != vm['name'] or old['uuid'] != vm['uuid']:
        old['hold'] = 'VM identity changed; review required'
        return 'held', old, None
    if old['hold']:
        return 'held', old, None
    if not old['limit'] or not fresh['limit']:
        old['hold'] = 'Unlimited/finite transition; resync required'
        return 'held', old, None
    if fresh['used'] >= old['used']:
        return 'tracking', fresh, None
    # User policy: every decrease, regardless of date, mode or actor, is a reset.
    # Existing credits + signed operator limit edit = current limit - prior usage.
    available = fresh['limit'] - old['used'] + old['reserve']
    target = available // 100
    if target < 1:
        if policy != 'minimum-1gb':
            old['hold'] = 'Remaining below 1GB; zero means unlimited'
            return 'held', old, None
        target = 1
    fresh['limit'] = target * 100
    fresh['reserve'] = available - target * 100
    fresh['resets'] = old['resets'] + 1
    job = dict(expected=amount(vm['limit']), target=target, next=copy.deepcopy(fresh))
    return 'reset-carry-over', fresh, job


def save(path, state):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix='state-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(json.dumps(state, ensure_ascii=True, indent=2).encode())
            f.flush()
            os.fsync(f.fileno())
        if path.exists():
            with path.with_suffix('.previous.json').open('wb') as f:
                f.write(path.read_bytes())
                f.flush()
                os.fsync(f.fileno())
        os.replace(temporary, path)
        if os.name != 'nt':
            d = os.open(str(path.parent), os.O_RDONLY)
            try:
                os.fsync(d)
            finally:
                os.close(d)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class Bridge:
    def call(self, *args):
        r = subprocess.run([PHP, BRIDGE, *map(str, args)], capture_output=True,
                           text=True, timeout=45)
        if r.returncode:
            # Only fixed, sanitized error codes are relayed, never raw API data.
            code = r.stderr.strip()
            if not code.startswith('BRIDGE_ERROR: ') or not all(
                    c in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ_: \n' for c in code):
                code = 'API operation failed'
            raise RuntimeError(code)
        return json.loads(r.stdout)

    def snapshot(self):
        return self.call('snapshot')

    def write(self, key, job):
        return self.call('write', key, job['target'], job['expected'],
                         job['next']['uuid'], job['next']['name'])


def log(event, key='', detail=''):
    print(datetime.now().astimezone().isoformat(timespec='seconds'), event,
          'VPS='+key if key else '', detail, flush=True)


def process(state, snapshot, bridge, persist):
    problems = []
    # Only mark absence after receiving the complete current local VPS list.
    # Active held/pending records must never expire merely because they are old.
    now = int(snapshot['now'])
    present = {str(vm['id']) for vm in snapshot['vms']}
    changed = False
    for key, old in list(state['vms'].items()):
        if key in present:
            if 'missing_since' in old:
                old.pop('missing_since')
                changed = True
        elif 'missing_since' not in old:
            old['missing_since'] = now
            changed = True
        elif now - int(old['missing_since']) >= ABSENT_RETENTION:
            del state['vms'][key]
            changed = True
            log('FORGOTTEN-ABSENT', key)
    if changed:
        persist(state)
    for vm in snapshot['vms']:
        key = str(vm['id'])
        old = state['vms'].get(key)
        if old is None and not amount(vm['limit']):
            continue
        try:
            if old and old['pending']:
                job = old['pending']
                if old['hold']:
                    problems.append(key)
                    log('HELD-PENDING', key, old['hold'])
                    continue
                if old['uuid'] != vm['uuid'] or old['name'] != vm['name']:
                    raise RuntimeError('VM identity changed during pending write')
                if amount(vm['limit']) == job['target'] * 100:
                    old = copy.deepcopy(job['next'])
                    log('RECOVERED-COMMITTED-WRITE', key)
                elif amount(vm['limit']) == job['expected']:
                    bridge.write(key, job)
                    old = copy.deepcopy(job['next'])
                    vm = dict(vm, limit=str(job['target']))
                    log('RECOVERED-RETRIED-WRITE', key)
                else:
                    old['hold'] = 'Operator quota edit conflicts with pending correction'
                state['vms'][key] = old
                persist(state)
                if old['pending']:
                    problems.append(key)
                    continue
            event, fresh, job = decide(old, vm, int(snapshot['now']), state['policy'])
            if job and job['target'] * 100 != job['expected']:
                pending = copy.deepcopy(old)
                pending['pending'] = job
                state['vms'][key] = pending
                persist(state)  # Durable intent BEFORE the external write.
                bridge.write(key, job)
                log('QUOTA-REPLACED', key, '%s -> %s GB' %
                    (job['expected']/100, job['target']))
            elif event != 'tracking':
                log(event.upper(), key, fresh['hold'] or '')
            state['vms'][key] = fresh
            persist(state)
            if fresh['hold']:
                problems.append(key)
        except Exception as e:
            problems.append(key)
            if key in state['vms']:
                state['vms'][key]['hold'] = 'review-required: '+str(e)
                persist(state)
            log('ERROR', key, str(e))
    return problems


def show(state):
    print('POLICY=%s; every observed usage decrease is a reset' % state['policy'])
    print('VPS_ID     LIMIT_GB      USED_GB      LEFT_GB    RESERVE_GB RESETS STATUS')
    for key, s in sorted(state['vms'].items(), key=lambda x: int(x[0])):
        print('%-8s %10.2f %12.2f %12.2f %12.2f %6d %s' %
              (key, s['limit']/100, s['used']/100,
               max(0, s['limit']-s['used']+s['reserve'])/100,
               s['reserve']/100, s['resets'],
               s['hold'] or ('pending' if s['pending'] else 'tracking')))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['init', 'run', 'status', 'resync', 'backup'])
    parser.add_argument('value', nargs='?')
    args = parser.parse_args()
    if os.name == 'nt' or os.geteuid() != 0:
        parser.error('Run on the Linux Virtualizor host as root')
    import fcntl
    os.umask(0o077)
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (STATE_DIR/'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path = STATE_DIR/'state.json'
        state = json.loads(path.read_text()) if path.exists() else None
        if state is not None and (state.get('version') != 2 or 'vms' not in state):
            raise RuntimeError('Invalid state; refusing to overwrite history')
        if args.action in ('status', 'backup'):
            if state is None:
                raise RuntimeError('Not initialized')
            if args.action == 'status':
                show(state)
            else:
                backup = STATE_DIR/('backup-%d.json' % time.time_ns())
                save(backup, state)
                print(backup)
            return
        if args.action == 'init':
            if state is not None:
                raise RuntimeError('Already initialized; history preserved')
            if args.value not in ('minimum-1gb', 'hold'):
                parser.error('Choose init minimum-1gb OR init hold')
        elif state is None:
            raise RuntimeError('State missing; refusing automatic recreation')
        bridge = Bridge()
        snapshot = bridge.snapshot()
        if state is None:
            state = dict(version=2, policy=args.value, vms={})
        if args.action == 'resync':
            key = str(int(args.value or '0'))
            vm = next((v for v in snapshot['vms'] if str(v['id']) == key), None)
            if vm is None:
                raise RuntimeError('Unknown local VPS')
            state['vms'][key] = baseline(vm, snapshot['now'])
            save(path, state)
            log('RESYNC-ACCEPTED', key, 'accepted current panel state; quota unchanged')
            return
        problems = process(state, snapshot, bridge, lambda s: save(path, s))
        if args.action == 'init':
            show(state)
            if not state['vms']:
                raise RuntimeError('No finite-quota guests enrolled')
        if problems:
            raise RuntimeError('Review required for VPS(s): '+','.join(problems))


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print('ERROR:', str(e), file=sys.stderr)
        sys.exit(1)

RC_CORE
cat > "$stage_dir/bridge.php" <<'RC_BRIDGE'
<?php
ini_set('display_errors','0');
error_reporting(0);
if (PHP_SAPI!=='cli') {http_response_code(403);exit;}
define('VIRTUALIZOR',1);
require_once '/usr/local/virtualizor/universal.php';
require_once '/usr/local/virtualizor/sdk/admin.php';
function rb_managed($api,$id) {
    $r=$api->call('index.php?act=managevps&vpsid='.$id);
    if (!is_array($r['vps']??null) || !empty($r['error']) || (int)($r['vps']['vpsid']??0)!==$id)
        throw new Exception('VPS_READ_FAILED');
    return $r['vps'];
}
try {
    if (empty($globals['key']) || empty($globals['pass'])) throw new Exception('CREDENTIALS_UNAVAILABLE');
    $api=new Virtualizor_Admin_API('127.0.0.1',$globals['key'],$globals['pass']);
    $action=$argv[1]??'';
    if ($action==='snapshot') {
        $vms=array();$seen=array();$done=false;
        for ($page=1;$page<=100;$page++) {
            $r=$api->listvs($page,50);
            if (!is_array($r['vs']??null) || !empty($r['error'])) throw new Exception('VPS_LIST_FAILED');
            if (!$r['vs']) {$done=true;break;}
            foreach ($r['vs'] as $v) {
                $id=(int)($v['vpsid']??0);
                if ($id<1 || isset($seen[$id])) throw new Exception('INVALID_PAGINATION');
                $seen[$id]=true;
                if (($v['virt']??'')==='kvm' && (int)($v['serid']??-1)===0) $vms[$id]=$v;
            }
        }
        if (!$done || !$vms) throw new Exception('NO_SUPPORTED_LOCAL_VPS');
        $stats=array();
        foreach (array_chunk(array_keys($vms),20) as $ids) {
            $r=$api->status($ids);
            if (!is_array($r)) throw new Exception('USAGE_READ_FAILED');
            foreach ($r as $id=>$s) $stats[$id]=$s;
        }
        $out=array('now'=>time(),'vms'=>array());
        foreach ($vms as $id=>$v) {
            $used=$stats[$id]['used_bandwidth']??null;
            if (!is_numeric($used) || !is_numeric($v['bandwidth']??null) || $used<0 || $v['bandwidth']<0)
                throw new Exception('USAGE_INVALID');
            if (empty($v['uuid']) || empty($v['vps_name'])) throw new Exception('IDENTITY_MISSING');
            $out['vms'][]=array('id'=>(string)$id,'uuid'=>$v['uuid'],'name'=>$v['vps_name'],
                               'limit'=>(string)$v['bandwidth'],'used'=>(string)$used);
        }
    } elseif ($action==='write') {
        if (count($argv)!==7) throw new Exception('INVALID_ARGUMENTS');
        $id=(int)$argv[2];$target=(int)$argv[3];$expected=(int)$argv[4];
        $uuid=$argv[5];$name=$argv[6];
        if ($id<1 || $target<1 || $expected<1) throw new Exception('INVALID_QUOTA');
        $before=rb_managed($api,$id);
        if (($before['uuid']??'')!==$uuid || ($before['vps_name']??'')!==$name ||
            (int)round((float)$before['bandwidth']*100)!==$expected)
            throw new Exception('QUOTA_CHANGED_BEFORE_WRITE');
        // SDK adds editvps/theme_edit. No other configuration values are posted.
        $api->managevps(array('vpsid'=>$id,'bandwidth'=>$target));
        $after=rb_managed($api,$id);
        if ((float)$after['bandwidth']!==(float)$target) throw new Exception('QUOTA_WRITE_NOT_CONFIRMED');
        foreach (array('uuid','vps_name','serid','plid','uid','hostname','osid','space','ram','swap',
                       'cores','cpu','cpu_percent','network_speed','upload_speed','band_suspend',
                       'mac','nic_type','virtio','io','io_mode','kvm_cache','ips','ips_int','ips_vpc') as $key) {
            if (($before[$key]??null)!==($after[$key]??null)) throw new Exception('NON_QUOTA_FIELD_CHANGED');
        }
        $out=array('ok'=>true,'limit'=>$target);
    } else throw new Exception('UNKNOWN_ACTION');
    echo json_encode($out,JSON_THROW_ON_ERROR),"\n";
} catch (Throwable $e) {
    $code=$e->getMessage();
    if (!preg_match('/^[A-Z_]+$/',$code)) $code='OPERATION_FAILED';
    fwrite(STDERR,'BRIDGE_ERROR: '.$code."\n");exit(1);
}

RC_BRIDGE
cat > "$stage_dir/carryover_manager.py" <<'RC_MANAGER'
#!/usr/bin/env python3
"""Virtualizor KVM bandwidth carry-over with bounded storage and complete removal."""
import argparse
from collections import deque
from contextlib import contextmanager, redirect_stdout, redirect_stderr
from datetime import datetime
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

VERSION = '2.2.0'
DAY = 86400
LOG_BYTES = 5 * 1024 * 1024
LOG_ARCHIVES = 3
LOG_DAYS = 7
BACKUP_COUNT = 5
BACKUP_DAYS = 7
SOURCE_URL = 'https://raw.githubusercontent.com/mmdkevin/kvm-bandwidth-carryover/main/install-reset-carryover.sh'
ASSETS = ('reset_carryover.py', 'bridge.php', 'carryover_manager.py',
          'test_reset_carryover.py', 'test_carryover_manager.py')
CRON = ('SHELL=/bin/bash\n'
        'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
        '* * * * * root timeout 55s /usr/local/sbin/reset-carryover scheduled-run\n')
WRAPPER = ('#!/usr/bin/env bash\nset -euo pipefail\numask 077\n'
           'exec /usr/bin/python3 /opt/reset-carryover/carryover_manager.py "$@"\n')


class Paths:
    def __init__(self, root=None):
        self.root = Path(root) if root is not None else Path('/')
        self.app = self.root/'opt/reset-carryover'
        self.data = self.root/'var/lib/reset-carryover'
        self.state = self.data/'state.json'
        self.paused = self.data/'paused'
        self.heartbeat = self.data/'last-run.json'
        self.cron = self.root/'etc/cron.d/reset-carryover'
        self.rotate = self.root/'etc/logrotate.d/reset-carryover'
        self.log = self.root/'var/log/reset-carryover.log'
        self.command = self.root/'usr/local/sbin/reset-carryover'
        self.alias = self.root/'usr/local/sbin/kvm-bw'
        self.php = self.root/'usr/local/emps/bin/php'
        self.sdk = self.root/'usr/local/virtualizor/sdk/admin.php'
        self.universal = self.root/'usr/local/virtualizor/universal.php'
        self.python = self.root/'usr/bin/python3'


def host_info(root):
    """Read distribution metadata as data; never source/execute os-release."""
    fields = {}
    for relative in ('etc/os-release', 'usr/lib/os-release'):
        file = root/relative
        if not file.is_file():
            continue
        for line in file.read_text(encoding='utf-8').splitlines():
            key, sep, value = line.partition('=')
            if sep and key in ('ID', 'ID_LIKE', 'VERSION_ID', 'PRETTY_NAME'):
                try:
                    parts = shlex.split(value, comments=True)
                    fields[key] = parts[0] if len(parts) == 1 else ''
                except ValueError:
                    pass
        break
    family = {fields.get('ID', ''), *fields.get('ID_LIKE', '').split()}
    debian = bool(family & {'ubuntu', 'debian'})
    rhel = bool(family & {'almalinux', 'rhel', 'centos', 'rocky', 'fedora'})
    if debian:
        hint = ('apt-get update && apt-get install -y python3 cron curl '
                'ca-certificates coreutils bash')
    elif rhel:
        hint = 'dnf install -y python3 cronie curl ca-certificates coreutils bash'
    else:
        hint = 'Install Python 3.9+, cron/cronie, curl, ca-certificates, coreutils and bash.'
    return dict(id=fields.get('ID', 'unknown'), version=fields.get('VERSION_ID', ''),
                name=fields.get('PRETTY_NAME') or 'Linux (distribution unknown)',
                cron_services=('cron', 'crond') if debian else ('crond', 'cron'),
                dependency_hint=hint)


def atomic(path, data, mode=0o600):
    path = Path(path)
    if path.is_symlink():
        raise RuntimeError('Refusing symlink: '+str(path))
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    raw = data.encode() if isinstance(data, str) else data
    fd, tmp = tempfile.mkstemp(prefix='.kvm-bw-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(raw)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def validated_state(path):
    state = json.loads(Path(path).read_text())
    if state.get('version') != 2 or state.get('policy') not in ('minimum-1gb', 'hold'):
        raise RuntimeError('Unsupported accounting data; refusing to reinitialize it')
    if not isinstance(state.get('vms'), dict):
        raise RuntimeError('Invalid saved VPS data')
    for s in state['vms'].values():
        for key in ('name', 'uuid', 'limit', 'used', 'at', 'reserve', 'hold', 'pending', 'resets'):
            if key not in s:
                raise RuntimeError('Incomplete accounting record: '+key)
    return state


def prune_files(files, keep, max_age, max_bytes=None):
    now = time.time()
    entries = sorted(((file.stat().st_mtime, file) for file in files
                      if file.is_file() and not file.is_symlink()),
                     key=lambda item: (item[0], item[1].name), reverse=True)
    retained = 0
    for modified, file in entries:
        if (now - modified > max_age or retained >= keep or
                (max_bytes is not None and file.stat().st_size > max_bytes)):
            file.unlink()
        else:
            retained += 1


class BoundedLog:
    """A UTF-8 print stream; limit each file, including a single large write."""
    encoding = 'utf-8'

    def __init__(self, path):
        self.path = path
        path.parent.mkdir(parents=True, exist_ok=True)
        for file in [path] + [Path(str(path)+'.'+str(i)) for i in range(1, LOG_ARCHIVES+1)]:
            if file.is_symlink():
                raise RuntimeError('Refusing log symlink: '+str(file))
        daily_rotation = False
        if path.exists():
            if time.time() - path.stat().st_mtime > LOG_DAYS * DAY:
                path.unlink()
            elif path.stat().st_size > LOG_BYTES:
                with path.open('rb') as file:
                    file.seek(-LOG_BYTES, os.SEEK_END)
                    tail = file.read().decode('utf-8', errors='ignore').encode('utf-8')
                atomic(path, tail)
            if path.exists():
                daily_rotation = int(path.stat().st_mtime // DAY) != int(time.time() // DAY)
        self.file = path.open('ab')
        os.chmod(path, 0o600)
        if daily_rotation and self.file.tell():
            self.rotate()

    def rotate(self):
        self.file.close()
        oldest = Path(str(self.path)+'.'+str(LOG_ARCHIVES))
        if oldest.exists():
            oldest.unlink()
        for i in range(LOG_ARCHIVES-1, 0, -1):
            file = Path(str(self.path)+'.'+str(i))
            if file.exists():
                os.replace(file, Path(str(self.path)+'.'+str(i+1)))
        os.replace(self.path, Path(str(self.path)+'.1'))
        self.file = self.path.open('ab')
        os.chmod(self.path, 0o600)

    def write(self, text):
        data = text.encode('utf-8', errors='replace')
        while data:
            room = LOG_BYTES - self.file.tell()
            end = min(len(data), max(room, 0))
            while end > 0 and end < len(data) and data[end] & 0xc0 == 0x80:
                end -= 1
            if not end:
                self.rotate()
                continue
            self.file.write(data[:end])
            data = data[end:]
        return len(text)

    def flush(self):
        self.file.flush()

    def isatty(self):
        return False

    def close(self):
        self.file.close()


@contextmanager
def terminal_input():
    """Read commands without requiring a terminal to support seek/update mode."""
    owned = False
    try:
        stream = open('/dev/tty', 'r', encoding='utf-8', errors='replace')
        owned = True
    except OSError:
        if sys.stdin is not None and sys.stdin.isatty():
            stream = sys.stdin
        else:
            raise RuntimeError('No interactive terminal. Add an argument such as upgrade, install, status, or commands.') from None
    try:
        yield stream
    finally:
        if owned:
            stream.close()


class MenuScreen:
    """Keep menu pages in an alternate screen; leave CLI/log output untouched."""
    def __init__(self, output=None):
        self.output = output if output is not None else sys.stdout
        self.enabled = bool(self.output.isatty() and os.environ.get('TERM') != 'dumb')

    def __enter__(self):
        if self.enabled:
            self.output.write('\x1b[?1049h')
            self.output.flush()
        return self

    def clear(self):
        if self.enabled:
            self.output.write('\x1b[2J\x1b[H')
            self.output.flush()

    def __exit__(self, *error):
        if self.enabled:
            self.output.write('\x1b[?1049l')
            self.output.flush()


class Manager:
    def __init__(self, paths=None, source=None):
        self.p = paths or Paths()
        self.source = Path(source or Path(__file__).resolve().parent)

    def missing_commands(self):
        return [name for name in ('systemctl', 'timeout', 'bash')
                if shutil.which(name) is None]

    @contextmanager
    def locked_log(self, nonblocking=False):
        self.guard_directories()
        with (self.p.data/'log.lock').open('a') as file:
            if os.name != 'nt':
                import fcntl
                fcntl.flock(file, fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0))
            yield

    def log_archives(self):
        pattern = re.compile(re.escape(self.p.log.name)+r'(?:\.\d+(?:\.gz)?|-\d+(?:\.gz)?)$')
        return [file for file in self.p.log.parent.glob(self.p.log.name+'*')
                if pattern.fullmatch(file.name)]

    def prune_logs(self):
        prune_files(self.log_archives(), LOG_ARCHIVES, LOG_DAYS * DAY, LOG_BYTES)

    def prune_backups(self):
        folder = self.p.data/'backups'
        if folder.is_symlink():
            raise RuntimeError('Backup directory must not be a symlink')
        files = list(folder.glob('backup-*.tar.gz')) + list(self.p.data.glob('backup-*.json'))
        prune_files(files, BACKUP_COUNT, BACKUP_DAYS * DAY)

    def scheduled_run(self):
        if not self.installed() or self.p.paused.exists() or not self.p.cron.is_file():
            return 0
        try:
            with self.locked_log(nonblocking=True):
                # Uninstall may have completed while this process waited to enter.
                if not self.installed() or self.p.paused.exists() or not self.p.cron.is_file():
                    return 0
                self.prune_logs()
                stream = BoundedLog(self.p.log)
                try:
                    with redirect_stdout(stream), redirect_stderr(stream):
                        try:
                            return self.run(scheduled=True)
                        except Exception as error:
                            print('ERROR:', error)
                            return 1
                finally:
                    stream.close()
                    self.prune_logs()
        except BlockingIOError:
            return 0

    def cron_status(self):
        info = host_info(self.p.root)
        for service in info['cron_services']:
            try:
                result = subprocess.run(['systemctl', 'is-active', '--quiet', service],
                                        capture_output=True, timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                continue
            if result.returncode == 0:
                return service, True
        return info['cron_services'][0], False

    def guard_directories(self):
        for path in (self.p.app, self.p.data):
            if path.is_symlink():
                raise RuntimeError('Managed directory must not be a symlink: '+str(path))
        self.p.data.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.p.data, 0o700)
        for path in (self.p.state, self.p.data/'state.previous.json', self.p.heartbeat,
                     self.p.paused, self.p.data/'lock', self.p.data/'operation.lock',
                     self.p.data/'log.lock'):
            if path.is_symlink():
                raise RuntimeError('Managed data file must not be a symlink: '+str(path))

    @contextmanager
    def locked(self, core=False, nonblocking=False):
        self.guard_directories()
        handles = []
        try:
            for name in ('operation.lock', 'lock') if core else ('operation.lock',):
                f = (self.p.data/name).open('a')
                handles.append(f)
                if os.name != 'nt':
                    import fcntl
                    flags = fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0)
                    fcntl.flock(f, flags)
            yield
        finally:
            for f in reversed(handles):
                f.close()

    def installed(self):
        return (self.p.app/'reset_carryover.py').is_file()

    def enabled(self):
        return self.p.cron.is_file() and not self.p.paused.exists()

    def installed_version(self):
        version = self.p.app/'VERSION'
        return version.read_text().strip() if version.is_file() else ('legacy' if self.installed() else 'not installed')

    def heartbeat(self):
        if not self.p.heartbeat.exists():
            return None
        try:
            value = json.loads(self.p.heartbeat.read_text())
            if not isinstance(value, dict):
                raise ValueError('not an object')
            return value
        except (OSError, ValueError):
            return {'last_success': None, 'metadata_error': 'Run metadata is unreadable; the next check will rebuild it'}

    def _backup(self):
        folder = self.p.data/'backups'
        if folder.is_symlink():
            raise RuntimeError('Backup directory must not be a symlink')
        folder.mkdir(mode=0o700, parents=True, exist_ok=True)
        archive = folder/('backup-'+datetime.now().strftime('%Y%m%d-%H%M%S-')+str(time.time_ns())+'.tar.gz')
        selected = [(self.p.state, 'data/state.json'),
                    (self.p.data/'state.previous.json', 'data/state.previous.json'),
                    (self.p.heartbeat, 'data/last-run.json'),
                    (self.p.paused, 'data/paused'), (self.p.cron, 'config/cron'),
                    (self.p.command, 'config/reset-carryover'), (self.p.alias, 'config/kvm-bw')]
        selected += [(self.p.app/name, 'app/'+name) for name in (*ASSETS, 'VERSION')]
        with tarfile.open(archive, 'w:gz') as tar:
            for file, name in selected:
                if file.is_file() and not file.is_symlink():
                    tar.add(file, arcname=name, recursive=False)
        os.chmod(archive, 0o600)
        self.prune_backups()
        return archive

    def backup(self):
        with self.locked(core=True):
            if not self.p.state.exists():
                raise RuntimeError('No accounting data exists')
            validated_state(self.p.state)
            path = self._backup()
        print('Backup:', path)
        return path

    def validate_source(self):
        for name in ASSETS:
            if not (self.source/name).is_file():
                raise RuntimeError('Incomplete package: '+name)
            if name.endswith('.py'):
                compile((self.source/name).read_text(encoding='utf-8'), name, 'exec')
        result = subprocess.run([str(self.p.php), '-l', str(self.source/'bridge.php')],
                                capture_output=True, text=True, timeout=15)
        if result.returncode:
            raise RuntimeError('PHP syntax validation failed')
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
        result = subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s',
                                 str(self.source), '-p', 'test_*.py', '-q'],
                                env=env, capture_output=True, text=True, timeout=90)
        if result.returncode:
            raise RuntimeError('Package tests failed:\n'+result.stdout[-2000:]+result.stderr[-2000:])
        print('Package syntax and isolated tests: PASS')

    def preflight(self):
        if sys.version_info < (3, 9):
            raise RuntimeError('Python 3.9 or later is required')
        info = host_info(self.p.root)
        missing = self.missing_commands()
        if missing:
            raise RuntimeError('Missing host commands: '+', '.join(missing)+
                               '. Install dependencies: '+info['dependency_hint'])
        if not self.p.python.is_file():
            raise RuntimeError('/usr/bin/python3 is required. '+info['dependency_hint'])
        for file in (self.p.php, self.p.sdk, self.p.universal):
            if not file.is_file():
                raise RuntimeError('Required file is missing: '+str(file))
        old_cron = self.p.root/'etc/cron.d/native-carryover'
        if old_cron.exists():
            raise RuntimeError('Disable the old native-carryover Cron first; its data will not be removed')
        if subprocess.run(['systemctl', 'is-active', '--quiet', 'vps-credit.timer'],
                          capture_output=True, timeout=10).returncode == 0:
            raise RuntimeError('Old network-control version is active. Run: vps-credit disable')
        service, active = self.cron_status()
        if not active:
            raise RuntimeError('No active cron/crond service. Install dependencies if missing: '+
                               info['dependency_hint']+'. Then run: systemctl enable --now '+service)
        print('Host:', info['name'], '| Cron:', service)

    def core_command(self, *args):
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
        return subprocess.run([sys.executable, str(self.p.app/'reset_carryover.py'), *args],
                              env=env, capture_output=True, text=True, timeout=120)

    def _schedule(self, enabled):
        if enabled:
            self.p.log.parent.mkdir(parents=True, exist_ok=True)
            self.p.log.touch(mode=0o600, exist_ok=True)
            atomic(self.p.cron, CRON, 0o644)
            if self.p.paused.exists():
                self.p.paused.unlink()
        else:
            atomic(self.p.paused, 'Automatic checks are paused.\n')
            if self.p.cron.exists():
                self.p.cron.unlink()

    def install(self, policy=None):
        self.guard_directories()
        self.preflight()
        self.validate_source()  # No installed files are replaced before validation.
        with self.locked(core=True):
            existing = self.installed()
            was_enabled = self.enabled()
            # An active installation is upgraded. Leftovers after removal are
            # never used as the baseline for a new installation.
            old_state = self.p.state.read_bytes() if existing and self.p.state.exists() else None
            if existing and old_state is None:
                raise RuntimeError('Installed accounting state is missing; inspect before upgrading')
            if old_state is not None:
                old_saved = validated_state(self.p.state)
                if policy is not None and policy != old_saved['policy']:
                    raise RuntimeError('Upgrade preserves the current policy. Use: kvm-bw policy '+policy)
            backup = self._backup() if existing else None
            files = [self.p.app/name for name in (*ASSETS, 'VERSION')]
            files += [self.p.command, self.p.alias, self.p.cron, self.p.rotate, self.p.paused]
            files += [self.p.state, self.p.data/'state.previous.json', self.p.heartbeat]
            previous = {file: (file.read_bytes(), file.stat().st_mode & 0o777)
                        if file.is_file() and not file.is_symlink() else None for file in files}
            if any(file.is_symlink() for file in files):
                raise RuntimeError('Refusing a symlink in managed installation files')
            try:
                self.p.app.mkdir(mode=0o700, parents=True, exist_ok=True)
                for name in ASSETS:
                    atomic(self.p.app/name, (self.source/name).read_bytes())
                atomic(self.p.app/'VERSION', VERSION+'\n')
                atomic(self.p.command, WRAPPER, 0o700)
                atomic(self.p.alias, WRAPPER, 0o700)
                if old_state is None:
                    # Initialize in this process while both locks remain held.
                    # Do not start a subprocess that would re-lock the ledger.
                    self.initialize_unlocked(policy or 'minimum-1gb')
                    for file in (self.p.data/'state.previous.json', self.p.heartbeat):
                        if file.exists():
                            file.unlink()
                elif self.p.state.read_bytes() != old_state:
                    raise RuntimeError('Accounting data changed unexpectedly during upgrade')
                if self.p.rotate.exists():
                    self.p.rotate.unlink()  # Rotation is handled by scheduled-run.
                self.prune_backups()
                with self.locked_log():
                    self.prune_logs()
                    stream = BoundedLog(self.p.log)
                    stream.close()
                self._schedule(was_enabled if existing else True)
            except Exception:
                for file, contents in previous.items():
                    if contents is None:
                        if file.is_file() and not file.is_symlink():
                            file.unlink()
                    else:
                        atomic(file, contents[0], contents[1])
                raise
        print(('UPGRADED' if existing else 'INSTALLED')+' v'+VERSION)
        print('Accounting history preserved.' if old_state is not None else 'Current panel usage saved as the initial baseline.')
        print('Automatic checks:', 'enabled (every minute)' if self.enabled() else 'paused')
        if backup:
            print('Pre-upgrade backup:', backup)

    def initialize_unlocked(self, policy):
        # Fresh initialization in this process avoids re-locking from a subprocess.
        spec = importlib.util.spec_from_file_location('_kvm_bw_install_core', self.p.app/'reset_carryover.py')
        core = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(core)
        core.BRIDGE = str(self.p.app/'bridge.php')
        core.PHP = str(self.p.php)
        bridge = core.Bridge()
        snapshot = bridge.snapshot()
        state = dict(version=2, policy=policy, vms={})
        problems = core.process(state, snapshot, bridge, lambda s: None)
        if problems or not state['vms']:
            raise RuntimeError('Initial enrollment failed; Cron not enabled')
        core.save(self.p.state, state)

    def pause(self):
        self.guard_directories()
        # Stop new scheduled checks before waiting for an in-flight worker.
        atomic(self.p.paused, 'Automatic checks are paused.\n')
        with self.locked(core=True):
            self._schedule(False)
        print('Automatic checks paused. Quotas and accounting history unchanged.')

    def enable(self):
        if not self.installed() or not self.p.state.exists():
            raise RuntimeError('Install the application first')
        self.preflight()
        with self.locked(core=True):
            validated_state(self.p.state)
            self._schedule(True)
        print('Automatic checks enabled: every minute.')

    def run(self, scheduled=False):
        if scheduled and (self.p.paused.exists() or not self.p.cron.exists()):
            return 0
        try:
            with self.locked(nonblocking=True):
                if scheduled and self.p.paused.exists():
                    return 0
                if not self.installed() or not self.p.state.exists():
                    raise RuntimeError('Not installed or accounting state missing')
                self.prune_backups()
                started = time.time()
                try:
                    result = self.core_command('run')
                    if result.stdout:
                        print(result.stdout, end='')
                    if result.stderr:
                        print(result.stderr, end='', file=sys.stderr)
                    code = result.returncode
                    detail = result.stderr.strip()[-500:] if code else ''
                except subprocess.TimeoutExpired:
                    code, detail = 124, 'Accounting check timed out; journal retained'
                except Exception as e:
                    code, detail = 1, str(e)[:500]
                finished = time.time()
                previous = self.heartbeat() or {}
                heartbeat = dict(version=VERSION, started=started, finished=finished,
                                 duration=round(finished-started, 2), exit_code=code,
                                 last_success=finished if code == 0 else previous.get('last_success'),
                                 error=detail)
                atomic(self.p.heartbeat, json.dumps(heartbeat, indent=2))
                print(datetime.now().astimezone().isoformat(timespec='seconds'),
                      'RUN_OK' if code == 0 else 'RUN_FAILED', 'exit='+str(code))
                return code
        except BlockingIOError:
            print('Another accounting/management operation is running; this check was skipped.')
            return 0

    def status(self, as_json=False):
        state = validated_state(self.p.state) if self.p.state.exists() else None
        heartbeat = self.heartbeat()
        tracked = len(state['vms']) if state else 0
        held = sum(bool(s['hold']) for s in state['vms'].values()) if state else 0
        pending = sum(bool(s['pending']) for s in state['vms'].values()) if state else 0
        last = heartbeat.get('last_success') if heartbeat else (
            self.p.state.stat().st_mtime if state else None)
        report = dict(version=self.installed_version(), available_version=VERSION,
                      installed=self.installed(), enabled=self.enabled(), tracked=tracked,
                      held=held, pending=pending, last_success=last,
                      stale=bool(self.enabled() and (last is None or time.time()-last > 180)),
                      last_run=heartbeat, state_path=str(self.p.state), vms=state['vms'] if state else {})
        if as_json:
            print(json.dumps(report, indent=2))
            return report
        print('KVM Bandwidth Carryover | installed:', report['version'])
        print('Automatic checks:', 'ENABLED / every minute' if report['enabled'] else 'PAUSED / not configured')
        print('VPS: %d tracked | %d need review | %d pending' % (tracked, held, pending))
        print('Last successful check:', datetime.fromtimestamp(last).astimezone().isoformat(timespec='seconds') if last else 'not yet recorded')
        if heartbeat and heartbeat.get('metadata_error'):
            print('ATTENTION:', heartbeat['metadata_error'])
        if report['stale']:
            print('ATTENTION: no successful check in the last 3 minutes. Run: kvm-bw doctor')
        if state:
            print('VPS_ID    LIMIT_GB     USED_GB     LEFT_GB  STATUS')
            for key, s in sorted(state['vms'].items(), key=lambda pair: int(pair[0])):
                print('%-8s %10.2f %11.2f %11.2f  %s' %
                      (key, s['limit']/100, s['used']/100,
                       max(0, s['limit']-s['used']+s['reserve'])/100,
                       s['hold'] or ('pending' if s['pending'] else 'tracking')))
        return report

    def logs(self, lines=30):
        if not self.p.log.exists():
            print('No application log yet.')
            return
        with self.p.log.open(errors='replace') as file:
            print(''.join(deque(file, maxlen=min(500, max(1, lines)))), end='')

    def preview(self):
        with self.locked():
            state = validated_state(self.p.state)
            spec = importlib.util.spec_from_file_location('_kvm_bw_preview_core', self.p.app/'reset_carryover.py')
            core = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(core)
            core.BRIDGE, core.PHP = str(self.p.app/'bridge.php'), str(self.p.php)
            snapshot = core.Bridge().snapshot()
            print('PREVIEW ONLY: no accounting state or quotas will be changed.')
            for vm in snapshot['vms']:
                key = str(vm['id'])
                old = state['vms'].get(key)
                if old and old['pending']:
                    print('VPS', key, 'pending correction; inspect status')
                    continue
                event, fresh, job = core.decide(old, vm, snapshot['now'], state['policy'])
                print('VPS', key, ('quota %s -> %s GB' % (vm['limit'], job['target'])) if job else event,
                      fresh['hold'] or '')

    def resync(self, key):
        with self.locked():
            with self.locked_core_only():
                validated_state(self.p.state)
                backup = self._backup()
            result = self.core_command('resync', str(int(key)))
            print(result.stdout, end='')
            if result.returncode:
                raise RuntimeError(result.stderr.strip() or 'Resync failed')
            print('Previous baseline backup:', backup)

    @contextmanager
    def locked_core_only(self):
        with (self.p.data/'lock').open('a') as file:
            if os.name != 'nt':
                import fcntl
                fcntl.flock(file, fcntl.LOCK_EX)
            yield

    def policy(self, value):
        with self.locked(core=True):
            state = validated_state(self.p.state)
            backup = self._backup()
            state['policy'] = value
            atomic(self.p.state, json.dumps(state, indent=2))
        print('Under-1GB policy:', value, '| backup:', backup)

    def doctor(self):
        checks = []
        def check(label, good, detail=''):
            checks.append(bool(good))
            print(('PASS' if good else 'FAIL')+' '+label+(' | '+detail if detail else ''))
        check('Python >= 3.9', sys.version_info >= (3, 9), sys.version.split()[0])
        info = host_info(self.p.root)
        print('INFO Host:', info['name'])
        missing = self.missing_commands()
        check('Host commands available', not missing,
              ', '.join(missing)+' | '+info['dependency_hint'] if missing else '')
        for file in (self.p.python, self.p.php, self.p.sdk, self.p.universal, self.p.app/'bridge.php'):
            check('Required file '+file.name, file.is_file())
        try:
            state = validated_state(self.p.state)
            check('Accounting data readable', True, '%d VPS' % len(state['vms']))
            check('No held or pending corrections', not any(s['hold'] or s['pending'] for s in state['vms'].values()))
        except Exception as e:
            check('Accounting data readable', False, str(e))
        if self.enabled():
            service, active = self.cron_status()
            check('Cron service active', active, service)
            check('Cron uses managed scheduled-run command', 'scheduled-run' in self.p.cron.read_text())
        else:
            print('INFO Automatic checks are paused / not configured.')
        heartbeat = self.heartbeat()
        if heartbeat:
            check('Run metadata readable', not heartbeat.get('metadata_error'))
            if heartbeat.get('exit_code') is not None:
                check('Last accounting check succeeded', heartbeat['exit_code'] == 0)
        try:
            result = subprocess.run([str(self.p.php), str(self.p.app/'bridge.php'), 'snapshot'],
                                    capture_output=True, text=True, timeout=45)
            snapshot = json.loads(result.stdout) if result.returncode == 0 else None
            check('Read-only Virtualizor API check', bool(snapshot and snapshot.get('vms')))
        except Exception:
            check('Read-only Virtualizor API check', False)
        return 0 if all(checks) else 1

    def uninstall(self):
        remnants = any(path.exists() or path.is_symlink() for path in
                       (self.p.app, self.p.data, self.p.command, self.p.alias,
                        self.p.cron, self.p.rotate, self.p.log)) or bool(self.log_archives())
        if not remnants:
            print('Not installed. Nothing to remove.')
            return
        # Verify exact owned paths before recursive removal of the private data
        # directory. Never follow an alternate data/app root or a symlink.
        for path, relative in ((self.p.data, 'var/lib/reset-carryover'),
                               (self.p.app, 'opt/reset-carryover'),
                               (self.p.cron, 'etc/cron.d/reset-carryover'),
                               (self.p.rotate, 'etc/logrotate.d/reset-carryover'),
                               (self.p.command, 'usr/local/sbin/reset-carryover'),
                               (self.p.alias, 'usr/local/sbin/kvm-bw'),
                               (self.p.log, 'var/log/reset-carryover.log')):
            expected = self.p.root.resolve()/relative
            if path.is_symlink() or path.resolve() != expected:
                raise RuntimeError('Refusing unexpected removal target: '+str(path))
        self.guard_directories()
        self._schedule(False)
        with self.locked(core=True):
            owned = [self.p.cron, self.p.rotate, self.p.command, self.p.alias]
            owned += [self.p.app/name for name in (*ASSETS, 'VERSION')]
            for file in owned:
                if file.is_symlink():
                    raise RuntimeError('Refusing unexpected symlink during uninstall: '+str(file))
                if file.is_file():
                    file.unlink()
            # Delete only our own bytecode files, never recurse over unrelated files.
            cache = self.p.app/'__pycache__'
            if cache.is_dir() and not cache.is_symlink():
                stems = {Path(name).stem for name in ASSETS if name.endswith('.py')}
                for file in cache.glob('*.pyc'):
                    if file.name.split('.')[0] in stems and file.is_file() and not file.is_symlink():
                        file.unlink()
                if not any(cache.iterdir()):
                    cache.rmdir()
            if self.p.app.is_dir() and not any(self.p.app.iterdir()):
                self.p.app.rmdir()
            with self.locked_log():
                for file in [self.p.log] + self.log_archives():
                    if file.is_symlink() or file.is_file():
                        file.unlink()
        # Locks must be closed before deleting their directory on Windows too.
        shutil.rmtree(self.p.data)
        print('UNINSTALLED: application, Cron, accounting data, backups and logs removed.')
        print('Panel quotas and Virtualizor jobs unchanged.')

    def remote_upgrade(self):
        with urllib.request.urlopen(SOURCE_URL, timeout=30) as response:
            payload = response.read(2_000_001)
        if len(payload) > 2_000_000 or b'# KVM_BW_MANAGER_BOOTSTRAP_V2' not in payload[:500]:
            raise RuntimeError('GitHub does not contain the new management installer yet. Upload the new package first.')
        with tempfile.TemporaryDirectory(prefix='kvm-bw-upgrade-') as folder:
            file = Path(folder)/'install.sh'
            file.write_bytes(payload)
            os.chmod(file, 0o700)
            return subprocess.run(['bash', str(file), 'upgrade']).returncode

    def menu(self):
        with terminal_input() as tty, MenuScreen() as screen:
            def ask(prompt):
                print(prompt, end='', flush=True)
                try:
                    line = tty.readline()
                except OSError:
                    return None
                return line.strip() if line else None
            while True:
                screen.clear()
                print('KVM Bandwidth Carryover v'+VERSION+' | installed: '+self.installed_version())
                print('-' * 68)
                print('1) Install / Upgrade\n2) Status\n3) Preview changes (read-only)\n4) Run one check')
                print('5) Enable automatic checks\n6) Pause automatic checks\n7) Logs\n8) Doctor')
                print('9) Backup\n10) Commands\n11) Uninstall completely\n0) Exit')
                choice = ask('Select: ')
                try:
                    if choice is None or choice == '0':
                        return 0
                    screen.clear()
                    titles = {'1': 'Install / Upgrade', '2': 'Status', '3': 'Preview changes',
                              '4': 'Run one check', '5': 'Enable automatic checks',
                              '6': 'Pause automatic checks', '7': 'Logs', '8': 'Doctor',
                              '9': 'Backup', '10': 'Commands', '11': 'Uninstall'}
                    print('KVM Bandwidth Carryover | '+titles.get(choice, 'Unknown option'))
                    print('-' * 68)
                    actions = {'1': lambda: self.remote_upgrade() if self.source.resolve() == self.p.app.resolve() else self.install(),
                               '2': self.status, '3': self.preview, '4': self.run, '5': self.enable,
                               '6': self.pause, '7': self.logs, '8': self.doctor, '9': self.backup,
                               '10': print_commands, '11': self.uninstall}
                    if choice not in actions:
                        print('Unknown choice.')
                    else:
                        actions[choice]()
                except Exception as e:
                    print('ERROR:', e)
                next_choice = ask('\nEnter to continue, or q to exit: ')
                if next_choice is None or next_choice.lower() == 'q':
                    return 0


def print_commands():
    print('''kvm-bw                     Interactive menu
kvm-bw status              Version, Cron, last check and VPS balances
kvm-bw status --json       Machine-readable status
kvm-bw preview             Preview quota corrections without writing
kvm-bw run                 Process one accounting check now
kvm-bw enable / start      Enable the one-minute Cron
kvm-bw disable / stop      Pause Cron and wait for current check to finish
kvm-bw logs --lines 50      Read recent application logs
kvm-bw doctor              Read-only dependency/API/health checks
kvm-bw backup              Back up ledger, application and job settings
kvm-bw resync VPS_ID       Accept current panel state as the new baseline
kvm-bw policy hold         Hold corrections when the balance is below 1GB
kvm-bw policy minimum-1gb  Use a minimum finite quota of 1GB
kvm-bw upgrade             Download a newer installer; preserve history
kvm-bw uninstall           Remove program/Cron, accounting data, logs and backups
kvm-bw version             Print version
The legacy reset-carryover command supports these same subcommands.''')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', action='version', version=VERSION)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parent, help=argparse.SUPPRESS)
    sub = parser.add_subparsers(dest='command')
    for name in ('menu', 'commands', 'version', 'upgrade', 'uninstall', 'enable', 'disable', 'start', 'stop',
                 'doctor', 'backup', 'preview', 'run', 'scheduled-run'):
        sub.add_parser(name)
    install = sub.add_parser('install')
    install.add_argument('--policy', choices=['minimum-1gb', 'hold'])
    status = sub.add_parser('status')
    status.add_argument('--json', action='store_true')
    logs = sub.add_parser('logs')
    logs.add_argument('--lines', type=int, default=30)
    resync = sub.add_parser('resync')
    resync.add_argument('vps_id', type=int)
    policy = sub.add_parser('policy')
    policy.add_argument('value', choices=['minimum-1gb', 'hold'])
    args = parser.parse_args()
    command = args.command or 'menu'
    if command == 'commands':
        print_commands()
        return 0
    if command == 'version':
        print(VERSION)
        return 0
    if sys.platform != 'linux' or os.geteuid() != 0:
        parser.error('Run on the Linux Virtualizor host as root')
    os.umask(0o077)
    manager = Manager(source=args.source)
    if command == 'menu':
        return manager.menu()
    if command == 'install':
        manager.install(args.policy)
    elif command == 'upgrade':
        if manager.source.resolve() == manager.p.app.resolve():
            return manager.remote_upgrade()
        manager.install()
    elif command == 'status':
        manager.status(args.json)
    elif command == 'logs':
        manager.logs(args.lines)
    elif command in ('disable', 'stop'):
        manager.pause()
    elif command in ('enable', 'start'):
        manager.enable()
    elif command == 'uninstall':
        manager.uninstall()
    elif command == 'backup':
        manager.backup()
    elif command == 'preview':
        manager.preview()
    elif command == 'resync':
        manager.resync(args.vps_id)
    elif command == 'policy':
        manager.policy(args.value)
    elif command == 'doctor':
        return manager.doctor()
    elif command == 'scheduled-run':
        return manager.scheduled_run()
    elif command == 'run':
        return manager.run()
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('\nCancelled.', file=sys.stderr)
        sys.exit(130)
    except Exception as error:
        print('ERROR:', error, file=sys.stderr)
        sys.exit(1)

RC_MANAGER
cat > "$stage_dir/test_reset_carryover.py" <<'RC_CORE_TEST'
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import reset_carryover as r


class FakeBridge:
    def __init__(self, saved):
        self.saved = saved
        self.writes = []

    def write(self, key, job):
        assert self.saved[-1]['vms'][key]['pending'] is not None
        self.writes.append((key, copy.deepcopy(job)))
        return {'ok': True}


class ResetTests(unittest.TestCase):
    def setUp(self):
        quiet = patch.object(r, 'log')
        quiet.start()
        self.addCleanup(quiet.stop)
        self.vm = dict(id='101', name='demo-vm', uuid='known', limit='5000', used='4300')
        self.old = r.baseline(self.vm, 100)
        self.new = dict(self.vm, used='0')

    def decide(self, **kwargs):
        return r.decide(self.old, self.new, 160, **kwargs)

    def test_requested_example(self):
        _, state, job = self.decide()
        self.assertEqual(job['target'], 700)
        self.assertEqual(state['used'], 0)

    def test_usage_after_reset_is_not_refunded(self):
        self.new['used'] = '20'
        _, state, job = self.decide()
        self.assertEqual(job['target'], 700)
        self.assertEqual(state['limit']-state['used'], 68000)

    def test_every_drop_is_reset_even_without_period_change_or_log(self):
        self.new['used'] = '4000'
        self.assertEqual(self.decide()[2]['target'], 700)

    def test_zero_stays_zero_without_double_deduction(self):
        _, state, job = self.decide()
        self.assertIsNone(r.decide(state, dict(self.new, limit='700'), 220)[2])

    def test_increasing_usage_does_not_change_quota(self):
        self.new['used'] = '4301'
        self.assertIsNone(self.decide()[2])

    def test_normal_manual_topup_needs_no_script_write(self):
        self.new.update(limit='6300', used='4301')
        _, state, job = self.decide()
        self.assertIsNone(job)
        self.assertEqual(state['limit']-state['used'], 199900)

    def test_topup_during_reset_interval(self):
        self.new['limit'] = '6300'
        self.assertEqual(self.decide()[2]['target'], 2000)

    def test_manual_reduction_during_reset(self):
        self.new['limit'] = '4800'
        self.assertEqual(self.decide()[2]['target'], 500)

    def test_fraction_is_retained(self):
        self.old['used'] = r.amount('4299.49')
        _, state, job = self.decide()
        self.assertEqual((job['target'], state['reserve']), (700, 51))

    def test_fraction_applies_at_next_reset(self):
        self.old.update(limit=70000, used=20000, reserve=51)
        self.new.update(limit='700')
        _, state, job = self.decide()
        self.assertEqual((job['target'], state['reserve']), (500, 51))

    def test_never_write_zero_for_exhausted_quota(self):
        self.old['used'] = self.old['limit']
        _, state, job = self.decide()
        self.assertEqual((job['target'], state['reserve']), (1, -100))

    def test_deficit_is_charged_against_future_topup(self):
        self.old.update(limit=100, used=100, reserve=-100)
        self.new.update(limit='1301')
        self.assertEqual(self.decide()[2]['target'], 1299)

    def test_alternative_hold_policy(self):
        self.old['used'] = self.old['limit']
        _, state, job = self.decide(policy='hold')
        self.assertIsNone(job)
        self.assertTrue(state['hold'])

    def test_unlimited_transition_is_not_a_topup(self):
        self.new['limit'] = '0'
        self.assertTrue(self.decide()[1]['hold'])

    def test_replaced_vm_is_not_written(self):
        self.new['uuid'] = 'replacement'
        self.assertTrue(self.decide()[1]['hold'])

    def test_fractional_operator_quota_is_rejected(self):
        self.new['limit'] = '5000.5'
        with self.assertRaises(ValueError):
            self.decide()

    def test_invalid_numbers_are_rejected(self):
        for value in ('NaN', 'Infinity', '-1'):
            with self.assertRaises(ValueError):
                r.amount(value)

    def state(self):
        return dict(version=2, policy='minimum-1gb', vms={'101': copy.deepcopy(self.old)})

    def snap(self, vm=None):
        return dict(now=160, vms=[copy.deepcopy(vm or self.new)])

    def test_real_process_persists_before_write_and_is_idempotent(self):
        state = self.state()
        saved = []
        bridge = FakeBridge(saved)
        r.process(state, self.snap(), bridge, lambda s: saved.append(copy.deepcopy(s)))
        self.assertEqual(bridge.writes[0][1]['target'], 700)
        r.process(state, self.snap(dict(self.new, limit='700')), bridge,
                  lambda s: saved.append(copy.deepcopy(s)))
        self.assertEqual(len(bridge.writes), 1)
        self.assertEqual(state['vms']['101']['resets'], 1)

    def test_crash_after_write_is_not_charged_twice(self):
        state = self.state()
        state['vms']['101']['pending'] = self.decide()[2]
        saved = []
        bridge = FakeBridge(saved)
        r.process(state, self.snap(dict(self.new, limit='700')), bridge,
                  lambda s: saved.append(copy.deepcopy(s)))
        self.assertEqual(bridge.writes, [])
        self.assertEqual(state['vms']['101']['limit'], 70000)

    def test_crash_before_write_retries_once(self):
        state = self.state()
        state['vms']['101']['pending'] = self.decide()[2]
        saved = [copy.deepcopy(state)]
        bridge = FakeBridge(saved)
        r.process(state, self.snap(), bridge, lambda s: saved.append(copy.deepcopy(s)))
        self.assertEqual(len(bridge.writes), 1)
        self.assertEqual(state['vms']['101']['limit'], 70000)

    def test_second_reset_after_interrupted_write_is_not_lost(self):
        state = self.state()
        self.new['used'] = '20'
        state['vms']['101']['pending'] = self.decide()[2]
        saved = []
        bridge = FakeBridge(saved)
        r.process(state, self.snap(dict(self.new, limit='700', used='0')), bridge,
                  lambda s: saved.append(copy.deepcopy(s)))
        self.assertEqual(bridge.writes[0][1]['target'], 680)
        self.assertEqual(state['vms']['101']['resets'], 2)

    def test_concurrent_operator_edit_is_not_overwritten_during_recovery(self):
        state = self.state()
        state['vms']['101']['pending'] = self.decide()[2]
        saved = []
        bridge = FakeBridge(saved)
        issues = r.process(state, self.snap(dict(self.new, limit='5300')), bridge,
                           lambda s: saved.append(copy.deepcopy(s)))
        self.assertEqual(bridge.writes, [])
        self.assertEqual(issues, ['101'])

    def test_failed_write_retains_intent_and_holds(self):
        class FailBridge(FakeBridge):
            def write(self, key, job):
                raise RuntimeError('test failure')
        state = self.state()
        saved = []
        bridge = FailBridge(saved)
        r.process(state, self.snap(), bridge, lambda s: saved.append(copy.deepcopy(s)))
        self.assertIsNotNone(state['vms']['101']['pending'])
        self.assertTrue(state['vms']['101']['hold'])

    def test_unknown_metadata_does_not_restore_manual_reset_behavior(self):
        snap = self.snap()
        snap.update(mode=1, resets=[dict(action='bwreset', id='101', status='1')])
        state = self.state()
        saved = []
        bridge = FakeBridge(saved)
        r.process(state, snap, bridge, lambda s: saved.append(copy.deepcopy(s)))
        self.assertEqual(bridge.writes[0][1]['target'], 700)

    def test_atomic_save_and_backup(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'state.json'
            r.save(path, {'value': 1})
            r.save(path, {'value': 2})
            self.assertEqual(json.loads(path.read_text())['value'], 2)
            self.assertEqual(json.loads(path.with_suffix('.previous.json').read_text())['value'], 1)

    def test_missing_guest_is_retained_for_thirty_days_then_forgotten(self):
        state = self.state()
        saved = []
        bridge = FakeBridge(saved)
        for now in (1000, 1000+r.ABSENT_RETENTION-1):
            r.process(state, dict(now=now, vms=[]), bridge,
                      lambda value: saved.append(copy.deepcopy(value)))
            self.assertIn('101', state['vms'])
        r.process(state, dict(now=1000+r.ABSENT_RETENTION, vms=[]), bridge,
                  lambda value: saved.append(copy.deepcopy(value)))
        self.assertNotIn('101', state['vms'])
        self.assertEqual(bridge.writes, [])
        self.assertEqual(saved[-1]['vms'], {})

    def test_old_held_guest_that_is_still_present_is_not_forgotten(self):
        state = self.state()
        state['vms']['101']['hold'] = 'review'
        saved = []
        bridge = FakeBridge(saved)
        r.process(state, dict(now=100*r.ABSENT_RETENTION, vms=[self.new]), bridge,
                  lambda value: saved.append(copy.deepcopy(value)))
        self.assertIn('101', state['vms'])
        self.assertEqual(state['vms']['101']['hold'], 'review')
        self.assertNotIn('missing_since', state['vms']['101'])
        self.assertEqual(bridge.writes, [])

    def test_returning_guest_clears_absence_timer_before_expiry(self):
        state = self.state()
        state['vms']['101']['missing_since'] = 1
        state['vms']['101']['hold'] = 'review'
        saved = []
        bridge = FakeBridge(saved)
        r.process(state, self.snap(), bridge, lambda value: saved.append(copy.deepcopy(value)))
        self.assertNotIn('missing_since', state['vms']['101'])
        self.assertEqual(bridge.writes, [])


if __name__ == '__main__':
    unittest.main()

RC_CORE_TEST
cat > "$stage_dir/test_carryover_manager.py" <<'RC_MANAGER_TEST'
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import carryover_manager as m
import reset_carryover as core


def state():
    return dict(version=2, policy='minimum-1gb', vms={
        '101': dict(name='demo-vm', uuid='known', limit=500000, used=430000,
                    at=123, reserve=52, hold=None, pending=None, resets=3)})


class TestManager(m.Manager):
    __test__ = False

    def preflight(self):
        pass

    def validate_source(self):
        pass

    def initialize_unlocked(self, policy):
        self.initialized += 1
        s = state()
        s['policy'] = policy
        m.atomic(self.p.state, json.dumps(s))

    def core_command(self, *args):
        self.calls.append(args)
        return subprocess.CompletedProcess(args, self.core_result, stdout='', stderr='')


class ManagementTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.paths = m.Paths(self.root/'host')
        self.source = self.root/'source'
        self.source.mkdir()
        for name in m.ASSETS:
            (self.source/name).write_text('# fixture '+name+'\n')
        self.manager = TestManager(self.paths, self.source)
        self.manager.initialized = 0
        self.manager.calls = []
        self.manager.core_result = 0
        self.output = io.StringIO()
        quiet = contextlib.redirect_stdout(self.output)
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)

    def install(self):
        self.manager.install()

    def test_fresh_install_initializes_once_and_adds_managed_cron(self):
        self.install()
        self.assertEqual(self.manager.initialized, 1)
        self.assertTrue(self.manager.enabled())
        self.assertIn('scheduled-run', self.paths.cron.read_text())
        self.assertTrue(self.paths.alias.exists())
        self.assertEqual(self.manager.installed_version(), m.VERSION)

    def test_upgrade_preserves_ledger_bytes_and_pending_correction(self):
        self.install()
        s = state()
        s['vms']['101']['pending'] = {'target': 700, 'expected': 500000}
        m.atomic(self.paths.state, json.dumps(s, indent=4))
        original = self.paths.state.read_bytes()
        (self.source/'reset_carryover.py').write_text('# newer core')
        self.manager.install()
        self.assertEqual(self.paths.state.read_bytes(), original)
        self.assertEqual(self.manager.initialized, 1)
        self.assertTrue(list((self.paths.data/'backups').glob('*.tar.gz')))

    def test_upgrade_keeps_paused_schedule_paused(self):
        self.install()
        self.manager.pause()
        self.manager.install()
        self.assertFalse(self.manager.enabled())
        self.assertFalse(self.paths.cron.exists())

    def test_legacy_install_can_upgrade_without_reenrollment(self):
        self.paths.app.mkdir(parents=True)
        self.paths.data.mkdir(parents=True)
        (self.paths.app/'reset_carryover.py').write_text('# legacy')
        m.atomic(self.paths.state, json.dumps(state()))
        m.atomic(self.paths.cron, '* * * * * root legacy-run\n')
        before = self.paths.state.read_bytes()
        self.manager.install()
        self.assertEqual(self.manager.initialized, 0)
        self.assertEqual(self.paths.state.read_bytes(), before)
        self.assertTrue(self.manager.enabled())
        self.assertIn('scheduled-run', self.paths.cron.read_text())

    def test_invalid_saved_state_is_not_reinitialized(self):
        self.paths.app.mkdir(parents=True)
        (self.paths.app/'reset_carryover.py').write_text('# installed')
        self.paths.data.mkdir(parents=True)
        self.paths.state.write_text('{broken')
        with self.assertRaises(ValueError):
            self.manager.install()
        self.assertEqual(self.paths.state.read_text(), '{broken')
        self.assertEqual(self.manager.initialized, 0)

    def test_enable_disable_do_not_edit_accounting_state(self):
        self.install()
        original = self.paths.state.read_bytes()
        self.manager.pause()
        self.assertFalse(self.manager.enabled())
        self.manager.enable()
        self.assertTrue(self.manager.enabled())
        self.assertEqual(self.paths.state.read_bytes(), original)
        self.assertEqual(self.manager.calls, [])

    def test_uninstall_removes_own_data_logs_backups_and_keeps_unrelated_files(self):
        self.install()
        self.paths.log.write_text('audit history')
        Path(str(self.paths.log)+'.1').write_text('old log')
        self.manager.backup()
        unrelated = self.paths.app/'unrelated.txt'
        unrelated.write_text('keep')
        virtualizor = self.paths.root/'etc/cron.d/virtualizor'
        virtualizor.write_text('original panel cron')
        self.manager.uninstall()
        self.assertFalse(self.paths.command.exists())
        self.assertFalse(self.paths.alias.exists())
        self.assertFalse(self.paths.cron.exists())
        self.assertFalse(self.manager.installed())
        self.assertFalse(self.paths.data.exists())
        self.assertFalse(self.paths.log.exists())
        self.assertFalse(Path(str(self.paths.log)+'.1').exists())
        self.assertEqual(unrelated.read_text(), 'keep')
        self.assertEqual(virtualizor.read_text(), 'original panel cron')
        self.assertEqual(self.manager.calls, [])

    def test_reinstall_after_uninstall_enrolls_again(self):
        self.install()
        self.manager.uninstall()
        self.assertFalse(self.paths.data.exists())
        self.manager.install()
        self.assertEqual(self.manager.initialized, 2)
        self.assertTrue(self.manager.enabled())

    def test_backup_contains_ledger_and_excludes_backups_and_credentials(self):
        self.install()
        path = self.manager.backup()
        with tarfile.open(path) as archive:
            names = archive.getnames()
            self.assertIn('data/state.json', names)
            self.assertFalse(any('universal.php' in n or 'backups/' in n for n in names))

    def test_scheduled_check_is_skipped_when_paused(self):
        self.install()
        self.manager.pause()
        self.assertEqual(self.manager.run(scheduled=True), 0)
        self.assertEqual(self.manager.calls, [])
        self.assertFalse(self.paths.heartbeat.exists())

    def test_explicit_run_works_while_schedule_is_paused(self):
        self.install()
        self.manager.pause()
        self.assertEqual(self.manager.run(), 0)
        self.assertEqual(self.manager.calls, [('run',)])
        self.assertEqual(json.loads(self.paths.heartbeat.read_text())['exit_code'], 0)

    def test_failed_check_records_heartbeat_and_keeps_last_success(self):
        self.install()
        self.manager.run()
        success = json.loads(self.paths.heartbeat.read_text())['last_success']
        self.manager.core_result = 1
        self.assertEqual(self.manager.run(), 1)
        h = json.loads(self.paths.heartbeat.read_text())
        self.assertEqual(h['exit_code'], 1)
        self.assertEqual(h['last_success'], success)

    def test_corrupt_optional_heartbeat_does_not_stop_accounting(self):
        self.install()
        self.paths.heartbeat.write_text('{broken')
        self.assertEqual(self.manager.run(), 0)
        self.assertEqual(json.loads(self.paths.heartbeat.read_text())['exit_code'], 0)

    def test_status_json_reports_held_and_pending_records(self):
        self.install()
        s = state()
        s['vms']['101'].update(hold='review', pending={'target': 700})
        m.atomic(self.paths.state, json.dumps(s))
        capture = io.StringIO()
        with contextlib.redirect_stdout(capture):
            report = self.manager.status(as_json=True)
        self.assertEqual(json.loads(capture.getvalue())['held'], 1)
        self.assertEqual(report['pending'], 1)

    def test_first_failed_run_is_reported_as_stale(self):
        self.install()
        self.manager.core_result = 1
        self.manager.run()
        self.assertTrue(self.manager.status()['stale'])

    def test_policy_change_does_not_reset_balances(self):
        self.install()
        before = json.loads(self.paths.state.read_text())['vms']
        self.manager.policy('hold')
        after = json.loads(self.paths.state.read_text())
        self.assertEqual(after['policy'], 'hold')
        self.assertEqual(after['vms'], before)

    def test_logs_limit_is_bounded(self):
        self.install()
        self.paths.log.write_text(''.join(str(i)+'\n' for i in range(1000)))
        capture = io.StringIO()
        with contextlib.redirect_stdout(capture):
            self.manager.logs(50000)
        self.assertEqual(len(capture.getvalue().splitlines()), 500)

    def test_upgrade_failure_rolls_back_program_and_keeps_data(self):
        self.install()
        before_core = (self.paths.app/'reset_carryover.py').read_bytes()
        before_state = self.paths.state.read_bytes()
        before_cron = self.paths.cron.read_bytes()
        (self.source/'reset_carryover.py').write_text('# changed')
        with patch.object(self.manager, '_schedule', side_effect=RuntimeError('simulate install failure')):
            with self.assertRaises(RuntimeError):
                self.manager.install()
        self.assertEqual((self.paths.app/'reset_carryover.py').read_bytes(), before_core)
        self.assertEqual(self.paths.state.read_bytes(), before_state)
        self.assertEqual(self.paths.cron.read_bytes(), before_cron)

    def test_old_remote_installer_is_not_executed_as_an_upgrade(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, size): return b'#!/bin/bash\necho legacy\n'
        with patch.object(m.urllib.request, 'urlopen', return_value=Response()):
            with patch.object(m.subprocess, 'run') as execute:
                with self.assertRaises(RuntimeError):
                    self.manager.remote_upgrade()
                execute.assert_not_called()

    def test_actual_source_validation_failure_stops_before_install(self):
        manager = m.Manager(self.paths, self.source)
        self.source.joinpath('reset_carryover.py').write_text('def broken(')
        with self.assertRaises(SyntaxError):
            manager.validate_source()
        self.assertFalse(self.paths.command.exists())

    def test_status_remains_readable_with_corrupt_optional_metadata(self):
        self.install()
        before = self.paths.state.read_bytes()
        self.paths.heartbeat.write_text('{broken')
        report = self.manager.status()
        self.assertTrue(report['last_run']['metadata_error'])
        self.assertEqual(self.paths.state.read_bytes(), before)

    def test_upgrade_does_not_silently_change_requested_policy(self):
        self.install()
        before = self.paths.state.read_bytes()
        with self.assertRaises(RuntimeError):
            self.manager.install('hold')
        self.assertEqual(self.paths.state.read_bytes(), before)

    def test_resync_backup_contains_state_before_operator_override(self):
        self.install()
        before = self.paths.state.read_bytes()
        def override(*args):
            modified = state()
            modified['vms']['101']['used'] = 0
            m.atomic(self.paths.state, json.dumps(modified))
            return subprocess.CompletedProcess(args, 0, stdout='', stderr='')
        with patch.object(self.manager, 'core_command', side_effect=override):
            self.manager.resync(101)
        archives = list((self.paths.data/'backups').glob('*.tar.gz'))
        with tarfile.open(archives[-1]) as archive:
            self.assertEqual(archive.extractfile('data/state.json').read(), before)
        self.assertEqual(json.loads(self.paths.state.read_text())['vms']['101']['used'], 0)

    def test_doctor_is_read_only_and_intentional_pause_is_not_an_error(self):
        self.install()
        self.manager.pause()
        for file in (self.paths.python, self.paths.php, self.paths.sdk, self.paths.universal):
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('fixture')
        before = self.paths.state.read_bytes()
        calls = []
        def result(args, **kwargs):
            calls.append(args)
            if args[0] == 'systemctl':
                return subprocess.CompletedProcess(args, 0, stdout='', stderr='')
            return subprocess.CompletedProcess(args, 0, stdout='{"vms":[{"id":"101"}]}', stderr='')
        with patch.object(m.subprocess, 'run', side_effect=result):
            with patch.object(self.manager, 'missing_commands', return_value=[]):
                self.assertEqual(self.manager.doctor(), 0)
        self.assertEqual(self.paths.state.read_bytes(), before)
        self.assertFalse(any('write' in call for call in calls))

    def test_uninstall_before_install_does_not_create_or_delete_data(self):
        self.manager.uninstall()
        self.assertFalse(self.paths.data.exists())
        self.assertFalse(self.paths.app.exists())
        self.assertEqual(self.manager.calls, [])

    def test_menu_accepts_nonseekable_terminal_input(self):
        read_fd, write_fd = os.pipe()
        self.addCleanup(os.close, read_fd)
        os.write(write_fd, b'0\n')
        os.close(write_fd)
        def terminal(path, mode, **kwargs):
            self.assertEqual(path, '/dev/tty')
            if '+' in mode:
                class NonSeekableTerminal(io.RawIOBase):
                    def readable(self): return True
                    def writable(self): return True
                    def seekable(self): return False
                # Reproduce Python's buffered update mode on a non-seekable TTY.
                return io.TextIOWrapper(io.BufferedRandom(NonSeekableTerminal()))
            return os.fdopen(os.dup(read_fd), mode, **kwargs)
        with patch.object(m, 'open', side_effect=terminal, create=True):
            self.assertEqual(self.manager.menu(), 0)
        self.assertFalse(self.paths.data.exists())

    def test_menu_falls_back_to_tty_stdin_without_closing_it(self):
        class Terminal(io.StringIO):
            def isatty(self): return True
        stream = Terminal('0\n')
        with patch.object(m, 'open', side_effect=OSError('tty unavailable'), create=True):
            with patch.object(m.sys, 'stdin', stream):
                self.assertEqual(self.manager.menu(), 0)
        self.assertFalse(stream.closed)

    def test_menu_without_any_terminal_requests_noninteractive_command(self):
        stream = io.StringIO('installer stream must not be read')
        with patch.object(m, 'open', side_effect=OSError('no tty'), create=True):
            with patch.object(m.sys, 'stdin', stream):
                with self.assertRaisesRegex(RuntimeError, 'upgrade'):
                    self.manager.menu()
        self.assertEqual(stream.tell(), 0)
        self.assertFalse(self.paths.data.exists())

    def test_menu_exits_on_eof_instead_of_looping(self):
        with patch.object(m, 'open', return_value=io.StringIO(''), create=True):
            self.assertEqual(self.manager.menu(), 0)
        self.assertFalse(self.paths.data.exists())

    def test_menu_commands_and_quit_do_not_modify_state(self):
        self.install()
        before = self.paths.state.read_bytes()
        with patch.object(m, 'open', return_value=io.StringIO('10\nq\n'), create=True):
            self.assertEqual(self.manager.menu(), 0)
        self.assertEqual(self.paths.state.read_bytes(), before)

    def test_menu_redraws_pages_in_place_and_restores_shell(self):
        class TerminalOutput(io.StringIO):
            def isatty(self): return True
        output = TerminalOutput()
        with patch.dict(m.os.environ, {'TERM': 'xterm-256color'}):
            with patch.object(m, 'open', return_value=io.StringIO('10\n\n0\n'), create=True):
                with contextlib.redirect_stdout(output):
                    self.assertEqual(self.manager.menu(), 0)
        text = output.getvalue()
        pages = text.split('\x1b[2J\x1b[H')
        self.assertEqual(len(pages), 4)  # menu, commands page, refreshed menu
        self.assertIn('1) Install / Upgrade', pages[1])
        self.assertIn('kvm-bw status', pages[2])
        self.assertNotIn('1) Install / Upgrade', pages[2])
        self.assertIn('1) Install / Upgrade', pages[3])
        self.assertNotIn('kvm-bw status', pages[3])
        self.assertEqual(text.count('\x1b[?1049h'), 1)
        self.assertTrue(text.endswith('\x1b[?1049l'))

    def test_interrupt_restores_shell_screen(self):
        class TerminalOutput(io.StringIO):
            def isatty(self): return True
        class Interrupted(io.StringIO):
            def readline(self, *args): raise KeyboardInterrupt()
        output = TerminalOutput()
        with patch.dict(m.os.environ, {'TERM': 'xterm'}):
            with patch.object(m, 'open', return_value=Interrupted(), create=True):
                with contextlib.redirect_stdout(output):
                    with self.assertRaises(KeyboardInterrupt):
                        self.manager.menu()
        self.assertTrue(output.getvalue().endswith('\x1b[?1049l'))
        self.assertFalse(self.paths.data.exists())

    def test_menu_output_redirected_to_file_has_no_screen_control_codes(self):
        output = io.StringIO()
        with patch.object(m, 'open', return_value=io.StringIO('0\n'), create=True):
            with contextlib.redirect_stdout(output):
                self.assertEqual(self.manager.menu(), 0)
        self.assertNotIn('\x1b', output.getvalue())

    def test_dumb_terminal_is_not_sent_unsupported_screen_codes(self):
        class TerminalOutput(io.StringIO):
            def isatty(self): return True
        output = TerminalOutput()
        with patch.dict(m.os.environ, {'TERM': 'dumb'}):
            with patch.object(m, 'open', return_value=io.StringIO('0\n'), create=True):
                with contextlib.redirect_stdout(output):
                    self.assertEqual(self.manager.menu(), 0)
        self.assertNotIn('\x1b', output.getvalue())

    def test_status_command_does_not_clear_interactive_terminal(self):
        class TerminalOutput(io.StringIO):
            def isatty(self): return True
        self.install()
        output = TerminalOutput()
        with contextlib.redirect_stdout(output):
            self.manager.status()
        self.assertIn('VPS_ID', output.getvalue())
        self.assertNotIn('\x1b', output.getvalue())


class StorageLifecycleTests(unittest.TestCase):
    setUp = ManagementTests.setUp
    install = ManagementTests.install

    def test_fresh_install_ignores_stale_valid_state_policy_and_metadata(self):
        stale = state()
        stale['policy'] = 'hold'
        stale['vms']['999'] = stale['vms'].pop('101')
        m.atomic(self.paths.state, json.dumps(stale))
        m.atomic(self.paths.heartbeat, '{"last_success": 1}')
        m.atomic(self.paths.data/'state.previous.json', '{"old":true}')
        self.install()
        current = json.loads(self.paths.state.read_text())
        self.assertEqual(current['policy'], 'minimum-1gb')
        self.assertEqual(set(current['vms']), {'101'})
        self.assertEqual(self.manager.initialized, 1)
        self.assertFalse(self.paths.heartbeat.exists())
        self.assertFalse((self.paths.data/'state.previous.json').exists())

    def test_fresh_install_ignores_corrupt_leftover_state(self):
        m.atomic(self.paths.state, '{broken')
        self.install()
        self.assertEqual(self.manager.initialized, 1)
        self.assertEqual(json.loads(self.paths.state.read_text())['version'], 2)

    def test_fresh_install_uses_actual_snapshot_without_any_quota_writes(self):
        snapshot = dict(now=12345, vms=[dict(id='202', name='current-vm', uuid='current-id',
                                           limit='5300', used='1700.25')])
        class Bridge:
            def snapshot(self): return snapshot
            def write(self, *args): raise AssertionError('Enrollment must not write to the panel')
        module = SimpleNamespace(Bridge=Bridge, process=core.process, save=core.save)
        spec = SimpleNamespace(loader=SimpleNamespace(exec_module=lambda module: None))
        m.atomic(self.paths.state, json.dumps(state()))
        with patch.object(m.importlib.util, 'spec_from_file_location', return_value=spec):
            with patch.object(m.importlib.util, 'module_from_spec', return_value=module):
                with patch.object(self.manager, 'initialize_unlocked',
                                  side_effect=lambda policy: m.Manager.initialize_unlocked(self.manager, policy)):
                    self.install()
        current = json.loads(self.paths.state.read_text())
        self.assertEqual(set(current['vms']), {'202'})
        self.assertEqual(current['vms']['202']['limit'], 530000)
        self.assertEqual(current['vms']['202']['used'], 170025)
        self.assertEqual(current['vms']['202']['reserve'], 0)
        self.assertEqual(current['vms']['202']['resets'], 0)

    def test_failed_reenrollment_restores_leftovers_without_enabling_cron(self):
        before = b'{"stale":true}'
        m.atomic(self.paths.state, before)
        m.atomic(self.paths.heartbeat, 'old heartbeat')
        def fail(policy):
            m.atomic(self.paths.state, '{"partial":true}')
            raise RuntimeError('snapshot failed')
        with patch.object(self.manager, 'initialize_unlocked', side_effect=fail):
            with self.assertRaisesRegex(RuntimeError, 'snapshot failed'):
                self.install()
        self.assertEqual(self.paths.state.read_bytes(), before)
        self.assertEqual(self.paths.heartbeat.read_text(), 'old heartbeat')
        self.assertFalse(self.paths.cron.exists())
        self.assertFalse(self.manager.installed())

    def test_upgrade_with_missing_state_does_not_create_a_new_baseline(self):
        self.install()
        self.paths.state.unlink()
        with self.assertRaisesRegex(RuntimeError, 'accounting state is missing'):
            self.install()
        self.assertEqual(self.manager.initialized, 1)

    def test_complete_uninstall_removes_directories_and_stale_scheduled_run_does_nothing(self):
        self.install()
        self.manager.backup()
        self.manager.scheduled_run()
        self.manager.uninstall()
        for path in (self.paths.app, self.paths.data, self.paths.command, self.paths.alias,
                     self.paths.cron, self.paths.rotate, self.paths.log):
            self.assertFalse(path.exists(), str(path))
        self.assertEqual(self.manager.scheduled_run(), 0)
        self.assertFalse(self.paths.data.exists())

    def test_uninstall_also_cleans_old_version_leftovers_without_an_application(self):
        m.atomic(self.paths.state, '{broken but removable}')
        m.atomic(self.paths.data/'backups/backup-old.tar.gz', 'old archive')
        m.atomic(Path(str(self.paths.log)+'.7.gz'), 'legacy log')
        self.manager.uninstall()
        self.assertFalse(self.paths.data.exists())
        self.assertEqual(self.manager.log_archives(), [])

    def test_uninstall_rejects_removal_outside_the_exact_private_directory(self):
        self.install()
        outside = self.root/'unrelated-data'
        outside.mkdir()
        marker = outside/'keep.txt'
        marker.write_text('keep')
        self.paths.data = outside
        with self.assertRaisesRegex(RuntimeError, 'unexpected removal target'):
            self.manager.uninstall()
        self.assertEqual(marker.read_text(), 'keep')
        self.assertTrue(self.paths.cron.exists())

    def test_backups_are_limited_to_five_recent_archives(self):
        self.install()
        for _ in range(9):
            self.manager.backup()
        files = list((self.paths.data/'backups').glob('backup-*.tar.gz'))
        self.assertEqual(len(files), 5)
        for file in files:
            with tarfile.open(file) as archive:
                self.assertIn('data/state.json', archive.getnames())

    def test_scheduled_run_removes_expired_and_legacy_backups(self):
        self.install()
        archive = self.manager.backup()
        legacy = self.paths.data/'backup-123.json'
        legacy.write_text('legacy')
        old = m.time.time() - 8*m.DAY
        for file in (archive, legacy):
            os.utime(file, (old, old))
        self.manager.scheduled_run()
        self.assertFalse(archive.exists())
        self.assertFalse(legacy.exists())

    def test_log_stream_bounds_large_writes_and_preserves_utf8(self):
        original = ('ترافیک\n'*40).encode('utf-8')
        with patch.object(m, 'LOG_BYTES', 32):
            stream = m.BoundedLog(self.paths.log)
            stream.write(original.decode('utf-8'))
            stream.close()
        files = [Path(str(self.paths.log)+'.'+str(i)) for i in range(3, 0, -1)]
        files += [self.paths.log]
        retained = b''.join(file.read_bytes() for file in files if file.exists())
        self.assertTrue(original.endswith(retained))
        self.assertLessEqual(len(retained), 4*32)
        for file in files:
            self.assertLessEqual(file.stat().st_size, 32)
            file.read_bytes().decode('utf-8')

    def test_log_rotates_on_a_new_day_even_if_small(self):
        m.atomic(self.paths.log, 'previous day')
        old = m.time.time()-2*m.DAY
        os.utime(self.paths.log, (old, old))
        stream = m.BoundedLog(self.paths.log)
        stream.write('today')
        stream.close()
        self.assertEqual(self.paths.log.read_text(), 'today')
        self.assertEqual(Path(str(self.paths.log)+'.1').read_text(), 'previous day')

    def test_expired_active_log_is_discarded(self):
        m.atomic(self.paths.log, 'expired')
        old = m.time.time()-8*m.DAY
        os.utime(self.paths.log, (old, old))
        stream = m.BoundedLog(self.paths.log)
        stream.write('recent')
        stream.close()
        self.assertEqual(self.paths.log.read_text(), 'recent')
        self.assertEqual(self.manager.log_archives(), [])

    def test_log_pruning_limits_legacy_archives_and_keeps_other_app_logs(self):
        for i in range(1, 8):
            m.atomic(Path(str(self.paths.log)+'.'+str(i)+'.gz'), 'archive')
        unrelated = self.paths.log.parent/'virtualizor.log'
        unrelated.write_text('keep')
        expired = Path(str(self.paths.log)+'-20200101.gz')
        expired.write_text('expired')
        old = m.time.time()-8*m.DAY
        os.utime(expired, (old, old))
        self.manager.prune_logs()
        self.assertEqual(len(self.manager.log_archives()), 3)
        self.assertFalse(expired.exists())
        self.assertEqual(unrelated.read_text(), 'keep')

    def test_scheduled_failure_captures_output_and_restores_terminal_streams(self):
        self.install()
        before_stdout, before_stderr = m.sys.stdout, m.sys.stderr
        result = subprocess.CompletedProcess([], 1, stdout='panel issue\n', stderr='error detail\n')
        with patch.object(self.manager, 'core_command', return_value=result):
            self.assertEqual(self.manager.scheduled_run(), 1)
        content = self.paths.log.read_text()
        self.assertIn('panel issue', content)
        self.assertIn('error detail', content)
        self.assertIn('RUN_FAILED', content)
        self.assertIs(m.sys.stdout, before_stdout)
        self.assertIs(m.sys.stderr, before_stderr)
        self.assertEqual(json.loads(self.paths.heartbeat.read_text())['exit_code'], 1)
        self.assertNotIn('>>', self.paths.cron.read_text())
        self.assertFalse(self.paths.rotate.exists())

    def test_actual_cron_cli_uses_bounded_logging_entrypoint(self):
        self.install()
        with patch.object(m.sys, 'argv', ['kvm-bw', 'scheduled-run']):
            with patch.object(m.sys, 'platform', 'linux'):
                with patch.object(m.os, 'geteuid', return_value=0, create=True):
                    with patch.object(m, 'Manager', return_value=self.manager):
                        self.assertEqual(m.main(), 0)
        self.assertIn('RUN_OK', self.paths.log.read_text())
        self.assertEqual(self.manager.calls, [('run',)])


class HostCompatibilityTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.paths = m.Paths(self.root/'host')
        self.source = self.root/'source'
        self.source.mkdir()
        for name in m.ASSETS:
            (self.source/name).write_text('# fixture '+name+'\n')
        for file in (self.paths.python, self.paths.php, self.paths.sdk, self.paths.universal):
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('fixture')
        self.manager = m.Manager(self.paths, self.source)
        self.active = set()
        self.calls = []
        quiet = contextlib.redirect_stdout(io.StringIO())
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)
        executor = patch.object(m.subprocess, 'run', side_effect=self.execute)
        executor.start()
        self.addCleanup(executor.stop)
        commands = patch.object(m.shutil, 'which', side_effect=lambda name: '/usr/bin/'+name)
        commands.start()
        self.addCleanup(commands.stop)

    def release(self, distro, version='9', like=''):
        path = self.paths.root/'etc/os-release'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('ID='+distro+'\nVERSION_ID="'+version+'"\nID_LIKE="'+like+
                        '"\nPRETTY_NAME="'+distro+' '+version+'"\n')

    def execute(self, args, **kwargs):
        self.calls.append(args)
        if args[:3] == ['systemctl', 'is-active', '--quiet']:
            return subprocess.CompletedProcess(args, 0 if args[3] in self.active else 3)
        if args == [str(self.paths.php), str(self.paths.app/'bridge.php'), 'snapshot']:
            return subprocess.CompletedProcess(args, 0, stdout='{"vms":[{"id":"101"}]}')
        raise AssertionError('Unexpected host command: '+repr(args))

    def ledger(self):
        self.paths.app.mkdir(parents=True, exist_ok=True)
        (self.paths.app/'reset_carryover.py').write_text('# installed')
        (self.paths.app/'bridge.php').write_text('# bridge')
        m.atomic(self.paths.state, json.dumps(state(), indent=4))
        m.atomic(self.paths.cron, m.CRON, 0o644)
        return self.paths.state.read_bytes()

    def test_ubuntu_preflight_accepts_cron_on_22_and_24(self):
        self.active = {'cron'}
        for version in ('22.04', '24.04'):
            with self.subTest(version=version):
                self.release('ubuntu', version, 'debian')
                self.calls.clear()
                self.manager.preflight()
                self.assertTrue(any(args[-1] == 'cron' for args in self.calls))
                self.assertFalse(any(args[-1] == 'crond' for args in self.calls))
                self.assertFalse(self.paths.state.exists())

    def test_almalinux_preflight_keeps_crond(self):
        self.release('almalinux', '9.5', 'rhel centos fedora')
        self.active = {'crond'}
        self.manager.preflight()
        self.assertTrue(any(args[-1] == 'crond' for args in self.calls))
        self.assertFalse(any(args[-1] == 'cron' for args in self.calls))

    def test_ubuntu_falls_back_to_an_active_crond(self):
        self.release('ubuntu', '24.04')
        self.active = {'crond'}
        self.assertEqual(self.manager.cron_status(), ('crond', True))
        self.assertEqual([args[-1] for args in self.calls], ['cron', 'crond'])

    def test_unknown_distribution_can_use_an_active_cron(self):
        self.active = {'cron'}
        self.assertEqual(self.manager.cron_status(), ('cron', True))

    def test_inactive_ubuntu_cron_stops_before_writes_and_gives_correct_hint(self):
        self.release('ubuntu', '24.04')
        before = self.ledger()
        with self.assertRaisesRegex(RuntimeError, 'systemctl enable --now cron$'):
            self.manager.install()
        self.assertEqual(self.paths.state.read_bytes(), before)
        self.assertTrue(all(args[1:3] == ['is-active', '--quiet'] for args in self.calls))
        self.assertFalse((self.paths.app/'VERSION').exists())

    def test_missing_dependencies_give_distribution_package_commands_without_installing(self):
        for distro, expected in (('ubuntu', 'apt-get'), ('almalinux', 'dnf')):
            with self.subTest(distro=distro):
                self.release(distro)
                self.calls.clear()
                with patch.object(m.shutil, 'which', return_value=None):
                    with self.assertRaisesRegex(RuntimeError, expected):
                        self.manager.preflight()
                self.assertEqual(self.calls, [])
                self.assertFalse(self.paths.state.exists())

    def test_missing_system_python_reports_dependency_hint(self):
        self.release('ubuntu', '24.04')
        self.paths.python.unlink()
        with self.assertRaisesRegex(RuntimeError, '/usr/bin/python3 is required.*apt-get'):
            self.manager.preflight()
        self.assertEqual(self.calls, [])

    def test_missing_panel_sdk_stops_before_host_service_queries(self):
        self.release('ubuntu', '24.04')
        self.paths.sdk.unlink()
        with self.assertRaisesRegex(RuntimeError, 'Required file is missing'):
            self.manager.preflight()
        self.assertEqual(self.calls, [])

    def test_ubuntu_doctor_uses_cron_and_leaves_ledger_unchanged(self):
        self.release('ubuntu', '24.04', 'debian')
        self.active = {'cron'}
        before = self.ledger()
        self.assertEqual(self.manager.doctor(), 0)
        self.assertEqual(self.paths.state.read_bytes(), before)
        services = [args[-1] for args in self.calls if args[0] == 'systemctl']
        self.assertEqual(services, ['cron'])

    def test_service_command_failure_is_reported_as_inactive(self):
        self.release('ubuntu', '24.04')
        with patch.object(m.subprocess, 'run', side_effect=FileNotFoundError('systemctl')):
            self.assertEqual(self.manager.cron_status(), ('cron', False))

    def test_os_release_fallback_and_quoted_family(self):
        file = self.paths.root/'usr/lib/os-release'
        file.parent.mkdir(parents=True)
        file.write_text('ID=ubuntu\nID_LIKE="debian"\nPRETTY_NAME="Ubuntu 24.04 LTS"\n')
        info = m.host_info(self.paths.root)
        self.assertEqual(info['name'], 'Ubuntu 24.04 LTS')
        self.assertEqual(info['cron_services'][0], 'cron')
        self.assertIn('apt-get', info['dependency_hint'])
        self.assertEqual(self.calls, [])

    def test_os_release_does_not_execute_shell_values(self):
        self.release('ubuntu', '24.04')
        file = self.paths.root/'etc/os-release'
        file.write_text('ID=ubuntu\nPRETTY_NAME="$(touch /tmp/do-not-run)"\n')
        info = m.host_info(self.paths.root)
        self.assertEqual(info['name'], '$(touch /tmp/do-not-run)')
        self.assertEqual(self.calls, [])

    def test_real_preflight_upgrade_preserves_ledger_on_both_platforms(self):
        for distro, active in (('ubuntu', 'cron'), ('almalinux', 'crond')):
            with self.subTest(distro=distro):
                self.release(distro)
                self.active = {active}
                before = self.ledger()
                with patch.object(self.manager, 'validate_source'):
                    self.manager.install()
                self.assertEqual(self.paths.state.read_bytes(), before)
                self.assertEqual((self.paths.app/'VERSION').read_text().strip(), m.VERSION)
                self.assertTrue(self.manager.enabled())
                self.assertTrue(list((self.paths.data/'backups').glob('*.tar.gz')))


if __name__ == '__main__':
    unittest.main()

RC_MANAGER_TEST
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "$stage_dir/carryover_manager.py" --source "$stage_dir" "$@"
