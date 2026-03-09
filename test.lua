package.path = 'lua/?.lua;' .. package.path
local close_stack = require('close-stack').close_stack

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
  local s <close> = close_stack()
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
  local s <close> = close_stack()
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
  local s <close> = close_stack()
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
    local s <close> = close_stack()
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
    local s <close> = close_stack()
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
    local s <close> = close_stack()
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
  local s <close> = close_stack()
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
    local s <close> = close_stack()
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
    local s <close> = close_stack()
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
    local s <close> = close_stack()
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
    local s <close> = close_stack()
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
  local s <close> = close_stack()
  local obj = recorder({}, "x")
  assert_eq(s:push(obj), obj)
  s:close()
end)

test("push(nil) returns nil and does not add to stack", function()
  local s <close> = close_stack()
  assert_eq(s:push(nil), nil)
  assert_eq(#s, 0)
  s:close()
end)

test("push(false) returns false and does not add to stack", function()
  local s <close> = close_stack()
  assert_eq(s:push(false), false)
  assert_eq(#s, 0)
  s:close()
end)

test("callback returns the function", function()
  local s <close> = close_stack()
  local fn = function() end
  assert_eq(s:callback(fn), fn)
  s:close()
end)

test("callback passes stored arguments on close", function()
  local captured
  local s <close> = close_stack()
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
  local s <close> = close_stack()
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
  local s <close> = close_stack()
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
    local s <close> = close_stack()
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
    local s <close> = close_stack()
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

test("__len tracks pushes, callbacks, and close", function()
  local s <close> = close_stack()
  assert_eq(#s, 0)
  s:push(recorder({}, "a"))
  assert_eq(#s, 1)
  s:push(recorder({}, "b"))
  assert_eq(#s, 2)
  s:callback(function() end)
  assert_eq(#s, 3)
  s:close()
  assert_eq(#s, 0)
end)

----------------------------------------------------------------------
print("\n--- __newindex ---")

test("direct assignment to close stack errors", function()
  local s <close> = close_stack()
  local ok, err = pcall(function() s.foo = "bar" end)
  assert_eq(ok, false)
  assert(tostring(err):find("can not create entries"),
    "expected __newindex error message")
  s:close()
end)

----------------------------------------------------------------------
print("\n--- Empty and double close ---")

test("closing empty stack is a no-op", function()
  local s <close> = close_stack()
  s:close() -- should not error
end)

test("closing empty stack with error re-raises it", function()
  local sentinel = {}
  local ok, err = pcall(function()
    local s <close> = close_stack()
    s:close(sentinel)
  end)
  assert_eq(ok, false)
  assert_eq(err, sentinel)
end)

test("second close is a no-op", function()
  local log = {}
  local s <close> = close_stack()
  s:push(recorder(log, "A"))
  s:close()
  assert_eq(#log, 1)
  s:close()
  assert_eq(#log, 1) -- not called again
end)

test("manual close before <close> scope exit prevents double invocation", function()
  local log = {}
  do
    local s <close> = close_stack()
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
  local s <close> = close_stack()
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
  local s <close> = close_stack()
  s:push(recorder(log, "A"))
  local s2 = s:pop_all()
  s:close()
  assert_eq(#log, 0) -- original has nothing to close
  s2:close() -- clean up
end)

test("pop_all result works as <close>", function()
  local log = {}
  do
    local s <close> = close_stack()
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
    local s <close> = close_stack()
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
  local s <close> = close_stack()
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
print("\n--- as <close> variable ---")

test("close stack as <close> fires closers on scope exit", function()
  local log = {}
  do
    local s <close> = close_stack()
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
    local s <close> = close_stack()
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
