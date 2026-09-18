-- io: global passthrough (M2 compat).
-- The kernel provides the io table; this exists so that
-- require("io") works the same way it does under OpenOS.
return io
