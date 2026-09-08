from meeting_transcriber_v25_1 import Utterance, assign_speakers


def turn(start,end,speaker):
    return dict(start=start,end=end,speaker=speaker)


def word(start,end,text):
    return dict(start=start,end=end,word=text)


def test_split_at_word_level_preserves_text_and_time():
    rows = [Utterance(0,4,"Я начну. Ты продолжай.",words=[
        word(0,1," Я"),word(1,2," начну."),word(2,3," Ты"),word(3,4," продолжай.")])]
    assign_speakers(rows,[turn(0,2,"A"),turn(2,4,"B")])
    assert [(r.speaker_id,r.text,r.start,r.end) for r in rows] == [("A","Я начну.",0,2),("B","Ты продолжай.",2,4)]


def test_no_distant_guess_or_forced_identity_without_diarization():
    rows = [Utterance(100,110,"далеко")]
    assign_speakers(rows,[turn(0,4,"A")])
    assert rows[0].speaker_id.startswith("UNASSIGNED_")
    assert rows[0].speaker_name == "Голос не определён"
    rows = [Utterance(0,1,"без диаризации")]
    assign_speakers(rows,[])
    assert rows[0].speaker_id.startswith("UNASSIGNED_")


def test_sum_disjoint_turns_per_voice_not_largest_individual_turn():
    rows = [Utterance(0,10,"фраза")]
    assign_speakers(rows,[turn(0,3,"A"),turn(7,10,"A"),turn(3,7,"B")])
    assert rows[0].speaker_id == "A"


def test_overlap_and_low_coverage_not_assigned():
    for turns in ([turn(0,10,"A"),turn(0,10,"B")],[turn(0,1,"A")]):
        rows = [Utterance(0,10,"неоднозначно")]
        assign_speakers(rows,turns)
        assert rows[0].speaker_id.startswith("UNASSIGNED_")


def test_duplicate_intervals_do_not_inflate_coverage():
    rows = [Utterance(0,10,"фраза")]
    assign_speakers(rows,[turn(0,3,"A")]*4+[turn(3,10,"B")])
    assert rows[0].speaker_id == "B"


def test_nested_long_interval_is_found_by_index():
    rows = [Utterance(95,99,"фраза")]
    assign_speakers(rows,[turn(0,100,"A"),turn(10,11,"B"),turn(20,21,"C")])
    assert rows[0].speaker_id == "A"


def test_corrected_text_preserved_if_speaker_did_not_change():
    rows = [Utterance(0,2,"CJM",words=[word(0,1," си"),word(1,2," джей эм")])]
    assign_speakers(rows,[turn(0,2,"A")])
    assert rows[0].text == "CJM"


def test_bad_word_metadata_falls_back_to_segment():
    rows = [Utterance(0,2,"фраза",words=[{"word":"bad"}])]
    assign_speakers(rows,[turn(0,2,"A")])
    assert rows[0].speaker_id == "A"
