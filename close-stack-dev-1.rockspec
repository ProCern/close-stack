package = "close-stack"
version = "dev-1"

source = {
  url = "git+https://github.com/ProCern/close-stack.git",
}

description = {
  summary = "A stack-based closer for Lua to-be-closed values",
  detailed = [[
    A Lua stack-based closer and callback caller, equivalent to Python's
    ExitStack, but for Lua to-be-closed values. Manages a dynamic list of
    closeable resources and closes them in reverse order on scope exit,
    manual close, or error unwinding.
  ]],
  homepage = "https://github.com/ProCern/close-stack",
  license = "MPL-2.0",
}

dependencies = {
  "lua >= 5.4",
}

build = {
  type = "builtin",
}
