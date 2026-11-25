-keepclassmembers class ** implements com.alizesa.motif.lxprobe.IFixtureCatalog {
    int query(int);
}
-keepclassmembers class ** implements com.alizesa.motif.lxprobe.IScriptBroker {
    byte[] request(byte[]);
}
-keepclasseswithmembernames class com.alizesa.motif.lxprobe.ProbeService {
    native <methods>;
}
