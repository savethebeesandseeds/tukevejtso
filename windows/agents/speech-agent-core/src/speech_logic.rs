//! Platform-independent speech reconciliation and request scheduling policies.
use std::time::Instant;

pub(crate) const MIN_RESTART_PREFIX_WORDS: usize = 4;

/// Preserve the newest snapshot and pending actions within its generation.
pub(crate) fn coalesce_latest<T>(
    pending: &mut Option<T>,
    mut next: T,
    generation: impl Fn(&T) -> u64,
    merge_pending: impl Fn(&mut T, &T),
) {
    if let Some(previous) = pending.as_ref() {
        if generation(previous) > generation(&next) {
            return;
        }
        if generation(previous) == generation(&next) {
            merge_pending(&mut next, previous);
        }
    }
    *pending = Some(next);
}

pub(crate) fn should_decode_final(
    has_samples: bool,
    best_text_empty: bool,
    last_voice_at: Option<Instant>,
    last_decoded_voice_at: Option<Instant>,
) -> bool {
    has_samples
        && (best_text_empty
            || last_voice_at.is_some_and(|voice| {
                last_decoded_voice_at.map_or(true, |decoded| voice > decoded)
            }))
}

pub(crate) fn audio_frame_is_current(
    captured_at: Instant,
    refresh_cutoff: Option<Instant>,
) -> bool {
    refresh_cutoff.map_or(true, |cutoff| captured_at >= cutoff)
}

pub(crate) fn is_informative_delta(text: &str, has_context: bool) -> bool {
    is_informative_text(text)
        || (has_context
            && text.split_whitespace().map(compare_token).any(|word| {
                word.chars().any(|character| character.is_alphanumeric())
                    && !matches!(
                        word.as_str(),
                        "uh" | "um" | "er" | "erm" | "hm" | "hmm" | "ah" | "eh" | "mm"
                    )
            }))
}

pub(crate) fn is_informative_text(text: &str) -> bool {
    let alnum_count = text.chars().filter(|value| value.is_alphanumeric()).count();
    let word_count = text
        .split_whitespace()
        .filter(|word| word.chars().any(|value| value.is_alphanumeric()))
        .count();

    text.contains('?') || (alnum_count >= 8 && word_count >= 2)
}

pub(crate) fn new_text_since(previous: Option<&str>, current: &str, max_chars: usize) -> String {
    let current = current.trim();
    let Some(previous) = previous.map(str::trim).filter(|value| !value.is_empty()) else {
        return recent_chars(current, max_chars);
    };
    if current.is_empty() {
        return String::new();
    }
    if current == previous {
        return String::new();
    }
    if let Some(new_text) = current.strip_prefix(previous) {
        return recent_chars(new_text.trim(), max_chars);
    }

    let previous_words = comparable_word_spans(previous);
    let current_words = comparable_word_spans(current);
    if !previous_words.is_empty() && !current_words.is_empty() {
        let previous_cmp = previous_words
            .iter()
            .map(|word| word.0.clone())
            .collect::<Vec<_>>();
        let current_cmp = current_words
            .iter()
            .map(|word| word.0.clone())
            .collect::<Vec<_>>();
        if previous_cmp == current_cmp {
            return String::new();
        }

        let shared_words = shared_prefix_len(&previous_cmp, &current_cmp);
        if shared_words > 0 {
            return current_words
                .get(shared_words)
                .map(|word| recent_chars(current[word.1..].trim(), max_chars))
                .unwrap_or_default();
        }

        let max_overlap = previous_cmp.len().min(current_cmp.len());
        for overlap in (2..=max_overlap).rev() {
            if previous_cmp[previous_cmp.len() - overlap..] == current_cmp[..overlap] {
                return current_words
                    .get(overlap)
                    .map(|word| recent_chars(current[word.1..].trim(), max_chars))
                    .unwrap_or_default();
            }
        }
    }

    let shared_chars = shared_prefix_char_count(previous, current);
    let current_tail = current
        .char_indices()
        .nth(shared_chars)
        .map(|(index, _)| &current[index..])
        .unwrap_or("");
    if current_tail.trim().is_empty() {
        recent_chars(current, max_chars)
    } else {
        recent_chars(current_tail.trim(), max_chars)
    }
}

fn shared_prefix_char_count(left: &str, right: &str) -> usize {
    left.chars()
        .zip(right.chars())
        .take_while(|(left, right)| left == right)
        .count()
}

