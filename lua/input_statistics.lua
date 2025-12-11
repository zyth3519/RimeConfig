-- github.com/amzxyz
-- input_stats.lua
-- Rime 统计增强版 (LevelDB / 滚动时间窗口 / 效率仪表盘 / 汉字提纯)
-- 维度升级：1, 2, 3, 4, ≥5 字独立统计
-- UI优化：综合数据田字格布局，峰值与均速分开显示

local userdb = require("lib/userdb")
-- 初始化数据库
local db = userdb.LevelDb("lua/stats")

-- 硬编码信息
local schema_name = "万象拼音"
local software_name = rime_api.get_distribution_code_name()

-- -----------------------------------------------------------------------------
-- 汉字识别核心逻辑
-- -----------------------------------------------------------------------------
local function is_chinese_code(c)
    return (c >= 0x4E00 and c <= 0x9FFF) or (c >= 0x3400 and c <= 0x4DBF) or 
           (c >= 0x20000 and c <= 0x2A6DF) or (c >= 0x2A700 and c <= 0x2B73F) or 
           (c >= 0x2B740 and c <= 0x2B81F) or (c >= 0x2B820 and c <= 0x2CEAF) or 
           (c >= 0x2CEB0 and c <= 0x2EBEF) or (c >= 0x30000 and c <= 0x3134F) or 
           (c >= 0x31350 and c <= 0x323AF) or (c >= 0x2EBF0 and c <= 0x2EE5F) or 
           (c >= 0xF900  and c <= 0xFAFF) or (c >= 0x2F800 and c <= 0x2FA1F) or 
           (c >= 0x2E80  and c <= 0x2EFF) or (c >= 0x2F00  and c <= 0x2FDF)
end

local function get_pure_chinese_length(text)
    local count = 0
    for _, code in utf8.codes(text) do
        if is_chinese_code(code) then count = count + 1 end
    end
    return count
end

-- -----------------------------------------------------------------------------
-- 内存缓存：实时分速
-- -----------------------------------------------------------------------------
local speed_buffer = {}
local last_cleanup_ts = 0

local function get_current_kpm(now)
    if now - last_cleanup_ts > 5 then
        local new_buf = {}
        local threshold = now - 60
        for _, item in ipairs(speed_buffer) do
            if item.ts > threshold then table.insert(new_buf, item) end
        end
        speed_buffer = new_buf
        last_cleanup_ts = now
    end
    local total = 0
    local threshold = now - 60
    for _, item in ipairs(speed_buffer) do
        if item.ts > threshold then total = total + item.len end
    end
    return total
end

-- -----------------------------------------------------------------------------
-- 数据库操作
-- -----------------------------------------------------------------------------
local function ensure_db_open()
    if not db:loaded() then return db:open() end
    return true
end

local function db_get(key)
    return tonumber(db:fetch(key)) or 0
end

local function db_incr_day_and_total(key_suffix, amount, day_key)
    amount = amount or 1
    local d_key = day_key .. key_suffix
    db:update(d_key, tostring(db_get(d_key) + amount))
    local t_key = "total" .. key_suffix
    db:update(t_key, tostring(db_get(t_key) + amount))
end

local function db_set_max_day(key_suffix, new_val, day_key)
    local d_key = day_key .. key_suffix
    if new_val > db_get(d_key) then db:update(d_key, tostring(new_val)) end
    local t_key = "total" .. key_suffix
    if new_val > db_get(t_key) then db:update(t_key, tostring(new_val)) end
end

local function clear_all_data()
    if not ensure_db_open() then return false end
    if db.empty then
        db:empty()
        speed_buffer = {}
        return true
    end
    local ok, iter = pcall(function() return db:query("") end)
    if ok and iter then
        local keys = {}
        for key, _ in iter do table.insert(keys, key) end
        for _, key in ipairs(keys) do db:erase(key) end
        speed_buffer = {}
        return true
    end
    return false
end

