#!/usr/bin/env bash
# KVM_BW_MANAGER_BOOTSTRAP_V2
set -euo pipefail
umask 077
command -v python3 >/dev/null || { echo 'Python 3.9 or later is required.' >&2; exit 1; }
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
        parser.error('Run on the AlmaLinux host as root')
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
"""KVM Bandwidth Carryover management commands. Accounting data survives uninstall."""
import argparse
from collections import deque
from contextlib import contextmanager
from datetime import datetime
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

VERSION = '2.0.1'
SOURCE_URL = 'https://raw.githubusercontent.com/mmdkevin/kvm-bandwidth-carryover/main/install-reset-carryover.sh'
ASSETS = ('reset_carryover.py', 'bridge.php', 'carryover_manager.py',
          'test_reset_carryover.py', 'test_carryover_manager.py')
CRON = ('SHELL=/bin/bash\n'
        'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
        '* * * * * root timeout 55s /usr/local/sbin/reset-carryover scheduled-run '
        '>> /var/log/reset-carryover.log 2>&1\n')
WRAPPER = ('#!/usr/bin/env bash\nset -euo pipefail\numask 077\n'
           'exec /usr/bin/python3 /opt/reset-carryover/carryover_manager.py "$@"\n')
ROTATE = ('/var/log/reset-carryover.log {\n    size 5M\n    rotate 7\n'
          '    compress\n    missingok\n    notifempty\n    create 0600 root root\n}\n')


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


class Manager:
    def __init__(self, paths=None, source=None):
        self.p = paths or Paths()
        self.source = Path(source or Path(__file__).resolve().parent)

    def guard_directories(self):
        for path in (self.p.app, self.p.data):
            if path.is_symlink():
                raise RuntimeError('Managed directory must not be a symlink: '+str(path))
        self.p.data.mkdir(mode=0o700, parents=True, exist_ok=True)

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
        for file in (self.p.php, self.p.sdk, self.p.universal):
            if not file.is_file():
                raise RuntimeError('Required file is missing: '+str(file))
        old_cron = self.p.root/'etc/cron.d/native-carryover'
        if old_cron.exists():
            raise RuntimeError('Disable the old native-carryover Cron first; its data will not be removed')
        if subprocess.run(['systemctl', 'is-active', '--quiet', 'vps-credit.timer'],
                          capture_output=True).returncode == 0:
            raise RuntimeError('Old network-control version is active. Run: vps-credit disable')
        if subprocess.run(['systemctl', 'is-active', '--quiet', 'crond'],
                          capture_output=True).returncode != 0:
            raise RuntimeError('crond is not active; start it before enabling automatic checks')

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
            old_state = self.p.state.read_bytes() if self.p.state.exists() else None
            if old_state is not None:
                old_saved = validated_state(self.p.state)
                if policy is not None and policy != old_saved['policy']:
                    raise RuntimeError('Upgrade preserves the current policy. Use: kvm-bw policy '+policy)
            backup = self._backup() if existing or old_state is not None else None
            files = [self.p.app/name for name in (*ASSETS, 'VERSION')]
            files += [self.p.command, self.p.alias, self.p.cron, self.p.rotate, self.p.paused]
            previous = {file: (file.read_bytes(), file.stat().st_mode & 0o777)
                        if file.is_file() and not file.is_symlink() else None for file in files}
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
                elif self.p.state.read_bytes() != old_state:
                    raise RuntimeError('Accounting data changed unexpectedly during upgrade')
                atomic(self.p.rotate, ROTATE, 0o644)
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
        problems = core.process(state, snapshot, bridge, lambda s: core.save(self.p.state, s))
        if problems or not state['vms']:
            raise RuntimeError('Initial enrollment failed; accounting data retained, Cron not enabled')

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
        for file in (self.p.php, self.p.sdk, self.p.universal, self.p.app/'bridge.php'):
            check('Required file '+file.name, file.is_file())
        try:
            state = validated_state(self.p.state)
            check('Accounting data readable', True, '%d VPS' % len(state['vms']))
            check('No held or pending corrections', not any(s['hold'] or s['pending'] for s in state['vms'].values()))
        except Exception as e:
            check('Accounting data readable', False, str(e))
        active = subprocess.run(['systemctl', 'is-active', '--quiet', 'crond'], capture_output=True).returncode == 0
        if self.enabled():
            check('Cron service active', active)
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
        if not self.installed() and not self.p.state.exists():
            print('Not installed; no accounting data found. Nothing changed.')
            return
        self.guard_directories()
        atomic(self.p.paused, 'Uninstalled; accounting history intentionally retained.\n')
        with self.locked(core=True):
            backup = self._backup()
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
        print('UNINSTALLED: program and its Cron removed.')
        print('Panel quotas unchanged. Accounting data and logs retained.')
        print('Data:', self.p.data, '| backup:', backup)

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
        with terminal_input() as tty:
            def ask(prompt):
                print(prompt, end='', flush=True)
                try:
                    line = tty.readline()
                except OSError:
                    return None
                return line.strip() if line else None
            while True:
                print('\nKVM Bandwidth Carryover v'+VERSION+' | installed: '+self.installed_version())
                print('1) Install / Upgrade\n2) Status\n3) Preview changes (read-only)\n4) Run one check')
                print('5) Enable automatic checks\n6) Pause automatic checks\n7) Logs\n8) Doctor')
                print('9) Backup\n10) Commands\n11) Uninstall (keep accounting data)\n0) Exit')
                choice = ask('Select: ')
                try:
                    if choice is None or choice == '0':
                        return 0
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
kvm-bw uninstall           Remove program/Cron; keep data and panel quotas
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
    if os.name == 'nt' or os.geteuid() != 0:
        parser.error('Run on the AlmaLinux host as root')
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
    elif command in ('run', 'scheduled-run'):
        return manager.run(command == 'scheduled-run')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('\nCancelled. Accounting data retained.', file=sys.stderr)
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
import unittest
from unittest.mock import patch

import carryover_manager as m


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

    def test_uninstall_removes_program_but_preserves_state_log_and_other_files(self):
        self.install()
        original = self.paths.state.read_bytes()
        self.paths.log.write_text('audit history')
        unrelated = self.paths.app/'unrelated.txt'
        unrelated.write_text('keep')
        virtualizor = self.paths.root/'etc/cron.d/virtualizor'
        virtualizor.write_text('original panel cron')
        self.manager.uninstall()
        self.assertFalse(self.paths.command.exists())
        self.assertFalse(self.paths.alias.exists())
        self.assertFalse(self.paths.cron.exists())
        self.assertFalse(self.manager.installed())
        self.assertEqual(self.paths.state.read_bytes(), original)
        self.assertEqual(self.paths.log.read_text(), 'audit history')
        self.assertEqual(unrelated.read_text(), 'keep')
        self.assertEqual(virtualizor.read_text(), 'original panel cron')
        self.assertEqual(self.manager.calls, [])

    def test_reinstall_after_uninstall_preserves_history(self):
        self.install()
        original = self.paths.state.read_bytes()
        self.manager.uninstall()
        self.manager.install()
        self.assertEqual(self.paths.state.read_bytes(), original)
        self.assertEqual(self.manager.initialized, 1)
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
        for file in (self.paths.php, self.paths.sdk, self.paths.universal):
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


if __name__ == '__main__':
    unittest.main()

RC_MANAGER_TEST
PYTHONDONTWRITEBYTECODE=1 python3 "$stage_dir/carryover_manager.py" --source "$stage_dir" "$@"
