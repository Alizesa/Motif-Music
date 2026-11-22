package com.alizesa.motif

import com.alizesa.motif.library.SafLibraryScanner
import com.alizesa.motif.lx.LxFixtureBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var libraryScanner: SafLibraryScanner? = null
    private var lxFixture: LxFixtureBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        libraryScanner?.close()
        libraryScanner = SafLibraryScanner(this, flutterEngine.dartExecutor.binaryMessenger)
        lxFixture?.close()
        if (BuildConfig.MOTIF_LX_FIXTURE) {
            lxFixture = LxFixtureBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        }
    }

    override fun onDestroy() {
        libraryScanner?.close()
        libraryScanner = null
        lxFixture?.close()
        lxFixture = null
        super.onDestroy()
    }
}
