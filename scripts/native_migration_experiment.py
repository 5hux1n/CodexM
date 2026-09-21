#!/usr/bin/env python3
"""Local, rollout-only research harness. Never mutates a source or an existing profile.
No turn/start, credentials, SQL writes, Terminal.app, or account requests.
"""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import sqlite3
import subprocess
import threading
import time
import uuid

MARKER = 'codexm-native-experiment-v1'


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def write_json(path, value):
    tmp = path.with_suffix('.tmp')
    with tmp.open('x', encoding='utf-8') as f:
        json.dump(value, f, ensure_ascii=False, indent=2)
    tmp.chmod(0o600)
    tmp.replace(path)


def safe_path(path):
    path = Path(os.path.abspath(path))
    if path.resolve() != path:
        raise ValueError('Symlink path rejected')
    return path


def inventory(root):
    result = {}
    if not root.exists():
        return result
    for p in sorted(root.rglob('*')):
        if p.is_symlink():
            raise ValueError('Unexpected symlink in experiment')
        if p.is_file():
            result[str(p.relative_to(root))] = {'size': p.stat().st_size, 'sha256': digest(p)}
    return result


def require_stopped(root):
    # lsof sees descendants too, including processes whose argv omits CODEX_HOME.
    if not root.exists():
        return
    check = subprocess.run(['/usr/sbin/lsof', '-n', '-t', '+D', str(root)], capture_output=True)
    if check.returncode not in (0, 1) or check.stdout.strip() or check.stderr.strip():
        raise ValueError('Target is in use or process check failed')


def inspect_rollout(path):
    counts = collections.Counter()
    payload_types = collections.Counter()
    meta = None
    with path.open('rb') as f:
        for index, line in enumerate(f):
            if not line.endswith(b'\n'):
                raise ValueError('Incomplete rollout tail')
            item = json.loads(line)
            if not isinstance(item, dict) or not isinstance(item.get('type'), str):
                raise ValueError('Unknown rollout shape')
            counts[item['type']] += 1
            if index == 0:
                if item['type'] != 'session_meta':
                    raise ValueError('Missing initial session metadata')
                meta = item['payload']
            payload = item.get('payload')
            if isinstance(payload, dict) and isinstance(payload.get('type'), str):
                payload_types[payload['type']] += 1
    if not meta or not meta.get('cwd', '').startswith('/'):
        raise ValueError('Invalid session metadata')
    uuid.UUID(meta['id'])
    return meta, dict(counts), dict(payload_types)


