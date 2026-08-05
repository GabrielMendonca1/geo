from __future__ import annotations
import fcntl as _fcntl
import hashlib as _hashlib
import json as _json
import os as _os
import re as _re
import unicodedata as _unicodedata
import uuid as _uuid
from datetime import datetime as _datetime
from datetime import timedelta as _timedelta
from datetime import timezone as _timezone
from pathlib import Path as _Path
from . import guard as _guard
from ._fs import atomic_write as _atomic_write
from ._fs import atomic_write_json as _atomic_write_json
from ._fs import now_iso as _now_iso
from ._fs import parse_frontmatter as _parse_frontmatter
from ._fs import split_frontmatter as _split_frontmatter
from .client import GeoError as _GeoError
from .matching import normalize as _normalize
from .tasks_fs import LOCAL_TZ as _LOCAL_TZ
from .tasks_fs import _default_reminders, _local_day, _normalize_anchor, _normalize_reminders
VAULT_DIR = _Path(_os.environ.get("GEOVAULT_DIR", _Path.home() / "Vault"))
BLOCKS_DIR = VAULT_DIR / "Blocks"
TASKS_DIR = VAULT_DIR / "Tasks"
INDEX_DIR = VAULT_DIR / "Index"
WRITERS = frozenset({"context-scraping", "geo-agent", "ios-bridge", "sweep"})
__all__ = ["write_block", "append_block", "write_task", "update_task", "add_occurrence"]
_TYPES = frozenset({"fleeting", "literature", "moc", "permanent", "project"})
_LAYERS = frozenset({"user", "agent", "review", "shared"})
_KINDS = frozenset({"task", "event", "habit", "milestone"})
_OPS = frozenset({"complete", "delete", "expire"})
_BAD_FILENAME = _re.compile(r'[/:\\*?"<>|]')
_WORDS = _re.compile(r"[a-z0-9]+")
_DAY_LINK = _re.compile(r"^\[\[\d{4}-\d{2}-\d{2}\]\]$")
_TRAILING_DAY_LINK = _re.compile(r"(?m)^\[\[\d{4}-\d{2}-\d{2}\]\]\s*$")
_SIMHASH_DISTANCE = 12
class _Reject(Exception):
    def __init__(self, reason, message, id=None, title_norm=None, simhash=None):
        super().__init__(message)
        self.reason = reason
        self.id = id
        self.title_norm = title_norm
        self.simhash = simhash
def _reject(reason, message, id=None, title_norm=None, simhash=None):
    raise _Reject(reason, message, id, title_norm, simhash)
