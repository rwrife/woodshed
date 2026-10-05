"""Await an App Store Connect build from THIS run, not just a successful upload.

Only non-secret app/build IDs and processing state are printed. This script is
run in a temporary venv with PyJWT[crypto], never in system pip (PEP 668).
"""
import argparse
import json
import time
import urllib.parse
import urllib.request
from pathlib import Path

BASE = 'https://api.appstoreconnect.apple.com'


def find_build(api, bundle_id, build_number):
    apps = api('/v1/apps', {'filter[bundleId]': bundle_id, 'limit': 5})['data']
    if len(apps) != 1:
        raise RuntimeError(f'Expected one App Store Connect record for {bundle_id}; found {len(apps)}')
    app_id = apps[0]['id']
    builds = api('/v1/builds', {'filter[app]': app_id, 'sort': '-uploadedDate', 'limit': 50})['data']
    matches = [b for b in builds if b['attributes'].get('version') == build_number]
    if len(matches) > 1:
        raise RuntimeError(f'Ambiguous build number {build_number} for app {app_id}')
    return app_id, matches[0] if matches else None


def await_processing(api, bundle_id, build_number, timeout=900, interval=30, clock=time.monotonic, sleep=time.sleep):
    deadline = clock() + timeout
    while clock() < deadline:
        app_id, build = find_build(api, bundle_id, build_number)
        if build is not None:
            state = build['attributes'].get('processingState')
            print(f'App Store Connect app={app_id} build={build["id"]} number={build_number} state={state}', flush=True)
            if state in ('VALID', 'COMPLETE'):
                return app_id, build['id'], state
            if state in ('FAILED', 'INVALID'):
                raise RuntimeError(f'App Store Connect rejected build {build["id"]}: {state}')
        else:
            print(f'Build number {build_number} not indexed in app {app_id} yet', flush=True)
        sleep(min(interval, max(0, deadline - clock())))
    raise TimeoutError(f'Build {build_number} did not finish processing within {timeout}s')


def main():
    parser = argparse.ArgumentParser()
    for option in ('key', 'key-id', 'issuer-id', 'bundle-id', 'build-number'):
        parser.add_argument('--' + option, required=True)
    parser.add_argument('--timeout', type=int, default=900)
    args = parser.parse_args()
    import jwt

    key = Path(args.key).read_text()

    def api(path, params):
        now = int(time.time())
        token = jwt.encode({'iss': args.issuer_id, 'aud': 'appstoreconnect-v1',
                            'iat': now, 'exp': now + 600}, key,
                           algorithm='ES256', headers={'kid': args.key_id})
        url = BASE + path + '?' + urllib.parse.urlencode(params)
        request = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + token})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

    app_id, build_id, state = await_processing(api, args.bundle_id, args.build_number, args.timeout)
    print(f'PROCESSED_BUILD: app={app_id} id={build_id} number={args.build_number} state={state}')


if __name__ == '__main__':
    main()
