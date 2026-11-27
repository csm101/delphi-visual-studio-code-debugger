library LtFixB;

// DevTools\LoaderTimingProbe fixture. Same fixed image base as LtFixA, no dynamic base: loaded second, it must move.
// Built by DevTools\build_loader_fixtures.bat; the probe verifies the resulting
// PE header itself (LoaderTimingProbe -pe) instead of trusting these directives.

{$IMAGEBASE $31000000}
{$DYNAMICBASE OFF}

{$I LtDllBody.inc}
