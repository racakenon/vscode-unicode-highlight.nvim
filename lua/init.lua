-- init.lua (Neovim 0.10+)
-- Single-pass UTF-8 scanner + diagnostics + quickfix + virtual text
-- Messages:
--   ambiguous:  "U+XXXX looks like 'X'"
--   invisible:  "invisible U+XXXX detected"

local M = {}

-- Load external data (data.lua must provide `invisible` and `ambiguous`)
local ok, data = pcall(require, "data")
if not ok then
  error("[unicode-highlight] Missing `data.lua`. Provide invisible/ambiguous tables.")
end

-- ======================
-- Configuration
-- ======================
local config = {
  highlight_ambiguous = true,
  highlight_invisible = true,
  ambiguous_hl = "@comment.warning",
  invisible_hl = "@comment.error",
  auto_enable = true,
  filetypes = {},                                 -- empty => all filetypes allowed
  excluded_filetypes = { "help", "qf", "terminal" },
  debounce_ms = 35,                                -- debounce for TextChanged*
  virtual_text_prefix = "·",
}

-- ======================
-- Namespaces & State
-- ======================
local ns_hl   = vim.api.nvim_create_namespace("unicode_highlight")
local ns_diag = vim.api.nvim_create_namespace("unicode_highlight_diag")

local lookup = nil            -- codepoint -> { kind="invisible/ambiguous", hl, alt? }
local scheduled = {}          -- bufnr -> bool (debounce flag)
local vt_enabled = true       -- virtual text on/off state

-- ======================
-- Utilities
-- ======================

-- Convert "\%uXXXX" to actual char; return original if no match
local function escape_to_char(escape_str)
  local hex = escape_str:match("\\%%u(%x+)")
  if hex then
    local codepoint = tonumber(hex, 16)
    return vim.fn.nr2char(codepoint)
  end
  return escape_str
end

local function severity_of(kind)
  return (kind == "invisible") and vim.diagnostic.severity.ERROR or vim.diagnostic.severity.WARN
end

-- Build message for diagnostics/quickfix (and used by virtual text formatter as fallback)
local function message_of(kind, codepoint, alt)
  if kind == "invisible" then
    return ("invisible U+%04X detected"):format(codepoint)
  else
    if type(alt) == "string" and #alt > 0 then
      return ("U+%04X looks like '%s'"):format(codepoint, alt)
    else
      return ("U+%04X looks like '?'"):format(codepoint)
    end
  end
end

-- UTF-8 decode next codepoint from string s at byte index i (1-based).
-- Returns: codepoint, next_index, byte_len; nil if incomplete sequence.
local function utf8_next(s, i)
  local b1 = s:byte(i)
  if not b1 then return nil end

  if b1 < 0x80 then
    return b1, i + 1, 1
  elseif b1 < 0xE0 then
    local b2 = s:byte(i + 1); if not b2 then return nil end
    -- ((b1 & 0x1F) << 6) | (b2 & 0x3F)
    local cp = (b1 % 0x20) * 0x40 + (b2 % 0x40)
    return cp, i + 2, 2
  elseif b1 < 0xF0 then
    local b2, b3 = s:byte(i + 1), s:byte(i + 2); if not (b2 and b3) then return nil end
    -- ((b1 & 0x0F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)
    local cp = (b1 % 0x10) * 0x1000 + (b2 % 0x40) * 0x40 + (b3 % 0x40)
    return cp, i + 3, 3
  else
    local b2, b3, b4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3); if not (b2 and b3 and b4) then return nil end
    -- ((b1 & 0x07) << 18) | ((b2 & 0x3F) << 12) | ((b3 & 0x3F) << 6) | (b4 & 0x3F)
    local cp = (b1 % 0x08) * 0x40000 + (b2 % 0x40) * 0x1000 + (b3 % 0x40) * 0x40 + (b4 % 0x40)
    return cp, i + 4, 4
  end
end

local function should_highlight_filetype(ft)
  for _, ex in ipairs(config.excluded_filetypes) do
    if ft == ex then return false end
  end
  if #config.filetypes > 0 then
    for _, allow in ipairs(config.filetypes) do
      if ft == allow then return true end
    end
    return false
  end
  return true
end

-- Virtual text formatter (uses diagnostic.user_data)
local function vt_format(d)
  local ud = d.user_data or {}
  if ud.kind == "ambiguous" and ud.codepoint and ud.alt then
    return ("U+%04X looks like '%s'"):format(ud.codepoint, ud.alt)
  elseif ud.kind == "invisible" and ud.codepoint then
    return ("invisible U+%04X detected"):format(ud.codepoint)
  end
  return d.message
end

-- Build lookup map from data.lua based on current config
local function build_lookup()
  local t = {}
  if config.highlight_invisible and data.invisible then
    for _, esc in ipairs(data.invisible) do
      local ch = escape_to_char(esc)
      local cp = vim.fn.char2nr(ch)
      t[cp] = { kind = "invisible", hl = config.invisible_hl, alt = nil }
    end
  end
  if config.highlight_ambiguous and data.ambiguous then
    for _, pair in ipairs(data.ambiguous) do
      local ch = escape_to_char(pair[1])
      local cp = vim.fn.char2nr(ch)
      local alt = pair[2]
      if type(alt) == "string" then
        alt = escape_to_char(alt)  -- allow alt to also be "\%u0041" etc.
      else
        alt = nil
      end
      t[cp] = { kind = "ambiguous", hl = config.ambiguous_hl, alt = alt }
    end
  end
  lookup = t
