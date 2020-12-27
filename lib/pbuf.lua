-- simple buffer implementation --

local computer = require("computer")

local buffer = {}

function buffer.new(stream, mode)
  local new = {
    tty = false,
    mode = {},
    rbuf = "",
    wbuf = "",
    stream = stream,
    closed = false,
    bufsize = math.max(512, math.min(8 * 1024, computer.freeMemory() / 8))
  }
  mode = mode or "r"
  for c in mode:gmatch(".") do
    new.mode[c] = true
  end
  return setmetatable(new, {
    __index = buffer,
    __name = "FILE*",
    __metatable = {}
  })
end

-- this might be inefficient but it's still much better than raw file handles!
function buffer:read_byte()
  if self.bufsize == 0 then
    return self.stream:read(1)
  end
  if #self.rbuf <= 0 then
    self.rbuf = self.stream:read(self.bufsize) or ""
  end
  local read = self.rbuf:sub(1,1)
  self.rbuf = self.rbuf:sub(2)
  if read == "" or not read then
    return nil
  end
  return read
end

function buffer:write_byte(byte)
  checkArg(1, byte, "string")
  byte = byte:sub(1,1)
  if #self.wbuf >= self.bufsize then
    self.stream:write(self.wbuf)
    self.wbuf = ""
  end
  self.wbuf = self.wbuf .. byte
end

function buffer:read(fmt)
  checkArg(1, fmt, "string", "number", "nil")
  fmt = fmt or "l"
  if type(fmt) == "number" then
    local ret = ""
    if self.bufsize == 0 then
      return self.stream:read(fmt)
    else
      for i=1, fmt, 1 do
        ret = ret .. (self:read_byte() or "")
      end
    end
    if ret == "" then
      return nil
    end
    return ret
  else
    local ret = ""
    local read = 0
    if fmt == "a" then
      repeat
        local byte = self:read_byte()
        ret = ret .. (byte or "")
        if byte then read = read + 1 end
      until not byte
    elseif fmt == "l" then
      repeat
        local byte = self:read_byte()
        if byte ~= "\n" then
          ret = ret .. (byte or "")
        end
        if byte then read = read + 1 end
      until byte == "\n" or not byte
    elseif fmt == "L" then
      repeat
        local byte = self:read_byte()
        ret = ret .. (byte or "")
        if byte then read = read + 1 end
      until byte == "\n" or not byte
    else
      error("bad argument to 'read' (invalid format)")
    end
    if read > 0 then
      return ret
    end
    return nil
  end
end

function buffer:lines(fmt)
  return function()
    return self:read(fmt)
  end
end

function buffer:write(...)
  local args = table.pack(...)
  for i=1, args.n, 1 do
    args[i] = tostring(args[i])
  end
  local write = table.concat(args)
  if self.bufsize == 0 then
    self.stream:write(write)
  else
    for byte in write:gmatch(".") do
      self:write_byte(byte)
    end
  end
  return self
end

function buffer:seek(whence, offset)
  checkArg(1, whence, "string", "nil")
  checkArg(2, offset, "number", "nil")
  if whence then
    self:flush()
    return self.stream:seek(whence, offset)
  end
  if self.mode.r then
    return self.stream:seek() + #self.rbuf
  elseif self.mode.w or self.mode.a then
    return self.stream:seek() + #self.wbuf
  end
  return 0, self
end

function buffer:flush()
  if self.mode.w then
    self.stream:write(self.wbuf)
    self.wbuf = ""
  end
  return true, self
end

function buffer:setvbuf(mode)
  if mode == "no" then
    self.bufsize = 0
  else
    self.bufsize = 512
  end
end

function buffer:size()
  if self.stream.size then
    return self.stream:size()
  end
  return 0
end

function buffer:close()
  self:flush()
  self.stream:close()
  self.closed = true
  return true
end

return buffer
