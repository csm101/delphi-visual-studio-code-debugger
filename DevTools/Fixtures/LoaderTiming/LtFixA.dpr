library LtFixA;

// DevTools\LoaderTimingProbe fixture. Fixed image base, no dynamic base: loads at its preferred base.
// Built by DevTools\build_loader_fixtures.bat; the probe verifies the resulting
// PE header itself (LoaderTimingProbe -pe) instead of trusting these directives.

{$IMAGEBASE $31000000}
{$DYNAMICBASE OFF}

{$I LtDllBody.inc}
