//! Performance Data Helper: the counters Task Manager and perfmon read, open to standard users.
//! English counter paths (`PdhAddEnglishCounterW`) so localized Windows installs work.

use std::collections::HashMap;

use windows::core::PCWSTR;
use windows::Win32::System::Performance::*;

pub struct Pdh {
    query: PDH_HQUERY,
    counters: HashMap<&'static str, PDH_HCOUNTER>,
}

// PDH query handles may be used from any thread, one at a time; Blip's sampler owns this one.
unsafe impl Send for Pdh {}

const FMT_DOUBLE_NOCAP: PDH_FMT = PDH_FMT(PDH_FMT_DOUBLE.0 | 0x8000);

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

impl Pdh {
    pub fn new() -> Option<Self> {
        let mut q = PDH_HQUERY::default();
        // SAFETY: out-pointer to a local.
        let rc = unsafe { PdhOpenQueryW(PCWSTR::null(), 0, &mut q) };
        (rc == 0).then(|| Self {
            query: q,
            counters: HashMap::new(),
        })
    }

    /// Adds a counter; silently skipped when this machine doesn't have it (e.g. no GPU counters
    /// on Windows 10 1607, no thermal zones on many desktops).
    pub fn add(&mut self, key: &'static str, path: &str) -> bool {
        let w = wide(path);
        let mut c = PDH_HCOUNTER::default();
        // SAFETY: valid query; `w` outlives the call.
        let rc = unsafe { PdhAddEnglishCounterW(self.query, PCWSTR(w.as_ptr()), 0, &mut c) };
        if rc == 0 {
            self.counters.insert(key, c);
            true
        } else {
            false
        }
    }

    pub fn has(&self, key: &str) -> bool {
        self.counters.contains_key(key)
    }

    pub fn collect(&self) {
        // SAFETY: valid query handle.
        unsafe {
            PdhCollectQueryData(self.query);
        }
    }

    pub fn value(&self, key: &str) -> Option<f64> {
        let c = self.counters.get(key)?;
        let mut v = PDH_FMT_COUNTERVALUE::default();
        // SAFETY: valid counter; out-pointer to a local.
        let rc = unsafe { PdhGetFormattedCounterValue(*c, FMT_DOUBLE_NOCAP, None, &mut v) };
        if rc != 0 || (v.CStatus != 0 && v.CStatus != 1) {
            return None;
        }
        // SAFETY: we asked for PDH_FMT_DOUBLE.
        Some(unsafe { v.Anonymous.doubleValue })
    }

    /// Every instance of a wildcard counter: (instance name, value).
    pub fn array(&self, key: &str) -> Vec<(String, f64)> {
        let Some(c) = self.counters.get(key) else {
            return Vec::new();
        };
        let mut size = 0u32;
        let mut count = 0u32;
        // SAFETY: size query with a null buffer.
        let rc = unsafe { PdhGetFormattedCounterArrayW(*c, FMT_DOUBLE_NOCAP, &mut size, &mut count, None) };
        if rc != PDH_MORE_DATA || size == 0 {
            return Vec::new();
        }
        // u64-aligned backing store large enough for `size` bytes.
        let mut buf = vec![0u64; (size as usize).div_ceil(8)];
        let items = buf.as_mut_ptr() as *mut PDH_FMT_COUNTERVALUE_ITEM_W;
        // SAFETY: buffer is `size` bytes as PDH requested.
        let rc =
            unsafe { PdhGetFormattedCounterArrayW(*c, FMT_DOUBLE_NOCAP, &mut size, &mut count, Some(items)) };
        if rc != 0 {
            return Vec::new();
        }
        let mut out = Vec::with_capacity(count as usize);
        for i in 0..count as usize {
            // SAFETY: PDH wrote `count` items into our buffer; names point inside it.
            let item = unsafe { &*items.add(i) };
            if item.FmtValue.CStatus != 0 && item.FmtValue.CStatus != 1 {
                continue;
            }
            let name = unsafe { item.szName.to_string() }.unwrap_or_default();
            out.push((name, unsafe { item.FmtValue.Anonymous.doubleValue }));
        }
        out
    }
}

impl Drop for Pdh {
    fn drop(&mut self) {
        // SAFETY: we own the query.
        unsafe {
            PdhCloseQuery(self.query);
        }
    }
}