-- -----------------------------------------------------------------------------
-- 记录逻辑
-- -----------------------------------------------------------------------------
local function record_stats(hanzi_len, code_len)
    if not ensure_db_open() then return end
    
    local now = os.time()
    local t = os.date("*t", now)
    local day_key = string.format("d_%04d%02d%02d", t.year, t.month, t.day)
    
    table.insert(speed_buffer, {ts = now, len = hanzi_len})
    local current_kpm = get_current_kpm(now)
    
    db_incr_day_and_total("_len", hanzi_len, day_key)
    db_incr_day_and_total("_cnt", 1, day_key)
    db_incr_day_and_total("_code", code_len, day_key)
    
    if hanzi_len == 1 then db_incr_day_and_total("_l1", 1, day_key)
    elseif hanzi_len == 2 then db_incr_day_and_total("_l2", 1, day_key)
    elseif hanzi_len == 3 then db_incr_day_and_total("_l3", 1, day_key)
    elseif hanzi_len == 4 then db_incr_day_and_total("_l4", 1, day_key)
    elseif hanzi_len > 4  then db_incr_day_and_total("_l_gt4", 1, day_key)
    end
    
    db_set_max_day("_spd", current_kpm, day_key)
end

-- -----------------------------------------------------------------------------
-- 聚合查询逻辑
-- -----------------------------------------------------------------------------
local function aggregate_stats(days_lookback)
    if not ensure_db_open() then return nil end
    
    if days_lookback == 0 then
        local prefix = "total"
        return {
            len = db_get(prefix .. "_len"),
            cnt = db_get(prefix .. "_cnt"),
            code = db_get(prefix .. "_code"),
            spd = db_get(prefix .. "_spd"),
            l1 = db_get(prefix .. "_l1"),
            l2 = db_get(prefix .. "_l2"),
            l3 = db_get(prefix .. "_l3"),
            l4 = db_get(prefix .. "_l4"),
            l_gt4 = db_get(prefix .. "_l_gt4")
        }
    end

    local res = {len=0, cnt=0, code=0, spd=0, l1=0, l2=0, l3=0, l4=0, l_gt4=0}
    local now_ts = os.time()
    
    for i = 0, days_lookback - 1 do
        local target_ts = now_ts - (i * 86400)
        local t = os.date("*t", target_ts)
        local day_key = string.format("d_%04d%02d%02d", t.year, t.month, t.day)
        
        res.len = res.len + db_get(day_key .. "_len")
        res.cnt = res.cnt + db_get(day_key .. "_cnt")
        res.code = res.code + db_get(day_key .. "_code")
        res.l1 = res.l1 + db_get(day_key .. "_l1")
        res.l2 = res.l2 + db_get(day_key .. "_l2")
        res.l3 = res.l3 + db_get(day_key .. "_l3")
        res.l4 = res.l4 + db_get(day_key .. "_l4")
        res.l_gt4 = res.l_gt4 + db_get(day_key .. "_l_gt4")
        
        local daily_spd = db_get(day_key .. "_spd")
        if daily_spd > res.spd then res.spd = daily_spd end
    end
    return res
end

-- -----------------------------------------------------------------------------
-- UI 渲染
-- -----------------------------------------------------------------------------
local function draw_bar(percent)
    local length = 10
    local filled_len = math.floor((percent / 100) * length)
    local empty_len = length - filled_len
    return string.rep("▓", filled_len) .. string.rep("░", empty_len)
end

