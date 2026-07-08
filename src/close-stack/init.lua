local callback_closer = require 'close-stack._callback-closer'
local make_map_proxy = require 'close-stack._map-proxy'

local M <const> = {}

--- @class close-stack.CloseStack
--- @operator len(): integer
--- @field private _stack any[]
--- @field private _map {[any]: any}
--- @field map {[any]: any} Public table-like proxy over the keyed map. Index, assign, `#`, and `pairs` all route through the `map_set`/`map_get`/`map_len`/`map_pairs` methods, so it inherits their const-once-set guarantee.
local methods <const> = {}

--- @class close-stack.CloseStack
local metatable <const> = {__index = methods}

function metatable:__len()
  return #self._stack
end

function metatable:__gc()
  if #self._stack > 0 or next(self._map) ~= nil then
    warn('close stack was garbage collected with items in it before it was closed!')
  end
end

function metatable:__newindex()
  error('You can not create entries in the close stack directly. Use the methods provided.')
end

-- Advance one entry through a map. Given a key (which must be non-nil), returns
-- the value stored at that key and the following key (or nil when the iteration
-- is exhausted). A nil key short-circuits to (nil, nil) so it is safe to call on
-- a slot that has already run off the end of the map.
--- @param map {[any]: any}
--- @param key any
--- @return any value, any next_key
local function step(map, key)
  if key == nil then
    return nil, nil
  end
  return map[key], next(map, key)
end

-- Unwind an unordered map of closeables, invoking each value's closer. Unlike
-- the ordered stack there is no meaningful index arithmetic, so we walk the map
-- with `next`, threading the current key through the recursion. Because the map
-- is unordered, the closing order among its values is unspecified.
--- @param map {[any]: any}
--- @param key any The next key to close, or nil when the map is exhausted.
--- @param err? any
local function unwind_map(map, key, err)
  -- The deepest layer: no more keys to close, so re-raise any pending error so
  -- that it propagates back up through every closer we have opened.
  if key == nil then
    if err ~= nil then
      -- We re-raise any error inside the map so that the closers see the
      -- error in their `__close` method and can behave accordingly.
      error(err)
    end
    return
  end

  -- Unrolled to 16 closers per stack frame, mirroring `unwind`. Each `step`
  -- binds one value to a `<close>` local and advances to the following key; once
  -- the map is exhausted the remaining slots receive nil (which Lua ignores).
  local value_0 <close>, key_1 = step(map, key)
  local value_1 <close>, key_2 = step(map, key_1)
  local value_2 <close>, key_3 = step(map, key_2)
  local value_3 <close>, key_4 = step(map, key_3)
  local value_4 <close>, key_5 = step(map, key_4)
  local value_5 <close>, key_6 = step(map, key_5)
  local value_6 <close>, key_7 = step(map, key_6)
  local value_7 <close>, key_8 = step(map, key_7)
  local value_8 <close>, key_9 = step(map, key_8)
  local value_9 <close>, key_10 = step(map, key_9)
  local value_10 <close>, key_11 = step(map, key_10)
  local value_11 <close>, key_12 = step(map, key_11)
  local value_12 <close>, key_13 = step(map, key_12)
  local value_13 <close>, key_14 = step(map, key_13)
  local value_14 <close>, key_15 = step(map, key_14)
  local value_15 <close>, key_16 = step(map, key_15)
  return unwind_map(map, key_16, err)
end

