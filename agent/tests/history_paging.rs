use remote_ai_agent::adapters::{DEFAULT_HISTORY_TURNS, history_turn_page};

#[test]
fn the_first_page_is_the_newest_turns() {
    let (range, cursor) = history_turn_page(7, None, 3).unwrap();
    assert_eq!(range, 4..7, "the phone opens on the newest turns");
    assert_eq!(cursor.as_deref(), Some("4"), "four older turns remain");
}

#[test]
fn each_cursor_walks_one_page_further_back() {
    let (first_range, first) = history_turn_page(7, None, 3).unwrap();
    let (second_range, second) = history_turn_page(7, first.as_deref(), 3).unwrap();
    let (third_range, third) = history_turn_page(7, second.as_deref(), 3).unwrap();

    assert_eq!(first_range, 4..7);
    assert_eq!(second_range, 1..4);
    assert_eq!(third_range, 0..1);
    assert_eq!(third, None, "the oldest page ends the walk");
}

#[test]
fn a_cursor_stays_valid_when_newer_turns_are_appended() {
    // The phone paged back to turn 4 while the conversation was seven turns
    // long, then two more turns arrived live. A cursor counted from the newest
    // end would now point somewhere else and repeat turns already shown.
    let (_, cursor) = history_turn_page(7, None, 3).unwrap();
    let (range, _) = history_turn_page(9, cursor.as_deref(), 3).unwrap();
    assert_eq!(
        range,
        1..4,
        "the page before turn 4 is unchanged by appends"
    );
}

#[test]
fn a_conversation_shorter_than_one_page_is_a_single_page() {
    let (range, cursor) = history_turn_page(2, None, DEFAULT_HISTORY_TURNS).unwrap();
    assert_eq!(range, 0..2);
    assert_eq!(cursor, None);
}

#[test]
fn an_empty_conversation_has_an_empty_page_and_no_cursor() {
    let (range, cursor) = history_turn_page(0, None, DEFAULT_HISTORY_TURNS).unwrap();
    assert!(range.is_empty());
    assert_eq!(cursor, None);
}

#[test]
fn a_cursor_that_is_not_a_position_is_rejected() {
    history_turn_page(5, Some("banana"), 3).unwrap_err();
    history_turn_page(5, Some("9"), 3).unwrap_err();
}
