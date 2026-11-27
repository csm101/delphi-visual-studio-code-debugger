library LtDllStatic;

// DevTools\LoaderTimingProbe fixture. Statically imported by LtHost.exe.
// Built by DevTools\build_loader_fixtures.bat; the probe verifies the resulting
// PE header itself (LoaderTimingProbe -pe) instead of trusting these directives.

{$IMAGEBASE $32000000}
{$DYNAMICBASE ON}

{$I LtDllBody.inc}
