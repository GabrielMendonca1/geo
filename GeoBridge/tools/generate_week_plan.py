#!/usr/bin/env python3

import argparse
import json
import math
import pathlib
import re
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from geobridge import valid_plan

MIN_SESSION_MINUTES = 40.0
MAX_SESSION_MINUTES = 70.0
DENIED_IDS = {
    "paralela",
    "rotacao-externa-cabo",
    "rotacao-interna-cabo",
    "face-pull",
    "flexao-escapular",
}
DENIED_RISK_FLAGS = {"overhead-load"}
ALLOWED_GATE_STATES = {"open", "locked", "pending"}
ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
RECIPES = {
    4: (
        ("bl.aquecimento", "bl.costas-a.gate", "bl.bracos-a", "bl.abdomen"),
        ("bl.aquecimento", "bl.quadriceps", "bl.panturrilha"),
        ("bl.aquecimento", "bl.costas-b.gate", "bl.bracos-b1", "bl.core-surf"),
        ("bl.aquecimento", "bl.posterior", "bl.panturrilha", "bl.abdomen"),
    ),
    5: (
        ("bl.aquecimento", "bl.costas-a.gate", "bl.bracos-a", "bl.abdomen"),
        ("bl.aquecimento", "bl.quadriceps", "bl.panturrilha"),
        ("bl.aquecimento", "bl.costas-b.gate", "bl.bracos-b1", "bl.core-surf"),
        ("bl.aquecimento", "bl.posterior", "bl.panturrilha", "bl.abdomen"),
        ("bl.aquecimento", "bl.costas-a.gate", "bl.bracos-b2", "bl.abdomen"),
    ),
}
TRAINING_SLOTS = {4: (0, 1, 3, 5), 5: (0, 1, 3, 4, 5)}


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
    return isinstance(value, str) and value not in {"", ".", ".."} and ID_RE.fullmatch(value)


def indexed(values, kind):
    if not isinstance(values, list):
        raise GenerationError(f"invalid {kind} list")
    result = {}
    for value in values:
        if not isinstance(value, dict) or not stable_id(value.get("id")) or value["id"] in result:
            raise GenerationError(f"invalid or duplicate {kind} id")
        result[value["id"]] = value
    return result


def validate_sources(catalog, blocks, safety):
    if catalog.get("schema") != "vitals.catalog/1" or not stable_id(catalog.get("id")):
        raise GenerationError("invalid catalog identity")
    if type(catalog.get("version")) is not int or catalog["version"] < 1:
        raise GenerationError("invalid catalog version")
    if blocks.get("schema") != "vitals.blocks/1" or type(blocks.get("version")) is not int or blocks["version"] < 1:
        raise GenerationError("invalid blocks identity")
    if safety.get("schema") != "vitals.safety/1" or type(safety.get("version")) is not int or safety["version"] < 1:
        raise GenerationError("invalid safety identity")

    exercises = indexed(catalog.get("exercises"), "exercise")
    block_index = indexed(blocks.get("blocks"), "block")
    gates = indexed(safety.get("gates"), "gate")
    rules = safety.get("publicationRules")
    if not isinstance(rules, dict):
        raise GenerationError("missing publication rules")
    denied_gate_states = rules.get("denyGateStates")
    denied_review_states = rules.get("denyReviewStates")
    if not isinstance(denied_gate_states, list) or not all(isinstance(value, str) for value in denied_gate_states):
        raise GenerationError("invalid denied gate states")
    if not isinstance(denied_review_states, list) or not all(isinstance(value, str) for value in denied_review_states):
        raise GenerationError("invalid denied review states")
    denied_gate_states = set(denied_gate_states)
    denied_review_states = set(denied_review_states)
    if not {"locked", "pending"}.issubset(denied_gate_states):
        raise GenerationError("safety rules do not deny locked and pending gates")
    if not {"locked", "pending", "phase-gated"}.issubset(denied_review_states):
        raise GenerationError("safety rules do not deny unavailable reviews")

    blocked_exercises = set(DENIED_IDS)
    blocked_blocks = set()
    blocked_risks = set(DENIED_RISK_FLAGS)
    for gate in gates.values():
        state = gate.get("state")
        if state not in ALLOWED_GATE_STATES:
            raise GenerationError(f"invalid gate state: {gate['id']}")
        exercise_ids = gate.get("exerciseIds", [])
        block_ids = gate.get("blockIds", [])
        risk_flags = gate.get("appliesToRiskFlags", [])
        if not all(isinstance(value, str) and value in exercises for value in exercise_ids):
            raise GenerationError(f"invalid gate exercise reference: {gate['id']}")
        if not all(isinstance(value, str) and value in block_index for value in block_ids):
            raise GenerationError(f"invalid gate block reference: {gate['id']}")
        if not all(isinstance(value, str) and value for value in risk_flags):
            raise GenerationError(f"invalid gate risk reference: {gate['id']}")
        if state in denied_gate_states:
            blocked_exercises.update(exercise_ids)
            blocked_blocks.update(block_ids)
            blocked_risks.update(risk_flags)

    for exercise in exercises.values():
        if exercise.get("status") not in {"active", "retired"}:
            raise GenerationError(f"invalid exercise status: {exercise['id']}")
        if not isinstance(exercise.get("reviewState"), str):
            raise GenerationError(f"missing review state: {exercise['id']}")
        if not isinstance(exercise.get("riskFlags"), list) or not all(isinstance(value, str) for value in exercise["riskFlags"]):
            raise GenerationError(f"invalid risk flags: {exercise['id']}")
        gate_ids = exercise.get("safetyGateIds", [])
        if not isinstance(gate_ids, list) or not all(value in gates for value in gate_ids):
            raise GenerationError(f"invalid exercise gate reference: {exercise['id']}")
        if exercise["status"] != "active" or exercise["reviewState"] in denied_review_states:
            blocked_exercises.add(exercise["id"])
        if exercise.get("shoulderTier") in {"C", "COND"}:
            blocked_exercises.add(exercise["id"])
        if blocked_risks.intersection(exercise["riskFlags"]):
            blocked_exercises.add(exercise["id"])
        if any(gates[gate_id]["state"] in denied_gate_states for gate_id in gate_ids):
            blocked_exercises.add(exercise["id"])

    for block in block_index.values():
        if type(block.get("version")) is not int or block["version"] < 1:
            raise GenerationError(f"invalid block version: {block['id']}")
        if type(block.get("publishable")) is not bool or not isinstance(block.get("blockedReasons"), list):
            raise GenerationError(f"invalid publication state: {block['id']}")
        minutes = block.get("estimatedMinutes")
        if isinstance(minutes, bool) or not isinstance(minutes, (int, float)) or not math.isfinite(minutes) or minutes <= 0:
            raise GenerationError(f"invalid estimated time: {block['id']}")
        if not isinstance(block.get("items"), list) or not block["items"]:
            raise GenerationError(f"invalid block items: {block['id']}")
        for item in block["items"]:
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
            if type(item.get("restSec")) is not int or item["restSec"] < 0:
                raise GenerationError(f"invalid rest: {block['id']}")

    return exercises, block_index, blocked_exercises, blocked_blocks


