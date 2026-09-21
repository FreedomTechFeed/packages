#!/usr/bin/env python3
"""Bundle vendor lock: record/verify sha256 of the prebuilt bundles the feed ships.

build/ is gitignored in tollgate-captive-portal-site, so a vendor-drift guard
cannot diff the built bundles against the portal repo directly. Instead we lock
the vendored files (portal bundle + admin bundle + rpcd ACL) to the portal commit
they were built from:

  gen   <portal_commit>   rewrite net/tollgate-wrt/vendor.lock.json
  check                   fail if the vendored files differ from the lock

CI additionally rebuilds the portal at the locked commit and runs `check`
(see .github/workflows/vendor-drift.yml) so a stale bundle cannot ship.
"""
import hashlib
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FEED = "net/tollgate-wrt"
PORTAL_DIR = os.path.join(FEED, "files/tollgate-captive-portal-site")
ADMIN_DIR = os.path.join(FEED, "files/tollgate-admin")
ACL = os.path.join(FEED, "files/rpcd/tollgate_acl.json")
LOCK = os.path.join(FEED, "vendor.lock.json")

# welcome.html is module-only (not produced by the portal build) so it is not
# part of the locked bundle.
PORTAL_EXCLUDE = {"welcome.html"}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def collect():
    files = {}
    for base, exclude in ((PORTAL_DIR, PORTAL_EXCLUDE), (ADMIN_DIR, set())):
        for dirpath, _dirs, names in os.walk(base):
            for name in names:
                if name in exclude:
                    continue
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, ".")
                files[rel] = sha256(full)
    files[ACL] = sha256(ACL)
    return files


def gen(commit, repo="OpenTollGate/tollgate-captive-portal-site"):
    lock = {
        "portal_repo": repo,
        "portal_commit": commit,
        "files": dict(sorted(collect().items())),
    }
    with open(LOCK, "w") as fh:
        json.dump(lock, fh, indent=2, sort_keys=True)
        fh.write("\n")
    print("wrote %s (%d files, %s@%s)" % (LOCK, len(lock["files"]), repo, commit))


def check():
    with open(LOCK) as fh:
        lock = json.load(fh)
    want = lock.get("files", {})
    have = collect()
    ok = True
    for rel, digest in want.items():
        if rel not in have:
            print("DRIFT: %s missing from the vendored tree" % rel, file=sys.stderr)
            ok = False
        elif have[rel] != digest:
            print("DRIFT: %s sha256 differs from the lock" % rel, file=sys.stderr)
            ok = False
    for rel in have:
        if rel not in want:
            print("DRIFT: %s is not in the lock (re-run gen)" % rel, file=sys.stderr)
            ok = False
    if not ok:
        print("Re-vendor + regenerate vendor.lock.json.", file=sys.stderr)
        return 1
    print("OK: %d vendored files match vendor.lock.json (portal_commit=%s)"
          % (len(want), lock.get("portal_commit", "?")))
    return 0


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("gen", "check"):
        print(__doc__)
        return 2
    if sys.argv[1] == "gen":
        commit = sys.argv[2] if len(sys.argv) > 2 else "unknown"
        repo = sys.argv[3] if len(sys.argv) > 3 else "OpenTollGate/tollgate-captive-portal-site"
        gen(commit, repo)
        return 0
    return check()


if __name__ == "__main__":
    sys.exit(main())
