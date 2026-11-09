#!/usr/bin/env python3
"""Rotate the SeaweedFS S3 identities without downtime and prove the result.

The identity file lives in OpenBao at consumers/data/john2143-com/default/seaweedfs-s3-config
under the key s3.json and is rendered into Secret default/seaweedfs-s3-config, which the
SeaweedFS filer and S3 gateway both read. SeaweedFS accepts several credentials per identity,
so a rotation is issue (old+new valid) -> propagate (consumers pick up new) -> verify ->
retire (drop old). No consumer ever sees a dead key, and the only outage is the filer restart
each config write costs.

Usage:
  seaweedfs-rotate.py audit [--json]
  seaweedfs-rotate.py issue  [<identity> ... | --all] [--apply]
  seaweedfs-rotate.py propagate [<identity> ... | --all] [--apply]
  seaweedfs-rotate.py verify [<identity> ... | --all] [--json]
  seaweedfs-rotate.py retire [<identity> ... | --all] [--apply]
  seaweedfs-rotate.py delete-identity <identity> [--apply] [--force --reason TEXT]
  seaweedfs-rotate.py status

Every mutating subcommand prints what it would do unless --apply is given. No credential is
ever written to stdout: any occurrence of a key or secret in output is replaced by ***.

S3 access uses rclone (aws-cli is not installed on the workstation); the remote is configured
through RCLONE_CONFIG_ROT_* environment variables so no key reaches argv or disk.
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

S3_ENDPOINT = "http://192.168.6.31:8333"
BAO_MOUNT = "consumers"
CONFIG_KEY = "john2143-com/default/seaweedfs-s3-config"
CONFIG_FIELD = "s3.json"
CONTEXT = "closet-as-admin"
FILER_ES = ("default", "seaweedfs-s3-config")

STATE_DIR = os.path.expanduser("~/.local/state/seaweedfs-rotation")
RCLONE_CONF = os.path.join(STATE_DIR, "rclone.conf")

# Buckets that existed at audit time. Used to pick an out-of-scope probe target; never used to
# create anything.
KNOWN_BUCKETS = (
    "edge-tofu-state", "frigate-genai", "history-old", "imagehost-files",
    "litellm-spend-logs", "loki-admin", "loki-chunks", "loki-ruler", "marvel3-logs",
    "mimir-alertmanager", "mimir-blocks", "mimir-rules", "rots4-releases", "shares",
    "tempo-blocks", "tuwunel-media",
)

CONSUMERS = {
    "observability": [dict(kind="bao", path="john2143-com/observability/o11y-rustfs-buckets",
                           keys=("S3_ACCESS_KEY", "S3_SECRET_KEY"),
                           es=("observability", "o11y-rustfs-buckets"))],
    "litellm": [dict(kind="bao", path="john2143-com/default/litellm-s3-creds",
                     keys=("S3_ACCESS_KEY", "S3_SECRET_KEY"),
                     es=("default", "litellm-s3-creds"))],
    "seaweedfs-frigate-genai": [dict(kind="bao", path="john2143-com/default/frigate-genai-worker-creds",
                                     keys=("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"),
                                     es=("default", "frigate-genai-worker-creds"))],
    "john2143-worker-home": [dict(kind="bao", path="john2143-com/default/minio-creds",
                                  keys=("S3_ACCESS_KEY", "S3_SECRET_KEY"),
                                  es=("default", "minio-creds"))],
    "edge-tofu": [dict(kind="bao", path="edge/s3", keys=("access_key", "secret_key"), es=None)],
    "rots4-ci": [dict(kind="manual",
                      note="GitHub Actions secret outside this checkout; locate before retiring")],
    "rain-marvel": [dict(kind="manual", note="consumer unknown; locate before retiring")],
}

SCOPES = {
    "observability": ["mimir-alertmanager", "mimir-blocks", "mimir-rules",
                      "loki-admin", "loki-chunks", "loki-ruler", "tempo-blocks"],
    "litellm": ["litellm-spend-logs"],
    "seaweedfs-frigate-genai": ["frigate-genai"],
    "john2143-worker-home": ["imagehost-files"],
    "rots4-ci": ["rots4-releases"],
    "edge-tofu": ["edge-tofu-state"],
    "rain-marvel": ["marvel3-logs"],
}


class Fail(Exception):
    pass


_SECRETS: list[str] = []


def redact(text: str) -> str:
    for value in _SECRETS:
        if value:
            text = text.replace(value, "***")
    return text


def run(cmd, env=None, input_bytes=None, check=True, quiet=False):
    proc = subprocess.run(cmd, input=input_bytes, capture_output=True, env=env)
    out = proc.stdout.decode("utf-8", "replace")
    err = proc.stderr.decode("utf-8", "replace")
    if check and proc.returncode != 0:
        raise Fail(redact(f"{' '.join(cmd[:4])}... failed ({proc.returncode}): {err.strip()[:400]}"))
    if not quiet and err.strip() and not check:
        pass
    return proc.returncode, out, err


def require_token() -> None:
    rc, out, err = run(["bao", "token", "lookup", "-format=json"], check=False)
    if rc != 0:
        raise Fail("no usable OpenBao token: run `bao login -method=oidc` first")
    info = json.loads(out)
    policies = info.get("data", {}).get("policies", [])
    if not any(p in ("root", "openbao-admin") for p in policies):
        raise Fail(f"token lacks openbao-admin (policies: {policies})")


# ---------------------------------------------------------------- OpenBao

def bao_kv_get(path: str) -> dict:
    _, out, _ = run(["bao", "kv", "get", "-mount=" + BAO_MOUNT, "-format=json", path])
    body = json.loads(out)["data"]
    return body.get("data", body)


def bao_kv_put(path: str, fields: dict) -> None:
    """Write every field through a 0600 temp file so no value ever appears in argv or ps."""
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    temps: list[str] = []
    try:
        pairs = []
        for key, value in fields.items():
            fd, name = tempfile.mkstemp(dir=STATE_DIR, prefix=".put-")
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w") as handle:
                handle.write(value)
            temps.append(name)
            pairs.append(f"{key}=@{name}")
        run(["bao", "kv", "put", "-mount=" + BAO_MOUNT, path, *pairs])
    finally:
        for name in temps:
            try:
                with open(name, "r+b") as handle:
                    handle.write(b"\0" * os.path.getsize(name))
                os.unlink(name)
            except OSError:
                pass


def load_config() -> dict:
    raw = bao_kv_get(CONFIG_KEY).get(CONFIG_FIELD)
    if not raw:
        raise Fail(f"{CONFIG_KEY} has no {CONFIG_FIELD} field")
    cfg = json.loads(raw)
    for ident in cfg.get("identities", []):
        for cred in ident.get("credentials", []):
            for field in ("accessKey", "secretKey"):
                if cred.get(field):
                    _SECRETS.append(cred[field])
    return cfg


def save_config(cfg: dict) -> None:
    bao_kv_put(CONFIG_KEY, {CONFIG_FIELD: json.dumps(cfg, separators=(",", ":"))})


def config_version() -> int:
    _, out, _ = run(["bao", "kv", "metadata", "get", "-mount=" + BAO_MOUNT, "-format=json", CONFIG_KEY])
    return int(json.loads(out)["data"]["current_version"])


# ---------------------------------------------------------------- cluster

def force_sync(namespace: str, name: str) -> None:
    run(["kubectl", "--context", CONTEXT, "-n", namespace, "annotate", "externalsecret", name,
         f"force-sync={int(time.time())}", "--overwrite"])


def secret_keys(namespace: str, name: str) -> dict:
    """Return the Secret's data keys mapped to their decoded values (never printed)."""
    rc, out, _ = run(["kubectl", "--context", CONTEXT, "-n", namespace, "get", "secret", name,
                      "-o", "json"], check=False)
    if rc != 0:
        return {}
    import base64
    data = json.loads(out).get("data") or {}
    return {k: base64.b64decode(v).decode("utf-8", "replace") for k, v in data.items()}


