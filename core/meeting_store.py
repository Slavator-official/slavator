"""Current meeting versions and a recoverable, application-owned recycle bin.

Only result folders immediately under the configured root may be moved.
Source recordings and global voice profiles are never deletion targets.
"""
from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import uuid

TRASH = ".slavator-trash"


def family_name(name):
    return re.sub(r"_\d{8}_\d{6}$", "", name.removesuffix("_result"))


def result_groups(root):
    root = Path(root).expanduser().resolve(strict=True)
    groups = {}
    for folder in root.iterdir():
        if (folder.name.endswith("_result") and not folder.is_symlink()
                and folder.is_dir() and (folder / "transcript.json").is_file()):
            groups.setdefault(family_name(folder.name), []).append(folder)
    for family, folders in groups.items():
        # The pipeline renames its previous result before writing the current
        # canonical folder. Editing an archived folder must not make it current.
        folders.sort(key=lambda p: (p.name == family + "_result", p.stat().st_mtime_ns, p.name), reverse=True)
    return groups


def active_results(root):
    return sorted(folders[0] for folders in result_groups(root).values())


def _bin(root):
    path = root / TRASH
    if path.is_symlink():
        raise ValueError("Корзина Славатора не должна быть символической ссылкой")
    path.mkdir(mode=0o700, exist_ok=True)
    return path


def _entry(root, token):
    if not re.fullmatch(r"[0-9a-f]{32}", token):
        raise ValueError("Некорректный идентификатор удаления")
    path = root / TRASH / token
    if (root / TRASH).is_symlink() or path.is_symlink() or not path.is_dir():
        raise ValueError("Запись корзины не найдена")
    return path


def _receipt(entry):
    path = entry / "receipt.json"
    if path.is_symlink():
        raise ValueError("Некорректная запись корзины")
    data = json.loads(path.read_text(encoding="utf-8"))
    names = data.get("folders")
    if (not isinstance(names, list) or not names or len(set(names)) != len(names)
            or not all(isinstance(n, str) and n.endswith("_result")
                       and n not in (".", "..") and "/" not in n and "\\" not in n for n in names)):
        raise ValueError("Повреждён список папок в корзине")
    return data


def list_deleted(root):
    root = Path(root).expanduser().resolve(strict=True)
    folder = root / TRASH
    if not folder.exists():
        return []
    if folder.is_symlink():
        raise ValueError("Корзина Славатора не должна быть символической ссылкой")
    items = []
    for path in folder.iterdir():
        try:
            entry = _entry(root, path.name)
            data = _receipt(entry)
            # A crash can leave a partial move. Retain and expose every moved
            # directory so it can be recovered; never remove it as 'cleanup'.
            present = [n for n in data["folders"] if (entry / n).is_dir() and not (entry / n).is_symlink()]
            if present:
                items.append(dict(id=entry.name, title=data.get("title", present[0]),
                                  date=data.get("date", ""), count=len(present)))
        except (ValueError, OSError, TypeError):
            continue  # Do not mutate an unrecognised entry; files remain on disk.
    return sorted(items, key=lambda x: (x["date"], x["id"]), reverse=True)


def trash_meeting(root, meeting):
    root = Path(root).expanduser().resolve(strict=True)
    target = Path(meeting).expanduser().absolute()
    if target.parent.resolve() != root or target.is_symlink():
        raise ValueError("Удалять можно только встречу из выбранной папки результатов")
    groups = result_groups(root)
    family = family_name(target.name)
    folders = groups.get(family, [])
    if not folders or target.resolve() not in folders:
        raise ValueError("Встреча не найдена; обновите список")
    entry = _bin(root) / uuid.uuid4().hex
    entry.mkdir(mode=0o700)
    receipt = dict(title=family, date=datetime.now(timezone.utc).isoformat(),
                   folders=[p.name for p in folders])
    # Persist the recovery manifest before moving anything.
    with (entry / "receipt.json").open("x", encoding="utf-8") as handle:
        json.dump(receipt, handle, ensure_ascii=False, indent=2)
        handle.flush()
        os.fsync(handle.fileno())
    moved = []
    try:
        for source in folders:
            if source.is_symlink():
                raise ValueError("Папка встречи изменилась; удаление остановлено")
            source.rename(entry / source.name)
            moved.append(source)
    except Exception:
        for source in reversed(moved):
            if not source.exists():
                (entry / source.name).rename(source)
        raise
    return dict(id=entry.name, title=family, count=len(moved), date=receipt["date"])


def restore_meeting(root, token):
    root = Path(root).expanduser().resolve(strict=True)
    entry = _entry(root, token)
    data = _receipt(entry)
    names = [n for n in data["folders"] if (entry / n).exists()]
    if not names:
        raise ValueError("Эта встреча уже восстановлена")
    for name in names:
        source = entry / name
        if source.is_symlink() or not source.is_dir():
            raise ValueError("Некорректная папка в корзине")
        if (root / name).exists() or (root / name).is_symlink():
            raise ValueError("На месте восстановления уже есть встреча. Ничего не перезаписано.")
    moved = []
    try:
        for name in names:
            (entry / name).rename(root / name)
            moved.append(name)
    except Exception:
        for name in reversed(moved):
            if not (entry / name).exists():
                (root / name).rename(entry / name)
        raise
    # Keep the tiny receipt as a recovery record; no recursive cleanup needed.
    return len(moved)
