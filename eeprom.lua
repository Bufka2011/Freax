-- eeprom: mediated EEPROM access (M2 compat).
-- First EEPROM found; same calls OpenOS flash uses.
local eeprom = {}

function eeprom.address() return freax.eepromAddr() end
function eeprom.get() return freax.eepromGet() end
function eeprom.set(data) return freax.eepromSet(data) end
function eeprom.getLabel() return freax.eepromLabel() end
function eeprom.setLabel(label) return freax.eepromSetLabel(label) end
function eeprom.getSize() return freax.eepromSize() end

return eeprom