def _ledger(row: dict) -> None:
    INDEX_DIR.mkdir(parents=True, exist_ok=True)
    with (INDEX_DIR / "ledger.jsonl").open("a", encoding="utf-8") as stream:
        stream.write(_json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
        stream.flush()
def _execute(writer, op, entity, action, title_norm=None, simhash=None):
    INDEX_DIR.mkdir(parents=True, exist_ok=True)
    with (INDEX_DIR / ".write.lock").open("a+") as lock:
        _fcntl.flock(lock.fileno(), _fcntl.LOCK_EX)
        row = {"ts": _now_iso(), "writer": writer, "op": op, "entity": entity,
               "id": None, "title_norm": title_norm, "simhash": simhash, "result": "ok"}
        try:
            if writer not in WRITERS:
                _reject("invalid_writer", f"writer desconhecido: {writer!r}")
            value, entity_id, actual_title, actual_hash = action()
            row.update(id=entity_id, title_norm=actual_title, simhash=actual_hash)
            _ledger(row)
            return value
        except _Reject as error:
            row.update(id=error.id,
                       title_norm=error.title_norm if error.title_norm is not None else title_norm,
                       simhash=error.simhash if error.simhash is not None else simhash,
                       result=error.reason)
            _ledger(row)
            raise _GeoError(str(error)) from None
        except _GeoError:
            row["result"] = "rejected"
            _ledger(row)
            raise
        except Exception as error:
            row["result"] = "error"
            _ledger(row)
            raise _GeoError(f"falha de escrita em {entity}: {error}") from None
def _uuid4() -> str:
    return str(_uuid.uuid4()).upper()
def _sanitize(title: str) -> str:
    name = _BAD_FILENAME.sub("-", title or "")
    name = " ".join(name.split()).strip(" -")
    return _unicodedata.normalize("NFC", name) or "Block"
def _live_blocks() -> list[_Path]:
    if not BLOCKS_DIR.exists():
        return []
    out = []
    for path in BLOCKS_DIR.rglob("*.md"):
        rel = path.relative_to(BLOCKS_DIR)
        if any(part.startswith(".") for part in rel.parts):
            continue
        if ".sync-conflict-" in path.name:
            continue
        out.append(path)
    return sorted(out)
def _read_block(path: _Path) -> tuple[dict, str, str]:
    text = path.read_text(encoding="utf-8")
    frontmatter, body = _split_frontmatter(text)
    return _parse_frontmatter(text), frontmatter, body
def _block_title(path: _Path, body: str) -> str:
    for line in body.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return path.stem
def _block_id(path: _Path, frontmatter: dict | None = None) -> str:
    fm = frontmatter if frontmatter is not None else _read_block(path)[0]
    return fm.get("id") or str(path.relative_to(BLOCKS_DIR))
def _resolve_block(value: str | _Path) -> _Path:
    raw = _Path(value).expanduser()
    candidates = [raw] if raw.is_absolute() else [BLOCKS_DIR / raw]
    if not raw.suffix:
        candidates.append(BLOCKS_DIR / f"{raw}.md")
    for path in candidates:
        if path.is_file():
            return path
    wanted = str(value)
    for path in _live_blocks():
        if _block_id(path) == wanted:
            return path
    _reject("not_found", f"bloco não encontrado: {value}", wanted)
def _tokens(text: str) -> list[str]:
    plain = _unicodedata.normalize("NFKD", text).casefold()
    plain = "".join(char for char in plain if not _unicodedata.combining(char))
    return _WORDS.findall(plain)
def _simhash(text: str) -> int | None:
    words = _tokens(text)
    shingles = [" ".join(words[i : i + 3]) for i in range(len(words) - 2)]
    if not shingles:
        return None
    weights = [0] * 64
    for shingle in shingles:
        value = int(_hashlib.md5(shingle.encode()).hexdigest(), 16)
        for bit in range(64):
            weights[bit] += 1 if value & (1 << bit) else -1
    return sum(1 << bit for bit, weight in enumerate(weights) if weight >= 0)
def _block_content(rendered: str) -> str:
    lines = rendered.splitlines()
    if lines and lines[0].startswith("# "):
        lines = lines[1:]
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    if lines and _DAY_LINK.fullmatch(lines[-1].strip()):
        lines.pop()
    while lines and not lines[-1].strip():
        lines.pop()
    return "\n".join(lines)
def _created_recent(value: str | None, cutoff: _datetime) -> bool:
    if not value:
        return False
    try:
        parsed = _datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=_timezone.utc)
        return parsed >= cutoff
    except ValueError:
        return False
def _simhash_corpus(type_: str) -> list[tuple[int, str]]:
    ledger_path = INDEX_DIR / "ledger.jsonl"
    cutoff = _datetime.now(_timezone.utc) - _timedelta(days=90)
    if ledger_path.exists() and ledger_path.stat().st_size:
        latest = {}
        for line in ledger_path.read_text(encoding="utf-8").splitlines():
            try:
                row = _json.loads(line)
            except ValueError:
                continue
            if (row.get("entity") == "block"
                    and row.get("op") in {"write_block", "append_block"}
                    and row.get("result") == "ok" and isinstance(row.get("simhash"), int)
                    and _created_recent(row.get("ts"), cutoff)):
                block_id = row.get("id")
                if block_id:
                    previous = latest.get(block_id)
                    if previous is None or row["ts"] >= previous["ts"]:
                        latest[block_id] = row
        out = []
        for block_id, row in latest.items():
            path = _find_block_id(block_id)
            if path and _read_block(path)[0].get("type") == type_:
                out.append((row["simhash"], block_id))
        return out
    out = []
    for path in _live_blocks():
        fm, _, body = _read_block(path)
        if fm.get("type") == type_ and _created_recent(fm.get("created"), cutoff):
            value = _simhash(_block_content(body))
            if value is not None:
                out.append((value, _block_id(path, fm)))
    return out
