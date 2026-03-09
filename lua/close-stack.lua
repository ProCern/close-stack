local M <const> = {}

local metatable <const> = {__index = {}}

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
local function unwind(stack, index, err)
  -- Check for the stack index first to speed up no-ops from pop_all.
  if not stack[index] then
    if err ~= nil then
      error(err)
    else
      return
    end
  end

  -- Unrolled to 8 closers per stack frame to increase effective capacity.
  local closer_0 <close> = stack[index]
  local closer_1 <close> = stack[index + 1]
  local closer_2 <close> = stack[index + 2]
  local closer_3 <close> = stack[index + 3]
  local closer_4 <close> = stack[index + 4]
  local closer_5 <close> = stack[index + 5]
  local closer_6 <close> = stack[index + 6]
  local closer_7 <close> = stack[index + 7]
  unwind(stack, index + 8, err)
end


function metatable:__close(err)
  return self:close(err)
end

-- Push a to-be-closed value into the stack and return it.
function metatable.__index:push(closeable)
  if closeable then
    local stack <const> = self._stack
    stack[#stack+1] = closeable
  end
  return closeable
end

local callback_metatable <const> = {}
function callback_metatable:__close()
  return self.fun(table.unpack(self.args, 1, self.args.n))
end

-- Push a callback function to the stack and return it. This will be called
-- in its usual spot in line. This does not get the error value input like
-- closeables do.
function metatable.__index:callback(fun, ...)
  local closeable <const> = setmetatable({
    fun = fun,
    args = table.pack(...),
  }, callback_metatable)
  self:push(closeable)
  return fun
end

-- If err is non-nil, it is taken to be the error, and will be re-raised.
function metatable.__index:close(err)
  local stack <const> = self._stack
  self._stack = {}
  unwind(stack, 1, err)
end

-- Transfers the stack to a new callback stack and returns it, leaving this one empty.
function metatable.__index:pop_all()
  local stack <const> = self._stack
  self._stack = {}
  return setmetatable({
    _stack = stack,
  }, metatable)
end

function M.close_stack()
  return setmetatable({
    _stack = {},
  }, metatable)
end

return M
