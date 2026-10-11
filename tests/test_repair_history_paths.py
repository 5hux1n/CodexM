from contextlib import closing
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('repair', Path(__file__).parents[1] / 'scripts/repair_history_paths.py')
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class RepairTests(unittest.TestCase):
    def test_backup_repair_and_missing_preservation(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp).resolve()
            session = home / 'sessions/2026/10/01/rollout-test.jsonl'
            session.parent.mkdir(parents=True)
            session.write_text(json.dumps({'type': 'session_meta', 'payload': {'id': 'test'}}) + '\n')
            db = home / 'state_5.sqlite'
            old = '/old/codex/sessions/2026/10/01/rollout-test.jsonl'
            with closing(sqlite3.connect(db)) as c:
                c.execute('CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, title TEXT)')
                c.executemany('INSERT INTO threads VALUES(?,?,?)', [('test', old, 'title'), ('missing', '/old/codex/sessions/rollout-missing.jsonl', 'keep')])
                c.commit()
            plans, missing = repair.plan(home)
            self.assertEqual(len(plans[0][1]), 1)
            self.assertEqual(missing, ['missing'])
            with patch.object(repair, 'assert_stopped'):
                count, missing, backup = repair.apply(home)
            self.assertEqual(count, 1)
            with closing(sqlite3.connect(db)) as c:
                self.assertEqual(c.execute('SELECT rollout_path,title FROM threads WHERE id="test"').fetchone(), (str(session), 'title'))
                self.assertEqual(c.execute('SELECT rollout_path FROM threads WHERE id="missing"').fetchone()[0], '/old/codex/sessions/rollout-missing.jsonl')
            with closing(sqlite3.connect(backup / db.name)) as c:
                self.assertEqual(c.execute('SELECT rollout_path FROM threads WHERE id="test"').fetchone()[0], old)
            self.assertEqual((backup / db.name).stat().st_mode & 0o777, 0o600)
            session.write_text('{"type":"session_meta","payload":{"id":"wrong"}}\n')
            with self.assertRaises(ValueError):
                repair.plan(home)

    def test_live_client_rejected(self):
        with patch.object(repair.subprocess, 'check_output', return_value='/Applications/ChatGPT.app/Contents/MacOS/ChatGPT\n'):
            with self.assertRaises(RuntimeError):
                repair.assert_stopped()


if __name__ == '__main__':
    unittest.main()
