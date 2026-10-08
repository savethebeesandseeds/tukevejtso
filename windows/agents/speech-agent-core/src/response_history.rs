//! Append-only Agent Insights response history with an explicit live view.

/// Stores every response in session order. None selects the live tail;
/// Some(index) pins that response while later responses continue to append.
#[derive(Clone, Debug)]
pub(crate) struct ResponseHistory<T> {
    entries: Vec<T>,
    selected: Option<usize>,
}

impl<T> Default for ResponseHistory<T> {
    fn default() -> Self {
        Self {
            entries: Vec::new(),
            selected: None,
        }
    }
}

impl<T> ResponseHistory<T> {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    /// Restore saved entries and browsing state. Invalid pinned indices clamp
    /// to the latest available response; an empty history always stays live.
    pub(crate) fn from_entries(entries: Vec<T>, selected: Option<usize>) -> Self {
        let selected =
            selected.and_then(|index| entries.len().checked_sub(1).map(|latest| index.min(latest)));
        Self { entries, selected }
    }

    /// Append a response. Returns whether the displayed response changes.
    pub(crate) fn append(&mut self, entry: T) -> bool {
        self.entries.push(entry);
        self.selected.is_none()
    }

    /// Move one response older. The first move from live skips the live tail
    /// when possible; with one response it pins that sole response.
    pub(crate) fn older(&mut self) -> bool {
        if self.entries.is_empty() {
            return false;
        }
        let next = match self.selected {
            Some(index) => index.saturating_sub(1),
            None => self.entries.len().saturating_sub(2),
        };
        let changed = self.selected != Some(next);
        self.selected = Some(next);
        changed
    }

    /// Move one response newer. Reaching the latest response remains pinned;
    /// moving newer from live pins the latest response without changing it.
    pub(crate) fn newer(&mut self) -> bool {
        let Some(latest) = self.entries.len().checked_sub(1) else {
            return false;
        };
        let next = match self.selected {
            Some(index) => index.saturating_add(1).min(latest),
            None => latest,
        };
        let changed = self.selected != Some(next);
        self.selected = Some(next);
        changed
    }

    /// Return to following the newest response.
    pub(crate) fn resume_live(&mut self) -> bool {
        self.selected.take().is_some()
    }

    pub(crate) fn current(&self) -> Option<&T> {
        match self.selected {
            Some(index) => self.entries.get(index),
            None => self.entries.last(),
        }
    }

    /// Return the pinned index; None means the view follows live responses.
    pub(crate) fn selected_index(&self) -> Option<usize> {
        self.selected
    }

    pub(crate) fn len(&self) -> usize {
        self.entries.len()
    }

    pub(crate) fn entries(&self) -> &[T] {
        &self.entries
    }

    pub(crate) fn is_browsing(&self) -> bool {
        self.selected.is_some()
    }