-- Unwind the stack, causing closers to be invoked in reverse order.
--- @param stack any[]
--- @param index integer
--- @param map {[any]: any}
--- @param err? any
local function unwind(stack, index, map, err)
  -- Check for the stack index first to speed up no-ops from pop_all.
  if not stack[index] then
    -- The deepest layer of the ordered stack hands off to the unordered map,
    -- which also takes care of re-raising any pending error.
    return unwind_map(map, next(map), err)
  end

  -- Unrolled to 16 closers per stack frame to increase effective capacity and
  -- performance.
  local closer_0 <close> = stack[index]
  local closer_1 <close> = stack[index + 1]
  local closer_2 <close> = stack[index + 2]
  local closer_3 <close> = stack[index + 3]
  local closer_4 <close> = stack[index + 4]
  local closer_5 <close> = stack[index + 5]
  local closer_6 <close> = stack[index + 6]
  local closer_7 <close> = stack[index + 7]
  local closer_8 <close> = stack[index + 8]
  local closer_9 <close> = stack[index + 9]
  local closer_10 <close> = stack[index + 10]
  local closer_11 <close> = stack[index + 11]
  local closer_12 <close> = stack[index + 12]
  local closer_13 <close> = stack[index + 13]
  local closer_14 <close> = stack[index + 14]
  local closer_15 <close> = stack[index + 15]
  return unwind(stack, index + 16, map, err)
end

--- @param err? any
function metatable:__close(err)
  return self:close(err)
end

--- Push a to-be-closed value into the stack and return it.
--- @param closeable any
function methods:push(closeable)
  if closeable then
    local stack <const> = self._stack
    stack[#stack+1] = closeable
  end
  return closeable
end

--- Push a callback function to the stack and return it. This will be called
--- in its usual spot in line. This does not get the error value input like
--- closeables do, and has no way of inspecting the error value.
--- 
--- The input function is returned.
--- 
--- @generic F: fun(...: any)
--- @param fun F
--- @param ... any
--- @return F
function methods:callback(fun, ...)
  self:push(callback_closer(fun, ...))
  return fun
end

--- Store a closeable in the keyed map under `key` and return it.
---
--- Entries are effectively const, mirroring the `<close>` values they become:
--- once a key holds a real (truthy) closeable you can not reset or unset it, so
--- an owned resource can never be silently dropped. Attempting to do so raises an
--- error. A falsy current value (`false`, or absent) is not a real resource, so
--- it may be freely overwritten. A `nil` or `false` closeable on an empty key is
--- a harmless no-op; `false` values are stored as-is (and so show up in
--- `map_pairs`), consistent with Lua ignoring them as to-be-closed values.
---
--- @param key any
--- @param closeable? any
--- @return any closeable
function methods:map_set(key, closeable)
  if key == nil then
    error('map key can not be nil')
  end
  local map <const> = self._map
  if map[key] then
    error('You can not overwrite an existing map entry. Map entries are const once set.')
  end
  map[key] = closeable
  return closeable
end

--- Get the closeable stored under `key`, or nil if there is none.
--- @param key any
--- @return any closeable
function methods:map_get(key)
  return self._map[key]
end

--- Return a stateful iterator over the map, yielding (key, closeable) pairs. The
--- underlying table is not exposed, so it can not be mutated through the
--- iterator.
--- @return fun(): any, any
function methods:map_pairs()
  local map <const> = self._map
  local key
  return function()
    local value
    key, value = next(map, key)
    return key, value
  end
end

--- Return the `#` length of the underlying map table. As with any Lua table,
--- this is only a meaningful count for sequence (1..n integer) keys; for
--- arbitrary keys check membership and size the way you would on a plain table.
--- @return integer
function methods:map_len()
  return #self._map
end

--- Closes and empties the stack. If err is non-nil, it is taken to be the
--- error, and will be re-raised.
--- @param err? any
function methods:close(err)
  local stack <const> = self._stack
  local map <const> = self._map
  self._stack = {}
  self._map = {}
  return unwind(stack, 1, map, err)
end

--- Transfers the stack and map to a new close stack and returns it, leaving this
--- one empty.
--- @return close-stack.CloseStack
function methods:pop_all()
  local new <const> = setmetatable({
    _stack = self._stack,
    _map = self._map,
  }, metatable)
  rawset(new, 'map', make_map_proxy(new))
  self._stack = {}
  self._map = {}
  return new
end

--- Create a new close stack.
--- @return close-stack.CloseStack
function M.new()
  local self <const> = setmetatable({
    _stack = {},
    _map = {},
  }, metatable)
  -- rawset bypasses the __newindex guard; the proxy is trusted internal state.
  rawset(self, 'map', make_map_proxy(self))
  return self
end

M.close_stack = M.new

return M
