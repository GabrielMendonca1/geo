from __future__ import annotations

import importlib
import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "hermes-extensions"))
geo_write = importlib.import_module("geo-tools.geo_write")
GeoError = importlib.import_module("geo-tools.client").GeoError

failures = []
state = {}
attempts = 0


def check(name, function):
    global attempts
    try:
        function()
        print(f"PASS {name}")
    except Exception as error:
        failures.append((name, error))
        print(f"FAIL {name}: {type(error).__name__}: {error}")


def equal(actual, expected):
    if actual != expected:
        raise AssertionError(f"esperado {expected!r}, recebido {actual!r}")


def truth(value, message):
    if not value:
        raise AssertionError(message)


def rejected(function, contains):
    global attempts
    attempts += 1
    try:
        function()
    except GeoError as error:
        truth(contains in str(error), f"erro não contém {contains!r}: {error}")
        return str(error)
    raise AssertionError("operação deveria ser rejeitada")


def accepted(function):
    global attempts
    attempts += 1
    return function()


def task_file(task_id):
    return geo_write.TASKS_DIR / f"{task_id}.json"


CALIBRATION_WORDS = (
    "abacaxi abajur abelha abrigo academia açafrão agenda algodão alicate amizade "
    "ampulheta âncora aquarela areia armário aroma artista árvore asfalto atleta avenida "
    "azulejo bagagem bailarina balcão bambu bandeira barco bateria biblioteca bicicleta "
    "biscoito bússola cabana cachorro caderno café caminho caneta carteira castelo cebola "
    "cidade cinema ciranda cozinha cristal desenho diamante escola escultura espelho estrela "
    "família fazenda feira janela jardim laranja livro madeira mercado mochila montanha música "
    "navio oficina palavra parque perfume planeta ponte praia queijo relógio retrato rio sapato "
    "teatro tesoura"
).split()
VALIDATION_WORDS = (
    "agricultor bombeiro cientista dentista eletricista fotógrafo geólogo historiador "
    "ilustrador jornalista locutor mecânico nutricionista operador padeiro químico radialista "
    "socorrista tradutor urbanista veterinário zelador aldeia bosque cânion deserto encosta "
    "fiorde geleira ilha lago mangue nascente oásis penhasco recife serra tundra vale vulcão "
    "alumínio bronze cobre estanho ferro granito mármore níquel ouro prata quartzo rubi safira "
    "titânio urânio âmbar circuito diodo engrenagem fusível hélice ímã joystick lâmpada motor "
    "núcleo órbita pistão radar sensor turbina válvula wafer xilofone iogurte zircônio envelope "
    "foguete garagem hospital"
).split()


def simhash_distances(words):
    base_hash = geo_write._simhash(" ".join(words))
    one_word = []
    two_words = []
    unrelated = []
    for index in range(50):
        first = (index * 13 + 7) % 80
        second = (index * 29 + 19) % 80
        if second == first:
            second = (second + 1) % 80
        near_one = list(words)
        near_one[first] = words[(first + 31 + index) % 80]
        if near_one[first] == words[first]:
            near_one[first] = words[(first + 1) % 80]
        near_two = list(near_one)
        near_two[second] = words[(second + 47 + index * 3) % 80]
        if near_two[second] == words[second]:
            near_two[second] = words[(second + 1) % 80]
        one_hash = geo_write._simhash(" ".join(near_one))
        two_hash = geo_write._simhash(" ".join(near_two))
        one_word.append((base_hash ^ one_hash).bit_count())
        two_words.append((base_hash ^ two_hash).bit_count())
    for index in range(20):
        left = words[:40]
        right = words[40:]
        left_offset = (index * 7) % 40
        right_offset = (index * 13) % 40
        left = left[left_offset:] + left[:left_offset]
        right = right[right_offset:] + right[:right_offset]
        left_hash = geo_write._simhash(" ".join(left))
        right_hash = geo_write._simhash(" ".join(right))
        unrelated.append((left_hash ^ right_hash).bit_count())
    return one_word, two_words, unrelated


def simhash_table(label, distances):
    one_word, two_words, unrelated = distances
    rows = []
    print(f"{label} threshold catch_1_word catch_2_words false_positive")
    for threshold in range(16):
        catch_one = sum(value <= threshold for value in one_word) / len(one_word)
        catch_two = sum(value <= threshold for value in two_words) / len(two_words)
        false_positive = sum(value <= threshold for value in unrelated) / len(unrelated)
        rows.append((threshold, catch_one, catch_two, false_positive))
        print(
            f"{label} {threshold:2d} {catch_one:6.1%} "
            f"{catch_two:6.1%} {false_positive:6.1%}"
        )
    return rows


