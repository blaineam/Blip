//! Fixed-length sample history for the sparklines and the CLI's 2-minute aggregates.

use std::collections::VecDeque;

#[derive(Debug, Clone)]
pub struct History {
    cap: usize,
    values: VecDeque<f64>,
}

impl History {
    /// 60 samples × 2 s = the Mac's 2-minute window.
    pub const DEFAULT_LEN: usize = 60;

    pub fn new(cap: usize) -> Self {
        Self { cap, values: VecDeque::with_capacity(cap) }
    }

    pub fn push(&mut self, v: f64) {
        if self.values.len() == self.cap {
            self.values.pop_front();
        }
        self.values.push_back(v);
    }

    pub fn values(&self) -> Vec<f64> {
        self.values.iter().copied().collect()
    }

    pub fn len(&self) -> usize {
        self.values.len()
    }

    pub fn is_empty(&self) -> bool {
        self.values.is_empty()
    }

    pub fn max(&self) -> Option<f64> {
        self.values.iter().copied().reduce(f64::max)
    }

    pub fn min(&self) -> Option<f64> {
        self.values.iter().copied().reduce(f64::min)
    }

    pub fn average(&self) -> Option<f64> {
        if self.values.is_empty() {
            None
        } else {
            Some(self.values.iter().sum::<f64>() / self.values.len() as f64)
        }
    }
}

impl Default for History {
    fn default() -> Self {
        Self::new(Self::DEFAULT_LEN)
    }
}

/// "Nice" axis maximum for a byte-rate chart: 1/2/5 × 10ⁿ at or above `v`.
pub fn nice_ceiling(v: f64) -> f64 {
    if v <= 0.0 {
        return 1.0;
    }
    let exp = v.log10().floor();
    let base = 10f64.powf(exp);
    for m in [1.0, 2.0, 2.5, 5.0, 10.0] {
        if m * base >= v {
            return m * base;
        }
    }
    10.0 * base
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ring_drops_oldest() {
        let mut h = History::new(3);
        for v in [1.0, 2.0, 3.0, 4.0] {
            h.push(v);
        }
        assert_eq!(h.values(), vec![2.0, 3.0, 4.0]);
        assert_eq!(h.average(), Some(3.0));
        assert_eq!(h.max(), Some(4.0));
    }

    #[test]
    fn nice_ceilings() {
        assert_eq!(nice_ceiling(73.0), 100.0);
        assert_eq!(nice_ceiling(4_100_000.0), 5_000_000.0);
        assert_eq!(nice_ceiling(0.0), 1.0);
    }
}
