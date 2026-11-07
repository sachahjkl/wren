//! The next context's device, made before a page asks for it (host.rs): a device takes tens of milliseconds to make, and a page's
//! thread waits for its context. One at a time, for one key (what decides the adapter); its state machine is here, apart from wgpu,
//! so that the tests drive it with plain values.

use std::sync::{Condvar, Mutex, MutexGuard};

enum State<K, T> {
    Empty,
    /// A thread is making one for this key, and gives it with `fill`.
    Making(K),
    Ready(K, T),
}

pub struct Spare<K, T> {
    state: Mutex<State<K, T>>,
    changed: Condvar,
}

impl<K: Copy + PartialEq, T> Spare<K, T> {
    pub const fn new() -> Spare<K, T> {
        Spare { state: Mutex::new(State::Empty), changed: Condvar::new() }
    }

    fn lock(&self) -> MutexGuard<'_, State<K, T>> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// true: nothing is made or being made, and the caller now makes one for `key`, given with `fill` (or `cancel`).
    pub fn begin(&self, key: K) -> bool {
        let mut s = self.lock();
        if !matches!(*s, State::Empty) {
            return false;
        }
        *s = State::Making(key);
        true
    }

    /// What `begin` asked for.
    pub fn fill(&self, item: T) {
        let mut s = self.lock();
        if let State::Making(k) = *s {
            *s = State::Ready(k, item);
        }
        self.changed.notify_all();
    }

    /// What `begin` asked for will not come.
    pub fn cancel(&self) {
        let mut s = self.lock();
        if matches!(*s, State::Making(_)) {
            *s = State::Empty;
        }
        self.changed.notify_all();
    }

    /// The one made for `key`, waiting while it is being made. None: there is none for `key` (one for another key is dropped: the
    /// preferences changed, and it would never fit).
    pub fn take(&self, key: K) -> Option<T> {
        let mut s = self.lock();
        while matches!(*s, State::Making(k) if k == key) {
            s = self.changed.wait(s).unwrap_or_else(|e| e.into_inner());
        }
        match std::mem::replace(&mut *s, State::Empty) {
            State::Ready(k, item) if k == key => Some(item),
            State::Making(k) => {
                *s = State::Making(k);
                None
            }
            other => {
                drop(s);
                drop(other);
                None
            }
        }
    }

    /// Whether one is ready or being made (tests).
    pub fn holds(&self) -> bool {
        !matches!(*self.lock(), State::Empty)
    }
}

#[cfg(test)]
mod spare_tests {
    use super::Spare;

    #[test]
    fn one_is_made_at_a_time_and_taken_once() {
        let s: Spare<u8, &str> = Spare::new();
        assert!(s.take(1).is_none(), "nothing made: the taker makes its own");
        assert!(s.begin(1));
        assert!(!s.begin(1), "one is being made: no second one");
        s.fill("a");
        assert!(!s.begin(1), "one is ready: no second one");
        assert_eq!(s.take(1), Some("a"));
        assert!(s.take(1).is_none(), "taken once");
        assert!(s.begin(1), "taken: the next one can be made");
    }

    #[test]
    fn a_taker_waits_for_the_one_being_made_rather_than_make_another() {
        static S: Spare<u8, u32> = Spare::new();
        assert!(S.begin(7));
        // (whenever the taker runs, before or after the fill, it gets the one made: a taker that did not wait would get None)
        let taker = std::thread::spawn(|| S.take(7));
        S.fill(42);
        assert_eq!(taker.join().unwrap(), Some(42));
        assert!(!S.holds());
    }

    #[test]
    fn one_for_other_preferences_is_not_given_and_does_not_stay() {
        let s: Spare<u8, &str> = Spare::new();
        assert!(s.begin(1));
        assert!(s.take(2).is_none(), "being made for another key: no wait, nothing given");
        assert!(s.holds(), "the one being made goes on");
        s.fill("for 1");
        assert!(s.take(2).is_none());
        assert!(!s.holds(), "one that cannot fit is dropped");
    }

    #[test]
    fn a_cancelled_one_lets_a_waiting_taker_go_with_nothing() {
        static S: Spare<u8, u32> = Spare::new();
        assert!(S.begin(3));
        let taker = std::thread::spawn(|| S.take(3));
        S.cancel();
        assert_eq!(taker.join().unwrap(), None);
        assert!(S.begin(3), "cancelled: another can be made");
    }
}