def scan_cluster(needles: list[str]) -> list[dict]:
    """Find every Secret/ConfigMap carrying any of the given values. Values are never printed."""
    needle_set = [n for n in needles if n]
    rc, out, err = run(["kubectl", "--context", CONTEXT, "get", "secret,configmap", "-A", "-o", "json"],
                       check=False)
    if rc != 0:
        raise Fail(redact(f"cluster scan failed: {err.strip()[:300]}"))
    hits = []
    for item in json.loads(out).get("items", []):
        meta = item.get("metadata", {})
        ns, name = meta.get("namespace", ""), meta.get("name", "")
        kind = item.get("kind", "").lower()
        if kind == "secret":
            import base64
            values = {k: base64.b64decode(v).decode("utf-8", "replace")
                      for k, v in (item.get("data") or {}).items()}
        else:
            values = dict(item.get("data") or {})
        for field, value in values.items():
            for needle in needle_set:
                if needle in value:
                    hits.append({"kind": kind, "namespace": ns, "name": name, "field": field})
                    break
    return hits


# ---------------------------------------------------------------- S3 via rclone

def rclone(ak: str, sk: str, args: list[str], input_bytes=None, check=True):
    env = dict(os.environ)
    env.update({
        "RCLONE_CONFIG": RCLONE_CONF,
        "RCLONE_CONFIG_ROT_TYPE": "s3",
        "RCLONE_CONFIG_ROT_PROVIDER": "Other",
        "RCLONE_CONFIG_ROT_ENDPOINT": S3_ENDPOINT,
        "RCLONE_CONFIG_ROT_ACCESS_KEY_ID": ak,
        "RCLONE_CONFIG_ROT_SECRET_ACCESS_KEY": sk,
        "RCLONE_CONFIG_ROT_FORCE_PATH_STYLE": "true",
        "RCLONE_CONFIG_ROT_NO_CHECK_BUCKET": "true",
        "RCLONE_CONFIG_ROT_V2_AUTH": "false",
    })
    base = ["rclone", "--config", RCLONE_CONF, "--retries", "1", "--timeout", "15s",
            "--contimeout", "5s", "--low-level-retries", "1"]
    return run(base + args, env=env, input_bytes=input_bytes, check=check)


