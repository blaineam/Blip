//! OpenSpeedTest's public test, driven headlessly the way the Mac does it: their own widget page
//! loads in an invisible WebView2 window (shipped with Windows 11 and every supported Windows
//! 10), a script reads the live and final numbers off the page, and they flow into the same
//! `SpeedTester` the self-hosted path uses. Manual runs only — it's donated infrastructure.

use std::sync::Mutex;

use blip_core::speedtest::{ExternalRun, SpeedTester};

static PENDING: Mutex<Option<ExternalRun>> = Mutex::new(None);
static CANCEL: Mutex<bool> = Mutex::new(false);

/// Kicks off a public run: latency is measured off-thread, then `pump` (main thread) opens the
/// web view.
pub fn start(tester: SpeedTester) {
    *CANCEL.lock().unwrap() = false;
    std::thread::spawn(move || {
        if let Some(run) = tester.begin_external() {
            if cfg!(windows) {
                *PENDING.lock().unwrap() = Some(run);
            } else {
                run.fail("The public test needs WebView2 (Windows). Use a self-hosted server here.");
            }
        }
    });
}

pub fn cancel() {
    *CANCEL.lock().unwrap() = true;
}

/// Call every frame on the UI thread. Returns true while a run is in flight.
pub fn pump() -> bool {
    #[cfg(windows)]
    {
        imp::pump()
    }
    #[cfg(not(windows))]
    {
        false
    }
}

/// Page script: polls the widget's result elements every 500 ms; auto-start comes from the
/// `?run` URL parameter with a click fallback (same logic as the Mac's runner).
#[cfg_attr(not(windows), allow(dead_code))]
const SCRIPT: &str = r#"
(function(){
  if (window.__blipInstalled) return; window.__blipInstalled = true;
  function num(el){if(!el)return null;var v=parseFloat((el.textContent||'').replace(/[^0-9.]/g,''));return isNaN(v)?null:v;}
  function post(o){try{window.ipc.postMessage(JSON.stringify(o));}catch(e){}}
  function fire(el){ try{el.click();}catch(e){}
    try{['mousedown','mouseup','click'].forEach(function(t){el.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,view:window}));});}catch(e){} }
  var started=false, lastUp=null, stableSince=0, done=false, ticks=0, lastClick=0;
  setInterval(function(){
    ticks++;
    var doc=document;
    if(!(doc.getElementById('startButtonDesk')||doc.getElementById('downResult'))){ return; }
    var btn=doc.getElementById('startButtonDesk')||doc.getElementById('startButtonMob');
    var down=num(doc.getElementById('downResult')), up=num(doc.getElementById('upRestxt')),
        live=num(doc.getElementById('oDoLiveSpeed')), ping=num(doc.getElementById('pingResult'));
    var st=doc.getElementById('oDoLiveStatus'); var status=st?(''+st.textContent).trim():'';
    if((down||0)>0||(up||0)>0||(ping||0)>0||(live||0)>0) started=true;
    if(!started && btn && ticks>20 && (Date.now()-lastClick>2500)){ lastClick=Date.now(); fire(btn); }
    if(done) return;
    post({type:'state', down:down, up:up, live:live, status:status});
    if(down!=null&&down>0&&up!=null&&up>0){
      if(up===lastUp){ if(Date.now()-stableSince>1500){ done=true; post({type:'done', down:down, up:up, ping:ping}); } }
      else { lastUp=up; stableSince=Date.now(); }
    }
  },500);
})();
"#;

#[cfg(windows)]
mod imp {
    use std::cell::RefCell;
    use std::num::NonZeroIsize;
    use std::rc::Rc;
    use std::time::Instant;

    use blip_core::speedtest::ExternalRun;
    use raw_window_handle::{HandleError, HasWindowHandle, RawWindowHandle, Win32WindowHandle, WindowHandle};
    use windows::core::w;
    use windows::Win32::Foundation::{COLORREF, HWND};
    use windows::Win32::UI::WindowsAndMessaging::*;

    use super::{CANCEL, PENDING, SCRIPT};

    struct Host(HWND);

