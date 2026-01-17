-- lua/super_english.lua
-- https://github.com/amzxyz/rime_wanxiang
-- @description: 英文全能处理器 (Filter Only: 锚点切分 + 动态分隔符 + 超时销毁)
-- @author: amzxyz

-- 核心功能清单:
-- 1. [Format] 语句级英文大写格式化,逐词大小写对应 (look HELLO -> look HELLO)
-- 2. [Spacing] 智能语句空格切分，智能单词上屏加空格 (Smart Spacing) 与无损分词还原
-- 3. [Memory] 全量历史缓存，完美解决回删乱码问题
-- 4. [Construct] 原生优先构造策略 (短词无分词则重置为原生输入)
-- 5. [Order] 单字母(a/A) 智能插队排序,补齐单字母候选

local F = {}

-- 引入常用函数
local byte = string.byte
local find = string.find
local gsub = string.gsub
local upper = string.upper
local lower = string.lower
local sub = string.sub
local match = string.match
local format = string.format
local STICKY_BUFFER_SIZE = 2  --输入/\的情况下，继续输入3个单词不加空格，适合网址路径
-- 辅助函数：获取候选类型
local function fast_type(c)
    local t = c.type
    if t then return t end
    local g = c.get_genuine and c:get_genuine() or nil
    return (g and g.type) or ""
end

-- 辅助函数：判断是否为置顶表词汇
local function is_table_type(c)
    local t = fast_type(c)
    return t == "user_table" or t == "fixed"
end
-- [Time] 封装统一的时间获取函数 (单位: 秒, 带小数)
local function get_now()
    -- 使用用户指定的原生 API (毫秒转秒，以便和配置文件里的 0.5 秒兼容)
    if rime_api and rime_api.get_time_ms then
        return rime_api.get_time_ms() / 1000
    end
    --以此为保底，防止 API 不存在时报错
    return os.time()
end

local function pure(s)
    return gsub(s, "[^a-zA-Z]", ""):lower()
end
local no_spacing_words = {
    ["http"]  = true,
    ["https"] = true,
    ["www"]   = true,
    ["ftp"]   = true,
    ["ssh"]   = true,
    ["mailto"]= true,
    ["file"]  = true,
    ["tel"]   = true,
}
local allowed_ascii_symbols = {
    [33] = true,  -- !
    [39] = true,  -- ' (Don't)
    [44] = true,  -- ,
    [45] = true,  -- - (Co-op)
    [46] = true,  -- .
    [63] = true,  -- ?
    [92] = true,  -- \
    -- 数字 0-9 (ASCII 48-57)
    [48]=true, [49]=true, [50]=true, [51]=true, [52]=true,
    [53]=true, [54]=true, [55]=true, [56]=true, [57]=true,
}
-- 规则：只允许 字母(A-Za-z) 和 上面配置表里的符号
local function is_ascii_phrase_fast(s)
    if not s or s == "" then return false end
    local len = #s
    for i = 1, len do
        local b = byte(s, i)
        -- 1. 判断是否为大写字母 A-Z (65-90)
        local is_upper = (b >= 65 and b <= 90)
        -- 2. 判断是否为小写字母 a-z (97-122)
        local is_lower = (b >= 97 and b <= 122)
        -- 3. 判断是否为白名单符号
        local is_allowed_sym = allowed_ascii_symbols[b]
        if not (is_upper or is_lower or is_allowed_sym) then
            return false
        end
    end
    return true
end

local function has_letters(s)
    return find(s, "[a-zA-Z]")
end

-- 序列匹配：返回 (首字母位置, 最后一个匹配字符的位置)
local function find_target_in_text(text, start_pos, target_fp)
    local text_len = #text
    local target_len = #target_fp
    if target_len == 0 then return nil, nil end

    local t_idx = 1       
    local scan_p = start_pos 
    local s_index = nil   

    while scan_p <= text_len and t_idx <= target_len do
        local char_txt = sub(text, scan_p, scan_p)
        if lower(char_txt) == sub(target_fp, t_idx, t_idx) then
            if t_idx == 1 then s_index = scan_p end 
            t_idx = t_idx + 1
        end
        scan_p = scan_p + 1
    end

    if t_idx > target_len then
        return s_index, scan_p - 1
    end
    return nil, nil
end

