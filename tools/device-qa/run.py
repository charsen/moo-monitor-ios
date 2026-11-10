#!/usr/bin/env python3
"""Authorized physical QA: isolated package + local Laravel/SQLite; no production credentials/data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
PKG = 'com.mooeen.monitor.ios.deviceqa'
TOKEN = 'moo_deviceqa_only_20261110_token_'

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True)
    parser.add_argument('--simulator', action='store_true', help='Explicit isolated CoreSimulator, never counts as physical validation')
    parser.add_argument('--host', required=True, help='This Mac LAN address, reachable by device')
    parser.add_argument('--cloud', default=str(ROOT.parent / 'moo-scaffold-cloud'))
    parser.add_argument('--profile', default=str(ROOT.parent / 'shuhe-apple/signing/profiles/ios-team-wildcard.mobileprovision'))
    parser.add_argument('--identity', default='5878AAD107EA3B9736843B9F49C45A57BE99D6AF')
    args = parser.parse_args()
    app = ROOT / ('build/device-qa/DerivedData/Build/Products/Debug-' + ('iphonesimulator' if args.simulator else 'iphoneos') + '/MonitorQa.app')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == PKG
    state = Path(tempfile.mkdtemp(prefix='simulator-qa-' if args.simulator else 'iphone-qa-', dir=ROOT / 'build'))
    (state / 'cloud.sqlite').touch(); (state / 'requests.jsonl').touch()
    env = dict(os.environ, MONITOR_QA_CLOUD_ROOT=args.cloud, MONITOR_QA_STATE=str(state),
               APP_ENV='testing', APP_DEBUG='false', DB_CONNECTION='sqlite', DB_DATABASE=str(state/'cloud.sqlite'),
               DB_URL='', CACHE_STORE='array', QUEUE_CONNECTION='sync', MAIL_MAILER='array', SESSION_DRIVER='array',
               PULSE_ENABLED='false', TELESCOPE_ENABLED='false', NIGHTWATCH_ENABLED='false')
    ctl = ['xcrun', 'devicectl']
    results = []
    container = None
    def command(parts, check=True, timeout=30):
        result = subprocess.run(parts, capture_output=True, text=True, timeout=timeout)
        if check and result.returncode: raise AssertionError((parts[:8], result.stdout[-2000:], result.stderr[-2000:]))
        return result
    def mode(value='accept', remaining=0):
        temp = state / 'control.tmp'
        temp.write_text(json.dumps({'mode':value,'remaining':remaining})); temp.replace(state/'control.json')
    def requests(start=0):
        return [json.loads(x) for x in (state/'requests.jsonl').read_text().splitlines()][start:]
    def count():
        with sqlite3.connect(state/'cloud.sqlite') as db: return db.execute('select coalesce(sum(count),0) from app_errors').fetchone()[0]
    def wait(label, predicate, timeout=50):
        end = time.monotonic()+timeout
        while time.monotonic()<end:
            result = predicate()
            if result: return result
            time.sleep(.5)
        raise AssertionError('timeout: '+label)
    def passed(name, **extra):
        results.append(dict(scenario=name, status='passed', **extra))
        (state/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps(results[-1],ensure_ascii=False),flush=True)
    def launch(action, token='A'):
        nonce = str(time.time_ns())
        if args.simulator:
            command(['xcrun','simctl','launch','--terminate-running-process',args.device,PKG,action,endpoint,TOKEN+token,nonce])
        else:
            command(ctl+['device','process','launch','--device',args.device,'--terminate-existing',PKG,action,endpoint,TOKEN+token,nonce])
        return nonce
    def report(nonce):
        destination = state/'device-report.json'
        if args.simulator:
            source = container/'Documents/qa-summary.json'
            try: data = json.loads(source.read_text())
            except (FileNotFoundError,json.JSONDecodeError): return None
            destination.write_text(json.dumps(data))
            return data if data.get('nonce') == nonce else None
        result = command(ctl+['device','copy','from','--device',args.device,'--domain-type','appDataContainer',
                              '--domain-identifier',PKG,'--source','Documents/qa-summary.json','--destination',str(destination)],check=False)
        if result.returncode: return None
        data = json.loads(destination.read_text())
        return data if data.get('nonce') == nonce else None
    def snapshot(nonce, timeout=50): return wait('QA report '+nonce, lambda: report(nonce), timeout)
    def crash_reports(label):
        path = state/(label+'-system-reports.json')
        if args.simulator:
            files = [{'name': p.name, 'path': str(p)} for p in sorted((Path.home()/'Library/Logs/DiagnosticReports').glob('MonitorQa*.ips'))]
            path.write_text(json.dumps({'reality':'simulated','files':files},indent=2)+'\n')
            return files
        command(ctl+['device','info','files','--device',args.device,'--domain-type','systemCrashLogs','--search','MonitorQa','--json-output',str(path)])
        value = json.loads(path.read_text())
        return value.get('result',{}).get('files',[])
    if args.simulator:
        command(['codesign','--force','--sign','-',str(app)])
    else:
        profile_path = Path(args.profile)
        profile = plistlib.loads(command(['security','cms','-D','-i',str(profile_path)]).stdout.encode())
        assert args.device in profile.get('ProvisionedDevices',[]), 'Device not included in existing development profile'
        assert profile['Entitlements']['application-identifier'].endswith('.*'), 'Wildcard development profile required'
        team = profile['TeamIdentifier'][0]
        shutil.copy2(profile_path, app/'embedded.mobileprovision')
        entitlements = {'application-identifier':team+'.'+PKG,'com.apple.developer.team-identifier':team,
                        'get-task-allow':True,'keychain-access-groups':[team+'.'+PKG]}
        ent = state/'entitlements.plist'; ent.write_bytes(plistlib.dumps(entitlements))
        command(['codesign','--force','--sign',args.identity,'--entitlements',str(ent),str(app)])
    command(['codesign','--verify','--deep','--strict',str(app)])
    executable = app/info['CFBundleExecutable']
    artifact = {'path':str(app),'bundle':PKG,'reality':'simulated' if args.simulator else 'physical','version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],
                'executable_bytes':executable.stat().st_size,'executable_sha256':hashlib.sha256(executable.read_bytes()).hexdigest(),
                'bundle_bytes':sum(p.stat().st_size for p in app.rglob('*') if p.is_file()),'platform':info.get('DTPlatformName'),
                'architectures':command(['lipo','-archs',str(executable)]).stdout.strip(),'signed':True}
    (state/'artifact.json').write_text(json.dumps(artifact,indent=2)+'\n')
    mode()
    seeded = subprocess.run(['php',str(Path(__file__).with_name('cloud-router.php')),'seed'],env=env,capture_output=True,text=True)
    assert seeded.returncode == 0, seeded.stderr
    ipv6 = ':' in args.host
    with socket.socket(socket.AF_INET6 if ipv6 else socket.AF_INET) as sock:
        sock.bind(('::' if ipv6 else '0.0.0.0',0)); port = sock.getsockname()[1]
    authority = '[' + args.host.strip('[]') + ']' if ipv6 else args.host
    endpoint = f'http://{authority}:{port}'
    log = (state/'server.log').open('w')
    server = subprocess.Popen(['php','-S',f'[::]:{port}' if ipv6 else f'0.0.0.0:{port}',str(Path(__file__).with_name('cloud-router.php'))],env=env,stdout=log,stderr=subprocess.STDOUT)
    print('EVIDENCE '+str(state),flush=True)
    try:
        if args.simulator:
            command(['xcrun','simctl','install',args.device,str(app)])
            container = Path(command(['xcrun','simctl','get_app_container',args.device,PKG,'data']).stdout.strip())
        else:
            command(ctl+['device','install','app','--device',args.device,str(app)])
        time.sleep(1)
        baseline = count()
        result = snapshot(launch('handled'), timeout=180)
        assert result['pending']==0 and count()==baseline+1, result
        event = requests()[-1]['records'][0]
        assert event['payload']['token']=='***'
        assert 'tiny' not in json.dumps(event) and 'test book.txt' not in json.dumps(event)
        passed('capture_redaction_cloud_receipt')
        before = count(); start = len(requests())
        result = snapshot(launch('batch'))
        assert result['pending']==0 and count()==before+180
        batches=requests(start)
        sizes=[len(x['records']) for x in batches]
        assert sum(sizes)==180 and len(sizes)>=4 and all(n<=50 for n in sizes)
        assert all(x['bytes']<=512*1024 for x in batches)
        assert len({r['event_id'] for x in batches for r in x['records']})==180
        passed('batch_continuation',batches=sizes)
        mode('partial',1); before=count(); start=len(requests())
        result=snapshot(launch('pair'),timeout=55)
        assert result['pending']==0 and count()==before+2
        assert [len(x['records']) for x in requests(start)] == [2,1]
        passed('partial_receipts_retained_then_retried')
        mode('retry-after',1); before=count(); start=len(requests())
        result=snapshot(launch('handled'))
        sent=requests(start)
        assert result['pending']==0 and count()==before+1 and len(sent)==2
        delay=sent[1]['at']-sent[0]['at']; assert delay>=2.9
        passed('retry_after',seconds=delay)
        mode('hold'); before=count(); start=len(requests())
        queued=snapshot(launch('queue'))
        assert queued['pending']==1 and count()==before
        stable=json.loads(queued['queue'].splitlines()[0])['event_id']
        for _ in range(3):
            held=snapshot(launch('status'))
            assert held['pending']==1 and count()==before
            assert json.loads(held['queue'].splitlines()[0])['event_id']==stable
        mode(); delivered=snapshot(launch('drain'),timeout=60)
        assert delivered['pending']==0 and count()==before+1
        assert requests(start)[-1]['records'][0]['event_id']==stable
        passed('service_unavailable_three_restarts_preserve_event_id',restarts=3)
        mode('unauthorized'); before=count()
        result=snapshot(launch('handled'))
        assert result['disabled'] and result['pending']==1 and count()==before
        mode(); result=snapshot(launch('drain','B'))
        assert result['pending']==0 and count()==before+1
        passed('unauthorized_preserves_queue_and_new_token_recovers')
        for action in ('fatal','unwrapped','exception'):
            before=count(); reports_before=crash_reports('before-'+action)
            launch(action,'B'); time.sleep(3)
            held=snapshot(launch('status','B'))
            records=[json.loads(x) for x in held['queue'].splitlines()]
            crashes=[x for x in records if x.get('kind')=='crash']
            assert len(crashes)==1, crashes
            assert not [x for x in records if x.get('kind')=='termination']
            result=snapshot(launch('drain','B'))
            assert result['pending']==0 and count()==before+1
            reports=wait('system crash report '+action,lambda: (current if len(current:=crash_reports('after-'+action))>len(reports_before) else None),timeout=40)
            (state/(action+'-record.json')).write_text(json.dumps(crashes[0],ensure_ascii=False,indent=2)+'\n')
            passed(action+'_crash_and_system_report',frames=len(crashes[0].get('frames',[])),reports=len(reports))
        (state/'summary.json').write_text(json.dumps({'count':count(),'results':len(results)},indent=2)+'\n')
    except BaseException:
        if not args.simulator:
            for source, name in [('Documents/qa-network.json','network-diagnostic.json'), ('Library/Application Support/monitor/retry.json','retry-diagnostic.json'), ('Library/Application Support/monitor/queue.jsonl','queue-diagnostic.jsonl')]:
                command(ctl+['device','copy','from','--device',args.device,'--domain-type','appDataContainer','--domain-identifier',PKG,'--source',source,'--destination',str(state/name)],check=False)
        raise
    finally:
        server.terminate(); server.wait(timeout=10); log.close()
        # Only the explicit fixture package; never an installed Shuhe app.
        if args.simulator:
            command(['xcrun','simctl','uninstall',args.device,PKG],check=False)
        else:
            command(ctl+['device','uninstall','app','--device',args.device,PKG],check=False)

if __name__=='__main__': main()