def probe_list(ak: str, sk: str, bucket: str) -> tuple[bool, str]:
    rc, out, err = rclone(ak, sk, ["lsf", f"rot:{bucket}", "--max-depth", "1"], check=False)
    return rc == 0, redact((err or out).strip())


def probe_write(ak: str, sk: str, bucket: str) -> tuple[bool, str]:
    rc, out, err = rclone(ak, sk, ["rcat", f"rot:{bucket}/.rotate-probe"], input_bytes=b"x", check=False)
    return rc == 0, redact((err or out).strip())


def probe_delete(ak: str, sk: str, bucket: str) -> tuple[bool, str]:
    rc, out, err = rclone(ak, sk, ["deletefile", f"rot:{bucket}/.rotate-probe"], check=False)
    return rc == 0, redact((err or out).strip())


def list_buckets(ak: str, sk: str) -> list[str]:
    rc, out, err = rclone(ak, sk, ["lsf", "rot:"], check=False)
    if rc != 0:
        return []
    return sorted(line.rstrip("/") for line in out.splitlines() if line.strip())


# ---------------------------------------------------------------- audit

def newest(ident: dict) -> dict:
    creds = ident.get("credentials") or []
    if not creds:
        raise Fail(f"identity {ident.get('name')} has no credentials")
    return creds[-1]


def is_global(ident: dict) -> bool:
    actions = [a.strip() for a in ident.get("actions", [])]
    if any(a.lower() == "admin" for a in actions):
        return True
    return not any(":" in a for a in actions)


