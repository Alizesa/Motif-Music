package com.alizesa.motif

import android.content.Intent
import com.alizesa.motif.library.SafLibraryScanner
import com.alizesa.motif.lx.LxFixtureBridge
import com.alizesa.motif.downloads.SafDownloadBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var libraryScanner: SafLibraryScanner? = null
    private var lxFixture: LxFixtureBridge? = null
    private var downloads: SafDownloadBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        downloads?.close()
        downloads = SafDownloadBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        libraryScanner?.close()
        libraryScanner = SafLibraryScanner(this, flutterEngine.dartExecutor.binaryMessenger)
        lxFixture?.close()
        if (BuildConfig.MOTIF_LX_FIXTURE) {
            lxFixture = LxFixtureBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        }
    }

    override fun onDestroy() {
        downloads?.close()
        downloads = null
        libraryScanner?.close()
        libraryScanner = null
        lxFixture?.close()
        lxFixture = null
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (downloads?.onActivityResult(requestCode, resultCode, data) == true) return
        if (lxFixture?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }
}