def calibration():
    equal(len(CALIBRATION_WORDS), 80)
    equal(len(VALIDATION_WORDS), 80)
    equal(len(set(CALIBRATION_WORDS)), 80)
    equal(len(set(VALIDATION_WORDS)), 80)
    equal(set(CALIBRATION_WORDS) & set(VALIDATION_WORDS), set())
    calibration_rows = simhash_table(
        "CALIBRATION_A", simhash_distances(CALIBRATION_WORDS)
    )
    validation_rows = simhash_table(
        "VALIDATION_B", simhash_distances(VALIDATION_WORDS)
    )
    threshold = geo_write._SIMHASH_DISTANCE
    truth(threshold < len(calibration_rows), "threshold fora da varredura")
    catch_one, catch_two, false_positive = validation_rows[threshold][1:]
    truth(catch_one >= 0.9, f"catch de 1 palavra abaixo de 90%: {catch_one:.1%}")
    truth(catch_two >= 0.9, f"catch de 2 palavras abaixo de 90%: {catch_two:.1%}")
    equal(false_positive, 0)
    return threshold


check("calibração empírica do simhash", calibration)


with tempfile.TemporaryDirectory() as temp:
    vault = Path(temp) / "GeoVault"
    geo_write.VAULT_DIR = vault
    geo_write.BLOCKS_DIR = vault / "Blocks"
    geo_write.TASKS_DIR = vault / "Tasks"
    geo_write.INDEX_DIR = vault / "Index"

    def block_per_writer():
        for index, writer in enumerate(sorted(geo_write.WRITERS)):
            result = accepted(
                lambda writer=writer, index=index: geo_write.write_block(
                    writer,
                    f"Bloco {writer}",
                    f"corpo exclusivo alfa {writer} valor {index} horizonte",
                    layer="agent",
                )
            )
            truth(Path(result["path"]).is_file(), writer)

    check("write_block happy path para cada writer", block_per_writer)

    def user_layer_all():
        for writer in sorted(geo_write.WRITERS):
            rejected(
                lambda writer=writer: geo_write.write_block(
                    writer, f"User {writer}", "texto protegido aqui", layer="user"
                ),
                "layer user",
            )

    check("layer user rejeitada para todos writers", user_layer_all)

    check(
        "permanent por automação rejeitado",
        lambda: rejected(
            lambda: geo_write.write_block(
                "sweep", "P automático", "conteúdo permanente automático", type="permanent"
            ),
            "só pode criar fleeting",
        ),
    )
    check(
        "moc por automação rejeitado",
        lambda: rejected(
            lambda: geo_write.write_block(
                "ios-bridge", "MOC automático", "mapa automático conteúdo", type="moc"
            ),
            "só pode criar fleeting",
        ),
    )
    check(
        "moc geo-agent sem aprovação rejeitado",
        lambda: rejected(
            lambda: geo_write.write_block(
                "geo-agent", "MOC sem aprovação", "mapa ainda sem aprovação", type="moc"
            ),
            "human_approved=True",
        ),
    )

    def approved_permanent():
        state["permanent"] = accepted(
            lambda: geo_write.write_block(
                "geo-agent",
                "Conhecimento aprovado",
                "princípio durável sobre sistemas geográficos",
                type="permanent",
                layer="shared",
                tags=["Sistema Geo"],
                human_approved=True,
            )
        )
        text = Path(state["permanent"]["path"]).read_text(encoding="utf-8")
        truth("created_by: geo-agent" in text, "created_by ausente")
        truth("[[" in text, "day-link ausente")

    check("permanent aprovado e frontmatter completo", approved_permanent)

    def append_happy():
        before = Path(state["permanent"]["path"]).read_text(encoding="utf-8")
        result = accepted(
            lambda: geo_write.append_block(
                "geo-agent", state["permanent"]["id"], ["linha nova", "outra linha"]
            )
        )
        after = Path(result["path"]).read_text(encoding="utf-8")
        truth("linha nova\noutra linha" in after, "append ausente")
        truth(after != before, "arquivo não mudou")

    check("append_block por id", append_happy)

    def append_user_rejected():
        path = geo_write.BLOCKS_DIR / "Manual.md"
        path.write_text("---\nid: MANUAL\nlayer: user\ntype: fleeting\n---\n# Manual\n", encoding="utf-8")
        rejected(lambda: geo_write.append_block("geo-agent", "MANUAL", "não pode"), "layer user")

    check("append_block recusa user", append_user_rejected)

    def duplicate_block_title():
        first = accepted(
            lambda: geo_write.write_block(
                "context-scraping", "Título Único", "um corpo completamente singular agora", layer="review"
            )
        )
        message = rejected(
            lambda: geo_write.write_block(
                "geo-agent", "titulo unico", "outro corpo bem diferente aqui", layer="agent"
            ),
            first["id"],
        )
        truth(first["path"] in message, "path existente ausente no erro")

    check("dedup de título de bloco retorna id e path", duplicate_block_title)

    check(
        "task sem due rejeitada",
        lambda: rejected(
            lambda: geo_write.write_task("context-scraping", "Sem prazo"),
            "due é obrigatório",
        ),
    )

    def task_happy_and_dup():
        state["task"] = accepted(
            lambda: geo_write.write_task(
                "context-scraping", "Entregar Relatório", due="2026-08-10"
            )
        )
        equal(state["task"]["created_by"], "context-scraping")
        rejected(
            lambda: geo_write.write_task(
                "ios-bridge", "entregar relatório", due="2026-08-11"
            ),
            state["task"]["id"],
        )

    check("task happy path e dedup normalizado", task_happy_and_dup)

    check(
        "force_new não geo-agent rejeitado",
        lambda: rejected(
            lambda: geo_write.write_task(
                "sweep", "Forçada", due="2026-09-01", force_new=True
            ),
            "force_new",
        ),
    )
    check(
        "force_new geo-agent aceito",
        lambda: accepted(
            lambda: geo_write.write_task(
                "geo-agent",
                "Entregar Relatório",
                due="2026-08-12",
                force_new=True,
            )
        ),
    )

    def event_happy():
        state["event"] = accepted(
            lambda: geo_write.write_task(
                "ios-bridge",
                "Consulta",
                kind="event",
                start="2026-08-01T10:00:00-03:00",
                end="2026-08-01T11:00:00-03:00",
            )
        )
        equal(state["event"]["body"]["kind"], "event")

    check("event com start e end", event_happy)

    check(
        "habit sem regra rejeitado",
        lambda: rejected(
            lambda: geo_write.write_task(
                "sweep", "Alongar", kind="habit", time_of_day="09:00"
            ),
            "rule e time_of_day",
        ),
    )

    def habit_happy():
        state["habit"] = accepted(
            lambda: geo_write.write_task(
                "sweep",
                "Alongar",
                kind="habit",
                rule={"type": "daily"},
                time_of_day="09:00",
            )
        )
        equal(state["habit"]["body"]["occurrences"], [])

    check("habit válido começa sem occurrences", habit_happy)

    check(
        "complete habit rejeitado",
        lambda: rejected(
            lambda: geo_write.update_task("geo-agent", state["habit"]["id"], "complete"),
            "nunca são concluídos",
        ),
    )
    check(
        "milestone por não geo-agent rejeitado",
        lambda: rejected(
            lambda: geo_write.write_task(
                "ios-bridge", "Marco", kind="milestone", target="2026-12-01"
            ),
            "só pode ser criado por geo-agent",
        ),
    )

    def milestone_happy():
        state["milestone"] = accepted(
            lambda: geo_write.write_task(
                "geo-agent", "Marco principal", kind="milestone", target="2026-12-01"
            )
        )
        equal(state["milestone"]["body"]["kind"], "milestone")

    check("milestone geo-agent aceito", milestone_happy)

    def occurrence_dedup():
        accepted(
            lambda: geo_write.add_occurrence(
                "ios-bridge", state["habit"]["id"], "2026-07-20T12:00:00Z"
            )
        )
        updated = accepted(
            lambda: geo_write.add_occurrence(
                "ios-bridge", state["habit"]["id"], "2026-07-20T18:00:00Z"
            )
        )
        equal(len(updated["body"]["occurrences"]), 1)

    check("occurrence dedup por dia local", occurrence_dedup)

    def complete_task():
        updated = accepted(
            lambda: geo_write.update_task("ios-bridge", state["task"]["id"], "complete")
        )
        equal(updated["status"], "completed")
        truth(updated.get("modifiedAt"), "modifiedAt ausente")

    check("update_task complete", complete_task)

    def delete_task():
        task = accepted(
            lambda: geo_write.write_task("ios-bridge", "Apagar", due="2026-08-05")
        )
        accepted(lambda: geo_write.update_task("ios-bridge", task["id"], "delete"))
        truth(not task_file(task["id"]).exists(), "task não removida")

    check("update_task delete", delete_task)

    def expire_task():
        task = accepted(
            lambda: geo_write.write_task("sweep", "Expirar", due="2026-01-01")
        )
        result = accepted(lambda: geo_write.update_task("sweep", task["id"], "expire"))
        archived = Path(result["path"])
        truth(archived.is_file(), "arquivo não movido")
        equal(json.loads(archived.read_text(encoding="utf-8"))["status"], "expired")
        equal(archived.parent.parent.name, ".archive")

    check("update_task expire arquiva com status", expire_task)

    def ledger_audits_all():
        rows = [
            json.loads(line)
            for line in (geo_write.INDEX_DIR / "ledger.jsonl").read_text(encoding="utf-8").splitlines()
        ]
        equal(len(rows), attempts)
        truth(any(row["result"] != "ok" for row in rows), "rejeições não auditadas")
        required = {"ts", "writer", "op", "entity", "id", "title_norm", "simhash", "result"}
        truth(all(set(row) == required for row in rows), "schema do ledger divergente")

    check("ledger registra aceites e rejeições", ledger_audits_all)

    simhash_vault = Path(temp) / "SimhashVault"
    geo_write.VAULT_DIR = simhash_vault
    geo_write.BLOCKS_DIR = simhash_vault / "Blocks"
    geo_write.TASKS_DIR = simhash_vault / "Tasks"
    geo_write.INDEX_DIR = simhash_vault / "Index"
    appended_words = CALIBRATION_WORDS + ["viagem", "violão", "xadrez", "zoológico"]

    def latest_ok_row(block_id):
        rows = [
            json.loads(line)
            for line in (geo_write.INDEX_DIR / "ledger.jsonl").read_text(
                encoding="utf-8"
            ).splitlines()
        ]
        return [
            row
            for row in rows
            if row["id"] == block_id
            and row["result"] == "ok"
            and row["op"] in {"write_block", "append_block"}
        ][-1]

    def disk_hash(path):
        body = geo_write._read_block(Path(path))[2]
        return geo_write._simhash(geo_write._block_content(body))

    def simhash_ledger_fallback_identity():
        state["simhash_base"] = accepted(
            lambda: geo_write.write_block(
                "geo-agent", "Fonte principal", " ".join(CALIBRATION_WORDS), layer="agent"
            )
        )
        block_id = state["simhash_base"]["id"]
        write_row = latest_ok_row(block_id)
        equal(write_row["op"], "write_block")
        equal(write_row["simhash"], disk_hash(state["simhash_base"]["path"]))
        accepted(
            lambda: geo_write.append_block(
                "geo-agent",
                block_id,
                "viagem violão xadrez zoológico",
            )
        )
        append_row = latest_ok_row(block_id)
        equal(append_row["op"], "append_block")
        equal(append_row["simhash"], disk_hash(state["simhash_base"]["path"]))
        equal(geo_write._simhash_corpus("fleeting"), [(append_row["simhash"], block_id)])

    check("simhash ledger e fallback bit-idênticos após write e append",
          simhash_ledger_fallback_identity)

    def simhash_realistic_near_duplicates():
        near_one = list(appended_words)
        near_one[31] = "girassol"
        near_two = list(appended_words)
        near_two[17] = "horizonte"
        near_two[68] = "saudade"
        rejected(
            lambda: geo_write.write_block(
                "geo-agent", "Título divergente um", " ".join(near_one), layer="agent"
            ),
            "simhash_dup",
        )
        rejected(
            lambda: geo_write.write_block(
                "geo-agent", "Título divergente dois", " ".join(near_two), layer="agent"
            ),
            "simhash_dup",
        )

    check("simhash captura alterações de uma e duas palavras com títulos distintos",
          simhash_realistic_near_duplicates)

    def simhash_unrelated_passes():
        result = accepted(
            lambda: geo_write.write_block(
                "geo-agent",
                "Corpo independente",
                " ".join(VALIDATION_WORDS),
                layer="agent",
            )
        )
        truth(Path(result["path"]).is_file(), "texto genuíno não foi aceito")

    check("simhash aceita corpo realista genuinamente diferente", simhash_unrelated_passes)

    def simhash_append_determinism():
        candidate = list(appended_words)
        candidate[23] = "neblina"
        candidate[72] = "ternura"
        ledger_verdict = rejected(
            lambda: geo_write.write_block(
                "geo-agent",
                "Veredito estável",
                " ".join(candidate),
                layer="agent",
            ),
            "simhash_dup",
        )
        (geo_write.INDEX_DIR / "ledger.jsonl").unlink()
        fallback_verdict = rejected(
            lambda: geo_write.write_block(
                "geo-agent",
                "Veredito estável",
                " ".join(candidate),
                layer="agent",
            ),
            "simhash_dup",
        )
        equal(ledger_verdict, fallback_verdict)

    check("simhash mantém veredito após append com ledger presente ou removido",
          simhash_append_determinism)

if failures:
    print(f"\n{len(failures)} FAIL")
    raise SystemExit(1)

print("\nALL PASS")
