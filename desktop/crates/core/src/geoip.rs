//! Optional offline GeoIP for the traceroute map — DB-IP's free City Lite database, same as the
//! Mac. Nothing is bundled and nothing downloads unless the user asks (Settings › Traceroute
//! map); once installed it refreshes monthly if auto-update is on.

use std::io::Read;
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, PartialEq)]
pub enum GeoStatus {
    Absent,
    /// 0…1, or negative while indeterminate.
    Downloading(f64),
    Ready {
        build_epoch: u64,
        kind: String,
    },
    Failed(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct GeoPoint {
    pub lat: f64,
    pub lon: f64,
    pub city: Option<String>,
    pub country: Option<String>,
}

#[derive(Clone)]
pub struct GeoDb {
    inner: Arc<Mutex<Inner>>,
}

struct Inner {
    status: GeoStatus,
    reader: Option<Arc<maxminddb::Reader<Vec<u8>>>>,
    downloading: bool,
}

pub const ATTRIBUTION_URL: &str = "https://db-ip.com";

impl Default for GeoDb {
    fn default() -> Self {
        Self::new()
    }
}

impl GeoDb {
    pub fn new() -> Self {
        let db = Self {
            inner: Arc::new(Mutex::new(Inner {
                status: GeoStatus::Absent,
                reader: None,
                downloading: false,
            })),
        };
        db.load_if_present();
        db
    }

    pub fn status(&self) -> GeoStatus {
        self.inner.lock().unwrap().status.clone()
    }

    pub fn is_ready(&self) -> bool {
        self.inner.lock().unwrap().reader.is_some()
    }

    pub fn load_if_present(&self) {
        let path = crate::paths::geoip_file();
        let mut g = self.inner.lock().unwrap();
        match std::fs::read(&path) {
            Err(_) => {
                g.status = GeoStatus::Absent;
                g.reader = None;
            }
            Ok(bytes) => match maxminddb::Reader::from_source(bytes) {
                Ok(r) => {
                    g.status = GeoStatus::Ready {
                        build_epoch: r.metadata().build_epoch,
                        kind: r.metadata().database_type.clone(),
                    };
                    g.reader = Some(Arc::new(r));
                }
                Err(_) => {
                    g.status =
                        GeoStatus::Failed("Installed database is unreadable — re-download to fix.".into());
                    g.reader = None;
                }
            },
        }
    }

    pub fn lookup(&self, ip: &str) -> Option<GeoPoint> {
        let reader = self.inner.lock().unwrap().reader.clone()?;
        let addr: std::net::IpAddr = ip.parse().ok()?;
        let city: maxminddb::geoip2::City = reader.lookup(addr).ok()?.decode().ok()??;
        let lat = city.location.latitude?;
        let lon = city.location.longitude?;
        let name = |names: &maxminddb::geoip2::Names| names.english.map(str::to_string);
        Some(GeoPoint {
            lat,
            lon,
            city: name(&city.city.names),
            country: name(&city.country.names),
        })
    }

    pub fn remove(&self) {
        let _ = std::fs::remove_file(crate::paths::geoip_file());
        let mut g = self.inner.lock().unwrap();
        g.reader = None;
        g.status = GeoStatus::Absent;
    }

    /// Downloads the newest monthly file on a worker thread.
    pub fn download(&self, notify: Option<Arc<dyn Fn() + Send + Sync>>) {
        {
            let mut g = self.inner.lock().unwrap();
            if g.downloading {
                return;
            }
            g.downloading = true;
            g.status = GeoStatus::Downloading(-1.0);
        }
        let me = self.clone();
        std::thread::spawn(move || {
            let n2 = notify.clone();
            let me2 = me.clone();
            let r = fetch_and_install(&move |p| {
                me2.inner.lock().unwrap().status = GeoStatus::Downloading(p);
                if let Some(n) = &n2 {
                    n();
                }
            });
            {
                let mut g = me.inner.lock().unwrap();
                g.downloading = false;
            }
            match r {
                Ok(month) => {
                    me.load_if_present();
                    let _ = std::fs::write(crate::paths::data_dir().join("geoip-month.txt"), month);
                }
                Err(e) => me.inner.lock().unwrap().status = GeoStatus::Failed(e),
            }
            if let Some(n) = notify {
                n();
            }
        });
    }

    /// At most daily: if auto-update is on and a newer month is published, fetch it.
    pub fn auto_update_check(&self, notify: Option<Arc<dyn Fn() + Send + Sync>>) {
        if !self.is_ready() {
            return;
        }
        let stamp = crate::paths::data_dir().join("geoip-lastcheck.txt");
        let now = crate::model::now_unix();
        let last: u64 = std::fs::read_to_string(&stamp)
            .ok()
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(0);
        if now.saturating_sub(last) < 86_400 {
            return;
        }
        let _ = std::fs::write(&stamp, now.to_string());
        let me = self.clone();
        std::thread::spawn(move || {
            let installed =
                std::fs::read_to_string(crate::paths::data_dir().join("geoip-month.txt")).unwrap_or_default();
            if let Some(newest) = newest_available_month() {
                if newest.as_str() > installed.trim() {
                    me.download(notify);
                }
            }
        });
    }
}

/// (tag, url) for this month and the three before it, newest first.
pub fn candidate_months(year: i32, month: u32) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let (mut y, mut m) = (year, month as i32);
    for _ in 0..4 {
        let tag = format!("{y:04}-{m:02}");
        out.push((
            tag.clone(),
            format!("https://download.db-ip.com/free/dbip-city-lite-{tag}.mmdb.gz"),
        ));
        m -= 1;
        if m == 0 {
            m = 12;
            y -= 1;
        }
    }
    out
}

fn current_year_month() -> (i32, u32) {
    // Civil-from-days (Howard Hinnant), no chrono dependency.
    let days = (crate::model::now_unix() / 86_400) as i64;
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    (y as i32, m as u32)
}

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(std::time::Duration::from_secs(300)))
        .user_agent("Blip (desktop)")
        .build()
        .into()
}

