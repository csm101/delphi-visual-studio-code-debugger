This release focuses on **expression-evaluation correctness** — watches, hovers, and the evaluate box.

- **Same-named classes are now told apart deterministically.** When two classes in different units share a bare name (e.g. a nested `TFields` versus `Data.DB.TFields`), the debugger picks the right one from the object's real VMT instance size, so members, counts and values come from the correct class instead of a look-alike.
- **Property getters return the right kind and size.** A property's return type is resolved from its exact debug-info type id, so string, `Variant`, record and set getters are decoded correctly — no more a `Variant` shown as its raw type word, or a record read as a pointer.
- **A bare function that needs arguments is refused, not mis-called.** Typing `SomeFunc` where `SomeFunc` takes parameters now reports `requires N argument(s)` instead of returning a garbage value from an unintended zero-argument call.
- **Set, record and floating-point returns** are decoded correctly in both call paths, and string- and `Variant`-alias types are classified by kind rather than by name.
- **New `read_memory` / `write_memory` MCP tools** for inspecting and patching debuggee memory.

All changes are covered by the automated suite (940+ tests).