local function format_summary(title, data)
    if not data or data.cnt == 0 then return "※ " .. title .. "暂无数据" end
    
    local avg_code = 0
    if data.len > 0 then avg_code = data.code / data.len end
    
    local phrase_rate = 0
    if data.len > 0 then phrase_rate = (data.len - data.l1) / data.len * 100 end

    -- 估算均速 (Average Speed)
    -- 由于没有记录精确的打字时长，这里用一个经验公式估算：
    -- 假设每次上屏平均耗时 1.5 - 2 秒左右，以此倒推一个大概的“均速”用于展示
    -- 公式：字数 / (次数 * 2秒 / 60)
    local estimated_avg_spd = 0
    if data.cnt > 0 then
        estimated_avg_spd = math.floor(data.len / ((data.cnt * 2) / 60))
        -- 修正：如果估算值超过峰值，说明上屏间隔极短（连打），则取峰值的 60%
        if estimated_avg_spd > data.spd then estimated_avg_spd = math.floor(data.spd * 0.6) end
        if estimated_avg_spd == 0 and data.len > 0 then estimated_avg_spd = data.len end -- 极少字数保底
    end

    local p1 = (data.l1 / data.cnt) * 100
    local p2 = (data.l2 / data.cnt) * 100
    local p3 = (data.l3 / data.cnt) * 100
    local p4 = (data.l4 / data.cnt) * 100
    local p_gt4 = (data.l_gt4 / data.cnt) * 100
    local ver = rime_api.get_distribution_version() or ""

    return string.format(
        "※ %s统计 · 效率仪表盘\n" ..
        "───────────────────\n" ..
        "📊 综合数据\n" ..
        "  总字数：%d\t上屏：%d\n" ..
        "  峰值速：%d\t均速：%d\n" ..
        "───────────────────\n" ..
        "⚡ 核心效率\n" ..
        "  平均编码：%.2f 键/字\n" ..
        "  词组连打：%.1f %%\n" ..
        "───────────────────\n" ..
        "📈 字词分布\n" ..
        "  [1] %3d%% %s\n" ..
        "  [2] %3d%% %s\n" ..
        "  [3] %3d%% %s\n" ..
        "  [4] %3d%% %s\n" ..
        "  [≥5] %2d%% %s\n" ..
        "───────────────────\n" ..
        "◉ 方案：%s\n" ..
        "◉ 平台：%s %s",
        title, data.len, data.cnt, 
        data.spd, estimated_avg_spd, -- 峰值与均速并排
        avg_code, phrase_rate,
        p1, draw_bar(p1), 
        p2, draw_bar(p2), 
        p3, draw_bar(p3), 
        p4, draw_bar(p4), 
        p_gt4, draw_bar(p_gt4), -- 改为 ≥5
        schema_name, software_name, ver
    )
end

-- -----------------------------------------------------------------------------
-- Init & Fini
-- -----------------------------------------------------------------------------
local function init(env)
    ensure_db_open()
    if env.stat_notifier then env.stat_notifier:disconnect() end
    local ctx = env.engine.context
    
    env.stat_notifier = ctx.commit_notifier:connect(function(ctx)
        local commit_text = ctx:get_commit_text()
        if not commit_text or commit_text == "" then return end
        if commit_text:sub(1, 1) == "/" then return end
        if commit_text:find("^[※◉]") then return end

        local hanzi_len = get_pure_chinese_length(commit_text)
        if hanzi_len == 0 then return end
        
        local script_text = ctx:get_script_text() or ""
        local code_len = string.len(script_text)
        if code_len == 0 then code_len = hanzi_len * 2 end 

        local now_ms = os.clock()
        if env.last_commit_time and (now_ms - env.last_commit_time < 0.05) then
             if env.last_commit_text == commit_text then return end
        end
        env.last_commit_time = now_ms
        env.last_commit_text = commit_text

        record_stats(hanzi_len, code_len)
    end)
end

local function fini(env)
    if env.stat_notifier then 
        env.stat_notifier:disconnect() 
        env.stat_notifier = nil
    end
    if db and db:loaded() then
        db:close()
    end
end

local function translator(input, seg, env)
    if input:sub(1, 1) ~= "/" then return end
    
    local summary = ""
    local data = nil
    local title = ""

    if input == "/tjql" then
        if clear_all_data() then
            yield(Candidate("stat", seg.start, seg._end, "※ 统计数据已全部清空。", "🗑️"))
        else
            yield(Candidate("stat", seg.start, seg._end, "※ 数据清空失败，请检查权限。", "❌"))
        end
        return
    end

    if input == "/rtj" then title = "今日"; data = aggregate_stats(1)
    elseif input == "/ztj" then title = "七日"; data = aggregate_stats(7)
    elseif input == "/ytj" then title = "卅日"; data = aggregate_stats(30)
    elseif input == "/ntj" then title = "本年"; data = aggregate_stats(365)
    elseif input == "/ttj" then title = "生涯"; data = aggregate_stats(0)
    end

    if data then
        summary = format_summary(title, data)
        yield(Candidate("stat", seg.start, seg._end, summary, "📊"))
    end
end

return { init = init, func = translator, fini = fini }