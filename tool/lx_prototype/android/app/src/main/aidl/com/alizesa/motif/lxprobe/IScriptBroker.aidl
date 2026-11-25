package com.alizesa.motif.lxprobe;

interface IScriptBroker {
    byte[] part(int index);
    byte[] request(in byte[] message);
    void publish(in byte[] message);
}
