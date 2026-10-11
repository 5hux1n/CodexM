#!/usr/bin/env python3
"""Inspect relocated account history; --apply requires all Codex clients stopped.
Only verified threads.rollout_path cells are updated. Backups contain private data.
"""
from contextlib import closing
import argparse
import datetime
import json
import os
from pathlib import Path
import sqlite3
import subprocess


def plan(home):
    home = home.resolve(strict=True)
    plans, missing = [], []
    for db in sorted(home.glob('state_*.sqlite')):
        if db.is_symlink():
            raise ValueError('Database symlink rejected')
        with closing(sqlite3.connect(db.as_uri() + '?mode=ro', uri=True)) as conn:
            rows = conn.execute('SELECT id, rollout_path FROM threads').fetchall()
        updates = []
        for tid, old in rows:
            parts = Path(old).parts
            starts = [i for i, part in enumerate(parts) if part in ('sessions', 'archived_sessions')]
            if not starts or '..' in parts or '.' in parts:
                raise ValueError('Unsafe history path')
            candidate = home.joinpath(*parts[starts[-1]:])
            if candidate.resolve() != candidate:
                raise ValueError('History symlink rejected')
            if not candidate.is_file():
                missing.append(tid)
                continue
            if not candidate.name.startswith('rollout-') or candidate.suffix != '.jsonl':
                raise ValueError('Invalid history filename')
            with candidate.open('rb') as stream:
                first = stream.readline(1048576)
            if not first.endswith(b'\n'):
                raise ValueError('Incomplete session metadata')
            meta = json.loads(first)
            if meta.get('type') != 'session_meta' or meta.get('payload', {}).get('id') != tid:
                raise ValueError('Session identity mismatch')
            if old != str(candidate):
                updates.append((str(candidate), tid, old))
        if updates:
            plans.append((db, updates))
    return plans, missing


def assert_stopped():
    commands = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
    clients = [c for c in commands if Path(c.strip()).name.lower() in ('codex', 'chatgpt')
               or 'ChatGPT.app/Contents/' in c or 'Codex.app/Contents/' in c]
    if clients:
        raise RuntimeError('请先退出全部 Codex / ChatGPT 客户端，再运行 --apply（关闭窗口不等于退出）。')


def apply(home):
    assert_stopped()
    plans, missing = plan(home)
    backup = None
    if plans:
        backup = home / ('history-path-backup-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
        backup.mkdir(mode=0o700)
        for db, updates in plans:
            assert_stopped()
            with closing(sqlite3.connect(db.as_uri() + '?mode=rw', uri=True, timeout=1)) as conn:
                saved = backup / db.name
                with closing(sqlite3.connect(saved)) as target:
                    conn.backup(target)
                os.chmod(saved, 0o600)
                conn.execute('BEGIN IMMEDIATE')
                try:
                    for new, tid, old in updates:
                        count = conn.execute('UPDATE threads SET rollout_path=? WHERE id=? AND rollout_path=?',
                                             (new, tid, old)).rowcount
                        if count != 1:
                            raise RuntimeError('History changed; repair rolled back')
                    assert_stopped()
                    conn.commit()
                except BaseException:
                    conn.rollback()
                    raise
                if conn.execute('PRAGMA quick_check').fetchone() != ('ok',):
                    raise RuntimeError('Database verification failed; retain backup')
    return sum(len(updates) for _, updates in plans), missing, backup


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', type=Path, required=True, help='Account CODEX_HOME directory')
    parser.add_argument('--apply', action='store_true', help='Back up and repair; default is read-only')
    args = parser.parse_args()
    home = args.home.resolve(strict=True)
    if args.apply:
        count, missing, backup = apply(home)
        print(f'已修复 {count} 条历史路径。备份：{backup or "无需备份"}')
    else:
        plans, missing = plan(home)
        print(f'只读检查：可修复 {sum(len(u) for _, u in plans)} 条历史路径；未找到文件 {len(missing)} 条。')
    if missing:
        print('未找到的会话（保持原记录）：' + ', '.join(missing))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError, OSError, sqlite3.Error) as error:
        raise SystemExit(str(error)) from None
