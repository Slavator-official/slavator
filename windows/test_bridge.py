"""Проверка моста между интерфейсом и ядром.

Окно здесь не поднимается: pywebview требует настоящего рабочего стола, а на
сборочной машине его нет. Зато проверяется всё, что окно спрашивает у питона, —
именно тут ломается чаще всего, и именно это нельзя проверить, просто
скомпилировав файл.

Запускается и на Windows, и на маке: пути к данным разведены по платформам.
"""
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

ЗДЕСЬ = Path(__file__).resolve().parent


def загрузить(tmp_path: Path):
    """Поднять slavator.py с подменённой папкой данных."""
    import os
    os.environ["MEETING_TRANSCRIBER_APP_SUPPORT"] = str(tmp_path)
    spec = importlib.util.spec_from_file_location("slavator", ЗДЕСЬ / "slavator.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["slavator"] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def мост(tmp_path):
    module = загрузить(tmp_path)
    return module.Bridge()


def test_настройки_по_умолчанию(мост):
    """Пустая машина не должна валить интерфейс отсутствием настроек."""
    значения = мост.settings()
    for ключ in ("theme", "results_dir", "my_name", "llm_model"):
        assert ключ in значения, f"нет настройки {ключ}"
    assert значения["theme"] in ("dark", "light")


def test_настройки_сохраняются(мост, tmp_path):
    мост.save_settings({"my_name": "Валерий"})
    assert мост.settings()["my_name"] == "Валерий"
    сохранённое = json.loads((tmp_path / "settings.json").read_text(encoding="utf-8"))
    assert сохранённое["my_name"] == "Валерий"


def test_окружение_отвечает_всегда(мост):
    """Даже когда ничего не установлено — интерфейс по этому решает, что рисовать."""
    данные = мост.environment()
    assert set(данные) >= {"ready", "core_exists", "ollama", "version"}
    assert isinstance(данные["ready"], bool)
    # Ядро лежит в репозитории рядом, поэтому обязано находиться.
    assert данные["core_exists"], "ядро не найдено — сломан путь до core/"


def test_записи_на_пустой_папке(мост, tmp_path):
    мост.save_settings({"results_dir": str(tmp_path / "нет-такой")})
    assert мост.records() == []


def test_записи_разбирают_результат(мост, tmp_path):
    """Папка _result без стенограммы игнорируется, со стенограммой — читается."""
    выход = tmp_path / "выход"
    пустая = выход / "мусор_result"
    пустая.mkdir(parents=True)
    готовая = выход / "Встреча_result"
    (готовая / "доп файлы, на случай ошибки summary").mkdir(parents=True)
    (готовая / "transcript.json").write_text(json.dumps({
        "duration": 61.0,
        "utterances": [{"start": 0.0, "end": 3.0, "speaker_id": "SPEAKER_00"}],
    }, ensure_ascii=False), encoding="utf-8")
    (готовая / "доп файлы, на случай ошибки summary" / "diarization.json").write_text(
        json.dumps([{"start": 0.0, "end": 3.0, "speaker": "SPEAKER_00"},
                    {"start": 4.0, "end": 9.0, "speaker": "SPEAKER_01"}]),
        encoding="utf-8")
    (готовая / "доп файлы, на случай ошибки summary" / "speaker_names.json").write_text(
        json.dumps({"SPEAKER_01": "Валерий"}, ensure_ascii=False), encoding="utf-8")

    мост.save_settings({"results_dir": str(выход)})
    записи = мост.records()
    assert len(записи) == 1, "папка без стенограммы не должна попадать в список"
    запись = записи[0]
    assert запись["title"] == "Встреча"
    assert len(запись["turns"]) == 2
    assert запись["turns"][1]["name"] == "Валерий"
    assert запись["summary"] == "", "резюме нет — путь обязан быть пустым"


def test_переписки_заводятся_и_удаляются(мост):
    первая = мост.chat_new()
    assert первая["id"]
    # Пустой черновик не плодим: вторая «новая» — это та же самая.
    assert мост.chat_new()["id"] == первая["id"]
    assert len(мост.chats()) == 1
    assert мост.chat_delete(первая["id"]) == []


def test_пустой_вопрос_не_ломает(мост):
    assert мост.ask(мост.chat_new()["id"], "   ")["ok"] is False


def test_обработка_несуществующего_файла(мост):
    ответ = мост.transcribe(str(ЗДЕСЬ / "нет-такого.mp4"))
    assert ответ["ok"] is False
    assert "не найден" in ответ["error"].lower()


def test_ход_обработки_отвечает_до_запуска(мост):
    """Интерфейс опрашивает это с первой секунды, ещё до любой обработки."""
    ход = мост.progress()
    assert ход["busy"] is False
    assert set(ход) >= {"busy", "stage", "percent", "detail", "error", "log"}


def test_сведения_о_файле(мост, tmp_path):
    файл = tmp_path / "проба.mp4"
    файл.write_bytes(b"0" * 2048)
    сведения = мост.file_info(str(файл))
    assert сведения["name"] == "проба.mp4"
    assert "МП4" not in сведения["size"]
    assert "КБ" in сведения["size"]


def test_интерфейс_на_месте():
    """Окно грузит этот файл; без него приложение не откроется."""
    страница = ЗДЕСЬ / "ui" / "index.html"
    assert страница.is_file(), "нет windows/ui/index.html"
    разметка = страница.read_text(encoding="utf-8")
    # Цвета обязаны совпадать с Theme.swift: приложение на двух платформах —
    # один продукт, а не два похожих.
    for цвет in ("#0A1420", "#2F6FF5", "#F2F6FC"):
        assert цвет in разметка, f"в интерфейсе потерян цвет {цвет}"
    assert "pywebviewready" in разметка, "интерфейс не дождётся моста"