-- 2. 核心逻辑：格式化与还原
local function restore_sentence_spacing(cand, split_pattern, check_pattern)
    local guide = cand.preedit or ""
    if not find(guide, check_pattern) then return cand end

    local text = cand.text
    local targets = {}
    for seg in string.gmatch(guide, split_pattern) do
        local t = pure(seg)
        if #t > 0 then table.insert(targets, t) end
    end
    if #targets == 0 then return cand end

    local starts = {}
    local p = 1
    for _, target in ipairs(targets) do
        local s, e = find_target_in_text(text, p, target)
        if not s then return cand end
        table.insert(starts, s)
        p = e + 1 
    end

    local parts = {}
    if starts[1] > 1 then
        table.insert(parts, sub(text, 1, starts[1] - 1))
    end

    for i = 1, #starts do
        local current_s = starts[i]
        local next_s = starts[i+1]
        local chunk_end = next_s and (next_s - 1) or #text
        table.insert(parts, sub(text, current_s, chunk_end))
    end

    local new_text = ""
    for i, part in ipairs(parts) do
        if i == 1 then
            new_text = part
        else
            local last_char = sub(new_text, -1)
            if last_char == "'" or last_char == "-" then
                new_text = new_text .. part
            else
                new_text = new_text .. " " .. part
            end
        end
    end
    new_text = gsub(new_text, "%s%s+", " ") 
    
    if new_text == "" then return cand end
    
    local nc = Candidate(cand.type, cand.start, cand._end, new_text, cand.comment)
    nc.preedit = cand.preedit
    return nc
end

local NBSP = string.char(0xC2, 0xA0)

local function apply_segment_formatting(text, input_code)
    if not input_code or input_code == "" then return text end
    
    local parts = {}
    local p_code = 1 
    
    for word in string.gmatch(text, "%S+") do
        local clean_word = pure(word)
        local w_len = #clean_word
        
        if w_len > 0 then
            if find(word, "[\128-\255]") then
                local input_remain = #input_code - p_code + 1
                if input_remain > 0 then
                     local check_len = (w_len < input_remain) and w_len or input_remain
                     p_code = p_code + check_len
                end
            else
                local input_remain = #input_code - p_code + 1
                if input_remain > 0 then
                    local check_len = (w_len < input_remain) and w_len or input_remain
                    local segment = sub(input_code, p_code, p_code + check_len - 1)
                    local is_pure_alpha = not find(word, "[^a-zA-Z]")
                    
                    if find(segment, "^%u%u") and is_pure_alpha then
                        word = upper(word)
                    elseif find(segment, "^%u") then
                        word = gsub(word, "^%a", upper)
                    end
                    p_code = p_code + check_len
                end
            end
        end
        table.insert(parts, word)
    end
    
    return table.concat(parts, " ")
end

local function apply_formatting(cand, code_ctx)
    local text = cand.text
    if not text or text == "" then return cand end
    local changed = false
    
    local norm = gsub(text, NBSP, " ")
    if norm ~= text then text = norm; changed = true end

    if is_ascii_phrase_fast(text) and has_letters(text) then
        if code_ctx.raw_input then
            local new_text = apply_segment_formatting(text, code_ctx.raw_input)
            if new_text ~= text then 
                text = new_text
                changed = true 
            end
        end

        if code_ctx.spacing_mode and code_ctx.spacing_mode ~= "off" then
            local mode = code_ctx.spacing_mode
            if mode == "smart" then
                if code_ctx.prev_is_eng then 
                    if not find(text, "^%s") then text = " " .. text; changed = true end
                end
            elseif mode == "before" then 
                if not find(text, "^%s") then text = " " .. text; changed = true end
            elseif mode == "after" then 
                if not find(text, "%s$") then text = text .. " "; changed = true end
            end
        end
    end

    if not changed then return cand end
    local nc = Candidate(cand.type, cand.start, cand._end, text, cand.comment)
    nc.preedit = cand.preedit
    return nc
end