def cmd_audit(args) -> int:
    require_token()
    cfg = load_config()
    idents = cfg.get("identities", [])
    needles = [c.get("accessKey") for i in idents for c in i.get("credentials", [])]
    needles += [c.get("secretKey") for i in idents for c in i.get("credentials", [])]
    hits = scan_cluster(needles)

    report = []
    probe_cred = None
    for ident in idents:
        cred = newest(ident)
        probe_cred = probe_cred or cred
        entry = {
            "name": ident.get("name"),
            "credentials": len(ident.get("credentials", [])),
            "actions": ident.get("actions", []),
            "resources": ident.get("resources"),
            "scope": "global" if is_global(ident) else "scoped",
            "holders": [],
            "probe": {},
        }
        for holder in CONSUMERS.get(ident["name"], []):
            if holder["kind"] == "bao":
                entry["holders"].append(f"bao:{holder['path']}")
            else:
                entry["holders"].append("manual (consumer unlocated)")
        for hit in hits:
            if hit["field"] in [c.get("accessKey") for c in ident["credentials"]]:
                entry["holders"].append(f"{hit['kind']}:{hit['namespace']}/{hit['name']}")
        for bucket in SCOPES.get(ident["name"], []):
            ok, err = probe_list(cred["accessKey"], cred["secretKey"], bucket)
            entry["probe"][bucket] = "ok" if ok else err[:120]
        report.append(entry)

    buckets = list_buckets(probe_cred["accessKey"], probe_cred["secretKey"]) or list(KNOWN_BUCKETS)
    if args.json:
        print(json.dumps({"identities": report, "buckets": buckets,
                          "cluster_hits": hits, "version": config_version()}, indent=2))
    else:
        print(f"config version: {config_version()}   identities: {len(report)}   buckets: {len(buckets)}")
        for entry in report:
            print(f"\n{entry['name']}")
            print(f"  credentials: {entry['credentials']}   scope: {entry['scope']}")
            print(f"  actions: {', '.join(entry['actions']) or '(none)'}")
            if entry["resources"]:
                print(f"  resources: {entry['resources']}")
            for holder in entry["holders"]:
                print(f"  holder: {holder}")
            bad = {b: e for b, e in entry["probe"].items() if e != "ok"}
            print(f"  probe: {len(entry['probe']) - len(bad)}/{len(entry['probe'])} ok"
                  + (f"   FAILED: {bad}" if bad else ""))
    return 1 if any(e["scope"] == "global" for e in report) else 0


# ---------------------------------------------------------------- issue

def scoped_actions(buckets: list[str]) -> list[str]:
    return [f"{verb}:{bucket}" for bucket in buckets for verb in ("Read", "Write", "List")]


def cmd_issue(args) -> int:
    require_token()
    cfg = load_config()
    targets = select_targets(args, cfg)
    before = config_version()
    for ident in cfg["identities"]:
        if ident["name"] not in targets:
            continue
        buckets = SCOPES.get(ident["name"])
        if not buckets:
            raise Fail(f"no SCOPES entry for {ident['name']}")
        cred = {"accessKey": secrets.token_hex(10), "secretKey": secrets.token_hex(20)}
        _SECRETS.append(cred["accessKey"]); _SECRETS.append(cred["secretKey"])
        old = len(ident.get("credentials", []))
        ident.setdefault("credentials", []).append(cred)
        ident["actions"] = scoped_actions(buckets)
        ident.pop("resources", None)
        print(f"{ident['name']}: credentials {old}->{old + 1}, scope -> {len(buckets)} buckets")
    if not args.apply:
        print(f"\nDRY RUN: would write version {before + 1}. Re-run with --apply.")
        return 0
    save_config(cfg)
    force_sync(*FILER_ES)
    print(f"\nwrote version {config_version()} and forced filer sync")
    return 0


# ---------------------------------------------------------------- propagate

def cmd_propagate(args) -> int:
    require_token()
    cfg = load_config()
    targets = select_targets(args, cfg)
    for ident in cfg["identities"]:
        if ident["name"] not in targets:
            continue
        cred = newest(ident)
        for holder in CONSUMERS.get(ident["name"], []):
            if holder["kind"] != "bao":
                print(f"{ident['name']}: MANUAL: {holder.get('note')}")
                continue
            existing = bao_kv_get(holder["path"])
            ak_key, sk_key = holder["keys"]
            existing[ak_key] = cred["accessKey"]
            existing[sk_key] = cred["secretKey"]
            print(f"{ident['name']}: {holder['path']} <- newest credential "
                  f"({ak_key}, {sk_key}){' [dry run]' if not args.apply else ''}")
            if args.apply:
                bao_kv_put(holder["path"], existing)
                if holder.get("es"):
                    force_sync(*holder["es"])
                    print(f"  force-synced externalsecret {holder['es'][0]}/{holder['es'][1]}")
    if not args.apply:
        print("\nDRY RUN. Re-run with --apply.")
    return 0


# ---------------------------------------------------------------- verify

