library LtDynB;

// DevTools\LoaderTimingProbe fixture. Same preferred base as LtDynA, dynamic base.
// Built by DevTools\build_loader_fixtures.bat; the probe verifies the resulting
// PE header itself (LoaderTimingProbe -pe) instead of trusting these directives.

{$IMAGEBASE $35000000}
{$DYNAMICBASE ON}

{$I LtDllBody.inc}
