#!/usr/bin/env python3

"""Deterministic generator for authorized routines (ficha A/B/C/D).

Pure and fail-closed: every exercise that the conservative safety rules would
deny must be listed, by ID, inside an explicit and scoped authorization.
An authorization never unlocks gates globally, never covers unknown exercises
or new blocks, and never claims professional verification.
"""

import argparse
import json
import math
import pathlib
import re
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from geobridge import valid_plan

MIN_SESSION_MINUTES = 30.0
MAX_SESSION_MINUTES = 70.0
DENIED_RISK_FLAGS = {"overhead-load"}
ALLOWED_GATE_STATES = {"open", "locked", "pending"}
REST_BANDS = {"compound": (120, 180), "isolation": (60, 90)}
DAY_KINDS = {"training", "cardio", "recovery", "rest"}
CLINICAL_TERMS = ("diagnóstico", "tratamento", "cura", "liberação profissional")
ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
AUTH_PREFIX = "requires-authorization:"


class GenerationError(ValueError):
    pass


def load_object(path):
    try:
        value = json.loads(pathlib.Path(path).read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise GenerationError(f"invalid JSON input: {path}") from error
    if not isinstance(value, dict):
        raise GenerationError(f"input must be an object: {path}")
    return value


def stable_id(value):
    return isinstance(value, str) and value not in {"", ".", ".."} and bool(ID_RE.fullmatch(value))


def indexed(values, kind):
    if not isinstance(values, list):
        raise GenerationError(f"invalid {kind} list")
    result = {}
    for value in values:
        if not isinstance(value, dict) or not stable_id(value.get("id")) or value["id"] in result:
            raise GenerationError(f"invalid or duplicate {kind} id")
        result[value["id"]] = value
    return result


def string_list(value, kind):
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        raise GenerationError(f"invalid {kind}")
    return value


def validate_catalog(catalog):
    if catalog.get("schema") != "vitals.catalog/1" or not stable_id(catalog.get("id")):
        raise GenerationError("invalid catalog identity")
    if type(catalog.get("version")) is not int or catalog["version"] < 1:
        raise GenerationError("invalid catalog version")
    return indexed(catalog.get("exercises"), "exercise")


def iso_moment(value, kind):
    text = value.strip()
    try:
        moment = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as error:
        raise GenerationError(f"invalid ISO date: {kind}") from error
    if len(text) > 10 and moment.tzinfo is None:
        raise GenerationError(f"ISO date needs a timezone: {kind}")
    return moment


def validate_safety(safety, exercises):
    if safety.get("schema") != "vitals.safety/2" or not stable_id(safety.get("id")):
        raise GenerationError("invalid safety identity")
    if type(safety.get("version")) is not int or safety["version"] < 2:
        raise GenerationError("invalid safety version")
    constraints = safety.get("constraints")
    if not isinstance(constraints, list) or not constraints:
        raise GenerationError("safety history must be preserved")
    governance = safety.get("governance")
    if not isinstance(governance, dict):
        raise GenerationError("missing governance")
    if governance.get("agentMayUnlockGates") is not False:
        raise GenerationError("governance must keep gates closed to the agent")
    if governance.get("selfReportCannotUnlockProfessionalGates") is not True:
        raise GenerationError("governance must keep professional gates closed to self-report alone")

    rules = safety.get("publicationRules")
    if not isinstance(rules, dict):
        raise GenerationError("missing publication rules")
    denied_gate_states = set(string_list(rules.get("denyGateStates"), "denied gate states"))
    denied_review_states = set(string_list(rules.get("denyReviewStates"), "denied review states"))
    if not {"locked", "pending"}.issubset(denied_gate_states):
        raise GenerationError("safety rules do not deny locked and pending gates")
    if not {"locked", "pending", "phase-gated"}.issubset(denied_review_states):
        raise GenerationError("safety rules do not deny unavailable reviews")

    gates = indexed(safety.get("gates"), "gate")
    for gate in gates.values():
        if gate.get("state") not in ALLOWED_GATE_STATES:
            raise GenerationError(f"invalid gate state: {gate['id']}")
        for exercise_id in string_list(gate.get("exerciseIds", []), f"gate exercises: {gate['id']}"):
            if exercise_id not in exercises:
                raise GenerationError(f"invalid gate exercise reference: {gate['id']}")
        string_list(gate.get("appliesToRiskFlags", []), f"gate risk flags: {gate['id']}")
        string_list(gate.get("blockIds", []), f"gate blocks: {gate['id']}")
        if gate.get("professionalClearanceRequired") is True:
            if gate["state"] != "locked":
                raise GenerationError(f"professional gate must stay locked: {gate['id']}")
            if gate.get("selfReportAloneCanUnlock") is not False:
                raise GenerationError(f"professional gate must deny self-report unlock: {gate['id']}")
    return gates, denied_gate_states, denied_review_states


def denial_reasons(exercise, gates, denied_gate_states, denied_review_states, blocked_risks):
    reasons = []
    if exercise.get("status") != "active":
        reasons.append("inactive")
    if exercise.get("doseType") not in {"reps", "time-min", "time-sec"}:
        raise GenerationError(f"invalid dose type: {exercise['id']}")
    review_state = exercise.get("reviewState")
    if not isinstance(review_state, str):
        raise GenerationError(f"missing review state: {exercise['id']}")
    if review_state in denied_review_states:
        reasons.append(f"review:{review_state}")
    if exercise.get("shoulderTier") in {"C", "COND"}:
        reasons.append(f"tier:{exercise['shoulderTier']}")
    risk_flags = string_list(exercise.get("riskFlags"), f"risk flags: {exercise['id']}")
    for flag in risk_flags:
        if flag in blocked_risks:
            reasons.append(f"risk:{flag}")
    gate_ids = exercise.get("safetyGateIds", [])
    if not isinstance(gate_ids, list) or not all(value in gates for value in gate_ids):
        raise GenerationError(f"invalid exercise gate reference: {exercise['id']}")
    for gate_id in gate_ids:
        if gates[gate_id]["state"] in denied_gate_states:
            reasons.append(f"gate:{gate_id}")
    return reasons, list(gate_ids)


def validate_authorization(safety, authorization_id, routine_id, exercises, gates):
    if not stable_id(authorization_id):
        raise GenerationError("invalid authorization id")
    authorizations = indexed(safety.get("authorizations"), "authorization")
    authorization = authorizations.get(authorization_id)
    if authorization is None:
        raise GenerationError(f"unknown authorization: {authorization_id}")
    if authorization.get("state") != "active":
        raise GenerationError(f"authorization is not active: {authorization_id}")
    if authorization.get("explicitUserAuthorization") is not True:
        raise GenerationError(f"authorization lacks explicit user authorization: {authorization_id}")
    evidence = authorization.get("evidence")
    if not isinstance(evidence, dict):
        raise GenerationError(f"authorization lacks evidence: {authorization_id}")
    if evidence.get("type") != "user-reported-professional-release":
        raise GenerationError(f"unsupported authorization evidence: {authorization_id}")
    if evidence.get("professionalVerified") is not False:
        raise GenerationError("authorization must not claim verified professional clearance")
    if not isinstance(evidence.get("quote"), str) or not evidence["quote"].strip():
        raise GenerationError(f"authorization evidence lacks the literal quote: {authorization_id}")
    if not isinstance(evidence.get("quotedAt"), str) or not evidence["quotedAt"].strip():
        raise GenerationError(f"authorization evidence lacks a date: {authorization_id}")
    iso_moment(evidence["quotedAt"], f"authorization quote date: {authorization_id}")
    history = authorization.get("historyPreserved")
    if not isinstance(history, dict) or history.get("dislocationHistoryRetained") is not True:
        raise GenerationError(f"authorization must preserve the reported history: {authorization_id}")

    scope = authorization.get("scope")
    if not isinstance(scope, dict):
        raise GenerationError(f"authorization lacks scope: {authorization_id}")
    if scope.get("globalUnlock") is not False:
        raise GenerationError("authorization must not unlock globally")
    if scope.get("appliesToUnknownExercises") is not False:
        raise GenerationError("authorization must not cover unknown exercises")
    if scope.get("appliesToNewBlocks") is not False:
        raise GenerationError("authorization must not cover new blocks")
    if routine_id not in string_list(scope.get("routineIds"), "authorization routines"):
        raise GenerationError(f"authorization does not cover routine: {routine_id}")
    scoped_exercises = string_list(scope.get("exerciseIds"), "authorization exercises")
    for exercise_id in scoped_exercises:
        if exercise_id not in exercises:
            raise GenerationError(f"authorization references unknown exercise: {exercise_id}")
    scoped_gates = string_list(scope.get("gateIds"), "authorization gates")
    for gate_id in scoped_gates:
        if gate_id not in gates:
            raise GenerationError(f"authorization references unknown gate: {gate_id}")
    return authorization, set(scoped_exercises), set(scoped_gates)


def validate_blocks(blocks, exercises, routine):
    if blocks.get("schema") != "vitals.blocks/1" or not stable_id(blocks.get("id")):
        raise GenerationError("invalid blocks identity")
    if type(blocks.get("version")) is not int or blocks["version"] < 1:
        raise GenerationError("invalid blocks version")
    if blocks["id"] != routine["blocksId"] or blocks["version"] != routine["blocksVersion"]:
        raise GenerationError("blocks source does not match routine pin")
    index = indexed(blocks.get("blocks"), "block")
    for block in index.values():
        if type(block.get("version")) is not int or block["version"] < 1:
            raise GenerationError(f"invalid block version: {block['id']}")
        if type(block.get("publishable")) is not bool:
            raise GenerationError(f"invalid publication state: {block['id']}")
        required = block.get("requiresAuthorizationId")
        if required is not None and not stable_id(required):
            raise GenerationError(f"invalid block authorization id: {block['id']}")
        string_list(block.get("blockedReasons"), f"blocked reasons: {block['id']}")
        minutes = block.get("estimatedMinutes")
        if isinstance(minutes, bool) or not isinstance(minutes, (int, float)) or not math.isfinite(minutes) or minutes <= 0:
            raise GenerationError(f"invalid estimated time: {block['id']}")
        items = block.get("items")
        if not isinstance(items, list) or not items:
            raise GenerationError(f"invalid block items: {block['id']}")
        for item in items:
            if not isinstance(item, dict) or item.get("exerciseId") not in exercises:
                raise GenerationError(f"invalid block exercise reference: {block['id']}")
            sets = item.get("sets")
            if not isinstance(sets, list) or not sets or not all(
                isinstance(value, list)
                and len(value) == 2
                and all(type(number) is int and number > 0 for number in value)
                and value[0] <= value[1]
                for value in sets
            ):
                raise GenerationError(f"invalid sets: {block['id']}")
            rest_class = item.get("restClass")
            if rest_class not in REST_BANDS:
                raise GenerationError(f"invalid rest class: {block['id']}")
            rest = item.get("restSec")
            low, high = REST_BANDS[rest_class]
            if type(rest) is not int or not low <= rest <= high:
                raise GenerationError(f"rest outside the {rest_class} band: {block['id']}")
            if item.get("doseType") != "reps":
                raise GenerationError(f"strength items must be measured in reps: {block['id']}")
            if exercises[item["exerciseId"]].get("doseType") != "reps":
                raise GenerationError(f"catalog dose type mismatch: {item['exerciseId']}")
            note = item.get("note")
            if note is not None and (not isinstance(note, str) or not note.strip()):
                raise GenerationError(f"invalid item note: {block['id']}")
    return index


def validate_routine(routine, catalog, authorization_id):
    if routine.get("schema") != "vitals.routine/1" or not stable_id(routine.get("id")):
        raise GenerationError("invalid routine identity")
    if type(routine.get("version")) is not int or routine["version"] < 1:
        raise GenerationError("invalid routine version")
    if routine.get("status") != "approved-by-user":
        raise GenerationError("routine is not approved by the user")
    if routine.get("requiresAuthorizationId") != authorization_id:
        raise GenerationError("routine requires a different authorization id")
    if routine.get("catalogId") != catalog["id"] or routine.get("catalogVersion") != catalog["version"]:
        raise GenerationError("catalog source does not match routine pin")
    if not stable_id(routine.get("blocksId")) or type(routine.get("blocksVersion")) is not int:
        raise GenerationError("invalid routine blocks pin")
    days = routine.get("days")
    if not isinstance(days, list) or len(days) != 7:
        raise GenerationError("routine must describe seven weekdays")
    if [day.get("weekday") if isinstance(day, dict) else None for day in days] != list(range(1, 8)):
        raise GenerationError("routine weekdays must be 1..7 in order")
    for day in days:
        if day.get("kind") not in DAY_KINDS:
            raise GenerationError("invalid routine day kind")
        if not isinstance(day.get("label"), str) or not day["label"].strip():
            raise GenerationError("invalid routine day label")
        if day["kind"] == "training":
            if not string_list(day.get("blockIds"), "routine day blocks"):
                raise GenerationError("training day without blocks")
        else:
            if day.get("blockIds"):
                raise GenerationError("non-training day must not carry blocks")
            if day["kind"] == "cardio":
                cardio = day.get("cardio")
                minutes = cardio.get("minutes") if isinstance(cardio, dict) else None
                if (
                    not isinstance(minutes, list)
                    or len(minutes) != 2
                    or not all(type(value) is int and value > 0 for value in minutes)
                    or minutes[0] > minutes[1]
                ):
                    raise GenerationError("invalid cardio dose")
                if f"{minutes[0]}–{minutes[1]} min" not in day["label"]:
                    raise GenerationError("cardio label must show the prescribed minutes")
    return days


def monday_for_week(week):
    try:
        monday = datetime.strptime(f"{week}-1", "%G-W%V-%u").replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise GenerationError("invalid ISO week") from error
    if monday.strftime("%G-W%V") != week:
        raise GenerationError("invalid ISO week")
    return monday


def build_plan(catalog, blocks, safety, routine, authorization_id, week, revision=1):
    if type(revision) is not int or revision < 1:
        raise GenerationError("revision must be positive")
    monday = monday_for_week(week)
    exercises = validate_catalog(catalog)
    gates, denied_gate_states, denied_review_states = validate_safety(safety, exercises)
    routine_days = validate_routine(routine, catalog, authorization_id)
    block_index = validate_blocks(blocks, exercises, routine)
    authorization, scoped_exercises, scoped_gates = validate_authorization(
        safety, authorization_id, routine["id"], exercises, gates
    )
    gated_blocks = {}
    for gate in gates.values():
        if gate["state"] in denied_gate_states:
            for block_id in gate.get("blockIds", []):
                gated_blocks.setdefault(block_id, []).append(gate["id"])

    blocked_risks = set(DENIED_RISK_FLAGS)
    for gate in gates.values():
        if gate["state"] in denied_gate_states:
            blocked_risks.update(gate.get("appliesToRiskFlags", []))

    used_blocks = []
    days = []
    for offset in range(7):
        date = (monday + timedelta(days=offset)).strftime("%Y-%m-%d")
        day = routine_days[offset]
        if day["kind"] != "training":
            days.append({"date": date, "items": [], "label": day["label"], "rest": True})
            continue
        items = []
        seen = set()
        duration = 0.0
        for block_id in day["blockIds"]:
            block = block_index.get(block_id)
            if block is None:
                raise GenerationError(f"missing routine block: {block_id}")
            required = block.get("requiresAuthorizationId")
            if required is None:
                if block["blockedReasons"]:
                    raise GenerationError(f"block declares reasons without authorization: {block_id}")
                if not block["publishable"]:
                    raise GenerationError(f"unpublishable routine block: {block_id}")
            else:
                if required != authorization_id:
                    raise GenerationError(f"block requires another authorization: {block_id}")
                if block["blockedReasons"] != [f"{AUTH_PREFIX}{required}"]:
                    raise GenerationError(f"block reasons must name the authorization: {block_id}")
                if block["publishable"]:
                    raise GenerationError(f"gated block must not be pre-published: {block_id}")
            for gate_id in gated_blocks.get(block_id, []):
                if gate_id not in scoped_gates:
                    raise GenerationError(f"block locked by gate: {gate_id}")
            duration += float(block["estimatedMinutes"])
            if block_id not in used_blocks:
                used_blocks.append(block_id)
            for source_item in block["items"]:
                exercise_id = source_item["exerciseId"]
                exercise = exercises[exercise_id]
                reasons, _ = denial_reasons(
                    exercise, gates, denied_gate_states, denied_review_states, blocked_risks
                )
                if reasons:
                    if exercise_id not in scoped_exercises:
                        raise GenerationError(
                            f"exercise requires an explicit authorization by id: {exercise_id}"
                        )
                    for reason in reasons:
                        if reason.startswith("gate:") and reason[5:] not in scoped_gates:
                            raise GenerationError(f"gate not covered by the authorization: {reason[5:]}")
                        if reason == "inactive":
                            raise GenerationError(f"inactive exercise cannot be authorized: {exercise_id}")
                if exercise_id in seen:
                    raise GenerationError(f"duplicate exercise in day: {exercise_id}")
                seen.add(exercise_id)
                name = exercise.get("name", "")
                note = source_item.get("note")
                items.append({
                    "doseType": "reps",
                    "exerciseId": exercise_id,
                    "muscles": exercise.get("muscles", []),
                    "name": f"{name} · {note}" if note else name,
                    "restSec": source_item["restSec"],
                    "sets": source_item["sets"],
                })
        if not MIN_SESSION_MINUTES <= duration <= MAX_SESSION_MINUTES:
            raise GenerationError(f"session time outside limits: {duration}")
        days.append({"date": date, "items": items, "label": day["label"], "rest": False})

    plan = {
        "days": days,
        "frozenAt": monday.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "id": f"plan-{week}.r{revision}",
        "revision": revision,
        "schema": "vitals.plan/1",
        "source": {
            "authorizationId": authorization["id"],
            "blocks": [
                {"blockId": block_id, "blockVersion": block_index[block_id]["version"]}
                for block_id in used_blocks
            ],
            "blocksId": blocks["id"],
            "blocksVersion": blocks["version"],
            "catalogId": catalog["id"],
            "catalogVersion": catalog["version"],
            "generator": "conversation",
            "routineId": routine["id"],
            "routineStatus": routine["status"],
            "routineVersion": routine["version"],
            "safetyId": safety["id"],
            "safetyVersion": safety["version"],
        },
        "week": week,
    }
    if not valid_plan(plan):
        raise GenerationError("generated plan violates vitals.plan/1")
    serialized = json.dumps(plan, ensure_ascii=False, sort_keys=True).lower()
    if any(term in serialized for term in CLINICAL_TERMS):
        raise GenerationError("generated plan contains clinical language")
    return plan


def plan_bytes(plan):
    return (json.dumps(plan, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def main(argv=None):
    base = pathlib.Path(__file__).resolve().parents[1] / "training" / "routines"
    parser = argparse.ArgumentParser()
    parser.add_argument("--week", required=True)
    parser.add_argument("--authorization", required=True)
    parser.add_argument("--revision", type=int, default=1)
    parser.add_argument("--routine", type=pathlib.Path, default=base / "routine-ficha-abcd.json")
    parser.add_argument("--catalog", type=pathlib.Path, default=base / "catalog-v2.json")
    parser.add_argument("--blocks", type=pathlib.Path, default=base / "blocks-ficha-abcd.json")
    parser.add_argument("--safety", type=pathlib.Path, default=base / "safety-v2.json")
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args(argv)
    try:
        plan = build_plan(
            load_object(args.catalog),
            load_object(args.blocks),
            load_object(args.safety),
            load_object(args.routine),
            args.authorization,
            args.week,
            args.revision,
        )
        data = plan_bytes(plan)
        if args.output is None:
            sys.stdout.buffer.write(data)
        else:
            if args.output.name in {"protocol.json", "state.json"}:
                raise GenerationError("generator only writes vitals.plan/1")
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_bytes(data)
    except GenerationError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
