# close-stack

A Lua stack-based closer and callback caller, equivalent to Python's
[`ExitStack`](https://docs.python.org/3/library/contextlib.html#contextlib.ExitStack),
but for Lua to-be-closed values.

Requires Lua 5.4 or later (which introduced to-be-closed variables).

## Usage

```lua
local close_stack = require('close-stack')
```

### Basic resource management

A close stack collects to-be-closed values and closes them in reverse order
(LIFO) when the stack itself is closed. The close stack is itself a to-be-closed
value, so you can assign it to a `<close>` variable and let scope exit handle
cleanup automatically.

```lua
local s <close> = close_stack.new()

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
local s <close> = close_stack.new()
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
local s <close> = close_stack.new()

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
  local s <close> = close_stack.new()

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

### The keyed map

In addition to the ordered stack, every close stack keeps a keyed map: a
collection of closeables keyed by arbitrary keys. This is handy when you want to
register a closeable under a key you can look up later, rather than pushing it
onto the ordered stack.

The most convenient way to use it is the public `map` field, a table-like proxy
you can index, assign, `#`, and `pairs` over just like a plain table:

```lua
local s <close> = close_stack.new()

s.map.database = db.connect()
s.map[socket_fd] = wrap_socket(socket_fd)

-- reach back in and use them by key
s.map.database:query('...')

for key, closeable in pairs(s.map) do
  -- ...
end

-- everything in the map is closed when s is closed.
```

The proxy is a thin view over four methods, which you can also call directly if
you prefer: `map_set`, `map_get`, `map_pairs`, and `map_len`. `s.map.k = v` is
`s:map_set('k', v)`, `s.map.k` is `s:map_get('k')`, `#s.map` is `s:map_len()`,
and `pairs(s.map)` is `s:map_pairs()`.

```lua
s:map_set('database', db.connect())
s:map_get('database'):query('...')
```

Map entries are **const once set**, mirroring the `<close>` values they become.
Just as the ordered stack won't let you pull an individual item back out, the map
won't let you reset or unset a key that already holds a real closeable — that
would let you silently drop an owned resource. Assigning (or calling `map_set`)
over such a key raises an error:

```lua
s.map.database = db.connect()
s.map.database = other -- error: can not overwrite an existing map entry
s.map.database = nil   -- error: same — you can not unset it either
```

A `nil` (or `false`) value is not a real resource, so it is treated as "nothing
to store": assigning `nil` to an empty key is a harmless no-op, and a key that
only holds `false` may be freely overwritten (nothing is lost). `false` values
are stored as-is and show up in iteration, consistent with Lua ignoring
`nil`/`false` as to-be-closed values.

Because the proxy routes everything through those methods, it inherits all of
this behavior — there is no back door. It only supports data access (index,
assign, `#`, `pairs`); the `map_*` methods live on the close stack itself, not on
the proxy.

The map is closed as the *deepest* layer of unwinding: all map values are closed
before any of the ordered stack's values. Because a map is unordered, the
closing order **among the map's own values is unspecified** — do not rely on it.
If you need ordering between two resources, use `push`.

Map values participate in error propagation exactly like stack values: they
receive the in-flight error in their `__close` metamethod, and an error thrown by
a map closer replaces the propagating error for everything closed afterward
(i.e. the whole ordered stack). `pop_all` transfers the map along with the stack,
and the map is emptied on close.

### Error handling

When a close stack is used as a `<close>` variable, it receives the in-flight
error object (if any) and passes it through to every closer in the stack. This
means closers can make decisions based on whether the scope exited normally or
due to an error.

```lua
local transaction_metatable = {}
function transaction_metatable:__close(err)
  if err then
    self.conn:rollback()
  else
    self.conn:commit()
  end
end

local function transaction(connection)
  connection:execute('BEGIN')
  return setmetatable({conn = connection}, transaction_metatable)
end

local s <close> = close_stack.new()
local conn = s:push(db.connect())
s:push(transaction(conn))

conn:execute('INSERT INTO ...')
-- on normal exit: commit, then close conn
-- on error: rollback, then close conn
```

You can also pass an error explicitly to `close()`:

```lua
local s <close> = close_stack.new()
s:push(resource)
s:close(err)  -- closers receive err; it is re-raised after all closers run
```

In this particular case, the effect is the same as just raising the error.

## API

### `new()`

Creates and returns a new close stack.

```lua
local s <close> = close_stack.new()
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

It is your responsibility to ensure that you only pass a proper closeable value
into the stack. A closer that throws an error is fine, but a non-closeable value
will throw an error at close-time and make the stack leak its contents.

### `stack:callback(fn, ...)`

Registers a function to be called when the stack is closed. Any additional
arguments are stored and passed to `fn` on close. Returns `fn`.

Callbacks do not receive the error object. If you need error-aware cleanup, use
`push` with a value that has a `__close` metamethod.

```lua
s:callback(os.remove, tempfile)
```

### `stack.map`

A public table-like proxy over the keyed map. Index, assign, `#`, and `pairs`
all route through the four `map_*` methods below:

| proxy expression        | equivalent method call |
| ----------------------- | ---------------------- |
| `stack.map[k]`          | `stack:map_get(k)`     |
| `stack.map[k] = v`      | `stack:map_set(k, v)`  |
| `#stack.map`            | `stack:map_len()`      |
| `pairs(stack.map)`      | `stack:map_pairs()`    |

Because it delegates, it inherits the const-once-set behavior — there is no way
to overwrite or unset an owned closeable through the proxy either. It supports
only data access; the methods themselves are not reachable through it (e.g.
`stack.map.map_get` just reads the key `'map_get'`).

```lua
stack.map.log = open_logfile(path)
for key, closeable in pairs(stack.map) do end
```

### `stack:map_set(key, closeable)`

Stores a closeable in the keyed map under `key` and returns it. All map values
are closed when the stack is closed, *before* any value on the ordered stack, in
an **unspecified order**. The map is emptied on close and transferred by
`pop_all`.

Entries are const once set: if `key` already holds a real (truthy) closeable,
`map_set` raises an error rather than overwriting or unsetting it. A `nil` or
`false` value is treated as "nothing to store" — a no-op on an empty key, and
allowed to overwrite a key that only holds a falsy value. `false` is stored as-is
(and appears in `map_pairs`). A `nil` `key` raises an error.

```lua
stack:map_set('log', open_logfile(path))
```

### `stack:map_get(key)`

Returns the closeable stored under `key`, or `nil` if there is none.

### `stack:map_pairs()`

Returns a stateful iterator yielding `(key, closeable)` pairs, for use in a
generic `for` loop. The underlying table is not exposed, so the map can not be
mutated through the iterator.

```lua
for key, closeable in stack:map_pairs() do
  -- ...
end
```

### `stack:map_len()`

Returns `#` of the underlying map table. As with any Lua table, this is only a
meaningful count for sequence (1..n integer) keys; for arbitrary keys, inspect
the map the way you would any plain table (e.g. via `map_pairs`).

### `stack:close([err])`

Closes the stack immediately, invoking all closers in reverse order. If `err` is
non-nil, it is re-raised after all closers have run, and every closer receives
it as the error argument to `__close`.

After closing, the stack is empty. Calling `close()` again is a no-op (unless
new items have been pushed since).

### `stack:pop_all()`

Transfers all entries — both the ordered stack and the keyed `map` — to a new
close stack and returns it. The original stack becomes empty. The returned stack
is a full close stack — it can be used as a `<close>` variable, closed manually,
or have more items pushed onto it.

### `#stack`

Returns the number of entries currently in the *ordered stack*. The keyed map is
separate and does not contribute to this length; use `stack:map_len()` or
`stack:map_pairs()` to inspect the map.

### Using as a `<close>` variable

The close stack itself implements `__close`. When used as a `<close>` variable,
it receives the error object from Lua's scope-exit machinery and forwards it to
all closers.

```lua
local s <close> = close_stack.new()
```

### `__newindex` guard

Direct field assignment on a close stack raises an error. Use the methods above.

### `__gc` warning

If a close stack is garbage collected while it still has entries in either the
ordered stack or the keyed `map` (i.e. it was never closed), a warning is emitted
via `warn()`.

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
  errors are converted to strings.

For the sake of a sane implementation, we just treat a `nil` error as being
no error.

## Design notes

This is implemented via the actual Lua function stack — each entry gets a
`<close>` local. This decision was made because of the following requirements:

* The incoming error must be passed into each closer, because some need to make
  decisions based on it (e.g. commit-or-rollback guards).
* We cannot do `getmetatable(value).__close(value, err)` directly, because
  `__metatable` can be used to prevent metatable access.
* An error thrown from a closer must become the error value seen by subsequent
  closers.

The only way to reliably satisfy all three is to assign each value to a real
to-be-closed variable and let Lua's built-in closing semantics handle error
propagation.

This does mean that the close stack depends on the user passing a proper
auto-closeable object. If you violate this, the stack will throw an error on
close, and leak parts of its stack.

The ordered stack is unwound 16 closers per function frame (an unrolling that
raises the effective capacity and reduces recursion overhead). The keyed map is
unwound the same way: because it is an unordered table rather than a sequence, it
cannot be walked by index, so its unwinder threads a key through `next` and binds
up to 16 values per frame to `<close>` locals, recursing on the key that follows
the sixteenth. Slots past the end of the map receive `nil`, which Lua's
to-be-closed machinery simply ignores. The map is unwound as the deepest layer,
so its values close before the ordered stack's — and, being unordered, in no
guaranteed order among themselves.

The map is kept as private state reached only through `map_set`/`map_get`/
`map_pairs`/`map_len`, never as a raw table. This is deliberate: a `<close>`
value is also `<const>`, and the whole close stack is built to honor that — you
can add resources but never quietly remove an individual one. A raw public table
would let a caller `delete` or overwrite an owned closeable and leak it, so
`map_set` enforces the const-once-set rule instead.

The public `stack.map` field is a proxy (see `src/close-stack/_map-proxy.lua`),
not the underlying table: a small table carrying a backreference to its owning
stack under a module-private key, with a metatable whose `__index`/`__newindex`/
`__len`/`__pairs` forward to the methods above. Since every operation goes
through `map_set`/`map_get`/etc., the ergonomic table syntax gets the exact same
guarantees as the methods, with no back door. `pairs` support relies on the
`__pairs` metamethod, which Lua 5.4 still honors.

### Limitations

Because entries use real function stack frames, the maximum number of entries
is bounded by the Lua call stack limit (around 600,000 by default). This was
previously implemented via a chain of `pcall`s, which removed the stack limit
but caused string error values to grow with each re-throw, eventually filling
memory. The stack frame approach is the better trade-off for any realistic
workload.
