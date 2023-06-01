-- 2023.06.01 impl pre process, and only reset by InsertLeave almostly

local config = require("paint.config")

local M = {}
M.enabled = false
---@type table<number,number>
M.bufs = {}

local bufLineBorderCache = {} -- {'buf1' = {1=1, 2=1, 3=0, }, }

---@param buf number
---@param first? number
---@param last? number
function M.highlight(buf, first, last, onlyCursorLine, skipCache)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    local endLine = vim.fn.line '$'
    first = first or 1
    last = last or endLine

    local borderCache = bufLineBorderCache[buf]
    if not borderCache then
        borderCache = {}
        bufLineBorderCache[buf] = borderCache
    end

    if not skipCache then
        if onlyCursorLine then
            if buf ~= vim.api.nvim_get_current_buf() then return end
            first = vim.fn.line '.'
            last = first
            vim.api.nvim_buf_clear_namespace(buf, config.ns, first - 1, last) -- only clear here
        else
            if not (borderCache[first] and borderCache[last] or first == 0 or last == endLine) then
                local unCacheCount = 0
                for i = first, last do
                    if not borderCache[i] then
                        unCacheCount = unCacheCount + 1
                    end
                end
                -- pre process:
                if last - first > 10 and unCacheCount < (last - first) / 3 then
                    local newCount = last - first
                    if borderCache[first] then
                        last = last + newCount
                        if last > endLine then last = endLine end
                    else
                        first = first - newCount
                        if first < 1 then first = 1 end
                    end
                end
            end
        end
    end

    local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
    local highlights = M.get_highlights(buf)

    for l, line in ipairs(lines) do
        local lnum = first + l - 1

        if skipCache or onlyCursorLine or borderCache[lnum] ~= 1 then
            if not skipCache then
                borderCache[lnum] = 1
            end
            vim.api.nvim_buf_clear_namespace(buf, config.ns, lnum - 1, lnum)
            for _, hl in ipairs(highlights) do
                local from, to, match = line:find(hl.pattern)

                while from do
                    if match and match ~= "" then
                        from, to = line:find(match, from, true)
                    end

                    vim.api.nvim_buf_set_extmark(
                        buf,
                        config.ns,
                        lnum - 1,
                        from - 1,
                        { end_col = to, hl_group = hl.hl, priority = 110 }
                    )

                    from, to, match = line:find(hl.pattern, to + 1)
                end
            end
        end
    end
    bufLineBorderCache[buf] = borderCache
end

---@return PaintHighlight[]
function M.get_highlights(buf)
    return vim.tbl_filter(
    ---@param hl PaintHighlight
        function(hl)
            return M.is(buf, hl.filter)
        end,
        config.options.highlights
    )
end

---@param buf number
---@param filter PaintFilter
function M.is(buf, filter)
    if type(filter) == "function" then
        return filter(buf)
    end
    ---@diagnostic disable-next-line: no-unknown
    for k, v in pairs(filter) do
        if vim.api.nvim_buf_get_option(buf, k) ~= v then
            return false
        end
    end
    return true
end

function M.detach(buf)
    vim.api.nvim_buf_clear_namespace(buf, config.ns, 0, -1)
    M.bufs[buf] = nil
    bufLineBorderCache[buf] = nil
end

function M.attach(buf)
    if M.bufs[buf] then
        return
    end
    if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then
        return
    end

    M.bufs[buf] = buf

    local ok = vim.api.nvim_buf_attach(buf, false, {
        on_lines = function(_, _, _, first, _, last)
            if not M.bufs[buf] then
                return true
            end
            bufLineBorderCache[buf] = nil
            vim.schedule(function()
                -- only deal with extmark invalidation
                local endL = vim.api.nvim_buf_line_count(buf)
                if first == 0 and last == endL and last ~= 1 then
                    M.highlight(buf, first + 1, last + 1, false, true)
                end
            end)
        end,
        on_reload = function()
            if not M.bufs[buf] then
                return true
            end
            bufLineBorderCache[buf] = nil
            M.highlight_buf(buf)
        end,
        on_detach = function()
            M.detach(buf)
        end,
    })
    if not ok then
        error("failed to attach")
    end
    M.highlight_buf(buf)
end

function M.highlight_buf(buf, onlyCursorLine)
    local wins = vim.api.nvim_list_wins()
    for _, win in ipairs(wins) do
        if vim.api.nvim_win_get_buf(win) == buf then
            M.highlight_win(win, onlyCursorLine)
        end
    end
end

-- highlights the visible range of the window
function M.highlight_win(win, onlyCursorLine)
    win = win or vim.api.nvim_get_current_win()

    if not vim.api.nvim_win_is_valid(win) then
        return
    end

    local buf = vim.api.nvim_win_get_buf(win)

    vim.api.nvim_win_call(win, function()
        local first = vim.fn.line("w0")
        local last = vim.fn.line("w$")
        M.highlight(buf, first, last, onlyCursorLine)
    end)
end

function M.disable()
    M.bufs = {}
    bufLineBorderCache = {}
    M.enabled = false
end

function M.enable()
    if M.enabled then
        M.disable()
    end
    M.enabled = true

    local group = vim.api.nvim_create_augroup("paint.nvim", { clear = true })

    vim.api.nvim_create_autocmd({ "BufWinEnter", "WinNew", "FileType" }, {
        group = group,
        callback = function(event)
            if #M.get_highlights(event.buf) > 0 then
                M.attach(event.buf)
            end
        end,
    })

    vim.api.nvim_create_autocmd({ "WinScrolled" }, {
        group = group,
        callback = function(event)
            local buf = event.buf
            M.highlight_buf(buf)
        end,
    })

    vim.api.nvim_create_autocmd({ 'InsertLeave' }, {
        group = group,
        callback = function(event)
            local buf = event.buf
            M.highlight_buf(buf, true)
        end,
    })

    vim.schedule(function()
        -- attach to all bufs in visible windows
        for _, buf in pairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_valid(buf) and #M.get_highlights(buf) > 0 then
                M.attach(buf)
            end
        end
    end)
end

function M.clearCache(buf)
    bufLineBorderCache[buf] = nil
end

return M
