-- computer: requireable shim over the process-global computer table.
-- The kernel injects `computer` (info-only subset + beep/shutdown) into
-- every process env, but require("computer") has no lib file behind it,
-- which broke require("note") (note.lua requires computer for beeps).
-- This module just re-exports the global. No hardware authority added:
-- whatever the sandbox exposes is all callers get.
return computer
