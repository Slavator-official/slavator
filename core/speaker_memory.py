"""Local meeting memory shared by macOS and Windows.

SQLite is a disposable index, never the source of truth. Quotes always come
from transcript.json; embeddings rank quotes, they never generate testimony.
Run with --root PATH --profiles PATH; send one JSON request on stdin. stdout
is NDJSON (progress events followed by one result/error). No third-party deps.
"""
from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import math
import re
import sqlite3
import struct
import sys
import urllib.request
from datetime import datetime
from pathlib import Path

from app_config import support_dir
from speaker_links import EXTRA, link_voice
from meeting_store import active_results, list_deleted, trash_meeting, restore_meeting

MODEL = "embeddinggemma:300m"
HOST = "http://127.0.0.1:11434"  # Intentionally independent of remote chat settings.
INDEX_VERSION = "4-current-meetings-meaningful-fragments"
STOP_WORDS = set("кто что когда где как о об обо и или а но в на с со по за из до от к у это эти этот через для было были говорил говорили сказал сказала про the a an is are to of in on about who what".split())
FRAGMENT_FILLERS = set((
    "как и а но ну вот то это же бы ли в на с со по за из до от к у о об "
    "э ээ эм мм все всё там тут здесь так такой такая такое такие этот эта эти "
    "он она оно они мы вы ты я мне нам вам нас вас его ее их себе свой своя "
    "буду будет будем будете будут был была было были быть есть значит типа "
    "the a an of to"
).split())


def normalize(text):
    return " ".join(re.findall(r"[^\W_]+", text.casefold().replace("ё", "е"), re.UNICODE))


def meaningful_fragment(text):
    tokens = normalize(text).split()
    # Keep short meaningful replies ('да', 'нет'), numbers and acronyms.
    # Suppress only standalone filler fragments, never delete source/context.
    return bool(tokens) and not (len(tokens) <= 3 and all(t in FRAGMENT_FILLERS for t in tokens))


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def read(path, default):
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8-sig"))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError("Перенаправление локальной модели запрещено")


class Embedder:
    def request(self, endpoint, body=None, timeout=60):
        request = urllib.request.Request(HOST + endpoint,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Content-Type": "application/json"})
        # No environment proxy may receive the contents of private meetings.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        with opener.open(request, timeout=timeout) as response:
            return json.load(response)

    def version(self):
        models = self.request("/api/tags", timeout=4).get("models", [])
        model = next((m for m in models if m.get("name") in (MODEL, "embeddinggemma:latest")), None)
        if not model:
            raise ValueError("Модель не установлена. Выполните ollama pull embeddinggemma:300m")
        self.model = model["name"]
        return MODEL + ":" + model["digest"]

    def embed(self, texts, query=False):
        prefix = "task: search result | query: " if query else "title: meeting | text: "
        raw = self.request("/api/embed", {"model": self.model,
            "input": [prefix + t for t in texts], "truncate": False,
            "keep_alive": "5m"}).get("embeddings", [])
        if len(raw) != len(texts):
            raise ValueError("Модель вернула неполный ответ")
        vectors = []
        for vector in raw:
            if not vector or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in vector):
                raise ValueError("Некорректный вектор модели")
            norm = math.sqrt(sum(v * v for v in vector))
            if not norm:
                raise ValueError("Пустой вектор модели")
            vectors.append([v / norm for v in vector])
        if len({len(v) for v in vectors}) != 1:
            raise ValueError("Размерности векторов не совпадают")
        return vectors


