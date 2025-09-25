local function get_active_param_indices(active_param_ix, params, label)
  if params and active_param_ix and active_param_ix >= 0 and active_param_ix < #params then
    local active_param = params[active_param_ix + 1].label

    if type(active_param) == 'table' then
      return unpack(active_param)
    end

    if type(active_param) == 'string' then
      local s, e = string.find(label, active_param, 1, true)
      return (s - 1), e
    end
  end

  return nil, nil
end

local function parse_signature_help_result(lsp_result)
  local sig_idx = (lsp_result.activeSignature or 0) + 1
  local sig = lsp_result.signatures[sig_idx]
  local active_param = sig.activeParameter or lsp_result.activeParameter
  local active_ix_start, active_ix_end = get_active_param_indices(active_param, sig.parameters, sig.label)
  local other_labels = {}
  for i, sigx in ipairs(lsp_result.signatures) do
    if i ~= sig_idx then
      table.insert(other_labels, sigx.label)
    end
  end
  return sig.label, sig.parameters, active_ix_start, active_ix_end, other_labels
end

local function highlight_text(bufnr, start_ix, end_ix, highlight_group)
  vim.api.nvim_buf_clear_namespace(bufnr, -1, 0, -1)
  if start_ix and end_ix then
    vim.api.nvim_buf_add_highlight(bufnr, 0, highlight_group, 0, start_ix, end_ix)
  end
end

local function calc_window_dimensions(labels, max_width, max_height)
  local widths = {}
  for _, v in pairs(labels) do
    table.insert(widths, string.len(v))
  end
  local width = math.min(max_width, math.max(unpack(widths)))

  local height = 0
  for _, v in pairs(labels) do
    height = height + math.ceil(string.len(v) / width)
  end

  return width, math.min(height, max_height)
end

local function window_config(label, config, width, height, other_labels)
  if config.window_config then
    return config.window_config(label, config, width, height, other_labels)
  end

  return {
    relative = 'editor',
    anchor = 'NE',
    width = width,
    height = height,
    row = 0,
    col = vim.api.nvim_win_get_width(0),
    focusable = false,
    zindex = config.zindex,
    style = 'minimal',
    border = config.border,
  }
end

local function close_signature_window(bufnr)
  local sig_window = vim.F.npcall(vim.api.nvim_buf_get_var, bufnr, 'sig-window-nvim')
  if sig_window and vim.api.nvim_win_is_valid(sig_window) then
    vim.api.nvim_win_close(sig_window, true)
  end
end

local function show_signature_window(label, active_ix_start, active_ix_end, config, other_labels)
  local bufnr = vim.api.nvim_get_current_buf()
  local w_bufnr = vim.api.nvim_create_buf(false, true)

  local all_labels = vim.split(label, '\n', { plain = true })
  for i, v in ipairs(other_labels) do
    vim.list_extend(all_labels, vim.split(v, '\n', { plain = true }))
  end

  vim.api.nvim_buf_set_lines(w_bufnr, 0, -1, true, all_labels)
  highlight_text(w_bufnr, active_ix_start, active_ix_end, config.hl_group)

  local width, height = calc_window_dimensions(all_labels, config.max_width, config.max_height)
  local winnr = vim.api.nvim_open_win(w_bufnr, false, window_config(label, config, width, height, other_labels))
  close_signature_window(bufnr)

  vim.api.nvim_win_set_option(winnr, 'wrap', true)
  vim.api.nvim_win_set_option(winnr, 'foldenable', false)
  vim.api.nvim_buf_set_option(w_bufnr, 'filetype', vim.bo[bufnr].filetype)
  vim.api.nvim_buf_set_option(w_bufnr, 'modifiable', false)
  vim.api.nvim_buf_set_option(w_bufnr, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_var(bufnr, 'sig-window-nvim', winnr)

  return w_bufnr
end

module = {
  default_config = {
    zindex = 50,
    border = 'rounded',
    max_width = 80,
    max_height = 5,
    hl_active_param = true,
    hl_group = 'DiagnosticWarn',
  },
  config = {},
  previous_label = '',
  previous_active_ix_start = -1,
  previous_active_ix_end = -1,
  window_bufnr = -1,
  is_open = false,
}

function module.signature_help_handler(_, result, _, config)
  if result and result.signatures and result.signatures[1] and vim.fn.mode() == 'i' then
    local label, _, active_ix_start, active_ix_end, other_labels = parse_signature_help_result(result)
    if label ~= module.previous_label or not module.is_open then
      module.previous_label = label
      module.previous_active_ix_start = active_ix_start
      module.previous_active_ix_end = active_ix_end
      module.window_bufnr = show_signature_window(label, active_ix_start, active_ix_end, config, other_labels)
      module.is_open = true
    elseif active_ix_start ~= module.previous_active_ix_start or active_ix_end ~= module.previous_active_ix_end then
      module.previous_active_ix_start = active_ix_start
      module.previous_active_ix_end = active_ix_end
      highlight_text(module.window_bufnr, active_ix_start, active_ix_end, config.hl_group)
    end
  elseif module.is_open then
    module.is_open = false
    close_signature_window(vim.api.nvim_get_current_buf())
  end
end

function module.close_signature_help()
  if module.is_open then
    module.is_open = false
    close_signature_window(vim.api.nvim_get_current_buf())
  end
end

function module.request_signature_help(opts)
  local config = module.config[opts.buf]
  if not config then
    return
  end

  local clients = vim.lsp.get_active_clients({ bufnr = opts.buf })
  if #clients == 0 then
    return
  end -- 如果没有活动的 client，直接返回

  local position_encoding = clients[1].offset_encoding or clients[1].position_encoding
  if not position_encoding then
    position_encoding = 'utf-16'
  end

  local params = vim.lsp.util.make_position_params(vim.api.nvim_get_current_win(), position_encoding)

  vim.lsp.buf_request(opts.buf, 'textDocument/signatureHelp', params, function(err, result, ctx, _)
    module.signature_help_handler(err, result, ctx, config)
  end)
end

function module.set_config(bufnr, config)
  config = config or {}
  module.config[bufnr] = {}
  for k, v in pairs(module.default_config) do
    module.config[bufnr][k] = v
  end
  for k, v in pairs(config) do
    module.config[bufnr][k] = v
  end
end

function module.setup(swn_config)
  module.user_config = swn_config or {}

  local grp = vim.api.nvim_create_augroup('sig_window_nvim_attach', { clear = true })
  vim.api.nvim_create_autocmd('LspAttach', {
    group = grp,
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      local bufnr = args.buf
      if not (client and client.server_capabilities and client.server_capabilities.signatureHelpProvider) then
        return
      end

      module.set_config(bufnr, module.user_config)

      local aug = 'sig_window_nvim_aug_' .. bufnr
      vim.api.nvim_create_augroup(aug, { clear = true })

      local request = {
        group = aug,
        buffer = bufnr,
        callback = function()
          module.request_signature_help({ buf = bufnr })
        end,
      }
      local close = { group = aug, buffer = bufnr, callback = module.close_signature_help }

      vim.api.nvim_create_autocmd('InsertEnter', request)
      vim.api.nvim_create_autocmd('CursorMovedI', request)
      vim.api.nvim_create_autocmd('InsertLeave', close)
      vim.api.nvim_create_autocmd('BufLeave', close)
      vim.api.nvim_create_autocmd('WinLeave', close)
      vim.api.nvim_create_autocmd('TabLeave', close)
    end,
  })
end

return module
