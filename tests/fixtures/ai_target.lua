local enabled = true
local  --[[ café ]]remoteValue = 2
local function remote(value)
  return value + remoteValue
end
return { remote = remote, value = remoteValue, enabled = enabled }
