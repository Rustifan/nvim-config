local enabled = true
local function localDef(value)
  return value * 2
end
local result = localDef(3)
return { enabled = enabled, result = result }
