package com.blainemiller.blip.speed

import android.annotation.SuppressLint
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.blainemiller.blip.L
import com.blainemiller.blip.core.Native
import org.json.JSONObject

/**
 * OpenSpeedTest's public test, driven the way every Blip drives it: their own widget page loads
 * in a WebView (invisible here), a script reads the live and final numbers off the page, and they
 * flow into the native core's tester — so results, curves and history match the self-hosted path.
 * Manual runs only: it's donated infrastructure.
 */
const val PUBLIC_URL = "https://openspeedtest.com/speedtest?run"

/** Same page script as the Windows and Mac runners. */
private const val SCRIPT = """
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
"""

/** Receives the page's messages (kept by ProGuard: see proguard-rules.pro). */
class PublicSpeedBridge(private val onFinished: () -> Unit) {
    @Volatile var finished = false
        private set

    @JavascriptInterface
    fun postMessage(json: String) {
        if (finished) return
        val o = runCatching { JSONObject(json) }.getOrNull() ?: return
        when (o.optString("type")) {
            "state" -> {
                val up = o.optDouble("up").takeIf { !it.isNaN() && it > 0 }
                val live = o.optDouble("live").takeIf { !it.isNaN() } ?: 0.0
                // Once an upload figure exists the widget is in its upload phase.
                Native.speedExternalProgress(up != null || o.optString("status").contains("upload", true), live)
            }
            "done" -> {
                finished = true
                Native.speedExternalComplete(o.optDouble("down"), o.optDouble("up"))
                onFinished()
            }
        }
    }

    fun fail(message: String) {
        if (finished) return
        finished = true
        Native.speedExternalFail(message)
        onFinished()
    }
}

/** Mount while a public run is in flight; unmounting tears the page down. */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun PublicSpeedTestHost(onFinished: () -> Unit) {
    val main = remember { Handler(Looper.getMainLooper()) }
    val started = remember { System.currentTimeMillis() }
    val web = remember { arrayOfNulls<WebView>(1) }
    val watchdog = remember { arrayOfNulls<Runnable>(1) }
    AndroidView(
        modifier = Modifier.size(2.dp).alpha(0f),
        factory = { ctx ->
            // Made here, with the page it serves (lint can't see its methods through remember).
            val bridge = PublicSpeedBridge { main.post(onFinished) }
            WebView(ctx).apply {
                web[0] = this
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                addJavascriptInterface(bridge, "ipc")
                webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView, url: String) {
                        view.evaluateJavascript(SCRIPT, null)
                    }

                    override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                        if (request.isForMainFrame) {
                            bridge.fail(L.t("Couldn't reach openspeedtest.com. Check your connection, or use a self-hosted server."))
                        }
                    }
                }
                loadUrl(PUBLIC_URL)
                // Watchdog: cancelled from the app, or no result within 3 minutes.
                val tick = object : Runnable {
                    override fun run() {
                        when {
                            bridge.finished -> Unit
                            Native.speedExternalCancelled() -> main.post(onFinished)
                            System.currentTimeMillis() - started > 180_000 ->
                                bridge.fail(L.t("The public test didn't finish. Try again, or use a self-hosted server."))
                            else -> postDelayed(this, 1000)
                        }
                    }
                }
                watchdog[0] = tick
                postDelayed(tick, 1000)
            }
        },
    )
    DisposableEffect(Unit) {
        onDispose {
            web[0]?.apply {
                watchdog[0]?.let(::removeCallbacks)
                stopLoading()
                destroy()
            }
            web[0] = null
        }
    }
}