pub(crate) fn recent_chars(text: &str, max_chars: usize) -> String {
    let chars: Vec<char> = text.chars().collect();
    if chars.len() <= max_chars {
        return text.to_string();
    }

    chars[chars.len() - max_chars..].iter().collect()
}

pub(crate) fn merge_transcript_estimate(existing: &str, current: &str) -> String {
    let existing = existing.trim();
    let current = current.trim();
    if existing.is_empty() {
        return current.to_string();
    }
    if current.is_empty() {
        return existing.to_string();
    }

    let existing_words: Vec<&str> = existing.split_whitespace().collect();
    let current_words: Vec<&str> = current.split_whitespace().collect();
    if existing_words.is_empty() {
        return current.to_string();
    }
    if current_words.is_empty() {
        return existing.to_string();
    }

    let existing_cmp: Vec<String> = existing_words
        .iter()
        .map(|word| compare_token(word))
        .collect();
    let current_cmp: Vec<String> = current_words
        .iter()
        .map(|word| compare_token(word))
        .collect();

    if contains_word_sequence(&current_cmp, &existing_cmp) {
        return current.to_string();
    }
    if contains_word_sequence(&existing_cmp, &current_cmp) {
        return existing.to_string();
    }

    let max_overlap = existing_cmp.len().min(current_cmp.len());
    let shared_prefix = shared_prefix_len(&existing_cmp, &current_cmp);
    if shared_prefix >= MIN_RESTART_PREFIX_WORDS && shared_prefix < max_overlap {
        let existing_tail_len = existing_words.len().saturating_sub(shared_prefix);
        let current_tail_len = current_words.len().saturating_sub(shared_prefix);
        if current_tail_len >= existing_tail_len || current_words.len() + 2 >= existing_words.len()
        {
            return current.to_string();
        }
    }

    let min_overlap = if max_overlap <= 2 { 1 } else { 2 };
    for overlap in (min_overlap..=max_overlap).rev() {
        if existing_cmp[existing_cmp.len() - overlap..] == current_cmp[..overlap] {
            let mut words = Vec::with_capacity(existing_words.len() + current_words.len());
            words.extend_from_slice(&existing_words[..existing_words.len() - overlap]);
            words.extend_from_slice(&current_words);
            return words.join(" ");
        }
    }

    for overlap in (min_overlap..=max_overlap).rev() {
        if current_cmp[current_cmp.len() - overlap..] == existing_cmp[..overlap] {
            let mut words = Vec::with_capacity(existing_words.len() + current_words.len());
            words.extend_from_slice(&current_words[..current_words.len() - overlap]);
            words.extend_from_slice(&existing_words);
            return words.join(" ");
        }
    }

    format!("{existing} {current}")
}

