-- Private key under which a map proxy stashes a backreference to its owning
-- close stack. It is a module-local table, so no external code can name it (the
-- worst it leaks is the owning stack itself, via a raw `next(proxy)`, which the
-- caller already holds anyway).
local stack_key <const> = {}

-- Metatable for the public `map` proxy: a thin table-like view over the map
-- methods of its owning close stack. Every access routes through those methods,
-- so the proxy inherits the const-once-set guarantee — you can not overwrite or
-- unset an owned closeable through it either.
local metatable <const> = {__mode = 'v'}

function metatable:__index(key)
  return self[stack_key]:map_get(key)
end

function metatable:__newindex(key, value)
  self[stack_key]:map_set(key, value)
end

function metatable:__len()
  return self[stack_key]:map_len()
end

function metatable:__pairs()
  return self[stack_key]:map_pairs()
end

-- Build the public map proxy bound to `stack`.
--- @param stack close-stack.CloseStack
--- @return {[any]: any}
return function(stack)
  return setmetatable({[stack_key] = stack}, metatable)
end