def prepare(source, experiment):
    source = safe_path(source)
    experiment = safe_path(experiment)
    if source.suffix != '.jsonl' or not source.name.startswith('rollout-') or not source.is_file():
        raise ValueError('Only a rollout JSONL is accepted')
    if experiment.exists():
        raise ValueError('Experiment path must be new; existing profiles are never modified')
    if source.is_relative_to(experiment) or experiment.is_relative_to(source.parent):
        raise ValueError('Source and target must be separate')
    before = digest(source)
    meta, counts, payload_types = inspect_rollout(source)
    if not Path(meta['cwd']).is_dir():
        raise ValueError('Project directory unavailable')
    experiment.mkdir(parents=True, mode=0o700)
    experiment.chmod(0o700)
    target = experiment / 'profile-C'
    home = target / 'codex'
    home.mkdir(parents=True, mode=0o700)
    (target / 'electron').mkdir(mode=0o700)
    (experiment / 'baseline').mkdir(mode=0o700)
    # Fresh, credential-free C has a verifiably empty baseline. It is intentional
    # that no existing account data is copied into this backup.
    shutil.copytree(target, experiment / 'baseline' / 'profile-C')
    write_json(experiment / 'baseline-manifest.json', inventory(target))
    write_json(experiment / 'owner.json', {'marker': MARKER, 'id': str(uuid.uuid4())})
    package = experiment / 'package'
    package.mkdir(mode=0o700)
    shutil.copyfile(source, package / 'rollout.jsonl')
    (package / 'rollout.jsonl').chmod(0o600)
    if digest(source) != before or digest(package / 'rollout.jsonl') != before:
        raise ValueError('Source changed during export; target left at empty baseline')
    date = str(meta.get('timestamp', ''))[:10].split('-')
    if len(date) != 3 or not all(x.isdigit() for x in date):
        date = ['2000', '01', '01']
    relative = Path('sessions', *date, source.name)
    dest = home / relative
    dest.parent.mkdir(parents=True, mode=0o700)
    if dest.exists():
        raise ValueError('Thread conflict')
    shutil.copyfile(package / 'rollout.jsonl', dest)
    dest.chmod(0o600)
    manifest = {'formatVersion': 1, 'migrationId': str(uuid.uuid4()), 'mode': 'rollout-only-experiment',
                'sourceThreadId': meta['id'], 'projectPath': meta['cwd'], 'sourcePath': str(source),
                'sourceCodexVersion': meta.get('cli_version'), 'targetRollout': str(relative),
                'credentialFilesIncluded': False, 'sha256': before, 'events': counts,
                'payloadTypes': payload_types, 'status': 'copied', 'evidenceLevel': 'M0',
                'createdAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
    write_json(package / 'manifest.json', manifest)
    write_json(package / 'checksums.json', {'rollout.jsonl': before})
    if digest(dest) != before:
        raise ValueError('Import hash mismatch')
    return manifest


def owned(experiment):
    experiment = safe_path(experiment)
    owner = json.loads((experiment / 'owner.json').read_text())
    if owner.get('marker') != MARKER:
        raise ValueError('Not a CodexM experiment')
    for name in ('profile-C', 'baseline', 'package'):
        safe_path(experiment / name)
    manifest = json.loads((experiment / 'package' / 'manifest.json').read_text())
    relative = Path(manifest['targetRollout'])
    if relative.is_absolute() or '..' in relative.parts or relative.parts[0] != 'sessions':
        raise ValueError('Invalid target rollout')
    return experiment, manifest


class Server:
    def __init__(self, binary, home, cwd, allow_hydrate=False):
        # Only ordinary OS environment; do not inherit another account's keys,
        # CODEX pipes, config, app socket or authentication environment.
        env = {k: os.environ[k] for k in ('PATH', 'HOME', 'TMPDIR', 'LANG', 'USER', 'LOGNAME') if k in os.environ}
        env['CODEX_HOME'] = str(home)
        self.allow_hydrate = allow_hydrate
        extra = []
        self.process = subprocess.Popen([str(binary), 'app-server', '--stdio', *extra], cwd=cwd, env=env,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.events = queue.Queue()
        self.sequence = 0
        threading.Thread(target=self._read, daemon=True).start()
        try:
            self.call('initialize', {'clientInfo': {'name': 'codexm-migration-research', 'version': '1.0'},
                                     'capabilities': {'experimentalApi': True}})
            self.send({'method': 'initialized', 'params': {}})
        except BaseException:
            self.close()
            raise

    def _read(self):
        for line in self.process.stdout:
            try:
                self.events.put(json.loads(line))
            except (ValueError, UnicodeDecodeError):
                pass

    def send(self, obj):
        self.process.stdin.write((json.dumps(obj) + '\n').encode())
        self.process.stdin.flush()

    def call(self, method, params, timeout=45):
        if method not in ('initialize', 'thread/list', 'thread/read', 'thread/turns/list') and not (method == 'thread/resume' and self.allow_hydrate):
            raise ValueError('Only discovery and non-resuming reads are allowed')
        self.sequence += 1
        ident = self.sequence
        self.send({'id': ident, 'method': method, 'params': params})
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            response = self.events.get(timeout=max(.1, deadline-time.monotonic()))
            if response.get('id') == ident:
                return response
        raise TimeoutError('Local app-server timeout')

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.process.kill(); self.process.wait(timeout=5)
        self.process.stdin.close(); self.process.stdout.close()


def verify(experiment):
    experiment, m = owned(experiment)
    target = experiment / 'profile-C'
    require_stopped(target)
    path = target / 'codex' / m['targetRollout']
    result = {'sourceUnchanged': digest(Path(m['sourcePath'])) == m['sha256'],
              'rolloutHashMatches': path.exists() and digest(path) == m['sha256'], 'databases': {}}
    for path in (target / 'codex').glob('*.sqlite'):
        if path.is_symlink():
            raise ValueError('Database symlink')
        with sqlite3.connect(path.as_uri() + '?mode=ro', uri=True) as db:
            tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")]
            item = {'integrity': db.execute('PRAGMA integrity_check').fetchone()[0], 'tables': tables}
            if 'threads' in tables:
                cols = [r[1] for r in db.execute('PRAGMA table_info(threads)')]
                item['threadColumns'] = cols
                if {'id', 'rollout_path'}.issubset(cols):
                    rows = db.execute('SELECT rollout_path FROM threads WHERE id=?', (m['sourceThreadId'],)).fetchall()
                    item['threadFound'] = bool(rows)
                    item['targetPathCorrect'] = bool(rows) and all(Path(r[0]) == target / 'codex' / m['targetRollout'] for r in rows)
            result['databases'][path.name] = item
    write_json(experiment / 'verification.json', result)
    return result


def probe(experiment, binary, hydrate=False):
    experiment, m = owned(experiment)
    target = experiment / 'profile-C'
    require_stopped(target)
    if (target / 'codex' / 'auth.json').exists():
        raise ValueError('Research probe requires a credential-free test profile')
    server = Server(binary, target / 'codex', m['projectPath'], allow_hydrate=hydrate)
    result = {'cliVersion': subprocess.check_output([str(binary), '--version'], text=True).strip(),
              'threadId': m['sourceThreadId'], 'requestsSent': [], 'modelTurnsSent': 0}
    try:
        if hydrate:
            response = server.call('thread/resume', {'threadId': m['sourceThreadId'], 'excludeTurns': True, 'approvalPolicy': 'never', 'sandbox': 'read-only'})
            result['requestsSent'].append('thread/resume (credential-free; no turn/start)')
            result['hydrateSucceeded'] = 'result' in response
            result['hydrateErrorCode'] = response.get('error', {}).get('code')
        response = server.call('thread/list', {'limit': 100, 'sourceKinds': ['cli', 'vscode', 'appServer', 'exec', 'unknown'], 'useStateDbOnly': False})
        result['requestsSent'].append('thread/list')
        data = response.get('result', {}).get('data', [])
        result['listed'] = any(t.get('id') == m['sourceThreadId'] for t in data)
        result['listErrorCode'] = response.get('error', {}).get('code')
        response = server.call('thread/read', {'threadId': m['sourceThreadId'], 'includeTurns': True})
        result['requestsSent'].append('thread/read')
        result['readErrorCode'] = response.get('error', {}).get('code')
        thread = response.get('result', {}).get('thread', {})
        turns = thread.get('turns', [])
        cursor = None
        paged_turns = []
        for _ in range(100):
            response = server.call('thread/turns/list', {'threadId': m['sourceThreadId'], 'limit': 50, 'itemsView': 'full', 'sortDirection': 'asc', 'cursor': cursor})
            result['requestsSent'].append('thread/turns/list')
            if 'error' in response:
                result['paginationErrorCode'] = response['error'].get('code')
                break
            page = response.get('result', {})
            paged_turns.extend(page.get('data', []))
            cursor = page.get('nextCursor')
            if not cursor:
                result['paginationComplete'] = True
                turns = paged_turns
                break
        result['readable'] = thread.get('id') == m['sourceThreadId']
        result['threadFields'] = sorted(thread.keys())
        result['turnCount'] = len(turns)
        result['turnStatuses'] = dict(collections.Counter(t.get('status', 'unknown') for t in turns))
        result['itemTypes'] = dict(collections.Counter(i.get('type', 'unknown') for t in turns for i in t.get('items', [])))
        # Store only hashes/counts of returned history, never messages or tool output.
        result['historyHash'] = hashlib.sha256(json.dumps(turns, sort_keys=True).encode()).hexdigest()
        result['desktopUIVerified'] = False
        result['crossAccountContinueVerified'] = False
    finally:
        server.close()
    history = experiment / 'probe-history.json'
    entries = json.loads(history.read_text()) if history.exists() else []
    entries.append(result)
    write_json(history, entries)
    return result


def rollback(experiment):
    experiment, _ = owned(experiment)
    target = experiment / 'profile-C'
    require_stopped(target)
    baseline = experiment / 'baseline' / 'profile-C'
    expected = json.loads((experiment / 'baseline-manifest.json').read_text())
    if inventory(baseline) != expected:
        raise ValueError('Backup hash mismatch')
    # Preserve post-experiment files for review. Never delete an existing account.
    saved = experiment / ('post-experiment-' + str(uuid.uuid4()))
    target.rename(saved)
    shutil.copytree(baseline, target)
    restored = inventory(target) == expected
    write_json(experiment / 'rollback.json', {'restored': restored, 'preserved': saved.name})
    return {'restored': restored}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest='command', required=True)
    p = subs.add_parser('prepare'); p.add_argument('--source', type=Path, required=True); p.add_argument('--experiment', type=Path, required=True)
    for name in ('probe', 'verify', 'rollback'):
        p = subs.add_parser(name); p.add_argument('--experiment', type=Path, required=True)
        if name == 'probe':
            p.add_argument('--binary', type=Path, required=True)
            p.add_argument('--hydrate', action='store_true', help='Try local resume without a new turn; requires a credential-free target')
    args = parser.parse_args()
    if args.command == 'prepare': result = prepare(args.source, args.experiment)
    elif args.command == 'probe': result = probe(args.experiment, args.binary, args.hydrate)
    elif args.command == 'verify': result = verify(args.experiment)
    else: result = rollback(args.experiment)
    # Summary deliberately excludes transcript content.
    print(json.dumps(result, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    main()