    /// Count responses newer than the pinned response, including entries that
    /// existed before browsing began. Live viewing has no unseen responses.
    pub(crate) fn unseen_count(&self) -> usize {
        self.selected
            .map(|index| self.entries.len().saturating_sub(index.saturating_add(1)))
            .unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::ResponseHistory;

    #[test]
    fn empty_navigation_stays_live() {
        let mut history = ResponseHistory::<u32>::new();
        assert!(!history.older());
        assert!(!history.newer());
        assert!(!history.resume_live());
        assert_eq!(history.current(), None);
        assert_eq!(history.selected_index(), None);
        assert!(!history.is_browsing());
        assert_eq!(history.len(), 0);
        assert!(history.entries().is_empty());
        assert_eq!(history.unseen_count(), 0);
    }

    #[test]
    fn default_does_not_require_a_default_response() {
        struct NoDefault(u32);
        let mut history: ResponseHistory<NoDefault> = ResponseHistory::default();
        assert!(history.append(NoDefault(7)));
        assert_eq!(history.current().map(|response| response.0), Some(7));
    }

    #[test]
    fn a_single_response_can_be_pinned_at_either_bound() {
        let mut history = ResponseHistory::from_entries(vec!["first"], None);
        assert!(history.older());
        assert_eq!(history.selected_index(), Some(0));
        assert_eq!(history.current(), Some(&"first"));
        assert!(history.is_browsing());
        assert!(!history.older());
        assert!(!history.newer());
        assert_eq!(history.unseen_count(), 0);
        assert!(history.resume_live());
        assert!(!history.resume_live());
        assert!(history.newer());
        assert_eq!(history.selected_index(), Some(0));
    }

    #[test]
    fn live_append_follows_each_response_and_preserves_all_entries() {
        let mut history = ResponseHistory::new();
        for response in 0..2_000 {
            assert!(history.append(response));
            assert_eq!(history.current(), Some(&response));
            assert_eq!(history.selected_index(), None);
            assert_eq!(history.unseen_count(), 0);
        }
        assert_eq!(history.len(), 2_000);
        assert_eq!(history.entries()[0], 0);
        assert_eq!(history.entries()[1_999], 1_999);
    }

    #[test]
    fn older_and_newer_navigate_without_leaving_browsing_at_the_bounds() {
        let mut history = ResponseHistory::from_entries(vec!["first", "second", "third"], None);
        assert!(history.older());
        assert_eq!(history.current(), Some(&"second"));
        assert_eq!(history.selected_index(), Some(1));
        assert_eq!(history.unseen_count(), 1);
        assert!(history.older());
        assert_eq!(history.current(), Some(&"first"));
        assert_eq!(history.unseen_count(), 2);
        assert!(!history.older());
        assert!(history.newer());
        assert_eq!(history.current(), Some(&"second"));
        assert!(history.newer());
        assert_eq!(history.current(), Some(&"third"));
        assert_eq!(history.unseen_count(), 0);
        assert!(history.is_browsing());
        assert!(!history.newer());
    }

    #[test]
    fn appending_while_browsing_keeps_the_selected_response() {
        let mut history = ResponseHistory::from_entries(vec!["first", "second", "third"], None);
        assert!(history.older());
        assert!(!history.append("fourth"));
        assert!(!history.append("fifth"));
        assert_eq!(history.current(), Some(&"second"));
        assert_eq!(history.selected_index(), Some(1));
        assert_eq!(history.unseen_count(), 3);
        assert_eq!(
            history.entries(),
            &["first", "second", "third", "fourth", "fifth"]
        );
        assert_eq!(history.len(), 5);
    }

    #[test]
    fn selecting_the_latest_response_still_pins_it() {
        let mut history = ResponseHistory::from_entries(vec!["first", "second"], None);
        assert!(history.newer());
        assert!(history.is_browsing());
        assert_eq!(history.selected_index(), Some(1));
        assert!(!history.append("third"));
        assert_eq!(history.current(), Some(&"second"));
        assert_eq!(history.unseen_count(), 1);
        assert!(history.newer());
        assert_eq!(history.current(), Some(&"third"));
        assert!(!history.append("fourth"));
        assert_eq!(history.current(), Some(&"third"));
        assert_eq!(history.unseen_count(), 1);
    }

    #[test]
    fn returning_live_shows_the_newest_response_and_follows_future_appends() {
        let mut history = ResponseHistory::from_entries(vec!["first", "second"], Some(0));
        assert!(!history.append("third"));
        assert!(history.resume_live());
        assert!(!history.is_browsing());
        assert_eq!(history.selected_index(), None);
        assert_eq!(history.current(), Some(&"third"));
        assert_eq!(history.unseen_count(), 0);
        assert!(history.append("fourth"));
        assert_eq!(history.current(), Some(&"fourth"));
        assert!(!history.resume_live());
    }

    #[test]
    fn restore_preserves_a_valid_pin_and_live_mode() {
        let mut pinned = ResponseHistory::from_entries(vec![10, 20, 30], Some(1));
        assert_eq!(pinned.current(), Some(&20));
        assert_eq!(pinned.selected_index(), Some(1));
        assert_eq!(pinned.unseen_count(), 1);
        assert!(!pinned.append(40));
        assert_eq!(pinned.current(), Some(&20));
        let mut live = ResponseHistory::from_entries(vec![10, 20], None);
        assert!(!live.is_browsing());
        assert_eq!(live.current(), Some(&20));
        assert!(live.append(30));
        assert_eq!(live.current(), Some(&30));
    }

    #[test]
    fn restore_clamps_out_of_range_pins_and_clears_empty_pins() {
        for invalid in [3, usize::MAX] {
            let history = ResponseHistory::from_entries(vec![10, 20, 30], Some(invalid));
            assert_eq!(history.selected_index(), Some(2));
            assert_eq!(history.current(), Some(&30));
            assert!(history.is_browsing());
            assert_eq!(history.unseen_count(), 0);
        }
        let mut empty = ResponseHistory::<u32>::from_entries(vec![], Some(usize::MAX));
        assert_eq!(empty.selected_index(), None);
        assert_eq!(empty.current(), None);
        assert!(!empty.is_browsing());
        assert_eq!(empty.unseen_count(), 0);
        assert!(empty.append(10));
        assert_eq!(empty.current(), Some(&10));
    }
}