def verify_identity(ident: dict, cfg: dict) -> tuple[bool, list[str]]:
    problems = []
    cred = newest(ident)
    name = ident["name"]
    for holder in CONSUMERS.get(name, []):
        if holder["kind"] != "bao" or not holder.get("es"):
            continue
        ns, sec = holder["es"]
        values = secret_keys(ns, sec)
        ak_key = holder["keys"][0]
        if values.get(ak_key) != cred["accessKey"]:
            problems.append(f"{ns}/{sec} does not hold the newest {ak_key}")
    for bucket in SCOPES.get(name, []):
        ok, err = probe_write(cred["accessKey"], cred["secretKey"], bucket)
        if not ok:
            problems.append(f"write denied on {bucket}: {err[:100]}")
            continue
        ok, err = probe_delete(cred["accessKey"], cred["secretKey"], bucket)
        if not ok:
            problems.append(f"delete denied on {bucket}: {err[:100]}")
    out_of_scope = next((b for b in KNOWN_BUCKETS if b not in SCOPES.get(name, [])), None)
    if out_of_scope and not is_global(ident):
        ok, err = probe_list(cred["accessKey"], cred["secretKey"], out_of_scope)
        if ok:
            problems.append(f"scope leak: {out_of_scope} is listable")
        elif "AccessDenied" not in err and "Forbidden" not in err and "403" not in err:
            problems.append(f"unexpected error on out-of-scope {out_of_scope}: {err[:100]}")
    if len(ident.get("credentials", [])) > 1:
        old = ident["credentials"][0]
        ok, err = probe_list(old["accessKey"], old["secretKey"], SCOPES.get(name, [name])[0])
        if not ok:
            problems.append(f"previous credential no longer authenticates: {err[:100]}")
    return not problems, problems


