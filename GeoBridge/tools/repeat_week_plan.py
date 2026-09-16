#!/usr/bin/env python3
"""Publish an approved frozen seven-day plan unchanged into a later ISO week."""

import argparse
import copy
import json
import pathlib
import re
import sys
import urllib.error
import urllib.request
from datetime import date, datetime, timedelta, timezone

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from geobridge import valid_plan

WEEK_RE = re.compile(r"^(\d{4})-W(\d{2})$")


class PublishError(RuntimeError):
    pass


def week_monday(value):
    match = WEEK_RE.fullmatch(value) if isinstance(value, str) else None
    if not match:
        raise PublishError("invalid ISO week: %s" % value)
    try:
        return date.fromisocalendar(int(match.group(1)), int(match.group(2)), 1)
    except ValueError as error:
        raise PublishError("invalid ISO week: %s" % value) from error


def current_week(today=None):
    iso = (today or date.today()).isocalendar()
    return "%04d-W%02d" % (iso.year, iso.week)


def load_template(path):
    try:
        plan = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PublishError("cannot read valid template JSON: %s" % path) from error
    if not valid_plan(plan):
        raise PublishError("template is not a valid vitals.plan/1")
    return plan


def require_active_authorization(template, safety):
    source = template["source"]
    authorization_id = source.get("authorizationId")
    if not authorization_id:
        return
    if not isinstance(safety, dict) or safety.get("schema") != "vitals.safety/2":
        raise PublishError("authorized template requires current safety policy")
    if safety.get("id") != source.get("safetyId") or safety.get("version") != source.get("safetyVersion"):
        raise PublishError("safety changed; explicitly review and replace the approved template")
    matches = [a for a in safety.get("authorizations", []) if isinstance(a, dict) and a.get("id") == authorization_id]
    if len(matches) != 1:
        raise PublishError("template authorization missing or ambiguous")
    authorization = matches[0]
    if authorization.get("state") != "active" or authorization.get("explicitUserAuthorization") is not True:
        raise PublishError("template authorization is no longer active")
    scope = authorization.get("scope", {})
    if source.get("routineId") not in scope.get("routineIds", []):
        raise PublishError("authorization no longer covers this routine")


def repeat_plan(template, target_week, safety=None):
    """Copy doses unchanged; recheck revocation before creating a new freeze."""
    if not valid_plan(template):
        raise PublishError("template is not a valid vitals.plan/1")
    require_active_authorization(template, safety)
    source_monday = week_monday(template["week"])
    target_monday = week_monday(target_week)
    if target_monday < source_monday:
        raise PublishError("target week is earlier than the approved template week")

    plan = copy.deepcopy(template)
    plan["week"] = target_week
    plan["revision"] = 1
    plan["id"] = "plan-%s.r1" % target_week
    plan["frozenAt"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    for offset, day in enumerate(plan["days"]):
        day["date"] = (target_monday + timedelta(days=offset)).isoformat()
    if not valid_plan(plan):
        raise PublishError("repeated output is not a valid vitals.plan/1")
    return plan


def _decode_plan(status, body, target_week, context):
    try:
        value = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PublishError("%s returned invalid JSON" % context) from error
    if status != 200 or not valid_plan(value) or value.get("week") != target_week:
        raise PublishError("%s returned an invalid plan" % context)
    return value


class HTTPClient:
    def __init__(self, base_url, token, timeout=15):
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.timeout = timeout

    def request(self, method, path, body=None):
        headers = {"Authorization": "Bearer " + self.token}
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            self.base_url + path, data=body, headers=headers, method=method
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            # Status is meaningful to the publisher; response bodies are deliberately
            # not echoed, keeping credentials and upstream details out of output.
            error.read()
            return error.code, b""
        except urllib.error.URLError as error:
            raise PublishError("GeoBridge request failed") from error


def publish(plan, client):
    """Publish r1 if absent. A concurrent 409 is accepted only after a valid GET."""
    target_week = plan.get("week")
    if not valid_plan(plan) or plan.get("revision") != 1:
        raise PublishError("output is not a valid revision-one plan")
    path = "/vitals/plan?week=" + target_week
    status, body = client.request("GET", path)
    if status == 200:
        return "exists", _decode_plan(status, body, target_week, "GET /vitals/plan")
    if status != 404:
        raise PublishError("GET /vitals/plan failed with HTTP %d" % status)

    encoded = json.dumps(plan, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    status, body = client.request("POST", "/vitals/plan", encoded)
    if status == 200:
        return "published", _decode_plan(status, body, target_week, "POST /vitals/plan")
    if status == 409:
        status, body = client.request("GET", path)
        if status != 200:
            raise PublishError("concurrent publish was not confirmed (HTTP %d)" % status)
        return "concurrent", _decode_plan(status, body, target_week, "GET after 409")
    raise PublishError("POST /vitals/plan failed with HTTP %d" % status)


def read_token(path):
    try:
        token = pathlib.Path(path).expanduser().read_text(encoding="utf-8").strip()
    except OSError as error:
        raise PublishError("cannot read token file") from error
    if not token:
        raise PublishError("token file is empty")
    return token


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Repeat an approved frozen plan into an ISO week without recalculating it."
    )
    parser.add_argument("--template", required=True, help="approved vitals.plan/1 JSON")
    parser.add_argument("--week", help="target ISO week (YYYY-Www); defaults to current week")
    parser.add_argument("--safety", help="current safety JSON; required for templates with authorizationId")
    parser.add_argument("--base-url", default="http://127.0.0.1:8643")
    parser.add_argument("--token-file", default="~/.hermes/geobridge.token")
    parser.add_argument("--dry-run", action="store_true", help="emit the repeated JSON; do no network I/O")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        safety = None
        if args.safety:
            try:
                safety = json.loads(pathlib.Path(args.safety).read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                raise PublishError("cannot read current safety policy") from error
        plan = repeat_plan(load_template(args.template), args.week or current_week(), safety)
        if args.dry_run:
            print(json.dumps(plan, ensure_ascii=False, separators=(",", ":")))
            return 0
        client = HTTPClient(args.base_url, read_token(args.token_file))
        outcome, actual = publish(plan, client)
        print(json.dumps({"status": outcome, "week": actual["week"], "id": actual["id"]}, separators=(",", ":")))
        return 0
    except PublishError as error:
        print("error: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