def _find_block_id(block_id: str) -> _Path | None:
    for path in _live_blocks():
        if _block_id(path) == block_id:
            return path
    return None
def _frontmatter(fields: list[tuple[str, str]]) -> str:
    return "---\n" + "\n".join(f"{key}: {value}" for key, value in fields) + "\n---\n"
def _render_block_text(title: str, body: str | None, day_id: str | None = None) -> str:
    text = body or ""
    token = f"[[{day_id or _datetime.now().strftime('%Y-%m-%d')}]]"
    return f"# {title}\n\n{text.rstrip()}\n\n{token}\n"
def _edit_field(frontmatter: str, key: str, value: str) -> str:
    lines = frontmatter.splitlines()
    inner = lines[1:-1] if len(lines) >= 2 else []
    replaced = False
    out = []
    for line in inner:
        if line.startswith(f"{key}:"):
            out.append(f"{key}: {value}")
            replaced = True
        else:
            out.append(line)
    if not replaced:
        out.append(f"{key}: {value}")
    return "---\n" + "\n".join(out) + "\n---\n"
def _task_path(task_id: str) -> _Path:
    return TASKS_DIR / f"{str(task_id).strip()}.json"
def _read_task(task_id: str) -> tuple[_Path, dict]:
    path = _task_path(task_id)
    if not path.is_file():
        _reject("not_found", f"tarefa não encontrada: {task_id}", task_id)
    try:
        return path, _json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        _reject("unreadable", f"tarefa ilegível: {task_id} ({error})", task_id)
def _task_files() -> list[_Path]:
    if not TASKS_DIR.exists():
        return []
    return sorted(
        path for path in TASKS_DIR.glob("*.json") if ".sync-conflict-" not in path.name
    )
def _valid_anchor(value, label):
    if not isinstance(value, str) or not value.strip():
        _reject("invalid_fields", f"{label} é obrigatório e deve ser uma data válida")
    normalized = _normalize_anchor(value, _LOCAL_TZ)
    if normalized is None:
        _reject("invalid_fields", f"{label} inválido: use YYYY-MM-DD ou ISO 8601")
    return normalized
