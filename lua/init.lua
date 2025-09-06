-- init.lua (Neovim 0.10+)
-- Byte-wise single-pass scanner using patterns from data.lua (byte arrays)
-- Diagnostics + quickfix + virtual text
-- Messages:
--   ambiguous:  "U+XXXX looks like 'X'"
--   invisible:  "invisible U+XXXX detected"

local M = {}

-- data.lua must provide:
--   M.ambiguous = { { {bytes}, {alt_bytes}, codepoint, alt_codepoint? }, ... }
--   M.invisible = { { {bytes}, codepoint }, ... }
local ok, data = pcall(require, "data")
if not ok then
  error("[unicode-highlight] Missing `data.lua`. Provide invisible/ambiguous byte tables.")
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

-- patterns: array of { bytes_str, len, kind, hl, codepoint, alt_str? }
-- index: first_byte (0-255) -> { pattern_indices... }
local patterns = nil
local index_by_first = nil

local scheduled = {}          -- bufnr -> bool (debounce flag)
local vt_enabled = true       -- virtual text on/off state

-- ======================
-- Utilities
-- ======================
local function severity_of(kind)
  return (kind == "invisible") and vim.diagnostic.severity.ERROR or vim.diagnostic.severity.WARN
end

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

-- Convert an array of bytes {b1,b2,...} to a Lua string WITHOUT unpack dependency
local function bytes_to_string(bytes)
  if not bytes or #bytes == 0 then return "" end
  local tmp = {}
  for i = 1, #bytes do
    tmp[i] = string.char(bytes[i])
  end
  return table.concat(tmp)
end

-- ======================
-- Build patterns & index from data.lua (byte arrays)
-- ======================
local function rebuild_patterns()
  local p = {}
  local idx = {}

  local function add_pattern(bytes, kind, hl, codepoint, alt_bytes)
    if not bytes or #bytes == 0 then return end
    local s = bytes_to_string(bytes)
    local first = bytes[1]
    local alt = nil
    if alt_bytes and #alt_bytes > 0 then
      alt = bytes_to_string(alt_bytes)
    end
    local entry = {
      bytes_str = s,
      len = #s,
      kind = kind,
      hl = hl,
      codepoint = codepoint,
      alt = alt,
    }
    p[#p + 1] = entry
    local arr = idx[first]
    if not arr then arr = {}; idx[first] = arr end
    arr[#arr + 1] = #p
  end

  if config.highlight_invisible and type(data.invisible) == "table" then
    for _, item in ipairs(data.invisible) do
      local bytes = item[1]     -- {bytes}
      local cp    = item[2]     -- integer codepoint
      add_pattern(bytes, "invisible", config.invisible_hl, cp, nil)
    end
  end

  if config.highlight_ambiguous and type(data.ambiguous) == "table" then
    for _, item in ipairs(data.ambiguous) do
      local bytes     = item[1] -- {bytes}
      local alt_bytes = item[2] -- {alt_bytes}
      local cp        = item[3] -- integer codepoint
      add_pattern(bytes, "ambiguous", config.ambiguous_hl, cp, alt_bytes)
    end
  end

  patterns = p
  index_by_first = idx
end

-- ======================
-- Core: Byte-wise scan & apply
-- ======================
local function scan_and_apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(bufnr, ns_hl, 0, -1)
  vim.diagnostic.reset(ns_diag, bufnr)

  if not patterns then rebuild_patterns() end
  if not patterns or #patterns == 0 then return end

  local diags = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for lnum, line in ipairs(lines) do
    local i, n = 1, #line
    while i <= n do
      local b = line:byte(i)
      local candidates = index_by_first and index_by_first[b]
      local matched = false

      if candidates then
        for _, pi in ipairs(candidates) do
          local pat = patterns[pi]
          if i + pat.len - 1 <= n and line:sub(i, i + pat.len - 1) == pat.bytes_str then
            local col0 = i - 1
            local end_col = col0 + pat.len

            -- Highlight
            vim.api.nvim_buf_add_highlight(bufnr, ns_hl, pat.hl, lnum - 1, col0, end_col)

            -- Diagnostic
            local msg = message_of(pat.kind, pat.codepoint, pat.alt)
            diags[#diags + 1] = {
              lnum = lnum - 1,
              col = col0,
              end_col = end_col,
              severity = severity_of(pat.kind),
              source = "unicode-highlight",
              message = msg,
              user_data = { kind = pat.kind, alt = pat.alt, codepoint = pat.codepoint },
            }

            i = i + pat.len   -- advance past matched bytes
            matched = true
            break
          end
        end
      end

      if not matched then
        i = i + 1
      end
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
    rebuild_patterns()
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
    rebuild_patterns()
    if config.highlight_ambiguous or config.highlight_invisible then
      schedule_scan(0)
    else
      local b = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_clear_namespace(b, ns_hl, 0, -1)
      vim.diagnostic.reset(ns_diag, b)
    end
  end, { desc = "Toggle ambiguous/invisible scanning" })

  vim.api.nvim_create_user_command("UnicodeHighlightQF", function()
    vim.diagnostic.setqflist({ open = true })
  end, { desc = "Send diagnostics to quickfix and open it" })

  vim.api.nvim_create_user_command("UnicodeHighlightVTextToggle", function()
    vt_enabled = not vt_enabled
    local vt_opt = vt_enabled and { prefix = config.virtual_text_prefix, format = vt_format } or false
    vim.diagnostic.config({ virtual_text = vt_opt }, ns_diag)
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

  vim.diagnostic.config({
    virtual_text = { prefix = config.virtual_text_prefix, format = vt_format },
    underline = true,
    signs = true,
    update_in_insert = true,
  }, ns_diag)

  rebuild_patterns()
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

    rebuild_patterns()
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