    impl HasWindowHandle for Host {
        fn window_handle(&self) -> Result<WindowHandle<'_>, HandleError> {
            let h = Win32WindowHandle::new(
                NonZeroIsize::new(self.0 .0 as isize).ok_or(HandleError::Unavailable)?,
            );
            // SAFETY: the HWND outlives the web view (destroyed after it in `teardown`).
            Ok(unsafe { WindowHandle::borrow_raw(RawWindowHandle::Win32(h)) })
        }
    }

    struct Runner {
        _webview: wry::WebView,
        host: Host,
        run: Rc<RefCell<Option<ExternalRun>>>,
        started: Instant,
        _ctx: Box<wry::WebContext>,
    }

    thread_local!(static RUNNER: RefCell<Option<Runner>> = const { RefCell::new(None) });

    fn create_host() -> Option<HWND> {
        // SAFETY: a plain popup of the built-in STATIC class; destroyed in `teardown`.
        unsafe {
            let hwnd = CreateWindowExW(
                WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                w!("STATIC"),
                w!("Blip speed test"),
                WS_POPUP,
                0,
                0,
                760,
                560,
                None,
                None,
                None,
                None,
            )
            .ok()?;
            // Nearly transparent and click-through but on screen, so Chromium doesn't treat the
            // page as occluded and throttle its timers (the Mac does the same with alpha 0).
            let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), 1, LWA_ALPHA);
            let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            Some(hwnd)
        }
    }

    fn teardown() {
        RUNNER.with(|r| {
            if let Some(runner) = r.borrow_mut().take() {
                let hwnd = runner.host.0;
                let run = runner.run.borrow_mut().take();
                drop(runner);
                // SAFETY: our own window.
                unsafe {
                    let _ = DestroyWindow(hwnd);
                }
                if let Some(run) = run {
                    run.fail("Public test didn't finish. Try again, or use a self-hosted server.");
                }
            }
        });
    }

    pub fn pump() -> bool {
        if let Some(run) = PENDING.lock().unwrap().take() {
            teardown();
            if let Some(run) = open(run) {
                run.fail(
                    "Couldn't reach openspeedtest.com. Check your connection, or use a self-hosted server.",
                );
            }
        }
        let active = RUNNER.with(|r| r.borrow().is_some());
        if !active {
            return false;
        }
        let cancelled = *CANCEL.lock().unwrap();
        let (timed_out, finished, ext_cancel) = RUNNER.with(|r| {
            let r = r.borrow();
            let runner = r.as_ref().unwrap();
            let finished = runner.run.borrow().is_none();
            let ext = runner.run.borrow().as_ref().is_some_and(|x| x.is_cancelled());
            (runner.started.elapsed().as_secs() > 180, finished, ext)
        });
        if finished {
            RUNNER.with(|r| {
                if let Some(runner) = r.borrow_mut().take() {
                    let hwnd = runner.host.0;
                    drop(runner);
                    unsafe {
                        let _ = DestroyWindow(hwnd);
                    }
                }
            });
            return false;
        }
        if timed_out || cancelled || ext_cancel {
            if timed_out {
                RUNNER.with(|r| {
                    if let Some(run) = r.borrow().as_ref().and_then(|x| x.run.borrow_mut().take()) {
                        run.fail("Public test timed out. Try again, or use a self-hosted server.");
                    }
                });
            }
            teardown();
            return false;
        }
        true
    }

    /// Opens the web view; hands the run back if that failed.
    fn open(run: ExternalRun) -> Option<ExternalRun> {
        let Some(hwnd) = create_host() else {
            return Some(run);
        };
        let host = Host(hwnd);
        let run = Rc::new(RefCell::new(Some(run)));
        let ipc_run = run.clone();
        let mut ctx = Box::new(wry::WebContext::new(Some(
            blip_core::paths::data_dir().join("WebView2"),
        )));
        let built = wry::WebViewBuilder::new_with_web_context(&mut ctx)
            .with_incognito(true)
            .with_initialization_script(SCRIPT)
            .with_url("https://openspeedtest.com/speedtest?run")
            .with_bounds(wry::Rect {
                position: wry::dpi::LogicalPosition::new(0, 0).into(),
                size: wry::dpi::LogicalSize::new(760, 560).into(),
            })
            .with_ipc_handler(move |req| {
                let Ok(v) = serde_json::from_str::<serde_json::Value>(req.body()) else {
                    return;
                };
                let mut slot = ipc_run.borrow_mut();
                match v.get("type").and_then(|t| t.as_str()) {
                    Some("state") => {
                        if let Some(r) = slot.as_mut() {
                            let upload = v
                                .get("status")
                                .and_then(|s| s.as_str())
                                .unwrap_or("")
                                .to_lowercase()
                                .contains("upload");
                            r.progress(upload, v.get("live").and_then(|l| l.as_f64()));
                        }
                    }
                    Some("done") => {
                        let down = v.get("down").and_then(|d| d.as_f64()).unwrap_or(0.0);
                        if let Some(r) = slot.take() {
                            if down > 0.0 {
                                r.complete(down, v.get("up").and_then(|u| u.as_f64()));
                            } else {
                                r.fail("Public test didn't finish. Try again, or use a self-hosted server.");
                            }
                        }
                    }
                    _ => {}
                }
            })
            .build_as_child(&host);
        match built {
            Ok(webview) => {
                RUNNER.with(|r| {
                    *r.borrow_mut() = Some(Runner {
                        _webview: webview,
                        host,
                        run,
                        started: Instant::now(),
                        _ctx: ctx,
                    })
                });
                None
            }
            Err(_) => {
                unsafe {
                    let _ = DestroyWindow(hwnd);
                }
                let r = run.borrow_mut().take();
                r
            }
        }
    }
}