def write_block(writer, title, body, type="fleeting", layer="review", tags=None,
                force_new=False, folder=None, day_id=None, status=None, *,
                human_approved=None):
    title_norm = _normalize(title)
    def action():
        if body is not None and not isinstance(body, str):
            _reject("invalid_body", "corpo deve ser uma string ou None")
        if not title_norm:
            _reject("invalid_title", "título do bloco não pode ser vazio")
        rendered_text = _render_block_text(title, body, day_id)
        content_hash = _simhash(body or "")
        if force_new and writer != "geo-agent":
            _reject("force_new_forbidden", "force_new só é aceito para geo-agent")
        if type not in _TYPES:
            _reject("invalid_type", f"tipo de bloco inválido: {type}")
        if layer not in _LAYERS:
            _reject("invalid_layer", f"layer de bloco inválido: {layer}")
        if layer == "user":
            _reject("layer_user", "layer user é protegida e não aceita escrita")
        if writer != "geo-agent" and (type != "fleeting" or layer not in {"agent", "review"}):
            _reject("writer_scope", f"{writer} só pode criar fleeting em agent/review")
        if type in {"moc", "permanent"} and writer == "geo-agent" and human_approved is None:
            _reject("human_approval_required", f"{type} exige geo-agent com human_approved=True")
        if not force_new:
            for path in _live_blocks():
                fm, _, existing_body = _read_block(path)
                if _normalize(_block_title(path, existing_body)) == title_norm:
                    existing_id = _block_id(path, fm)
                    _reject("title_dup", f"bloco duplicado: id={existing_id}, path={path}",
                            existing_id, title_norm, content_hash)
        if not force_new and content_hash is not None:
            nearest = None
            for existing_hash, existing_id in _simhash_corpus(type):
                distance = (content_hash ^ existing_hash).bit_count()
                if nearest is None or distance < nearest[0]:
                    nearest = (distance, existing_id)
            if nearest and nearest[0] <= _SIMHASH_DISTANCE:
                _reject("simhash_dup", f"simhash_dup: conteúdo próximo do bloco {nearest[1]}",
                        nearest[1], title_norm, content_hash)
        folder_path = _Path(str(folder or "").strip("/"))
        if folder_path.is_absolute() or ".." in folder_path.parts:
            _reject("invalid_folder", f"folder inválido: {folder}")
        _guard.BLOCKS_DIR = BLOCKS_DIR
        try:
            _guard.assert_create_layer(layer, str(folder_path) if folder else "")
        except _GeoError as error:
            _reject("invalid_folder", str(error))
        destination = BLOCKS_DIR / folder_path
        destination.mkdir(parents=True, exist_ok=True)
        path = destination / f"{_sanitize(title)}.md"
        suffix = 1
        while path.exists():
            path = destination / f"{_sanitize(title)}-{suffix}.md"
            suffix += 1
        block_id = _uuid4()
        ts = _now_iso()
        tag_values = [_normalize(tag).replace(" ", "-") for tag in (tags or []) if _normalize(tag)]
        fields = [("id", block_id), ("type", type), ("layer", layer), ("created", ts),
                  ("updated", ts), ("created_by", writer),
                  ("tags", "[" + ", ".join(tag_values) + "]")]
        if status:
            fields.insert(3, ("status", status))
        _atomic_write(path, _frontmatter(fields) + rendered_text)
        return {"id": block_id, "path": str(path)}, block_id, title_norm, content_hash
    return _execute(writer, "write_block", "block", action, title_norm, None)
def append_block(writer, block_path_or_id, lines):
    def action():
        path = _resolve_block(block_path_or_id)
        _guard.BLOCKS_DIR = BLOCKS_DIR
        try:
            _guard.assert_writable(path)
        except _GeoError:
            _reject("layer_user", f"layer user é protegida: {path}", _block_id(path))
        fm, frontmatter, body = _read_block(path)
        addition = lines if isinstance(lines, str) else "\n".join(str(line) for line in lines)
        trailing_link = _TRAILING_DAY_LINK.search(body)
        if trailing_link:
            link = trailing_link.group(0).strip()
            body = body[:trailing_link.start()].rstrip()
            if addition:
                body += ("\n" if body else "") + addition.rstrip("\n")
            body = body.rstrip() + f"\n\n{link}\n"
        else:
            if body and not body.endswith("\n"):
                body += "\n"
            body += addition
            if addition and not body.endswith("\n"):
                body += "\n"
        updated = _now_iso()
        _atomic_write(path, _edit_field(frontmatter, "updated", updated) + body)
        block_id = _block_id(path, fm)
        title_norm = _normalize(_block_title(path, body))
        return ({"id": block_id, "path": str(path)}, block_id, title_norm,
                _simhash(_block_content(body)))
    return _execute(writer, "append_block", "block", action)
