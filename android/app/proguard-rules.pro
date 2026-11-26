# JNI: the native library binds to these names.
-keep class com.blainemiller.blip.core.Native { native <methods>; }
# The public speed test's page calls this through addJavascriptInterface.
-keepclassmembers class com.blainemiller.blip.speed.PublicSpeedBridge {
    @android.webkit.JavascriptInterface <methods>;
}
