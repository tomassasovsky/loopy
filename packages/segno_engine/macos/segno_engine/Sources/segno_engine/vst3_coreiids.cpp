// Forwarder TU (SPM macOS build) — compiles the vendored VST3 pluginterfaces
// IID definitions (IPluginFactory/IPluginFactory2/FUnknown/… class IIDs) so the
// VST3 scan backend can queryInterface for IPluginFactory2. This is the only
// VST3 SDK source needed for scanning — no base/public.sdk hosting layer.
#include "../../../../third_party/vst3sdk/pluginterfaces/base/coreiids.cpp"
