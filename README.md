# close-stack

A Lua stack-based closer and callback caller, equivalent to Python's
[`ExitStack`](https://docs.python.org/3/library/contextlib.html#contextlib.ExitStack),
but for Lua to-be-closed values.

Requires Lua 5.4 or later (which introduced to-be-closed variables).

## Usage

```lua
local close_stack = require('close-stack').close_stack
```

### Basic resource management

A close stack collects to-be-closed values and closes them in reverse order
(LIFO) when the stack itself is closed. The close stack is itself a to-be-closed
value, so you can assign it to a `<close>` variable and let scope exit handle
cleanup automatically.

```lua
local s <close> = close_stack()

local file = s:push(io.open('/tmp/example.txt', 'w'))
local conn = s:push(db.connect())

-- use file and conn...
-- both are closed automatically when s goes out of scope,
-- conn first, then file.
```

### Manual close

You can close the stack explicitly instead of relying on scope exit. Even when
closing manually, the stack should still be a `<close>` variable so that
resources are cleaned up on error or early return. A second close is a no-op —
the stack empties itself on the first close.

```lua
local s <close> = close_stack()
s:push(resource_a)
s:push(resource_b)

-- close everything now
s:close()

-- safe to call again (including the implicit close on scope exit), does nothing
s:close()
```

### Callbacks

`callback` registers a plain function (with optional arguments) to be called in
its place in the closing order. Unlike closeables, callbacks do not receive the
error value.

```lua
local s <close> = close_stack()

s:push(some_resource)
s:callback(print, 'cleaning up...')
s:push(another_resource)

-- on scope exit: another_resource closed, then print called, then some_resource closed.
```

### Transferring ownership with pop_all

`pop_all` moves all entries to a new close stack and returns it, leaving the
original empty. This is useful for committing resources — do your setup in one
stack, and if everything succeeds, transfer ownership elsewhere.

```lua
local function setup()
  local s <close> = close_stack()

  local conn = s:push(db.connect())
  local stmt = s:push(conn:prepare('...'))

  -- everything succeeded; transfer cleanup responsibility to the caller
  return s:pop_all()
end

-- the returned stack owns conn and stmt now
local resources <close> = setup()
```

If `setup` throws before reaching `pop_all`, the `<close>` on `s` ensures
everything is cleaned up. Once `pop_all` is called, `s` is empty, so its scope
exit is a no-op.

### Error handling

When a close stack is used as a `<close>` variable, it receives the in-flight
error object (if any) and passes it through to every closer in the stack. This
means closers can make decisions based on whether the scope exited normally or
due to an error.

```lua
local commit_guard_mt = {}
function commit_guard_mt:__close(err)
  if err then
    self.conn:rollback()
  else
    self.conn:commit()
  end
end

local s <close> = close_stack()
local conn = s:push(db.connect())
s:push(setmetatable({ conn = conn }, commit_guard_mt))

conn:execute('INSERT INTO ...')
-- on normal exit: commit, then close conn
-- on error: rollback, then close conn
```

You can also pass an error explicitly to `close()`:

```lua
local s <close> = close_stack()
s:push(resource)
s:close(err)  -- closers receive err; it is re-raised after all closers run
```

## API

### `close_stack()`

Creates and returns a new close stack.

```lua
local s <close> = close_stack()
```

### `stack:push(closeable)`

Pushes a to-be-closed value onto the stack. Returns the value, so you can push
and assign in one expression.

`nil` and `false` are ignored (consistent with Lua's treatment of to-be-closed
variables) but still returned, which makes it safe to push values that may be
nil.

```lua
local f = s:push(io.open(path))  -- f may be nil if open failed
```

### `stack:callback(fn, ...)`

Registers a function to be called when the stack is closed. Any additional
arguments are stored and passed to `fn` on close. Returns `fn`.

Callbacks do not receive the error object. If you need error-aware cleanup, use
`push` with a value that has a `__close` metamethod.

```lua
s:callback(os.remove, tempfile)
```

### `stack:close([err])`

Closes the stack immediately, invoking all closers in reverse order. If `err` is
non-nil, it is re-raised after all closers have run, and every closer receives
it as the error argument to `__close`.

After closing, the stack is empty. Calling `close()` again is a no-op (unless
new items have been pushed since).

### `stack:pop_all()`

Transfers all entries to a new close stack and returns it. The original stack
becomes empty. The returned stack is a full close stack — it can be used as a
`<close>` variable, closed manually, or have more items pushed onto it.

### `#stack`

Returns the number of entries currently in the stack.

### Using as a `<close>` variable

The close stack itself implements `__close`. When used as a `<close>` variable,
it receives the error object from Lua's scope-exit machinery and forwards it to
all closers.

```lua
local s <close> = close_stack()
```

### `__newindex` guard

Direct field assignment on a close stack raises an error. Use the methods above.

### `__gc` warning

If a close stack is garbage collected while it still has entries (i.e. it was
never closed), a warning is emitted via `warn()`.

## Closing semantics

The close stack is designed to mirror the behavior of a sequence of `<close>`
variable declarations:

```lua
local a <close> = ...
local b <close> = ...
local c <close> = ...
```

Here, `c` closes first, then `b`, then `a`. The close stack provides a dynamic
equivalent of this pattern — the closing order, error propagation, and error
replacement behavior all come directly from Lua's native to-be-closed machinery.
The close stack does not define these semantics; it delegates to real `<close>`
variables internally and inherits whatever behavior the Lua version and
implementation provides.

Notable differences between Lua versions:

- In Lua 5.4, `__close` always receives an error argument (`nil` when there is
  no error). This makes it impossible to distinguish between a normal close and
  an `error(nil)`.
- In Lua 5.5, `__close` receives no error argument on normal close, and `nil`
  errors are converted to strings. The ambiguity is resolved.

## Design notes

This is implemented via the actual Lua function stack — each entry gets its own
stack frame with a `<close>` local. This decision was made because of the
following requirements:

* The incoming error must be passed into each closer, because some need to make
  decisions based on it (e.g. commit-or-rollback guards).
* We cannot do `getmetatable(value).__close(value, err)` directly, because
  `__metatable` can be used to prevent metatable access.
* An error thrown from a closer must become the error value seen by subsequent
  closers.

The only way to reliably satisfy all three is to assign each value to a real
to-be-closed variable and let Lua's built-in closing semantics handle error
propagation.

### Limitations

Because entries use real function stack frames, the maximum number of entries
is bounded by the Lua call stack limit (around 600,000 by default). This was
previously implemented via a chain of `pcall`s, which removed the stack limit
but caused string error values to grow with each re-throw, eventually filling
memory. The stack frame approach is the better trade-off for any realistic
workload.
