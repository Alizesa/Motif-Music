package com.alizesa.motif.lxprobe;

import com.alizesa.motif.lxprobe.IProbeResult;
import com.alizesa.motif.lxprobe.IFixtureCatalog;
import com.alizesa.motif.lxprobe.IScriptBroker;

oneway interface IProbe {
    void start(int fixture, String canary, int loopbackPort, IProbeResult result,
               IFixtureCatalog catalog);
    void stop();
    void startScript(String canary, int loopbackPort, IProbeResult result,
                     IScriptBroker broker);
}