fn contains_word_sequence(haystack: &[String], needle: &[String]) -> bool {
    if needle.is_empty() || needle.len() > haystack.len() {
        return false;
    }

    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

fn shared_prefix_len(left: &[String], right: &[String]) -> usize {
    left.iter()
        .zip(right.iter())
        .take_while(|(left, right)| left == right)
        .count()
}

pub(crate) fn compare_token(word: &str) -> String {
    word.trim_matches(|value: char| !value.is_alphanumeric())
        .to_ascii_lowercase()
}

pub(crate) fn comparable_word_spans(text: &str) -> Vec<(String, usize, usize)> {
    let mut words = Vec::new();
    let mut start = None;
    for (index, character) in text.char_indices() {
        if character.is_whitespace() {
            if let Some(word_start) = start.take() {
                push_comparable_word_span(text, word_start, index, &mut words);
            }
        } else if start.is_none() {
            start = Some(index);
        }
    }
    if let Some(word_start) = start {
        push_comparable_word_span(text, word_start, text.len(), &mut words);
    }
    words
}

fn push_comparable_word_span(
    text: &str,
    start: usize,
    end: usize,
    words: &mut Vec<(String, usize, usize)>,
) {
    let comparable = compare_token(&text[start..end]);
    if !comparable.is_empty() {
        words.push((comparable, start, end));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn final_decode_includes_voice_after_the_previous_pass() {
        let first = Instant::now();
        let tail = first + Duration::from_millis(500);
        assert!(should_decode_final(true, false, Some(tail), Some(first)));
    }

    #[test]
    fn final_decode_covers_short_speech_without_a_partial() {
        assert!(should_decode_final(true, true, Some(Instant::now()), None));
    }

    #[test]
    fn final_decode_skips_empty_or_already_decoded_audio() {
        let voice = Instant::now();
        assert!(!should_decode_final(false, true, Some(voice), None));
        assert!(!should_decode_final(true, false, Some(voice), Some(voice)));
        assert!(!should_decode_final(true, false, None, None));
    }

    #[test]
    fn refresh_rejects_old_frames_and_keeps_new_speech() {
        let cutoff = Instant::now();
        let old = cutoff - Duration::from_millis(1);
        let new = cutoff + Duration::from_millis(1);
        assert!(audio_frame_is_current(old, None));
        assert!(!audio_frame_is_current(old, Some(cutoff)));
        assert!(audio_frame_is_current(cutoff, Some(cutoff)));
        assert!(audio_frame_is_current(new, Some(cutoff)));
    }

    #[test]
    fn repeated_clauses_survive_the_first_hypothesis() {
        let text = "I think we should go. I think we should stay.";
        assert_eq!(merge_transcript_estimate("", text), text);
        let text = "We need to fix the database. We need to fix the server.";
        assert_eq!(merge_transcript_estimate("", text), text);
    }

    #[test]
    fn final_hypothesis_replaces_an_existing_partial_once() {
        assert_eq!(
            merge_transcript_estimate("The launch will be", "The launch will be Friday."),
            "The launch will be Friday."
        );
    }

    #[test]
    fn revised_tail_replaces_previous_estimate() {
        assert_eq!(
            merge_transcript_estimate("We need the answer by Thursday.", "We need the answer by Friday."),
            "We need the answer by Friday."
        );
    }

    #[test]
    fn rolling_windows_merge_the_shared_tail() {
        assert_eq!(
            merge_transcript_estimate("We discussed the database migration", "database migration and rollback."),
            "We discussed the database migration and rollback."
        );
    }

    #[test]
    fn short_replies_are_informative_in_context() {
        for text in ["Friday.", "Yes.", "No.", "42.", "Okay.", "Sure."] {
            assert!(is_informative_delta(text, true), "{text}");
        }
        assert!(!is_informative_delta("Friday.", false));
    }

    #[test]
    fn fillers_and_punctuation_stay_suppressed() {
        for text in ["uh", "Um.", "hmm", "...", "!"] {
            assert!(!is_informative_delta(text, true), "{text}");
        }
        assert!(is_informative_delta("Any updates?", false));
        assert!(is_informative_delta("need answer", false));
    }

    #[test]
    fn one_word_correction_is_detected() {
        let delta = new_text_since(Some("The launch is Thursday."), "The launch is Friday.", 100);
        assert_eq!(delta, "Friday.");
        assert!(is_informative_delta(&delta, true));
    }

    #[test]
    fn punctuation_and_case_changes_have_no_delta() {
        assert_eq!(new_text_since(Some("Hello, world."), "hello world", 100), "");
    }

    #[derive(Debug, PartialEq)]
    struct Snapshot {
        text: &'static str,
        generation: u64,
        force: bool,
    }

    fn queue(pending: &mut Option<Snapshot>, text: &'static str, generation: u64, force: bool) {
        coalesce_latest(
            pending,
            Snapshot { text, generation, force },
            |input| input.generation,
            |next, previous| next.force |= previous.force,
        );
    }

    #[test]
    fn queued_force_uses_the_newest_context() {
        let mut pending = None;
        queue(&mut pending, "F1 context", 0, true);
        queue(&mut pending, "newer automatic context", 0, false);
        assert_eq!(pending, Some(Snapshot { text: "newer automatic context", generation: 0, force: true }));
    }

    #[test]
    fn force_survives_separate_received_batches() {
        let mut latest = None;
        queue(&mut latest, "F1 context", 2, true);
        let mut batch = None;
        queue(&mut batch, "latest speech", 2, false);
        coalesce_latest(&mut latest, batch.unwrap(), |input| input.generation,
            |next, previous| next.force |= previous.force);
        assert!(latest.as_ref().unwrap().force);
        assert_eq!(latest.unwrap().text, "latest speech");
    }

    #[test]
    fn refresh_does_not_inherit_force_or_accept_older_snapshots() {
        let mut pending = None;
        queue(&mut pending, "old forced", 0, true);
        queue(&mut pending, "new session", 1, false);
        queue(&mut pending, "stale forced", 0, true);
        assert_eq!(pending, Some(Snapshot { text: "new session", generation: 1, force: false }));
    }
}
