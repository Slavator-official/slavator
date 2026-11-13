"""Завершение установки через ту же проверку и дозагрузку, что в приложении."""
import os
from pathlib import Path


def complete_setup(core, support: Path) -> int:
    marker = support / ".ready"
    marker.unlink(missing_ok=True)
    core.repair(allow_download=True)
    report = core.readiness()
    required = {"packages", "speech", "asr"}
    incomplete = [item for item in report["items"] if item["state"] != "ok"]
    if any(item["key"] in required for item in incomplete):
        print("\nУстановка не завершена: распознавание и модели голосов ещё не готовы.")
        for item in incomplete:
            print(f"  {item['title']}: {item['detail'] or item['state']}")
        return 2
    # Маркер разрешает обработку записей, а не обещает доступность Ollama.
    marker.write_text("speech-ready\n", encoding="utf-8")
    if incomplete:
        print("\nРасшифровка готова. Установка завершена с ограничениями:")
        for item in incomplete:
            print(f"  {item['title']}: {item['detail'] or item['state']}")
        print("Резюме и определение имён требуют Ollama и языковую модель.")
        print("Для завершения нажмите кнопку дозагрузки в Славаторе.")
        return 1
    print("\nГотово. Славатор установлен: распознавание, голоса и языковая модель проверены.")
    return 0


def main() -> int:
    import app_config
    # Настройки и каталоги совпадают с теми, что интерфейс передаёт ядру.
    os.environ.update(app_config.environment(app_config.load()))
    import meeting_transcriber_v25_1 as core
    return complete_setup(core, app_config.support_dir())


if __name__ == "__main__":
    try:
        status = main()
    except Exception as error:
        print(f"\nУстановка не завершена: {type(error).__name__}: {error}")
        status = 2
    raise SystemExit(status)
