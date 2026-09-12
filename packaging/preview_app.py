"""Запуск локальной сборки с отдельными демонстрационными данными."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def main():
    project = Path(__file__).resolve().parent.parent
    executable = project / "packaging/dist.noindex/Славатор.app/Contents/MacOS/slavator"
    if not executable.is_file():
        raise SystemExit("Сначала соберите приложение: bash packaging/build_app.sh")
    preview = Path(tempfile.mkdtemp(prefix="slavator-preview-"))
    results = preview / "Записи"
    profiles = preview / "speaker_profiles"
    results.mkdir()
    profiles.mkdir()
    write_json(preview / "settings.json", {
        "theme": "dark", "results_dir": str(results), "dictation_enabled": False,
        "widget_enabled": False, "my_name": "Вы",
    })
    write_json(profiles / "profiles.json", {
        "anna": {"name": "Анна", "position": "Дизайнер", "company": "Демо-команда", "samples": 0},
        "max": {"name": "Максим", "position": "Разработчик", "company": "Демо-команда", "samples": 0},
    })
    for title, offset in (("Демо · Обсуждение нового интерфейса", 0), ("Демо · Планирование недели", 1)):
        record = results / (title + "_result")
        extra = record / "доп файлы, на случай ошибки summary"
        write_json(record / "transcript.json", {"source": "", "segments": []})
        write_json(extra / "diarization.json", [
            {"start": i * 30, "end": i * 30 + 26, "speaker": "SPEAKER_0" + str((i + offset) % 2)}
            for i in range(20)
        ])
        write_json(extra / "speaker_names.json", {"SPEAKER_00": "Анна", "SPEAKER_01": "Максим"})
    (preview / "glossary.txt").write_text("# Демонстрационный словарь\nСлаватор\n", encoding="utf-8")

    # Переиспользуем только Python-библиотеки, данные и настройки изолированы.
    installed_env = Path.home() / "Library/Application Support/Славатор/env"
    if installed_env.is_dir():
        (preview / "env").symlink_to(installed_env, target_is_directory=True)
    env = {**os.environ, "SLAVATOR_PREVIEW": "1", "MEETING_TRANSCRIBER_APP_SUPPORT": str(preview),
           "MEETING_TRANSCRIBER_PROFILES": str(profiles), "MEETING_TRANSCRIBER_GLOSSARY": str(preview / "glossary.txt")}
    print("Демонстрационные данные и результаты: " + str(preview), flush=True)
    return subprocess.call([str(executable)], env=env)


if __name__ == "__main__":
    sys.exit(main())
