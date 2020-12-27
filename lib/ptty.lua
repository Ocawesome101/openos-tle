-- TTY driver --

local component = require("component")
local computer = require("computer")
local unicode = require("unicode")
local buffer = require("pbuf")
local event = require("event")

local vt = {}

-- these are the default VGA colors
local colors = {
  0x000000,
  0xaa0000,
  0x00aa00,
  0xaaaa00,
  0x0000aa,
  0xaa00aa,
  0x00aaaa,
  0xaaaaaa
}
local bright = {
  0x555555,
  0xff5555,
  0x55ff55,
  0xffff55,
  0x5555ff,
  0xff55ff,
  0x55ffff,
  0xffffff
}
-- and these are the 240 \27[38;5;NNNm colors
local palette = {
  0x000000,
  0xaa0000,
  0x00aa00,
  0xaaaa00,
  0x0000aa,
  0xaa00aa,
  0x00aaaa,
  0xaaaaaa,
  0x555555,
  0xff5555,
  0x55ff55,
  0xffff55,
  0x5555ff,
  0xff55ff,
  0x55ffff,
  0xffffff,
  0x000000
}
-- programmatically generate the rest since they follow a pattern
local function inc(n)
  if n >= 0xff then
    return 0
  else
    return n + 40
  end
end
local function pack(r,g,b)
  return (r << 16) + (g << 8) + b
end
local r, g, b = 0x5f, 0, 0
local i = 0

repeat
  table.insert(palette, pack(r, g, b))
  b = inc(b)
  if b == 0 then
    b = 0x5f
    g = inc(g)
  end
  if g == 0 then
    g = 0x5f
    r = inc(r)
  end
  if r == 0 then
    break
  end
until r == 0xff and g == 0xff and b == 0xff

table.insert(palette, pack(r,g,b))

for i=0x8, 0xee, 10 do
  table.insert(palette, pack(i,i,i))
end

local min, max = math.min, math.max

-- This function takes a gpu and screen address and returns a (non-buffered!) stream.
function vt.new(gpu, screen)
  checkArg(1, gpu, "string", "table")
  checkArg(2, screen, "string", "nil")
  if type(gpu) == "string" then gpu = component.proxy(gpu) end
  if screen then gpu.bind(screen) end
  local mode = 0
  -- TTY modes:
  -- 0: regular text
  -- 1: received '\27'
  -- 2: received '\27[', in escape
  -- 3: received '\27(', in control
  local rb = ""
  local wb = ""
  local nb = ""
  local ec = true -- local echo
  local lm = true -- line mode
  local raw = false -- raw read mode
  local buf
  local cx, cy = 1, 1
  local fg, bg = colors[8], colors[1]
  local w, h = gpu.maxResolution()
  gpu.setResolution(w, h)

  -- buffered TTYs for fullscreen apps, just like before but using control codes 
  --       \27(B/\27(b rather than \27[*m escape sequences
  if gpu.allocateBuffer then
    buf = gpu.allocateBuffer()
  end

  local function scroll(n)
    n = n or 1
    gpu.copy(1, 1, w, h, 0, -n)
    gpu.fill(1, h - n + 1, w, n + 1, " ")
  end

  local function checkCursor()
    if cx > w then cx, cy = 1, cy + 1 end
    if cy >= h then cy = h - 1 scroll(1) end
    if cx < 1 then cx = w + cx cy = cy - 1 end
    if cy < 1 then cy = 1 end
    cx = max(1, min(w, cx))
    cy = max(1, min(h, cy))
  end

  local function flushwb()
    while unicode.len(wb) > 0 do
      checkCursor()
      local ln = unicode.sub(wb, 1, w - cx + 1)
      gpu.set(cx, cy, ln)
      cx = cx + unicode.len(ln)
      wb = unicode.sub(wb, unicode.len(ln) + 1)
    end
  end

  local stream = {}

  local p = {}
  -- Write a string to the stream. The string will be parsed for vt100 codes.
  function stream:write(str)
    checkArg(1, str, "string")
    if self.closed then
      return nil, "input/output error"
    end
    str = str:gsub("\8", "\27[D")
    local _c, _f, _b = gpu.get(cx, cy)
    gpu.setForeground(_b)
    gpu.setBackground(_f)
    gpu.set(cx, cy, _c)
    gpu.setForeground(fg)
    gpu.setBackground(bg)
    for c in str:gmatch(".") do
      if mode == 0 then
        if c == "\n" then
          flushwb()
          cx, cy = 1, cy + 1
          checkCursor()
        elseif c == "\t" then
          local t = cx + #wb
          t = ((t-1) - ((t-1) % 8)) + 9
          if t > w then
            cx, cy = 1, cy + 1
            checkCursor()
          else
            wb = wb .. (" "):rep(t - (cx + #wb))
          end
        elseif c == "\27" then
          flushwb()
          mode = 1
        elseif c == "\7" then -- ascii BEL
          computer.beep(".")
        else
          wb = wb .. c
        end
      elseif mode == 1 then
        if c == "[" then
          mode = 2
        elseif c == "(" then
          mode = 3
        else
          mode = 0
        end
      elseif mode == 2 then
        if tonumber(c) then
          nb = nb .. c
        elseif c == ";" then
          p[#p+1] = tonumber(nb) or 0
          nb = ""
        else
          mode = 0
          if #nb > 0 then
            p[#p+1] = tonumber(nb) or 0
            nb = ""
          end
          if c == "A" then
            cy = cy + max(0, p[1] or 1)
          elseif c == "B" then
            cy = cy - max(0, p[1] or 1)
          elseif c == "C" then
            cx = cx + max(0, p[1] or 1)
          elseif c == "D" then
            cx = cx - max(0, p[1] or 1)
          elseif c == "E" then
            cx, cy = 1, cy + max(0, p[1] or 1)
          elseif c == "F" then
            cx, cy = 1, cy - max(0, p[1] or 1)
          elseif c == "G" then
            cx = min(w, max(p[1] or 1))
          elseif c == "H" or c == "f" then
            cx, cy = max(0, min(w, p[2] or 1)), max(0, min(h - 1, p[1] or 1))
          elseif c == "J" then
            local n = p[1] or 0
            if n == 0 then
              gpu.fill(cx, cy, w, 1, " ")
              gpu.fill(1, cy + 1, w, h, " ")
            elseif n == 1 then
              gpu.fill(1, 1, w, cy - 1, " ")
              gpu.fill(cx, cy, w, 1, " ")
            elseif n == 2 then
              gpu.fill(1, 1, w, h, " ")
            end
          elseif c == "K" then
            local n = p[1] or 0
            if n == 0 then
              gpu.fill(cx, cy, w, 1, " ")
            elseif n == 1 then
              gpu.fill(1, cy, cx, 1, " ")
            elseif n == 2 then
              gpu.fill(1, cy, w, 1, " ")
            end
          elseif c == "S" then
            scroll(max(0, p[1] or 1))
            checkCursor()
          elseif c == "T" then
            scroll(-max(0, p[1] or 1))
            checkCursor()
          elseif c == "m" then
            local ic = false -- in RGB-color escape
            local icm = 0 -- RGB-color mode: 2 = 240-color, 5 = 24-bit R;G;B
            local icc = 0 -- the color
            local icv = 0 -- fg or bg?
            local icn = 0 -- which segment we're on: 1 = R, 2 = G, 3 = B
            p[1] = p[1] or 0
            for i=1, #p, 1 do
              local n = p[i]
              if ic then
                if icm == 0 then
                  icm = n
                elseif icm == 2 then
                  if icn < 3 then
                    icn = icn + 1
                    icc = icc + n << (8 * (3 - icn))
                  else
                    ic = false
                    if icv == 1 then
                      bg = icc
                    else
                      fg = icc
                    end
                  end
                elseif icm == 5 then
                  if palette[n] then
                    icc = palette[n]
                  end
                  ic = false
                  if icv == 1 then
                    bg = icc
                  else
                  fg = icc
                  end
                end
              else
                icm = 0
                icc = 0
                icv = 0
                icn = 0
                if n == 0 then -- reset terminal attributes
                  fg, bg = colors[8], colors[1]
                  ec = true
                  lm = true
                elseif n == 8 then -- disable local echo
                  ec = false
                elseif n == 28 then -- enable local echo
                  ec = true
                elseif n > 29 and n < 38 then -- foreground color
                  fg = colors[n - 29]
                elseif n > 39 and n < 48 then -- background color
                  bg = colors[n - 39]
                elseif n == 38 then -- 256/24-bit color, foreground
                  ic = true
                  icv = 0
                elseif n == 48 then -- 256/24-bit color, background
                  ic = true
                  icv = 1
                elseif n == 39 then -- default foreground
                  fg = colors[8]
                elseif n == 49 then -- default background
                  bg = colors[1]
                elseif n > 89 and n < 98 then -- bright foreground
                  fg = bright[n - 89]
                elseif n > 99 and n < 108 then -- bright background
                  bg = bright[n - 99]
                end
                gpu.setForeground(fg)
                gpu.setBackground(bg)
              end
            end
          elseif c == "n" then
            if p[1] and p[1] == 6 then
              rb = rb .. string.format("\27[%d;%dR", cy, cx)
            end
          end
          p = {}
        end
      elseif mode == 3 then
        mode = 0
        if c == "l" then
          lm = false
        elseif c == "L" then
          lm = true
        elseif c == "r" then
          raw = false
        elseif c == "R" then
          raw = true
        elseif c == "b" then
          if buf then gpu.setActiveBuffer(0)
                      gpu.bitblt(0, 1, 1, w, h, buf) end
        elseif c == "B" then
          if buf then gpu.setActiveBuffer(buf) end
        end
      end
    end
    flushwb()
    checkCursor()
    local _c, f, b = gpu.get(cx, cy)
    gpu.setForeground(b)
    gpu.setBackground(f)
    gpu.set(cx, cy, _c)
    gpu.setForeground(fg)
    gpu.setBackground(bg)
    return true
  end

  -- this key input logic is... a lot simpler than i initially anticipated
  local function key_down(sig, kb, char, code)
  --  if keyboards[kb] then
      local c
      if char > 0 then
        c = (char > 255 and unicode.char or string.char)(char)
      -- up 00; down 208; right 205; left 203
      elseif code == 200 then
        c = "\27[A"
      elseif code == 208 then
        c = "\27[B"
      elseif code == 205 then
        c = "\27[C"
      elseif code == 203 then
        c = "\27[D"
      end

      c = c or ""
      if char == 13 and not raw then
        rb = rb .. "\n"
      else
        rb = rb .. c
      end
      if ec then
        if char == 13 and not raw then
          stream:write("\n")
        elseif char < 32 and char > 0 then
          -- i n l i n e   l o g i c   f t w
          stream:write("^"..string.char(
            (char < 27 and char + 96) or
            (char == 27 and "[") or
            (char == 28 and "\\") or
            (char == 29 and "]") or
            (char == 30 and "~") or
            (char == 31 and "?")
          ):upper())
        else
          stream:write(c)
        end
      end
    --end
  end

  local function clipboard(sig, kb, data)
    --if keyboards[kb] then
      for c in data:gmatch(".") do
        key_down("key_down", kb, c:byte(), 0)
      end
    --end
  end

  event.listen("key_down", key_down)
  --event.register("clipboard", clipboard)

  -- simpler than the original stream:read implementation:
  --   -> required 'n' argument
  --   -> does not support 'n' as string
  --   -> far simpler text reading logic
  function stream:read(n)
    checkArg(1, n, "number")
    if lm then
      while (not rb:find("\n")) or (rb:find("\n") < n) do
        event.pull()
      end
    else
      while #rb < n do
        event.pull()
      end
    end
    local ret = rb:sub(1, n)
    rb = rb:sub(n + 1)
    return ret
  end

  function stream:seek()
    return nil, "Illegal seek"
  end

  function stream:close()
    self.closed = true
    event.ignore("key_down", key_down)
    --event.(id2)
    return true
  end

  local new = buffer.new(stream, "rw")
  new:setvbuf("no")
  new.bufferSize = 1
  new.tty = true
  return new
end

return vt