fn newest_available_month() -> Option<String> {
    let (y, m) = current_year_month();
    let a = agent();
    candidate_months(y, m)
        .into_iter()
        .find(|(_, url)| a.head(url).call().is_ok())
        .map(|(t, _)| t)
}

fn fetch_and_install(progress: &dyn Fn(f64)) -> Result<String, String> {
    let (y, m) = current_year_month();
    let a = agent();
    let mut last = String::from("Download failed.");
    for (tag, url) in candidate_months(y, m) {
        let mut resp = match a.get(&url).call() {
            Ok(r) => r,
            Err(ureq::Error::StatusCode(404)) => continue,
            Err(ureq::Error::Timeout(_)) => return Err("Download timed out.".into()),
            Err(ureq::Error::Io(_)) | Err(ureq::Error::HostNotFound) | Err(ureq::Error::ConnectionFailed) => {
                return Err("No internet connection.".into())
            }
            Err(_) => {
                last = "Download failed.".into();
                continue;
            }
        };
        let total: Option<u64> = resp
            .headers()
            .get("content-length")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse().ok());
        let mut gz = Vec::new();
        let mut reader = resp.body_mut().with_config().limit(200 * 1024 * 1024).reader();
        let mut buf = vec![0u8; 256 * 1024];
        loop {
            let n = reader
                .read(&mut buf)
                .map_err(|_| "Download failed.".to_string())?;
            if n == 0 {
                break;
            }
            gz.extend_from_slice(&buf[..n]);
            progress(total.map_or(-1.0, |t| gz.len() as f64 / t as f64));
        }
        let mut mmdb = Vec::new();
        flate2::read::GzDecoder::new(&gz[..])
            .read_to_end(&mut mmdb)
            .map_err(|_| "Download failed.".to_string())?;
        maxminddb::Reader::from_source(mmdb.as_slice()).map_err(|_| "Download failed.".to_string())?;
        crate::paths::write_atomic(&crate::paths::geoip_file(), &mmdb).map_err(|e| e.to_string())?;
        return Ok(tag);
    }
    Err(last)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn months_roll_back_over_new_year() {
        let c = candidate_months(2026, 2);
        let tags: Vec<_> = c.iter().map(|(t, _)| t.as_str()).collect();
        assert_eq!(tags, ["2026-02", "2026-01", "2025-12", "2025-11"]);
        assert!(c[0].1.ends_with("dbip-city-lite-2026-02.mmdb.gz"));
    }

    #[test]
    fn civil_date_is_sane() {
        let (y, m) = current_year_month();
        assert!(y >= 2026 && (1..=12).contains(&m));
    }
}
