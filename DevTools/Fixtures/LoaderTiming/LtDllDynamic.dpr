library LtDllDynamic;

// DevTools\LoaderTimingProbe fixture. Loaded by LtHost.exe with LoadLibrary (-dll).
// Built by DevTools\build_loader_fixtures.bat; the probe verifies the resulting
// PE header itself (LoaderTimingProbe -pe) instead of trusting these directives.

{$IMAGEBASE $33000000}
{$DYNAMICBASE ON}

{$I LtDllBody.inc}
