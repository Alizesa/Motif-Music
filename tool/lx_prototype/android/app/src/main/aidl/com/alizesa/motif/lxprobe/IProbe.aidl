package com.alizesa.motif.lxprobe;

import com.alizesa.motif.lxprobe.IProbeResult;

oneway interface IProbe {
    void start(int fixture, String canary, int loopbackPort, IProbeResult result);
    void stop();
}
