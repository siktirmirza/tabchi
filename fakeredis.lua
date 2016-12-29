local unpack = table.unpack or unpack

--- Bit operations

local ok,bit
if _VERSION == "Lua 5.3" then
  bit = (load [[ return {
    band = function(x, y) return x & y end,
    bor = function(x, y) return x | y end,
    bxor = function(x, y) return x ~ y end,
    bnot = function(x) return ~x end,
    rshift = function(x, n) return x >> n end,
    lshift = function(x, n) return x << n end,
  } ]])()
else
  ok,bit = pcall(require,"bit")
  if not ok then bit = bit32 end
end

assert(type(bit) == "table", "module for bitops not found")

--- default sleep

local default_sleep
do
  local ok, mod = pcall(require, "socket")
  if ok and type(mod) == "table" then
    default_sleep = mod.sleep
  else
    default_sleep = function(n)
      local t0 = os.clock()
      while true do
        local delta = os.clock() - t0
        if (delta < 0) or (delta > n) then break end
      end
    end
  end
end

--- Helpers

local xdefv = function(ktype)
  if ktype == "list" then
    return {head = 0, tail = 0}
  elseif ktype == "zset" then
    return {
      list = {},
      set = {},
    }
  else return {} end
end

local xgetr = function(self, k, ktype)
  if self.data[k] then
    assert(
      (self.data[k].ktype == ktype),
      "ERR Operation against a key holding the wrong kind of value"
    )
    assert(self.data[k].value)
    return self.data[k].value
  else return xdefv(ktype) end
end

local xgetw = function(self, k, ktype)
  if self.data[k] and self.data[k].value then
    assert(
      (self.data[k].ktype == ktype),
      "ERR Operation against a key holding the wrong kind of value"
    )
  else
    self.data[k] = {ktype = ktype, value = xdefv(ktype)}
  end
  return self.data[k].value
end

local empty = function(self, k)
  local v, t = self.data[k].value, self.data[k].ktype
  if t == nil then
    return true
  elseif t == "string" then
    return not v[1]
  elseif (t == "hash") or (t == "set") then
    for _,_ in pairs(v) do return false end
    return true
  elseif t == "list" then
    return v.head == v.tail
  elseif t == "zset" then
    if #v.list == 0 then
      for _,_ in pairs(v.set) do error("incoherent") end
      return true
    else
      for _,_ in pairs(v.set) do return(false) end
      error("incoherent")
    end
  else error("unsupported") end
end

local cleanup = function(self, k)
  if empty(self, k) then self.data[k] = nil end
end

local is_integer = function(x)
  return (type(x) == "number") and (math.floor(x) == x)
end

local overflows = function(n)
  return (n > 2^53-1) or (n < -2^53+1)
end

local is_bounded_integer = function(x)
  return (is_integer(x) and (not overflows(x)))
end

local is_finite_number = function(x)
  return (type(x) == "number") and (x > -math.huge) and (x < math.huge)
end

local toint = function(x)
  if type(x) == "string" then x = tonumber(x) end
  return is_bounded_integer(x) and x or nil
end

local tofloat = function(x)
  if type(x) == "number" then return x end
  if type(x) ~= "string" then return nil end
  local r = tonumber(x)
  if r then return r end
  if x == "inf" or x == "+inf" then
    return math.huge
  elseif x == "-inf" then
    return -math.huge
  else return nil end
end

local tostr = function(x)
  if is_bounded_integer(x) then
    return string.format("%d", x)
  else return tostring(x) end
end

local char_bitcount = function(x)
  assert(
    (type(x) == "number") and
    (math.floor(x) == x) and
    (x >= 0) and (x < 256)
  )
  local n = 0
  while x ~= 0 do
    x = bit.band(x, x-1)
    n = n+1
  end
  return n
end

local chkarg = function(x)
  if type(x) == "number" then x = tostr(x) end
  assert(type(x) == "string")
  return x
end

local chkargs = function(n, ...)
  local arg = {...}
  assert(#arg == n)
  for i=1,n do arg[i] = chkarg(arg[i]) end
  return unpack(arg)
end

local getargs = function(...)
  local arg = {...}
  local n = #arg; assert(n > 0)
  for i=1,n do arg[i] = chkarg(arg[i]) end
  return arg
end

local getargs_as_map = function(...)
  local arg, r = getargs(...), {}
  assert(#arg%2 == 0)
  for i=1,#arg,2 do r[arg[i]] = arg[i+1] end
  return r
end

local chkargs_wrap = function(f, n)
  assert( (type(f) == "function") and (type(n) == "number") )
  return function(self, ...) return f(self, chkargs(n, ...)) end
end

local lset_to_list = function(s)
  local r = {}
  for v,_ in pairs(s) do r[#r+1] = v end
  return r
end

local nkeys = function(x)
  local r = 0
  for _,_ in pairs(x) do r = r + 1 end
  return r
end

--- Commands

-- keys

local del = function(self, ...)
  local arg = getargs(...)
  local r = 0
  for i=1,#arg do
    if self.data[arg[i]] then r = r + 1 end
    self.data[arg[i]] = nil
  end
  return r
end

local exists = function(self, k)
  return not not self.data[k]
end

local keys = function(self, pattern)
  assert(type(pattern) == "string")
  -- We want to convert the Redis pattern to a Lua pattern.
  -- Start by escaping dashes *outside* character classes.
  -- We also need to escape percents here.
  local t, p, n = {}, 1, #pattern
  local p1, p2
  while true do
    p1, p2 = pattern:find("%[.+%]", p)
    if p1 then
      if p1 > p then
        t[
