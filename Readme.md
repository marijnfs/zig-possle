# Proof of Space Search with Logarithmic Embargo (PoSS-LE)

# Todo:
x Setup Experiment struct

# Backlog:
x Difficulty adjustment
- Block verification by rebuilding the submitted block and comparing, don't accept blocks with unverified parents (but allow for later verification)
  - This can be done by storing it unverified and make a synching mechanism
  - When verified blocks get added, check for unverfied with there parents
- Block syncing that can return multiple blocks
- Use software posit implementation for deterministic float calculation
- find segfault that sometimes happens, perhaps db map access?
- cleanup public flag node usage
- Add bootstrap when node doesn't get pings for a while and everything counts as non-active
- make sure no duplicate fingers in sync
- Early sync (keep track of nearest embargo to avoid message bursts)
- Manage all memory, there are memory locally allocated objects that are not released