end

-- ======================
-- Core: Scan & Apply
-- ======================
local function scan_and_apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  vim.api.nvim_buf_clear_namespace(bufnr, ns_hl, 0, -1)
  vim.diagnostic.reset(ns_diag, bufnr)

  if not lookup then build_lookup() end
  if not lookup or next(lookup) == nil then return end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local diags = {}

  for lnum, line in ipairs(lines) do
    local i, line_len = 1, #line
    while i <= line_len do
      local cp, next_i, nbytes = utf8_next(line, i)
      if not cp then break end
      local hit = lookup[cp]
      if hit then
        local col0 = i - 1               -- 0-based start byte column
        local end_col = col0 + nbytes    -- exclusive

        -- Highlight
        vim.api.nvim_buf_add_highlight(bufnr, ns_hl, hit.hl, lnum - 1, col0, end_col)

        -- Diagnostic (used by quickfix, float, loclist, etc.)
        local msg = message_of(hit.kind, cp, hit.alt)
        diags[#diags + 1] = {
          lnum = lnum - 1,
          col = col0,
          end_col = end_col,
          severity = severity_of(hit.kind),
          source = "unicode-highlight",
          message = msg,
          user_data = { kind = hit.kind, alt = hit.alt, codepoint = cp }, -- for VT formatter
        }
      end
      i = next_i
    end
  end

  vim.diagnostic.set(ns_diag, bufnr, diags, {
    virtual_text = vt_enabled and { prefix = config.virtual_text_prefix, format = vt_format } or false,
    underline = true,
    signs = true,
    update_in_insert = true,
  })
end

-- Debounced scheduling for scan
local function schedule_scan(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if config.debounce_ms <= 0 then
    scan_and_apply(bufnr)
    return
  end
  if scheduled[bufnr] then return end
  scheduled[bufnr] = true
  vim.defer_fn(function()
    scheduled[bufnr] = false
    scan_and_apply(bufnr)
  end, config.debounce_ms)
end

-- ======================
-- Commands
-- ======================
local function setup_commands()
  vim.api.nvim_create_user_command("UnicodeHighlightEnable", function()
    build_lookup()
    schedule_scan(0)
  end, { desc = "Enable unicode highlighting for current buffer" })

  vim.api.nvim_create_user_command("UnicodeHighlightDisable", function()
    local b = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_clear_namespace(b, ns_hl, 0, -1)
    vim.diagnostic.reset(ns_diag, b)
  end, { desc = "Disable unicode highlighting for current buffer" })

  vim.api.nvim_create_user_command("UnicodeHighlightToggle", function()
    config.highlight_ambiguous = not config.highlight_ambiguous
    config.highlight_invisible = not config.highlight_invisible
    build_lookup()
    if config.highlight_ambiguous or config.highlight_invisible then
      schedule_scan(0)
    else
      local b = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_clear_namespace(b, ns_hl, 0, -1)
      vim.diagnostic.reset(ns_diag, b)
    end
  end, { desc = "Toggle ambiguous/invisible scanning" })

  vim.api.nvim_create_user_command("UnicodeHighlightQF", function()
    -- Push diagnostics to quickfix and open it
    vim.diagnostic.setqflist({ open = true })
  end, { desc = "Send diagnostics to quickfix and open it" })

  vim.api.nvim_create_user_command("UnicodeHighlightVTextToggle", function()
    vt_enabled = not vt_enabled
    local vt_opt = vt_enabled and { prefix = config.virtual_text_prefix, format = vt_format } or false
    vim.diagnostic.config({ virtual_text = vt_opt }, ns_diag)
    -- Rescan to reflect immediately
    schedule_scan(0)
  end, { desc = "Toggle virtual text for unicode-highlight diagnostics" })
end

-- ======================
-- Autocmds
-- ======================
local function setup_autocmds()
  local group = vim.api.nvim_create_augroup("UnicodeHighlight", { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
    group = group,
    callback = function(args)
      local ft = vim.bo[args.buf].filetype
      if should_highlight_filetype(ft) then
        schedule_scan(args.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(args)
      local ft = vim.bo[args.buf].filetype
      if should_highlight_filetype(ft) then
        schedule_scan(args.buf)
      end
    end,
  })
end

-- ======================
-- Public API
-- ======================
function M.setup(user_config)
  if user_config then
    config = vim.tbl_deep_extend("force", config, user_config)
  end

  -- Set per-namespace diagnostic defaults once
  vim.diagnostic.config({
    virtual_text = { prefix = config.virtual_text_prefix, format = vt_format },
    underline = true,
    signs = true,
    update_in_insert = true,
  }, ns_diag)

  build_lookup()
  setup_autocmds()
  setup_commands()

  if config.auto_enable then
    vim.defer_fn(function()
      local ft = vim.bo.filetype
      if should_highlight_filetype(ft) then
        schedule_scan(0)
      end
    end, 80)
  end
end

-- Optional auto-setup at load time
local function auto_setup()
  if config.auto_enable then
    vim.diagnostic.config({
      virtual_text = { prefix = config.virtual_text_prefix, format = vt_format },
      underline = true,
      signs = true,
      update_in_insert = true,
    }, ns_diag)

    build_lookup()
    setup_autocmds()
    setup_commands()
    vim.defer_fn(function()
      local ft = vim.bo.filetype
      if should_highlight_filetype(ft) then
        schedule_scan(0)
      end
    end, 80)
  end
end

auto_setup()

return M

