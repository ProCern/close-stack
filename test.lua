local close_stack = require('close-stack')

local passed, failed = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write(string.format("  PASS  %s\n", name))
  else
    failed = failed + 1
    io.write(string.format("  FAIL  %s\n        %s\n", name, tostring(err)))
  end
end

local function assert_eq(got, expected, msg)
  if got ~= expected then
    error(string.format("%s: expected %s, got %s",
      msg or "assert_eq", tostring(expected), tostring(got)), 2)
  end
end

-- Closeable that records when closed and what error it received.
local function recorder(log, name)
  return setmetatable({}, {
    __close = function(_, err)
      log[#log + 1] = { name = name, err = err }
    end,
  })
end

-- Closeable that records and then throws.
local function thrower(log, name, throw_val)
  return setmetatable({}, {
    __close = function(_, err)
      log[#log + 1] = { name = name, err = err }
      error(throw_val)
    end,
  })
end

----------------------------------------------------------------------
print("--- Close order ---")

test("closeables fire in LIFO order", function()
  local log = {}
  local s <close> = close_stack.new()
  s:push(recorder(log, "first"))
  s:push(recorder(log, "second"))
  s:push(recorder(log, "third"))
  s:close()
  assert_eq(#log, 3)
  assert_eq(log[1].name, "third")
  assert_eq(log[2].name, "second")
  assert_eq(log[3].name, "first")
end)

test("callbacks fire in LIFO order", function()
  local log = {}
  local s <close> = close_stack.new()
  s:callback(function() log[#log + 1] = "first" end)
  s:callback(function() log[#log + 1] = "second" end)
  s:callback(function() log[#log + 1] = "third" end)
  s:close()
  assert_eq(#log, 3)
  assert_eq(log[1], "third")
  assert_eq(log[2], "second")
  assert_eq(log[3], "first")
end)

test("mixed closeables and callbacks fire in LIFO order", function()
  local log = {}
  local s <close> = close_stack.new()
  s:push(recorder(log, "closer-1"))
  s:callback(function() log[#log + 1] = { name = "callback-2" } end)
  s:push(recorder(log, "closer-3"))
  s:close()
  assert_eq(#log, 3)
  assert_eq(log[1].name, "closer-3")
  assert_eq(log[2].name, "callback-2")
  assert_eq(log[3].name, "closer-1")
end)

----------------------------------------------------------------------
print("\n--- Error unwinding ---")

test("all closers fire on error unwinding", function()
  local log = {}
  local sentinel = {}
  local ok, err = pcall(function()
    local s <close> = close_stack.new()
    s:push(recorder(log, "A"))
    s:push(recorder(log, "B"))
    s:push(recorder(log, "C"))
    s:close(sentinel)
  end)
  assert_eq(ok, false)
  assert_eq(err, sentinel)
  assert_eq(#log, 3)
  assert_eq(log[1].name, "C")
  assert_eq(log[2].name, "B")
  assert_eq(log[3].name, "A")
end)

test("all callbacks fire on error unwinding", function()
  local log = {}
  local sentinel = {}
  local ok, err = pcall(function()
    local s <close> = close_stack.new()
    s:callback(function() log[#log + 1] = "A" end)
    s:callback(function() log[#log + 1] = "B" end)
    s:close(sentinel)
  end)
  assert_eq(ok, false)
  assert_eq(err, sentinel)
  assert_eq(#log, 2)
  assert_eq(log[1], "B")
  assert_eq(log[2], "A")
end)

test("closers receive the error value on error unwinding (sentinel table)", function()
  local log = {}
  local sentinel = {}
  pcall(function()
    local s <close> = close_stack.new()
    s:push(recorder(log, "A"))
    s:push(recorder(log, "B"))
    s:push(recorder(log, "C"))
    s:close(sentinel)
  end)
  for _, entry in ipairs(log) do
    assert_eq(entry.err, sentinel,
      string.format("closer %s should see sentinel", entry.name))
  end
end)

test("closers receive nil on normal close", function()
  local log = {}
  local s <close> = close_stack.new()
  s:push(recorder(log, "A"))
  s:push(recorder(log, "B"))
  s:close()
  for _, entry in ipairs(log) do
    assert_eq(entry.err, nil,
      string.format("closer %s should see nil", entry.name))
  end
end)

----------------------------------------------------------------------
print("\n--- Error chaining ---")

test("closer error during normal close propagates to remaining closers", function()
  local log = {}
  local thrown = {}
  local ok, err = pcall(function()
    local s <close> = close_stack.new()
    s:push(recorder(log, "A"))
    s:push(recorder(log, "B"))
    s:push(thrower(log, "C", thrown))
    s:close()
  end)
  assert_eq(ok, false)
  assert_eq(err, thrown)
  -- C fires first with no error, then throws
  assert_eq(log[1].name, "C")
  assert_eq(log[1].err, nil)
  -- B and A see the thrown error
  assert_eq(log[2].name, "B")
  assert_eq(log[2].err, thrown)
  assert_eq(log[3].name, "A")
  assert_eq(log[3].err, thrown)
end)

test("middle closer error propagates to earlier-pushed closers only", function()
  local log = {}
  local thrown = {}
  local ok, err = pcall(function()
    local s <close> = close_stack.new()
    s:push(recorder(log, "A"))
    s:push(thrower(log, "B", thrown))
    s:push(recorder(log, "C"))
    s:close()
  end)
  assert_eq(ok, false)
  assert_eq(err, thrown)
  -- C fires first with nil (before B throws)
  assert_eq(log[1].name, "C")
  assert_eq(log[1].err, nil)
  -- B fires next with nil, then throws
  assert_eq(log[2].name, "B")
  assert_eq(log[2].err, nil)
  -- A sees B's thrown error
  assert_eq(log[3].name, "A")
  assert_eq(log[3].err, thrown)
end)

-- When a closer throws during error unwinding, the new error replaces the
-- original as the propagating error.
warn("@off")
test("closer error during error close replaces the original", function()
  local log = {}
  local original = {}
  local replacement = {}
  local ok, err = pcall(function()
    local s <close> = close_stack.new()
    s:push(recorder(log, "A"))
    s:push(thrower(log, "C", replacement))
    s:close(original)
  end)
  assert_eq(ok, false)
  assert_eq(err, replacement)
  -- C fires with original error, then throws replacement
  assert_eq(log[1].name, "C")
  assert_eq(log[1].err, original)
  -- A sees the replacement error
  assert_eq(log[2].name, "A")
  assert_eq(log[2].err, replacement)
end)
warn("@on")

test("callback error propagates to remaining closers", function()
  local log = {}
  local thrown = {}
  local ok, err = pcall(function()
    local s <close> = close_stack.new()
    s:push(recorder(log, "A"))
    s:callback(function() error(thrown) end)
    s:push(recorder(log, "C"))
    s:close()
  end)
  assert_eq(ok, false)
  -- C fires first with nil
  assert_eq(log[1].name, "C")
  assert_eq(log[1].err, nil)
  -- callback threw; A sees the error
  assert_eq(log[2].name, "A")
  assert_eq(log[2].err, thrown)
end)

----------------------------------------------------------------------
print("\n--- push and callback ---")

test("push returns the closeable", function()
  local s <close> = close_stack.new()
  local obj = recorder({}, "x")
  assert_eq(s:push(obj), obj)
  s:close()
end)

test("push(nil) returns nil and does not add to stack", function()
  local s <close> = close_stack.new()
  assert_eq(s:push(nil), nil)
  assert_eq(#s, 0)
  s:close()
end)

test("push(false) returns false and does not add to stack", function()
  local s <close> = close_stack.new()
  assert_eq(s:push(false), false)
  assert_eq(#s, 0)
  s:close()
end)

test("callback returns the function", function()
  local s <close> = close_stack.new()
  local fn = function() end
  assert_eq(s:callback(fn), fn)
  s:close()
end)

test("callback passes stored arguments on close", function()
  local captured
  local s <close> = close_stack.new()
  s:callback(function(a, b, c)
    captured = { a, b, c }
  end, 1, "two", 3)
  s:close()
  assert_eq(captured[1], 1)
  assert_eq(captured[2], "two")
  assert_eq(captured[3], 3)
end)

test("callback preserves nil holes in arguments", function()
  local n
  local s <close> = close_stack.new()
  s:callback(function(...)
    n = select('#', ...)
  end, nil, nil, 3)
  s:close()
  assert_eq(n, 3)
end)

----------------------------------------------------------------------
print("\n--- Large batch ---")

test("100 closeables close in LIFO order", function()
  local log = {}
  local s <close> = close_stack.new()
  for i = 1, 100 do
    s:push(recorder(log, i))
  end
  s:close()
  assert_eq(#log, 100)
  for i = 1, 100 do
    assert_eq(log[i].name, 101 - i,
      string.format("position %d should be closer %d", i, 101 - i))
  end
end)

test("100 closeables all receive error on error unwinding", function()
  local log = {}
  local sentinel = {}
  pcall(function()
    local s <close> = close_stack.new()
    for i = 1, 100 do
      s:push(recorder(log, i))
    end
    s:close(sentinel)
  end)
  assert_eq(#log, 100)
  for i = 1, 100 do
    assert_eq(log[i].err, sentinel,
      string.format("closer %d should see sentinel", log[i].name))
  end
end)

test("100 items with a thrower mid-batch propagates correctly", function()
  local log = {}
  local thrown = {}
  local ok, err = pcall(function()
    local s <close> = close_stack.new()
    for i = 1, 50 do
      s:push(recorder(log, i))
    end
    s:push(thrower(log, "thrower", thrown))
    for i = 52, 100 do
      s:push(recorder(log, i))
    end
    s:close()
  end)
  assert_eq(ok, false)
  assert_eq(err, thrown)
  assert_eq(#log, 100)
  -- Items 52-100 fired before the thrower, should see nil
  for i = 1, 49 do
    assert_eq(log[i].err, nil,
      string.format("closer %s (before thrower) should see nil", tostring(log[i].name)))
  end
  -- The thrower itself sees nil
  assert_eq(log[50].name, "thrower")
  assert_eq(log[50].err, nil)
  -- Items 1-50 fired after the thrower, should see thrown
  for i = 51, 100 do
    assert_eq(log[i].err, thrown,
      string.format("closer %s (after thrower) should see thrown", tostring(log[i].name)))
  end
end)

----------------------------------------------------------------------
print("\n--- __len ---")

test("__len tracks pushes, callbacks, map_set, and close", function()
  local s <close> = close_stack.new()
  assert_eq(#s, 0)
  s:push(recorder({}, "a"))
  assert_eq(#s, 1)
  s:push(recorder({}, "b"))
  assert_eq(#s, 2)
  s:callback(function() end)
  assert_eq(#s, 3)
  -- map_set is an append onto the stack, so a truthy entry counts toward #s...
  s:map_set("k", recorder({}, "c"))
  assert_eq(#s, 4)
  -- ...but a falsy map entry pushes nothing.
  s:map_set("empty", false)
  assert_eq(#s, 4)
  s:close()
  assert_eq(#s, 0)
end)

----------------------------------------------------------------------
print("\n--- __newindex ---")

test("direct assignment to close stack errors", function()
  local s <close> = close_stack.new()
  local ok, err = pcall(function() s.foo = "bar" end)
  assert_eq(ok, false)
  assert(tostring(err):find("can not create entries"),
    "expected __newindex error message")
  s:close()
end)

----------------------------------------------------------------------
print("\n--- Empty and double close ---")

test("closing empty stack is a no-op", function()
  local s <close> = close_stack.new()
  s:close() -- should not error
end)

test("closing empty stack with error re-raises it", function()
  local sentinel = {}
  local ok, err = pcall(function()
    local s <close> = close_stack.new()
    s:close(sentinel)
  end)
  assert_eq(ok, false)
  assert_eq(err, sentinel)
end)

test("second close is a no-op", function()
  local log = {}
  local s <close> = close_stack.new()
  s:push(recorder(log, "A"))
  s:close()
  assert_eq(#log, 1)
  s:close()
  assert_eq(#log, 1) -- not called again
end)

test("manual close before <close> scope exit prevents double invocation", function()
  local log = {}
  do
    local s <close> = close_stack.new()
    s:push(recorder(log, "A"))
    s:close()
    assert_eq(#log, 1)
  end
  assert_eq(#log, 1) -- scope exit found empty stack
end)

----------------------------------------------------------------------
print("\n--- pop_all ---")

test("pop_all transfers items to new stack", function()
  local log = {}
  local s <close> = close_stack.new()
  s:push(recorder(log, "A"))
  s:push(recorder(log, "B"))
  local s2 = s:pop_all()
  assert_eq(#s, 0)
  assert_eq(#s2, 2)
  s2:close()
  assert_eq(#log, 2)
  assert_eq(log[1].name, "B")
  assert_eq(log[2].name, "A")
end)

test("pop_all leaves original empty", function()
  local log = {}
  local s <close> = close_stack.new()
  s:push(recorder(log, "A"))
  local s2 = s:pop_all()
  s:close()
  assert_eq(#log, 0) -- original has nothing to close
  s2:close() -- clean up
end)

test("pop_all result works as <close>", function()
  local log = {}
  do
    local s2 <close> = (function()
      local s <close> = close_stack.new()
      s:push(recorder(log, "A"))
      s:push(recorder(log, "B"))
      return s:pop_all()
    end)()
    assert_eq(#log, 0)
  end
  assert_eq(#log, 2)
  assert_eq(log[1].name, "B")
  assert_eq(log[2].name, "A")
end)

test("pop_all result works as <close>", function()
  local log = {}
  do
    local s <close> = close_stack.new()
    s:push(recorder(log, "A"))
    s:push(recorder(log, "B"))
    local s2 <close> = s:pop_all()
    assert_eq(#s, 0)
  end
  assert_eq(#log, 2)
  assert_eq(log[1].name, "B")
  assert_eq(log[2].name, "A")
end)

test("pop_all result propagates error on error exit", function()
  local log = {}
  local sentinel = {}
  local ok, err = pcall(function()
    local s <close> = close_stack.new()
    s:push(recorder(log, "A"))
    s:push(recorder(log, "B"))
    local s2 <close> = s:pop_all()
    error(sentinel)
  end)
  assert_eq(ok, false)
  assert_eq(err, sentinel)
  assert_eq(#log, 2)
  assert_eq(log[1].err, sentinel)
  assert_eq(log[2].err, sentinel)
end)

test("original stack can be reused after pop_all", function()
  local log = {}
  local s <close> = close_stack.new()
  s:push(recorder(log, "old"))
  local s2 = s:pop_all()
  s:push(recorder(log, "new"))
  s:close()
  s2:close()
  assert_eq(#log, 2)
  -- "new" was on s (closed first), "old" was on s2 (closed second)
  assert_eq(log[1].name, "new")
  assert_eq(log[2].name, "old")
end)

----------------------------------------------------------------------
print("\n--- map ---")

-- Collect all (key, value) pairs from map_pairs into a plain table keyed by key.
local function collect_pairs(s)
  local out = {}
  for k, v in s:map_pairs() do
    out[k] = v
  end
  return out
end

test("new stack has an empty map", function()
  local s <close> = close_stack.new()
  assert_eq(s:map_len(), 0)
  assert_eq(next(collect_pairs(s)), nil)
  s:close()
end)

test("map values are closed on close", function()
  local log = {}
  local s <close> = close_stack.new()
  s:map_set("a", recorder(log, "a"))
  s:map_set(42, recorder(log, "b"))
  s:map_set(recorder, recorder(log, "c"))
  s:close()
  assert_eq(#log, 3)
  -- order is unspecified, so just check that every value fired.
  local seen = {}
  for _, entry in ipairs(log) do seen[entry.name] = true end
  assert(seen.a and seen.b and seen.c, "all map values should be closed")
end)

test("map_set returns the closeable", function()
  local s <close> = close_stack.new()
  local obj = recorder({}, "x")
  assert_eq(s:map_set("k", obj), obj)
  s:close()
end)

test("map_get returns the stored closeable, or nil when absent", function()
  local s <close> = close_stack.new()
  local obj = recorder({}, "x")
  s:map_set("k", obj)
  assert_eq(s:map_get("k"), obj)
  assert_eq(s:map_get("missing"), nil)
  s:close()
end)

test("map_pairs yields the stored key/closeable pairs", function()
  local s <close> = close_stack.new()
  local a, b = recorder({}, "a"), recorder({}, "b")
  s:map_set("x", a)
  s:map_set("y", b)
  local got = collect_pairs(s)
  assert_eq(got.x, a)
  assert_eq(got.y, b)
  local n = 0
  for _ in pairs(got) do n = n + 1 end
  assert_eq(n, 2)
  s:close()
end)

test("map_set errors when overwriting a truthy entry", function()
  local s <close> = close_stack.new()
  s:map_set("k", recorder({}, "a"))
  local ok, err = pcall(function() s:map_set("k", recorder({}, "b")) end)
  assert_eq(ok, false)
  assert(tostring(err):find("overwrite an existing map entry"),
    "expected overwrite error message")
  s:close()
end)

test("map_set errors when unsetting a truthy entry with nil", function()
  local s <close> = close_stack.new()
  s:map_set("k", recorder({}, "a"))
  local ok, err = pcall(function() s:map_set("k", nil) end)
  assert_eq(ok, false)
  assert(tostring(err):find("overwrite an existing map entry"),
    "expected overwrite error message")
  s:close()
end)

test("map_set(emptykey, nil) is a silent no-op", function()
  local s <close> = close_stack.new()
  s:map_set("k", nil) -- must not error, must not store
  assert_eq(s:map_get("k"), nil)
  assert_eq(next(collect_pairs(s)), nil)
  s:close()
end)

test("map_set(nil, x) errors", function()
  local s <close> = close_stack.new()
  local ok, err = pcall(function() s:map_set(nil, recorder({}, "a")) end)
  assert_eq(ok, false)
  assert(tostring(err):find("map key can not be nil"),
    "expected nil-key error message")
  s:close()
end)

test("false values are stored, appear in map_pairs, and can be reset", function()
  local log = {}
  local s <close> = close_stack.new()
  -- false is a no-op closeable; it is stored as-is and shows up in map_pairs.
  s:map_set("k", false)
  local got = collect_pairs(s)
  assert_eq(got.k, false)
  -- a falsy entry is not an owned resource, so it may be overwritten...
  local real = recorder(log, "real")
  assert_eq(s:map_set("k", real), real) -- no error
  assert_eq(s:map_get("k"), real)
  s:close()
  assert_eq(#log, 1) -- only the real closeable ran
  assert_eq(log[1].name, "real")
end)

test("a falsy entry can be cleared with nil", function()
  local s <close> = close_stack.new()
  s:map_set("k", false)
  s:map_set("k", nil) -- allowed: old value was falsy
  assert_eq(s:map_get("k"), nil)
  s:close()
end)

test("map is emptied after close", function()
  local s <close> = close_stack.new()
  s:map_set("a", recorder({}, "a"))
  s:close()
  assert_eq(s:map_len(), 0)
  assert_eq(next(collect_pairs(s)), nil)
end)

test("map values receive the error on error unwinding", function()
  local log = {}
  local sentinel = {}
  pcall(function()
    local s <close> = close_stack.new()
    s:map_set("a", recorder(log, "a"))
    s:map_set("b", recorder(log, "b"))
    s:close(sentinel)
  end)
  assert_eq(#log, 2)
  for _, entry in ipairs(log) do
    assert_eq(entry.err, sentinel,
      string.format("map value %s should see sentinel", entry.name))
  end
end)

test("map values interleave with pushes in LIFO close order", function()
  local log = {}
  local s <close> = close_stack.new()
  -- map_set is an append onto the shared stack, so the close order is a single
  -- LIFO across both pushes and map_sets, at their insertion points.
  s:push(recorder(log, "push-1"))
  s:map_set("m1", recorder(log, "map-2"))
  s:push(recorder(log, "push-3"))
  s:map_set("m2", recorder(log, "map-4"))
  s:close()
  assert_eq(#log, 4)
  assert_eq(log[1].name, "map-4")
  assert_eq(log[2].name, "push-3")
  assert_eq(log[3].name, "map-2")
  assert_eq(log[4].name, "push-1")
end)

test("map supports arbitrary key types including false", function()
  local log = {}
  local s <close> = close_stack.new()
  s:map_set(false, recorder(log, "false-key"))
  s:map_set(true, recorder(log, "true-key"))
  s:close()
  assert_eq(#log, 2)
  local seen = {}
  for _, entry in ipairs(log) do seen[entry.name] = true end
  assert(seen["false-key"] and seen["true-key"],
    "both false-keyed and true-keyed values should close")
end)

test("many map values all close", function()
  local log = {}
  local s <close> = close_stack.new()
  for i = 1, 100 do
    s:map_set("key-" .. i, recorder(log, i))
  end
  s:close()
  assert_eq(#log, 100)
  local seen = {}
  for _, entry in ipairs(log) do seen[entry.name] = true end
  for i = 1, 100 do
    assert(seen[i], string.format("map value %d should close", i))
  end
end)

test("map_len reflects # on integer keys", function()
  local s <close> = close_stack.new()
  for i = 1, 5 do
    s:map_set(i, recorder({}, i))
  end
  assert_eq(s:map_len(), 5)
  s:close()
end)

test("empty map with error re-raises it", function()
  local sentinel = {}
  local ok, err = pcall(function()
    local s <close> = close_stack.new()
    s:map_set("a", recorder({}, "a"))
    s:close() -- drains the map
    s:close(sentinel) -- now empty; must still re-raise
  end)
  assert_eq(ok, false)
  assert_eq(err, sentinel)
end)

test("a thrower set in the map propagates like any pushed closer", function()
  local log = {}
  local thrown = {}
  local ok, err = pcall(function()
    local s <close> = close_stack.new()
    s:push(recorder(log, "stack"))
    s:map_set("t", thrower(log, "map-thrower", thrown))
    s:close()
  end)
  assert_eq(ok, false)
  assert_eq(err, thrown)
  -- the thrower was set last, so it closes first (LIFO) with nil error...
  assert_eq(log[1].name, "map-thrower")
  assert_eq(log[1].err, nil)
  -- ...then the earlier-pushed closer sees the replacement error.
  assert_eq(log[2].name, "stack")
  assert_eq(log[2].err, thrown)
end)

test("map values transfer with pop_all", function()
  local log = {}
  local s <close> = close_stack.new()
  s:map_set("a", recorder(log, "a"))
  local s2 = s:pop_all()
  assert_eq(s:map_len(), 0) -- original map emptied
  assert_eq(next(collect_pairs(s)), nil)
  s:close()
  assert_eq(#log, 0) -- nothing left on the original
  s2:close()
  assert_eq(#log, 1)
  assert_eq(log[1].name, "a")
end)

----------------------------------------------------------------------
print("\n--- map proxy ---")

test("proxy assignment stores and closes the value", function()
  local log = {}
  local s <close> = close_stack.new()
  s.map["a"] = recorder(log, "a")
  s.map[42] = recorder(log, "b")
  assert_eq(s:map_get("a"), s.map["a"]) -- proxy read matches method read
  s:close()
  assert_eq(#log, 2)
end)

test("proxy read returns the closeable, nil when absent", function()
  local s <close> = close_stack.new()
  local obj = recorder({}, "x")
  s.map["k"] = obj
  assert_eq(s.map["k"], obj)
  assert_eq(s.map["missing"], nil)
  s:close()
end)

test("proxy and methods interoperate", function()
  local s <close> = close_stack.new()
  local a, b = recorder({}, "a"), recorder({}, "b")
  s:map_set("viamethod", a) -- set via method...
  assert_eq(s.map["viamethod"], a) -- ...read via proxy
  s.map["viaproxy"] = b -- set via proxy...
  assert_eq(s:map_get("viaproxy"), b) -- ...read via method
  s:close()
end)

test("#proxy reports the map length", function()
  local s <close> = close_stack.new()
  for i = 1, 5 do
    s.map[i] = recorder({}, i)
  end
  assert_eq(#s.map, 5)
  assert_eq(#s.map, s:map_len())
  s:close()
end)

test("pairs(proxy) iterates key/closeable pairs", function()
  local s <close> = close_stack.new()
  local a, b = recorder({}, "a"), recorder({}, "b")
  s.map["x"] = a
  s.map["y"] = b
  local got = {}
  local n = 0
  for k, v in pairs(s.map) do
    got[k] = v
    n = n + 1
  end
  assert_eq(n, 2)
  assert_eq(got.x, a)
  assert_eq(got.y, b)
  s:close()
end)

test("proxy assignment enforces const-once-set", function()
  local s <close> = close_stack.new()
  s.map["k"] = recorder({}, "a")
  local ok, err = pcall(function() s.map["k"] = recorder({}, "b") end)
  assert_eq(ok, false)
  assert(tostring(err):find("overwrite an existing map entry"),
    "expected overwrite error through the proxy")
  s:close()
end)

test("proxy assignment of nil to a truthy key errors", function()
  local s <close> = close_stack.new()
  s.map["k"] = recorder({}, "a")
  local ok = pcall(function() s.map["k"] = nil end)
  assert_eq(ok, false)
  s:close()
end)

test("proxy assignment of nil to an empty key is a no-op", function()
  local s <close> = close_stack.new()
  s.map["k"] = nil -- must not error
  assert_eq(s.map["k"], nil)
  assert_eq(#s.map, 0)
  s:close()
end)

test("proxy stores false, shows it in pairs, and allows reset", function()
  local s <close> = close_stack.new()
  s.map["k"] = false
  local got = {}
  for k, v in pairs(s.map) do got[k] = v end
  assert_eq(got.k, false)
  local real = recorder({}, "real")
  s.map["k"] = real -- falsy entry may be overwritten
  assert_eq(s.map["k"], real)
  s:close()
end)

test("proxy works on a stack from pop_all", function()
  local log = {}
  local s <close> = close_stack.new()
  s.map["a"] = recorder(log, "a")
  local s2 <close> = s:pop_all()
  -- original proxy now operates on a fresh empty map
  assert_eq(#s.map, 0)
  assert_eq(s.map["a"], nil)
  -- transferred entry is reachable through the new stack's proxy
  local seen
  for k in pairs(s2.map) do seen = k end
  assert_eq(seen, "a")
  s2:close()
  assert_eq(#log, 1)
end)

----------------------------------------------------------------------
print("\n--- as <close> variable ---")

test("close stack as <close> fires closers on scope exit", function()
  local log = {}
  do
    local s <close> = close_stack.new()
    s:push(recorder(log, "A"))
    s:push(recorder(log, "B"))
  end
  assert_eq(#log, 2)
  assert_eq(log[1].name, "B")
  assert_eq(log[2].name, "A")
end)

test("close stack as <close> passes error to closers", function()
  local log = {}
  local sentinel = {}
  pcall(function()
    local s <close> = close_stack.new()
    s:push(recorder(log, "A"))
    s:push(recorder(log, "B"))
    error(sentinel)
  end)
  assert_eq(#log, 2)
  assert_eq(log[1].name, "B")
  assert_eq(log[1].err, sentinel)
  assert_eq(log[2].name, "A")
  assert_eq(log[2].err, sentinel)
end)

----------------------------------------------------------------------
print(string.format("\n%d passed, %d failed, %d total",
  passed, failed, passed + failed))
if failed > 0 then
  os.exit(1)
end
