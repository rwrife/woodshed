import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_poll', ROOT / 'Scripts/poll_testflight.py')
assert spec is not None and spec.loader is not None
release_poll = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_poll)


class ReleaseEvidenceTests(unittest.TestCase):
    def test_archive_contract_uses_real_plist(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'Info.plist'
            path.write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'com.infinityball.woodshed',
                'UIDeviceFamily': [1], 'CFBundleVersion': '72',
            }))
            import subprocess
            command = ['python3', str(ROOT / 'Scripts/check_release_archive.py'), str(path), '72']
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            for delta in ({'UIDeviceFamily': [1, 2]}, {'CFBundleIdentifier': 'com.wrong.woodshed'},
                          {'CFBundleVersion': '71'}):
                data = {'CFBundleIdentifier': 'com.infinityball.woodshed', 'UIDeviceFamily': [1], 'CFBundleVersion': '72'}
                data.update(delta)
                path.write_bytes(plistlib.dumps(data))
                self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)

    def test_poller_waits_for_exact_build_and_processing(self):
        states = iter([[], [{'id': 'older', 'attributes': {'version': '71', 'processingState': 'VALID'}}],
                       [{'id': 'new', 'attributes': {'version': '72', 'processingState': 'PROCESSING'}}],
                       [{'id': 'new', 'attributes': {'version': '72', 'processingState': 'VALID'}}]])
        calls = []

        def api(path, params):
            calls.append((path, params))
            if path == '/v1/apps':
                return {'data': [{'id': 'app-one'}]}
            return {'data': next(states)}

        ticks = iter(range(20))
        result = release_poll.await_processing(api, 'com.infinityball.woodshed', '72', timeout=10,
                                               interval=1, clock=lambda: next(ticks), sleep=lambda _: None)
        self.assertEqual(result, ('app-one', 'new', 'VALID'))
        self.assertEqual(calls[-1][1]['filter[app]'], 'app-one')

    def test_poller_rejects_failure_and_absent_app(self):
        def api(path, params):
            if path == '/v1/apps':
                return {'data': [{'id': 'app-one'}]}
            return {'data': [{'id': 'build', 'attributes': {'version': '72', 'processingState': 'FAILED'}}]}

        with self.assertRaisesRegex(RuntimeError, 'rejected build'):
            release_poll.await_processing(api, 'com.infinityball.woodshed', '72', timeout=10)
        with self.assertRaisesRegex(RuntimeError, 'Expected one'):
            release_poll.find_build(lambda _p, _q: {'data': []}, 'com.infinityball.woodshed', '72')

    def test_poller_fails_closed_on_timeout(self):
        def api(path, params):
            return {'data': [{'id': 'app-one'}]} if path == '/v1/apps' else {'data': []}
        ticks = iter(range(10))
        with self.assertRaises(TimeoutError):
            release_poll.await_processing(api, 'com.infinityball.woodshed', '72', timeout=3,
                                          interval=1, clock=lambda: next(ticks), sleep=lambda _: None)


if __name__ == '__main__':
    unittest.main()
