--- @class close-stack.CallbackCloser
--- @field private _fun fun(...: any)
--- @field private _args {[integer]: any, n: integer}
local metatable <const> = {}

function metatable:__close()
  return self._fun(table.unpack(self._args, 1, self._args.n))
end

--- @param fun fun(...: any)
--- @param ... any
--- @return close-stack.CallbackCloser
return function(fun, ...)
  return setmetatable({
    _fun = fun,
    _args = table.pack(...),
  }, metatable)
end
