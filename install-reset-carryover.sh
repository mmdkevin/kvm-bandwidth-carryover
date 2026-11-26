#!/usr/bin/env bash
set -euo pipefail
umask 077
if [[ $EUID -ne 0 ]]; then echo 'Run as root.' >&2; exit 1; fi
policy=minimum-1gb
if [[ $# -gt 1 ]]; then echo 'Usage: bash install-reset-carryover.sh [--hold-under-one-gb]' >&2; exit 1; fi
if [[ $# -eq 1 ]]; then
    case "$1" in
      --hold-under-one-gb) policy=hold ;;
      --minimum-one-gb) policy=minimum-1gb ;;
      *) echo 'Unknown option.' >&2; exit 1 ;;
    esac
fi
for dependency in python3 timeout install; do
    command -v "$dependency" >/dev/null || { echo "Missing command: $dependency" >&2; exit 1; }
done
test -x /usr/bin/python3
test -x /usr/local/emps/bin/php
test -r /usr/local/virtualizor/universal.php
test -r /usr/local/virtualizor/sdk/admin.php
/usr/bin/python3 -c 'import fcntl, json, decimal'
if command -v systemctl >/dev/null; then
    if systemctl is-active --quiet vps-credit.timer; then
        echo 'Older network-control version is active. Run vps-credit disable first.' >&2
        exit 1
    fi
    if ! systemctl is-active --quiet crond; then
        echo 'crond is not active. No changes installed.' >&2
        exit 1
    fi
fi
if [[ -e /etc/cron.d/native-carryover ]]; then
    echo 'Older experimental native-carryover Cron is still present. Disable it before installing this version.' >&2
    exit 1
fi
if [[ -e /var/lib/reset-carryover/state.json || -e /etc/cron.d/reset-carryover ]]; then
    echo 'Already installed or initialized. History preserved; no files overwritten.' >&2
    echo 'Use reset-carryover status. Do not delete the saved state.' >&2
    exit 1
fi
install -d -m 0700 /opt/reset-carryover /var/lib/reset-carryover
cat > '/opt/reset-carryover/reset_carryover.py' <<'RC_PYTHON'
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

RC_PYTHON
cat > '/opt/reset-carryover/bridge.php' <<'RC_PHP'
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

RC_PHP
cat > '/opt/reset-carryover/test_reset_carryover.py' <<'RC_TESTS'
import copy
import json
from pathlib import Path
import tempfile
import unittest
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

RC_TESTS
chmod 0600 /opt/reset-carryover/reset_carryover.py /opt/reset-carryover/test_reset_carryover.py /opt/reset-carryover/bridge.php
/usr/local/emps/bin/php -l /opt/reset-carryover/bridge.php
/usr/bin/python3 -m py_compile /opt/reset-carryover/reset_carryover.py
echo 'Running isolated tests (no panel writes).'
(cd /opt/reset-carryover && /usr/bin/python3 -m unittest -q test_reset_carryover)
cat > /usr/local/sbin/reset-carryover <<'RC_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
umask 077
if [[ $EUID -ne 0 ]]; then echo 'Run as root.' >&2; exit 1; fi
if [[ $# -eq 0 ]]; then set -- status; fi
exec /usr/bin/python3 /opt/reset-carryover/reset_carryover.py "$@"
RC_WRAPPER
chmod 0700 /usr/local/sbin/reset-carryover
/usr/local/sbin/reset-carryover init "$policy"
install -m 0600 /dev/null /var/log/reset-carryover.log
cat > /etc/cron.d/reset-carryover <<'RC_CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root timeout 55s /usr/local/sbin/reset-carryover run >> /var/log/reset-carryover.log 2>&1
RC_CRON
chmod 0644 /etc/cron.d/reset-carryover
if [[ -d /etc/logrotate.d ]]; then
cat > /etc/logrotate.d/reset-carryover <<'RC_ROTATE'
/var/log/reset-carryover.log {
    size 5M
    rotate 7
    compress
    missingok
    notifempty
    create 0600 root root
}
RC_ROTATE
chmod 0644 /etc/logrotate.d/reset-carryover
fi
echo 'INSTALLED: every observed decrease in usage will be treated as a reset.'
echo 'Cron runs every minute. Only bandwidth quota is edited.'
echo "Under-1GB policy: $policy. Zero is never written as a depleted quota."
echo 'Status: reset-carryover status'
echo 'Log: tail -n 30 /var/log/reset-carryover.log'
echo 'Backup: reset-carryover backup'
