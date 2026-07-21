unit TestTargetConflictSink;

// Shared keep-alive sink for the conflict units, so RunConflictN locals stay
// live at their breakpoint without depending on the main program's GSink.

interface

var
  ConflictSink: Integer;

implementation

end.
