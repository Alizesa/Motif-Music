package com.alizesa.motif.lxprobe;

import com.alizesa.motif.lxprobe.IProbeResult;
import com.alizesa.motif.lxprobe.IFixtureCatalog;

oneway interface IProbe {
    void start(int fixture, String canary, int loopbackPort, IProbeResult result,
               IFixtureCatalog catalog);
    void stop();
}
