# v2 state machine

## Work and command states

```text
unbound -> bound -> quarantined -> bound
                     `-> parked (different account)

localCommitted -> sealed -> sending -> completed
                                  |-> sealed (lost response, exact retry)
                                  |-> quarantined (fence/epoch change)
                                  `-> conflictPending
conflictPending -> sealed(resolveDevice|resolveServer|cloneWork)
                 `-> parked (no user choice)
```

Required invariants:

1. local commit succeeds without a network call and retains the manuscript on
   every failure path;
2. at most one `conflictPending` exists per WorkID;
3. a sealed command is immutable after its first network byte;
4. a different AccountID cannot use, rebind, or disclose a work's command,
   object, title, or conflict;
5. a changed AccountFence never resumes an old command; it quarantines it and
   requires capabilities/bootstrap/replan;
6. `useServer` preserves a pre-adoption checkpoint, and `cloneWork` creates a
   new WorkID; no path rewinds a head in place;
7. active editor text is changed only at the existing safe document/IME/session
   boundary.

## Conflict choices

The resolver is closed to the three values `useDevice`, `useServer`, and
`keepBoth`. The UI must present the selected branch and a stable conflict ID,
and must not offer an implicit winner or “always choose” setting in v2.