class Memory:
    def __init__(self, root, profiles, db=None):
        self.root = Path(root).expanduser().resolve()
        self.profiles = Path(profiles).expanduser().resolve()
        path = Path(db) if db else support_dir() / "memory" / (digest(str(self.root))[:24] + ".sqlite3")
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if not path.exists():
            path.touch(mode=0o600)
        self.db = sqlite3.connect(path, timeout=10)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS meetings (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, date TEXT NOT NULL,
                source TEXT NOT NULL, fingerprint TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS quotes (
                id TEXT PRIMARY KEY, meeting TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                seq INTEGER NOT NULL, start REAL NOT NULL, end REAL NOT NULL,
                voice TEXT NOT NULL, person TEXT NOT NULL, name TEXT NOT NULL,
                identity TEXT NOT NULL, text TEXT NOT NULL, hash TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS quotes_person ON quotes(person,meeting);
            CREATE INDEX IF NOT EXISTS quotes_meeting ON quotes(meeting,seq);
            CREATE VIRTUAL TABLE IF NOT EXISTS words USING fts5(text, tokenize='unicode61');
            CREATE TRIGGER IF NOT EXISTS quotes_delete AFTER DELETE ON quotes BEGIN
                DELETE FROM words WHERE rowid=old.rowid;
            END;
            CREATE TABLE IF NOT EXISTS vectors (
                hash TEXT NOT NULL, model TEXT NOT NULL, data BLOB NOT NULL,
                PRIMARY KEY(hash,model));
        """)
        if "searchable" not in {r[1] for r in self.db.execute("PRAGMA table_info(quotes)")}:
            self.db.execute("ALTER TABLE quotes ADD COLUMN searchable INTEGER NOT NULL DEFAULT 1")
            self.db.commit()

    def close(self):
        self.db.close()

    def sync(self, progress=lambda _: None):
        # Unreadable/missing roots must NOT erase a good existing index.
        folders = active_results(self.root)
        profiles = read(self.profiles / "profiles.json", {})
        assignments = read(self.profiles / "voice_assignments.json", {})
        if not isinstance(profiles, dict) or not isinstance(assignments, dict):
            raise ValueError("Повреждён файл профилей")
        profile_stamp = json.dumps([profiles, assignments], sort_keys=True, ensure_ascii=False)
        seen, warnings = set(), []
        for i, folder in enumerate(folders):
            mid = str(folder.resolve())
            transcript = folder / "transcript.json"
            if not transcript.exists():
                continue
            seen.add(mid)
            try:
                paths = [transcript] + [folder / EXTRA / f for f in
                    ("speaker_names.json", "speaker_recognition.json", "speaker_links.json")]
                stamp = digest(INDEX_VERSION + profile_stamp + repr([(str(p), p.stat().st_mtime_ns, p.stat().st_size)
                    for p in paths if p.exists()]))
                old = self.db.execute("SELECT fingerprint FROM meetings WHERE id=?", (mid,)).fetchone()
                if old and old[0] == stamp:
                    continue
                data = read(transcript, {})
                # Стенограмма прежних версий — просто массив реплик, без
                # обёртки с источником и датой. Такие встречи лежат у людей на
                # диске годами, и память обязана их читать: без этого одна
                # старая папка роняла разбор всех остальных.
                meta = data if isinstance(data, dict) else {}
                utterances = meta.get("utterances") if meta else data
                if not isinstance(utterances, list):
                    raise ValueError("нет массива utterances")
                names = read(paths[1], {})
                recognition = read(paths[2], [])
                links = read(paths[3], {})
                if not isinstance(names, dict) or not isinstance(recognition, list) or not isinstance(links, dict):
                    raise ValueError("некорректные данные голосов")
                recognized = {m["speaker_id"]: m.get("profile_key", "") for m in recognition
                    if isinstance(m, dict) and "speaker_id" in m}
                # Import explicit assignments from the Windows speaker service.
                for aid, key in assignments.items():
                    if aid.startswith(folder.name + ":"):
                        voice = Path(aid.split(":", 1)[1]).stem.split(" — ", 1)[0]
                        links.setdefault(voice, key)
                title = Path(str(meta.get("source") or folder.name.removesuffix("_result"))).stem
                date = str(meta.get("created_at") or datetime.fromtimestamp(transcript.stat().st_mtime).isoformat())
                source = str(meta.get("source_path") or "")
                rows = []
                for seq, item in enumerate(utterances):
                    if not isinstance(item, dict) or not isinstance(item.get("text"), str):
                        raise ValueError("некорректная реплика")
                    text = item["text"].strip()
                    if not text:
                        continue
                    start, end = float(item["start"]), float(item["end"])
                    if not math.isfinite(start + end) or start < 0 or end < start:
                        raise ValueError("некорректное время реплики")
                    voice = str(item.get("speaker_id") or "UNKNOWN")
                    key = links.get(voice) or recognized.get(voice)
                    if key and key in profiles:
                        person, name = "profile:" + key, str(profiles[key].get("name") or key)
                        identity = "manual" if voice in links else "voice"
                    else:
                        # A name inferred by an LLM is NOT a global identity.
                        person = "local:" + digest(mid + "\0" + voice)
                        name = str(names.get(voice) or item.get("speaker_name")
                                   or item.get("speaker") or voice)
                        identity = "unconfirmed"
                    # Split large utterances at whitespace, without dropping text.
                    parts = re.findall(r".{1,900}(?:\s+|$)|\S{1,900}", text, re.DOTALL)
                    for part, quote in enumerate(parts):
                        quote = quote.strip()
                        if not quote:
                            continue
                        uid = digest(mid + f":{seq}:{part}")
                        # Whisper segments are often half-sentences. Join only
                        # adjacent speech of the SAME local voice, at most 60s.
                        previous = rows[-1] if rows else None
                        if (previous and previous[5] == voice and 0 <= start-previous[4] <= 5
                                and end-previous[3] <= 60 and len(previous[9])+len(quote) < 900):
                            joined = previous[9] + " " + quote
                            rows[-1] = (*previous[:4],end,*previous[5:9],joined,digest(joined))
                        else:
                            rows.append((uid, mid, seq * 10000 + part, start, end, voice,
                                person, name, identity, quote, digest(quote)))
                with self.db:
                    self.db.execute("DELETE FROM meetings WHERE id=?", (mid,))
                    self.db.execute("INSERT INTO meetings VALUES(?,?,?,?,?)", (mid,title,date,source,stamp))
                    for row in rows:
                        searchable = int(meaningful_fragment(row[9]))
                        cur = self.db.execute("INSERT INTO quotes VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", (*row, searchable))
                        if searchable:
                            self.db.execute("INSERT INTO words(rowid,text) VALUES(?,?)", (cur.lastrowid, normalize(row[9])))
            except (ValueError, TypeError, KeyError, OSError, AttributeError) as error:
                # Preserve the last complete version while a writer is saving.
                warnings.append(f"{folder.name}: {error}")
            progress(f"Читаю встречи: {i + 1}/{len(folders)}")
        with self.db:
            for row in self.db.execute("SELECT id FROM meetings").fetchall():
                if row[0] not in seen:
                    self.db.execute("DELETE FROM meetings WHERE id=?", (row[0],))
            self.db.execute("DELETE FROM vectors WHERE hash NOT IN (SELECT hash FROM quotes WHERE searchable=1)")
        return warnings

    def build_vectors(self, embedder, progress=lambda _: None):
        model = embedder.version()
        pending = self.db.execute("""SELECT q.hash, MIN(q.text) text FROM quotes q
            LEFT JOIN vectors v ON v.hash=q.hash AND v.model=? WHERE v.hash IS NULL AND q.searchable=1 GROUP BY q.hash""", (model,)).fetchall()
        for offset in range(0, len(pending), 12):
            batch = pending[offset:offset+12]
            vectors = embedder.embed([r["text"] for r in batch])
            if len(vectors) != len(batch):
                raise ValueError("Неполный ответ модели")
            with self.db:
                self.db.executemany("INSERT OR REPLACE INTO vectors VALUES(?,?,?)", [
                    (r["hash"], model, struct.pack("<%sf" % len(v), *v)) for r, v in zip(batch, vectors)])
            progress(f"Память по смыслу: {min(offset + 12, len(pending))}/{len(pending)} новых фрагментов")
        with self.db:
            self.db.execute("DELETE FROM vectors WHERE model!=?", (model,))
        return model

    def overview(self, build_graph=True):
        # Название встречи нужно неподтверждённым голосам: они живут внутри
        # одной встречи, и без него список превращается в десяток одинаковых
        # строк «UNKNOWN», между которыми нельзя выбрать.
        people = [dict(r) for r in self.db.execute("""SELECT person id, name,
            COUNT(DISTINCT meeting) meetings, COUNT(*) quotes, MAX(m.date) last_seen,
            MIN(identity) identity, MIN(m.title) title FROM quotes q JOIN meetings m ON m.id=q.meeting
            WHERE q.searchable=1 AND (q.voice NOT LIKE 'UNASSIGNED_%' OR q.identity='manual')
            GROUP BY person ORDER BY (person LIKE 'profile:%') DESC,meetings DESC,name,person""")]
        meetings = [dict(r) for r in self.db.execute("SELECT id,title,date FROM meetings ORDER BY date DESC,id")]
        edges = {}
        for meeting in meetings if build_graph else []:
            ids = [r[0] for r in self.db.execute("SELECT DISTINCT person FROM quotes WHERE meeting=? AND searchable=1 AND (voice NOT LIKE 'UNASSIGNED_%' OR identity='manual') ORDER BY person", (meeting["id"],))]
            for a, b in itertools.combinations(ids, 2):
                edges.setdefault((a,b), []).append(meeting["id"])
        return {"people": people, "meetings": meetings,
            "quotes": self.db.execute("SELECT COUNT(*) FROM quotes WHERE searchable=1").fetchone()[0],
            "hidden_fragments": self.db.execute("SELECT COUNT(*) FROM quotes WHERE searchable=0").fetchone()[0],
            "edges": [{"a": a, "b": b, "meetings": mids} for (a,b), mids in sorted(edges.items())]}

    def search(self, query="", mode="phrase", person="", meeting="", offset=0, limit=30, embedder=None):
        offset, limit = max(0, int(offset)), max(1, min(100, int(limit)))
        query = query.strip()[:1000]
        where, params = ["q.searchable=1"], []
        for column, value in (("q.person", person), ("q.meeting", meeting)):
            if value:
                where.append(column + "=?")
                params.append(value)
        clause = " AND ".join(where)
        base = """SELECT q.*,m.title,m.date,m.source FROM quotes q JOIN meetings m ON m.id=q.meeting """
        notice, ranked, ready, total_vectors = "", [], 0, 0
        semantic_ready = False
        if query and mode == "semantic":
            if embedder is None:
                embedder = Embedder()
            try:
                model = embedder.version()
                vector = embedder.embed([query], query=True)[0]
                cursor = self.db.execute(base.replace("q.*,", "v.data vector,q.*,") + "JOIN vectors v ON q.hash=v.hash AND v.model=? WHERE " + clause,
                    [model] + params)
                # Stream BLOBs, avoiding a full NxD Python-float matrix in RAM.
                for row in cursor:
                    blob = row["vector"]
                    v = struct.unpack("<%sf" % (len(blob)//4), blob)
                    if len(v) != len(vector):
                        raise ValueError("Модель изменила размер векторов. Обновите индекс")
                    ready += 1
                    score = sum(a*b for a,b in zip(v,vector))
                    if score >= 0.23:
                        item = dict(row)
                        del item["vector"]
                        ranked.append((score, item))
                total_vectors = self.db.execute("SELECT count(*) FROM quotes q WHERE " + clause, params).fetchone()[0]
                semantic_ready = ready > 0
                if ready < total_vectors:
                    notice = f"По смыслу готовы {ready} из {total_vectors} фрагментов. Нажмите «Обновить память»."
            except Exception:
                notice = "Поиск по смыслу недоступен. Запустите Ollama, установите embeddinggemma:300m и обновите память. Показаны только совпадения слов."
        tokens = normalize(query).split()
        if mode == "semantic":
            tokens = [t for t in tokens if t not in STOP_WORDS and len(t) > 1]
        if query and tokens:
            expression = '"' + ' '.join(tokens) + '"' if mode == "phrase" else ' OR '.join('"' + t + '"*' for t in tokens)
            matches = self.db.execute(base + "JOIN words ON words.rowid=q.rowid WHERE words MATCH ? AND " + clause + " ORDER BY bm25(words),m.date DESC,q.seq", [expression] + params).fetchall()
            existing = {r[1]["id"]:i for i,r in enumerate(ranked)}
            for rank, row in enumerate(matches):
                if row["id"] in existing:
                    index = existing[row["id"]]
                    score, hit = ranked[index]
                    ranked[index] = (score + 0.05/(rank+1), hit)
                elif not semantic_ready or mode == "phrase":
                    ranked.append((1.0 / (rank + 1), dict(row)))
        elif not query:
            count = self.db.execute("SELECT count(*) FROM quotes q WHERE " + clause,params).fetchone()[0]
            rows = [dict(r) for r in self.db.execute(base + "WHERE " + clause + " ORDER BY m.date DESC,q.seq,q.id LIMIT ? OFFSET ?",params+[limit,offset])]
            return {"hits": rows,"total":count,"notice":""}
        ranked.sort(key=lambda r: (-r[0],r[1]["id"]))
        return {"hits":[r for _,r in ranked[offset:offset+limit]],"total":len(ranked),"notice":notice}

    def context(self, quote_id):
        row = self.db.execute("SELECT meeting,seq FROM quotes WHERE id=?",(quote_id,)).fetchone()
        if not row:
            raise ValueError("Реплика больше не существует; обновите память")
        before = self.db.execute("SELECT seq FROM quotes WHERE meeting=? AND seq<? ORDER BY seq DESC LIMIT 3", row).fetchall()
        after = self.db.execute("SELECT seq FROM quotes WHERE meeting=? AND seq>? ORDER BY seq LIMIT 3", row).fetchall()
        low = min([r[0] for r in before] + [row[1]])
        high = max([r[0] for r in after] + [row[1]])
        rows = self.db.execute("""SELECT q.*,m.title,m.date,m.source FROM quotes q
            JOIN meetings m ON m.id=q.meeting WHERE q.meeting=? AND q.seq BETWEEN ? AND ? ORDER BY q.seq""",
            (row[0],low,high)).fetchall()
        return [dict(r) for r in rows]


def emit(kind, **values):
    print(json.dumps({"event":kind,**values},ensure_ascii=False),flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--profiles", required=True)
    parser.add_argument("--db")
    args = parser.parse_args()
    memory = None
    try:
        request = json.loads(sys.stdin.readline())
        memory = Memory(args.root,args.profiles,args.db)
        action = request.get("action","search")
        progress = lambda message: emit("progress",message=message)
        warnings = memory.sync(progress)
        notice = ""
        if action == "delete_meeting":
            mid = str(Path(request["meeting"]).resolve())
            if not memory.db.execute("SELECT 1 FROM meetings WHERE id=?", (mid,)).fetchone():
                raise ValueError("Встреча больше не находится в текущем списке")
            deleted = trash_meeting(memory.root, request["meeting"])
            warnings = memory.sync(progress)
            notice = f"Встреча перемещена в корзину Славатора ({deleted['count']} версий). Исходная запись и голосовые профили сохранены."
        if action == "restore_meeting":
            restore_meeting(memory.root, request["token"])
            warnings = memory.sync(progress)
            notice = "Встреча восстановлена. Для смыслового поиска нажмите «Обновить память»."
        if action == "sync":
            try:
                memory.build_vectors(Embedder(),progress)
            except Exception:
                notice = "Текстовый индекс готов. Для поиска по смыслу запустите Ollama и установите embeddinggemma:300m; затем обновите память."
        if action == "link":
            mid = str(Path(request["meeting"]).resolve())
            if not memory.db.execute("SELECT 1 FROM quotes WHERE meeting=? AND voice=?",(mid,request["voice"])).fetchone():
                raise ValueError("Голос не найден в текущем индексе")
            if request["profile"] not in read(memory.profiles / "profiles.json",{}):
                raise ValueError("Профиль не найден")
            link_voice(Path(mid),request["voice"],request["profile"])
            warnings = memory.sync(progress)
        result = {"overview":memory.overview(build_graph=request.get("build_graph", True) is True),"warnings":warnings,"notice":notice,
                  "deleted":list_deleted(memory.root)}
        if action == "context":
            result["context"] = memory.context(request["id"])
        elif action == "search":
            result.update(memory.search(**{k:v for k,v in request.items() if k in
                ("query","mode","person","meeting","offset","limit")}))
        elif action not in ("sync","link","catalog","delete_meeting","restore_meeting"):
            raise ValueError("Неизвестное действие")
        emit("result",**result)
        return 0
    except Exception as error:
        emit("error",message=f"Память встреч: {type(error).__name__}: {error}")
        return 1
    finally:
        if memory is not None:
            memory.close()


if __name__ == "__main__":
    sys.exit(main())
