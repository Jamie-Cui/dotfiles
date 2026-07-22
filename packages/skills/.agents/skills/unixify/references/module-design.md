# Module Design

Read this reference when Unixifying modules, APIs, adapters, service boundaries, or test seams.

## Vocabulary

- **Module**: anything with an interface and an implementation, from a function to a process or service.
- **Interface**: everything a caller must know to use the module correctly, including invariants, ordering, failures, configuration, and resource behavior.
- **Depth**: the leverage an interface provides—the useful behavior callers gain per fact they must learn.
- **Seam**: a place where behavior can change without editing the caller.
- **Locality**: the degree to which related knowledge, change, bugs, and verification stay in one place.

## Shape deep tools

- Keep the public interface smaller than the complexity it owns. Internal helpers may be numerous; callers should not coordinate them.
- Apply the **deletion test** to a suspected module or layer. If deleting it makes complexity reappear across callers, it provides locality. If complexity simply vanishes or callers already know its internals, remove or deepen it.
- Treat the interface as the test surface. Verify observable behavior through the same seam callers use; keep internal seams private.
- Require a real reason for replaceability. Two implementations, a production/test adapter pair, independent ownership, privilege, lifecycle, failure, or scaling can justify a seam; hypothetical future variation cannot.
- Separate policy from mechanism when they have different owners, callers, or rates of change. Keep them together when the separation only creates pass-through coordination.

## Deepen safely

1. Map the current callers, dependencies, invariants, errors, and tests.
2. Identify coordination or knowledge duplicated across callers and move it behind one interface.
3. Collapse pass-through layers and keep necessary adapters at the seam they serve.
4. Preserve the public contract unless the user accepts a migration or breaking change.
5. Test the resulting behavior at the external interface; retain lower-level tests only when they protect an independent internal contract.

## Design it twice

For a hard-to-reverse public interface with multiple credible shapes, produce two or three materially different designs before choosing. Compare them by depth, locality, correct-use difficulty, compatibility, failure surface, and resource behavior. Recommend one design or a deliberate hybrid; avoid presenting an unranked menu.
