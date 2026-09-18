-- component: unavailable under Freax (M2 compat stub).
-- Processes hold no ambient hardware authority; everything goes
-- through freax.* syscalls. This stub exists only to fail loudly
-- instead of with a bare "module not found".
error("component access denied under Freax isolation " ..
  "(use freax.* syscalls or require filesystem/shell/event instead)")
