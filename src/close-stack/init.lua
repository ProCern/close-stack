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
  -- Truthy map entries are pushed onto the stack, so #_stack covers them too;
  -- purely-falsy map entries are not resources and need no warning.
  if #self._stack > 0 then
    warn('close stack was garbage collected with items in it before it was closed!')
  end
end

function metatable:__newindex()
  error('You can not create entries in the close stack directly. Use the methods provided.')
end

-- Unwind the stack, causing closers to be invoked in reverse order.
--- @param stack any[]
--- @param index integer
--- @param err? any
local function unwind(stack, index, err)
  -- Check for the stack index first to speed up no-ops from pop_all.
  if not stack[index] then
    if err ~= nil then
      -- We re-raise any error inside the stack so that the closers see the
      -- error in their `__close` method and can behave accordingly.
      error(err)
    end
    return
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
  return unwind(stack, index + 16, err)
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
--- Because map entries are const once set (see below), a `map_set` is really an
--- append: the closeable is `push`ed onto the same ordered stack as everything
--- else, so it closes in the shared LIFO order at the point where it was set. The
--- map itself just indexes it by key for later lookup via `map_get`/`map_pairs`.
---
--- Entries are const: once a key holds a real (truthy) closeable you can not
--- reset or unset it, so an owned resource can never be silently dropped.
--- Attempting to do so raises an error. A falsy current value (`false`, or
--- absent) is not a real resource, so it may be freely overwritten. A `nil` or
--- `false` closeable stores nothing on the stack but is still recorded for
--- lookup/iteration, consistent with Lua ignoring them as to-be-closed values.
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
  return self:push(closeable)
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
--- @return fun(...: any): any, any, ...
function methods:map_pairs()
  return pairs(self._map)
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
  self._stack = {}
  self._map = {}
  return unwind(stack, 1, err)
end

--- Transfers the stack and map to a new close stack and returns it, leaving this
--- one empty.
--- @return close-stack.CloseStack
function methods:pop_all()
  local new <const> = setmetatable({
    _stack = self._stack,
    _map = self._map,
    map = false,
  }, metatable)
  new.map = make_map_proxy(new)

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

    -- bypass the __newindex guard and make sure the table is exactly the right size.
    map = false,
  }, metatable)
  self.map = make_map_proxy(self)

  return self
end

M.close_stack = M.new

return M
