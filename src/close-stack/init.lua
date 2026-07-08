local callback_closer = require 'close-stack._callback-closer'

local M <const> = {}

--- @class close-stack.CloseStack
--- @operator len(): integer
--- @field private _stack any[]
local methods <const> = {}

--- @class close-stack.CloseStack
local metatable <const> = {__index = methods}

function metatable:__len()
  return #self._stack
end

function metatable:__gc()
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

--- Closes and empties the stack. If err is non-nil, it is taken to be the
--- error, and will be re-raised.
--- @param err? any
function methods:close(err)
  local stack <const> = self._stack
  self._stack = {}
  return unwind(stack, 1, err)
end

--- Transfers the stack to a new close stack and returns it, leaving this one empty.
--- @return close-stack.CloseStack
function methods:pop_all()
  local new <const> = setmetatable({
    _stack = self._stack,
  }, metatable)
  self._stack = {}
  return new
end

--- Create a new close stack.
--- @return close-stack.CloseStack
function M.new()
  return setmetatable({
    _stack = {},
  }, metatable)
end

M.close_stack = M.new

return M