def monday_for_week(week):
    try:
        monday = datetime.strptime(f"{week}-1", "%G-W%V-%u").replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise GenerationError("invalid ISO week") from error
    if monday.strftime("%G-W%V") != week:
        raise GenerationError("invalid ISO week")
    return monday


def build_plan(catalog, blocks, safety, week, training_days, revision=1):
    if training_days not in RECIPES:
        raise GenerationError("training days must be 4 or 5")
    if type(revision) is not int or revision < 1:
        raise GenerationError("revision must be positive")
    monday = monday_for_week(week)
    exercises, block_index, blocked_exercises, blocked_blocks = validate_sources(catalog, blocks, safety)
    recipes = RECIPES[training_days]
    slots = dict(zip(TRAINING_SLOTS[training_days], recipes))
    used_blocks = []
    days = []
    training_number = 0

    for offset in range(7):
        date = (monday + timedelta(days=offset)).strftime("%Y-%m-%d")
        recipe = slots.get(offset)
        if recipe is None:
            days.append({"date": date, "items": [], "label": "Descanso", "rest": True})
            continue
        training_number += 1
        items = []
        exercise_ids = set()
        duration = 0.0
        for block_id in recipe:
            block = block_index.get(block_id)
            if block is None:
                raise GenerationError(f"missing recipe block: {block_id}")
            if not block["publishable"] or block["blockedReasons"] or block_id in blocked_blocks:
                raise GenerationError(f"unpublishable recipe block: {block_id}")
            duration += float(block["estimatedMinutes"])
            if block_id not in used_blocks:
                used_blocks.append(block_id)
            for source_item in block["items"]:
                exercise_id = source_item["exerciseId"]
                exercise = exercises[exercise_id]
                if exercise_id in blocked_exercises:
                    raise GenerationError(f"blocked exercise selected: {exercise_id}")
                if exercise_id in exercise_ids:
                    raise GenerationError(f"duplicate exercise in day: {exercise_id}")
                exercise_ids.add(exercise_id)
                items.append({
                    "exerciseId": exercise_id,
                    "muscles": exercise.get("muscles", []),
                    "name": exercise.get("name", ""),
                    "restSec": source_item["restSec"],
                    "sets": source_item["sets"],
                })
        if not MIN_SESSION_MINUTES <= duration <= MAX_SESSION_MINUTES:
            raise GenerationError(f"session time outside limits: {duration}")
        days.append({"date": date, "items": items, "label": f"Treino {training_number}", "rest": False})

    plan = {
        "days": days,
        "frozenAt": monday.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "id": f"plan-{week}.r{revision}",
        "revision": revision,
        "schema": "vitals.plan/1",
        "source": {
            "blocks": [
                {"blockId": block_id, "blockVersion": block_index[block_id]["version"]}
                for block_id in used_blocks
            ],
            "catalogId": catalog["id"],
            "catalogVersion": catalog["version"],
            "generator": "conversation",
        },
        "week": week,
    }
    if not valid_plan(plan):
        raise GenerationError("generated plan violates vitals.plan/1")
    serialized = json.dumps(plan, ensure_ascii=False, sort_keys=True).lower()
    if any(term in serialized for term in ("diagnóstico", "tratamento", "cura", "liberação profissional")):
        raise GenerationError("generated plan contains clinical language")
    return plan


def plan_bytes(plan):
    return (json.dumps(plan, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def main(argv=None):
    base = pathlib.Path(__file__).resolve().parents[1] / "training"
    parser = argparse.ArgumentParser()
    parser.add_argument("--week", required=True)
    parser.add_argument("--days", required=True, type=int, choices=(4, 5))
    parser.add_argument("--revision", type=int, default=1)
    parser.add_argument("--catalog", type=pathlib.Path, default=base / "catalog.json")
    parser.add_argument("--blocks", type=pathlib.Path, default=base / "blocks.json")
    parser.add_argument("--safety", type=pathlib.Path, default=base / "safety.json")
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args(argv)
    try:
        plan = build_plan(
            load_object(args.catalog),
            load_object(args.blocks),
            load_object(args.safety),
            args.week,
            args.days,
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