-- 3. 状态管理 (Filter)
function F.init(env)
    env.memory = {}
    local cfg = env.engine.schema.config
    
    -- 1. 配置读取
    env.english_spacing_mode = "off"
    env.spacing_timeout = 0 
    env.lookup_key = "`"
    if cfg then
        local str = cfg:get_string("wanxiang_english/english_spacing")
        if str then env.english_spacing_mode = str end
        
        -- 读取超时 (单位: 秒, 支持小数)
        local timeout = cfg:get_double("wanxiang_english/spacing_timeout")
        if timeout then env.spacing_timeout = timeout end
        local key = cfg:get_string("wanxiang_lookup/key")
        if key and key ~= "" then env.lookup_key = key end
    end
    env.lookup_key_esc = gsub(env.lookup_key, "([%%%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    -- 2. 动态获取分隔符
    local delimiter_str = " '" 
    if cfg then
        delimiter_str = cfg:get_string('speller/delimiter') or delimiter_str
    end
    env.delimiter_char = sub(delimiter_str, 1, 1)  --提取自动分词符号
    local escaped_delims = gsub(delimiter_str, "([%%%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    env.split_pattern = "[^" .. escaped_delims .. "]+"     
    env.delim_check_pattern = "[" .. escaped_delims .. "]" 

    env.prev_commit_is_eng = false
    env.last_commit_time = 0   --记录上次提交时间
    env.comp_start_time = nil  -- 记录本次输入开始的时间
    env.spacing_active = false  
    env.decision_locked = false 
    env.sticky_countdown = 0    -- 粘性倒计时
    if env.engine.context then
        env.update_notifier = env.engine.context.update_notifier:connect(function(ctx)
            local curr_input = ctx.input
            -- 检测当前输入是否包含反查符
            if env.lookup_key and find(curr_input, env.lookup_key, 1, true) then
                env.block_derivation = true
            else
                env.block_derivation = false
            end
            -- 如果输入框为空，重置开始时间
            if curr_input == "" then
                env.comp_start_time = nil
            -- 如果输入框不为空，且还没记录开始时间，说明是“刚刚开始打字”
            elseif env.comp_start_time == nil then
                env.comp_start_time = get_now()
            end
        end)
        env.commit_notifier = env.engine.context.commit_notifier:connect(function(ctx)
            local commit_text = ctx:get_commit_text()
            -- 1. 先剔除空格，防止死循环
            local text_no_space = gsub(commit_text, "%s", "")
            local is_eng = is_ascii_phrase_fast(text_no_space)
            
            -- 2. 粘性触发 (结尾是 / 或 \)
            if find(text_no_space, "[/\\\\]$") then
                env.sticky_countdown = STICKY_BUFFER_SIZE
                is_eng = false 
            -- 3. 粘性缓冲期 (倒计时)
            elseif env.sticky_countdown > 0 then
                if is_eng then
                    -- 只要是英文，消耗一次缓冲，并强制不加空格
                    env.sticky_countdown = env.sticky_countdown - 1
                    is_eng = false 
                else
                    -- 遇到非英文(中文等)，打断缓冲
                    env.sticky_countdown = 0
                end
            -- 4. 普通黑名单 (http等)
            elseif is_eng then
                local clean = gsub(commit_text, "%s+$", ""):lower()
                if no_spacing_words[clean] then
                    is_eng = false
                end
            end
            env.prev_commit_is_eng = is_eng
            -- 仅英文上屏更新时间戳 (使用 rime_api 获取)
            if is_eng then
                env.last_commit_time = get_now()
            else
                env.last_commit_time = 0
            end
            ctx:set_property("english_spacing", "")
            env.block_derivation = false
        end)
    end
end

function F.fini(env)
    if env.update_notifier then env.update_notifier:disconnect(); env.update_notifier = nil end
    if env.commit_notifier then env.commit_notifier:disconnect(); env.commit_notifier = nil end
    env.memory = nil
end

-- 4. 主逻辑 (Filter)

function F.func(input, env)
    local ctx = env.engine.context
    local curr_input = ctx.input
    local has_valid_candidate = false
    local best_candidate_saved = false
    local code_len = #curr_input

    if code_len > 2 and sub(curr_input, -2) == "\\\\" then
        local raw_text = sub(curr_input, 1, code_len - 2)
        
        if is_ascii_phrase_fast(raw_text) then
            if ctx.composition and not ctx.composition:empty() then
                ctx.composition:back().prompt = "〔英文造词〕"
            end
            local cand = Candidate("english", 0, code_len, raw_text, "")
            cand.preedit = raw_text 
            yield(cand)
            return -- 强制结束，独占输出
        end
    end
    -- [Check 1] 外部脚本发来的打断信号
    local break_signal = (ctx:get_property("english_spacing") == "true")
    local effective_prev_is_eng = env.prev_commit_is_eng

    if break_signal then 
        effective_prev_is_eng = false
        env.prev_commit_is_eng = false
        
    -- [Check 2] 时间自然过期
    elseif effective_prev_is_eng and env.spacing_timeout > 0 then
        -- 取“输入开始时间”保证输入中
        local check_time = env.comp_start_time or get_now()
        -- 计算间隙：(开始打字时间 - 上次上屏时间)
        if (check_time - env.last_commit_time) > env.spacing_timeout then
            effective_prev_is_eng = false
            env.prev_commit_is_eng = false 
        end
    end

    local code_ctx = {
        raw_input = curr_input, 
        spacing_mode = env.english_spacing_mode,
        prev_is_eng = effective_prev_is_eng
    }

    local single_char_injected = false
    local single_chars = {}
    
    if code_len == 1 then
        local b = byte(curr_input)
        local is_upper = (b >= 65 and b <= 90)
        local is_lower = (b >= 97 and b <= 122)
        
        if is_upper or is_lower then
            -- 根据输入大小写决定排序：输入 N -> [N, n]; 输入 n -> [n, N]
            local t1 = curr_input
            local t2 = is_upper and lower(curr_input) or upper(curr_input)
            
            table.insert(single_chars, Candidate("completion", 0, 1, t1, ""))
            table.insert(single_chars, Candidate("completion", 0, 1, t2, ""))
        else
            single_char_injected = true 
        end
    else 
        single_char_injected = true 
    end

    for cand in input:iter() do
        local good_cand = restore_sentence_spacing(cand, env.split_pattern, env.delim_check_pattern)
        local fmt_cand = apply_formatting(good_cand, code_ctx)
        local is_ascii = is_ascii_phrase_fast(good_cand.text) 
        local is_tbl = is_table_type(cand)

        -- [策略1]：如果是普通词(completion)，还没输出单字母，则“插队”到它前面
        -- 场景：无高频词时，输出 A, a, able...
        if not single_char_injected and is_ascii and #single_chars > 0 and not is_tbl then
            if not best_candidate_saved then
                env.memory[curr_input] = { text = single_chars[1].text, preedit = single_chars[1].text }
                best_candidate_saved = true
            end
            for _, c in ipairs(single_chars) do yield(c) end
            single_char_injected = true
            has_valid_candidate = true 
        end

        local is_garbage = (cand.type == "raw") or (fmt_cand.text == curr_input)
        
        if not is_garbage then
            has_valid_candidate = true
            if not best_candidate_saved and cand.comment ~= "~" and not env.block_derivation then
                env.memory[curr_input] = {
                    text = fmt_cand.text,
                    preedit = fmt_cand.preedit or fmt_cand.text
                }
                best_candidate_saved = true
            end
        end
        
        yield(fmt_cand)

        -- [策略2]：如果是用户词(user_table/fixed)，且还没输出单字母，则“紧随”其后输出
        -- 场景：有高频词时，输出 AA, A, a, AB...
        if not single_char_injected and is_ascii and #single_chars > 0 and is_tbl then
             if not best_candidate_saved then
                env.memory[curr_input] = { text = single_chars[1].text, preedit = single_chars[1].text }
                best_candidate_saved = true
            end
            for _, c in ipairs(single_chars) do yield(c) end
            single_char_injected = true
            has_valid_candidate = true 
        end
    end

    -- [Phase 3] 构造补全
    if not has_valid_candidate then
        -- 如果设置了拦截标志 (意味着刚刚从反查模式退出来)，则即使有记忆也不派生！
        if env.block_derivation then return end
        if find(curr_input, "^[/]") then return end
        if not has_letters(curr_input) then return end
        local anchor = nil
        local diff = ""
        
        for i = #curr_input - 1, 1, -1 do
            local prefix = sub(curr_input, 1, i)
            if env.memory[prefix] then
                anchor = env.memory[prefix]
                diff = sub(curr_input, i + 1)
                break
            end
        end
        
        if anchor and diff ~= "" then
            local has_spacing = find(anchor.text, " ")
            local last_word = match(anchor.text, "(%S+)%s*$") or ""
            local last_len = #last_word
            
            local output_text = ""
            local output_preedit = ""
            
            -- 英文构造策略
            if is_ascii_phrase_fast(anchor.text) then
                -- === 英文逻辑：拼接 diff，长词加空格 ===
                if has_spacing then
                    output_text = anchor.text .. diff
                    output_preedit = (anchor.preedit or anchor.text) .. diff
                elseif last_len > 3 then
                    local spacer = " "
                    if sub(anchor.text, -1) == " " then spacer = "" end
                    output_text = anchor.text .. spacer .. diff
                    output_preedit = (anchor.preedit or anchor.text) .. spacer .. diff
                else
                    output_text = curr_input
                    output_preedit = curr_input
                end
            else
                -- 中文逻辑：只显示历史词 (anchor)，丢弃 diff
                -- 输入 nil -> anchor="你", diff="l" 注释 "~"
                output_text = anchor.text
                
                -- preedit 依然保留 diff，但中间加入自动分词符号
                output_preedit = (anchor.preedit or anchor.text) .. env.delimiter_char .. diff
            end
            
            output_text = apply_segment_formatting(output_text, curr_input)
            
            local cand = Candidate("completion", 0, #curr_input, output_text, "~")
            cand.preedit = output_preedit
            cand.quality = 999
            yield(cand)
        else
            local cand = Candidate("completion", 0, #curr_input, curr_input, "~")
            cand.preedit = curr_input
            yield(cand)
        end
    end
end

return F