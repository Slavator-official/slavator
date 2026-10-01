import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from repeats import collapse_text, collapse_words


def test_phrase_loop_keeps_one_and_final_punctuation():
    assert collapse_text("и так далее, и так далее, и так далее.") == ("и так далее.", 6)


def test_word_loop_collapses():
    assert collapse_text("да да да да") == ("да", 3)
    assert collapse_text("Спасибо. Спасибо. Спасибо. Спасибо.") == ("Спасибо.", 3)


def test_loop_inside_sentence():
    text = "я думаю что я думаю что я думаю что надо перенести"
    assert collapse_text(text) == ("я думаю что надо перенести", 6)


def test_living_speech_untouched():
    for text in ("да да, конечно", "нет нет, подожди", "очень очень важно",
                 "Обсудили бэклог, спринт и ретро.", ""):
        assert collapse_text(text) == (text, 0)


def test_two_repeats_of_a_phrase_stay():
    text = "как сказать, как сказать, вот"
    assert collapse_text(text) == (text, 0)


def test_words_follow_text():
    words = [{"word": w, "start": i, "end": i + 0.5}
             for i, w in enumerate([" Я", " думаю,", " что", " ну", " ну", " ну", " ну", " да."])]
    kept, removed = collapse_words(words)
    assert removed == 3
    assert "".join(w["word"] for w in kept).strip() == "Я думаю, что ну да."
    # Метки времени остаются от первого вхождения и идут по порядку.
    assert [w["start"] for w in kept] == [0, 1, 2, 3, 7]


def test_words_without_loop_are_the_same_object():
    words = [{"word": " привет", "start": 0, "end": 1}]
    assert collapse_words(words) == (words, 0)


def test_quality_gate_collapses_loops_in_text_and_words():
    import meeting_transcriber_v25_1 as core
    words = [{"word": w, "start": i, "end": i + 0.5}
             for i, w in enumerate([" Перенесём", " созвон", " ну", " ну", " ну", " ну"])]
    looped = core.Utterance(0, 6, "Перенесём созвон ну ну ну ну", words=words)
    plain = core.Utterance(6, 9, "и так далее и так далее и так далее")
    other = core.Utterance(9, 12, "Договорились на пятницу.")
    kept, warnings = core.quality_gate([looped, plain, other], 12)
    assert [item.text for item in kept] == ["Перенесём созвон ну", "и так далее", "Договорились на пятницу."]
    assert len(kept[0].words) == 3
    assert any("зацикливаний" in line for line in warnings)