def write_task(writer, title, kind="task", due=None, start=None, end=None, rule=None,
               time_of_day=None, target=None, force_new=False, priority=None,
               tag_ids=None, estimated_minutes=None, linked_block_id=None,
               reminders=None):
    title_norm = _normalize(title)
    def action():
        if not title_norm:
            _reject("invalid_title", "título da tarefa não pode ser vazio")
        if force_new and writer != "geo-agent":
            _reject("force_new_forbidden", "force_new só é aceito para geo-agent")
        if kind not in _KINDS:
            _reject("invalid_kind", f"kind inválido: {kind}")
        if kind == "milestone" and writer != "geo-agent":
            _reject("writer_scope", "milestone só pode ser criado por geo-agent")
        body = {"kind": kind}
        if kind == "task":
            body["due"] = _valid_anchor(due, "due")
            if estimated_minutes is not None:
                body["estimatedMinutes"] = estimated_minutes
            if not force_new:
                for path in _task_files():
                    try:
                        existing = _json.loads(path.read_text(encoding="utf-8"))
                    except (OSError, ValueError):
                        continue
                    existing_body = existing.get("body") or {}
                    if (existing.get("status") == "pending"
                            and existing_body.get("kind") == "task"
                            and _normalize(existing.get("title")) == title_norm):
                        existing_id = existing.get("id") or path.stem
                        _reject("title_dup", f"tarefa duplicada: id={existing_id} já está pendente",
                                existing_id, title_norm)
        elif kind == "event":
            body["start"] = _valid_anchor(start, "start")
            body["end"] = _valid_anchor(end, "end")
        elif kind == "habit":
            if rule is None or not time_of_day:
                _reject("invalid_fields", "habit exige rule e time_of_day")
            body["rule"] = rule if isinstance(rule, dict) else {"type": str(rule)}
            body["timeOfDay"] = time_of_day
            body["occurrences"] = []
        else:
            body["target"] = _valid_anchor(target, "target")
        task_id = _uuid4()
        ts = _now_iso()
        task = {"id": task_id, "title": title, "status": "pending",
                "priority": priority or "unset", "tagIds": list(tag_ids or []),
                "orderIndex": len(_task_files()), "createdAt": ts,
                "modifiedAt": ts, "created_at": ts, "created_by": writer,
                "body": body,
                "reminders": (_normalize_reminders(reminders) if reminders is not None
                              else _default_reminders(body))}
        if estimated_minutes is not None:
            task["estimatedMinutes"] = estimated_minutes
        if linked_block_id is not None:
            task["linkedBlockId"] = linked_block_id
        _atomic_write_json(_task_path(task_id), task)
        return task, task_id, title_norm, None
    return _execute(writer, "write_task", "task", action, title_norm)
def update_task(writer, task_id, op):
    def action():
        if op not in _OPS:
            _reject("invalid_op", f"op inválida: {op}", task_id)
        path, task = _read_task(task_id)
        kind = (task.get("body") or {}).get("kind")
        if op == "complete":
            if kind == "habit":
                _reject("habit_never_completes", "hábitos nunca são concluídos", task_id)
            task["status"] = "completed"
            task["modifiedAt"] = _now_iso()
            _atomic_write_json(path, task)
            value = task
        elif op == "delete":
            path.unlink()
            value = {"deleted": task_id}
        else:
            task["status"] = "expired"
            task["modifiedAt"] = _now_iso()
            archive = TASKS_DIR / ".archive" / _datetime.now().strftime("%Y-%m")
            destination = archive / path.name
            _atomic_write_json(path, task)
            archive.mkdir(parents=True, exist_ok=True)
            _os.replace(path, destination)
            value = {"id": task_id, "status": "expired", "path": str(destination)}
        return value, task_id, _normalize(task.get("title")), None
    return _execute(writer, "update_task", "task", action)
def add_occurrence(writer, habit_id, at=None):
    def action():
        path, task = _read_task(habit_id)
        body = task.get("body") or {}
        if body.get("kind") != "habit":
            _reject("not_habit", f"tarefa não é um hábito: {habit_id}", habit_id)
        when = at or _now_iso()
        day = _local_day(when) or _datetime.now(_LOCAL_TZ).strftime("%Y-%m-%d")
        occurrences = list(body.get("occurrences") or [])
        if not any((_local_day(item) or str(item)[:10]) == day for item in occurrences):
            occurrences.append(when)
        body["occurrences"] = occurrences
        task["body"] = body
        task["reminders"] = [{**r, "fired": False} for r in task.get("reminders") or []]
        task["modifiedAt"] = _now_iso()
        _atomic_write_json(path, task)
        return task, habit_id, _normalize(task.get("title")), None
    return _execute(writer, "add_occurrence", "task", action)
