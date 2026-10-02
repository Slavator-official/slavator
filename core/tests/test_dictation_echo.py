from dictation_worker import is_junk, strip_prompt_echo

GLOSSARY = ["CJM", "ЦОК", "МП Учителя", "бэклог", "спринт", "дейли", "ретро", "стейкхолдер"]


def test_echo_after_speech_is_cut():
    text = "Приоритизация. ЦОК, МП Учителя, бэклог, спринт, дейли, ретро, стейкхолдер."
    assert strip_prompt_echo(text, GLOSSARY) == "Приоритизация."


def test_echo_mid_phrase_is_cut():
    text = "Написал ком. МП Учителя, бэклог, спринт, дейли, ретро, стейкхолдер, привет"
    assert strip_prompt_echo(text, GLOSSARY) == "Написал ком. привет"


def test_terms_in_own_order_stay():
    text = "Обсудили ретро, бэклог, спринт и дейли."
    assert strip_prompt_echo(text, GLOSSARY) == text


def test_two_terms_in_order_stay():
    text = "Смотрим бэклог, спринт."
    assert strip_prompt_echo(text, GLOSSARY) == "Смотрим бэклог, спринт."


def test_prompt_head_is_junk():
    assert is_junk("Рабочая диктовка. В речи встречаются термины:")