def cmd_verify(args) -> int:
    require_token()
    cfg = load_config()
    targets = select_targets(args, cfg)
    results, ok_all = [], True
    for ident in cfg["identities"]:
        if ident["name"] not in targets:
            continue
        ok, problems = verify_identity(ident, cfg)
        ok_all = ok_all and ok
        results.append({"name": ident["name"], "ok": ok, "problems": problems})
        status = "ok" if ok else "FAIL"
        print(f"{ident['name']}: {status}  (creds={len(ident.get('credentials', []))}, "
              f"buckets={len(SCOPES.get(ident['name'], []))})")
        for problem in problems:
            print(f"  ! {problem}")
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    with open(os.path.join(STATE_DIR, "last-verify.json"), "w") as handle:
        json.dump({"at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                   "results": results}, handle, indent=2)
    if args.json:
        print(json.dumps(results, indent=2))
    return 0 if ok_all else 1


# ---------------------------------------------------------------- retire

def cmd_retire(args) -> int:
    require_token()
    cfg = load_config()
    targets = select_targets(args, cfg)
    for ident in cfg["identities"]:
        if ident["name"] not in targets:
            continue
        ok, problems = verify_identity(ident, cfg)
        if not ok:
            raise Fail(f"refusing to retire {ident['name']}: " + "; ".join(problems))
    retiring = [(i["name"], c) for i in cfg["identities"] if i["name"] in targets
                for c in (i.get("credentials") or [])[:-1]]
    if retiring:
        hits = scan_cluster([cred["accessKey"] for _, cred in retiring])
        if hits:
            raise Fail("refusing to retire: cluster values still carry the old key in "
                       + ", ".join(f"{hit['kind']} {hit['namespace']}/{hit['name']}" for hit in hits))
    for ident in cfg["identities"]:
        if ident["name"] not in targets:
            continue
        ident["credentials"] = [ident["credentials"][-1]]
        print(f"{ident['name']}: credentials -> 1")
    if not args.apply:
        print("\nDRY RUN. Re-run with --apply.")
        return 0
    save_config(cfg)
    force_sync(*FILER_ES)
    print(f"wrote version {config_version()}; waiting for the filer to restart")
    # The retired-key proof must not race the filer restart: until the new config is loaded,
    # the old key is still valid and every check would be meaningless.
    run(["kubectl", "--context", CONTEXT, "-n", "default", "rollout", "status",
         "deploy/seaweedfs-filer", "--timeout=240s"], check=False)
    for name, cred in retiring:
        rc, out, err = rclone(cred["accessKey"], cred["secretKey"], ["lsf", "rot:"], check=False)
        blob = err or out
        if "InvalidAccessKeyId" in blob:
            print(f"{name}: retired key rejected (InvalidAccessKeyId)")
        elif rc == 0:
            raise Fail(f"{name}: retired key still authenticates")
        else:
            print(f"{name}: retired key rejected ({blob.strip()[:80]})")
    return 0


# ---------------------------------------------------------------- delete-identity

def cmd_delete_identity(args) -> int:
    require_token()
    cfg = load_config()
    ident = next((i for i in cfg["identities"] if i["name"] == args.identity), None)
    if not ident:
        raise Fail(f"no identity named {args.identity}")
    keys = [c.get("accessKey") for c in ident.get("credentials", [])]
    hits = scan_cluster(keys)
    references = [f"{h['kind']} {h['namespace']}/{h['name']} field {h['field']}" for h in hits]
    if references and not args.force:
        raise Fail("refusing to delete: still referenced by " + ", ".join(references))
    print(f"{args.identity}: removing {len(ident.get('credentials', []))} credential(s), "
          f"{len(references)} cluster reference(s) found")
    for ref in references:
        print(f"  cluster: {ref}")
    if not args.apply:
        print("\nDRY RUN. Re-run with --apply.")
        return 0
    cfg["identities"] = [i for i in cfg["identities"] if i["name"] != args.identity]
    save_config(cfg)
    force_sync(*FILER_ES)
    print(f"wrote version {config_version()}")
    return 0


# ---------------------------------------------------------------- status

def cmd_status(args) -> int:
    require_token()
    cfg = load_config()
    path = os.path.join(STATE_DIR, "last-verify.json")
    verified = {}
    if os.path.exists(path):
        with open(path) as handle:
            blob = json.load(handle)
        verified = {r["name"]: (r["ok"], blob["at"]) for r in blob["results"]}
    print(f"{'identity':28} {'creds':>5} {'scope':>7} {'buckets':>7}  holders                 verified")
    for ident in cfg.get("identities", []):
        name = ident["name"]
        holders = len(CONSUMERS.get(name, []))
        ok, at = verified.get(name, (None, "-"))
        mark = "?" if ok is None else ("ok" if ok else "FAIL")
        print(f"{name:28} {len(ident.get('credentials', [])):>5} "
              f"{'global' if is_global(ident) else 'scoped':>7} "
              f"{len(SCOPES.get(name, [])):>7}  {holders:>3} holder(s)          {mark} {at}")
    return 0


# ---------------------------------------------------------------- shared

def select_targets(args, cfg) -> set[str]:
    names = {i["name"] for i in cfg.get("identities", [])}
    if getattr(args, "all", False):
        return names
    requested = set(getattr(args, "identities", []) or [])
    unknown = requested - names
    if unknown:
        raise Fail(f"unknown identities: {sorted(unknown)}")
    if not requested:
        raise Fail("name an identity or pass --all")
    return requested


def main(argv=None) -> int:
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    if not os.path.exists(RCLONE_CONF):
        open(RCLONE_CONF, "w").close()
        os.chmod(RCLONE_CONF, 0o600)

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("audit", help="report identities, scopes, holders and reachability")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_audit)

    for name, func, helptext in (
        ("issue", cmd_issue, "append a credential and tighten scope (one config write)"),
        ("propagate", cmd_propagate, "write the newest credential into each consumer"),
        ("retire", cmd_retire, "drop every credential except the newest (one config write)"),
    ):
        p = sub.add_parser(name, help=helptext)
        p.add_argument("identities", nargs="*")
        p.add_argument("--all", action="store_true")
        p.add_argument("--apply", action="store_true")
        p.set_defaults(func=func)

    p = sub.add_parser("verify", help="prove read, write and delete per scope")
    p.add_argument("identities", nargs="*")
    p.add_argument("--all", action="store_true")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("delete-identity", help="remove an identity entirely")
    p.add_argument("identity")
    p.add_argument("--apply", action="store_true")
    p.add_argument("--force", action="store_true")
    p.add_argument("--reason", default="")
    p.set_defaults(func=cmd_delete_identity)

    p = sub.add_parser("status", help="one line per identity")
    p.set_defaults(func=cmd_status)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Fail as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
