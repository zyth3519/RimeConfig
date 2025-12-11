--@amzxyz https://github.com/amzxyz/rime_wanxiang

--wanxiang_lookup: #设置归属于super_lookup.lua
  --tags: [ abc ]  # 检索当前tag的候选
  --key: "`"       # 输入中反查引导符，要添加到 speller/alphabet
  --lookup: [ wanxiang_reverse ] #反查滤镜数据库，万象都合并为一个了

------------------------------------------------------------
-- 工具函数
------------------------------------------------------------
local function alt_lua_punc(s)
    return s and s:gsub('([%.%+%-%*%?%[%]%^%$%(%)%%])', '%%%1') or ''
end

local function is_all_upper(s) return s:match('^%u+$') ~= nil end
local function is_all_lower(s) return s:match('^%l+$') ~= nil end

------------------------------------------------------------
-- 规则加载
------------------------------------------------------------
local function parse_and_separate_rules(schema_id)
    if not schema_id or #schema_id == 0 then return nil, nil end
    local schema = Schema(schema_id)
    if not schema then return nil, nil end
    local config = schema.config
    if not config then return nil, nil end
    local algebra_list = config:get_list('speller/algebra')
    if not algebra_list or algebra_list.size == 0 then return nil, nil end
    
    local main_rules, xlit_rules = {}, {}
    for i = 0, algebra_list.size - 1 do
        local rule = algebra_list:get_value_at(i).value
        if rule and #rule > 0 then
            if rule:match("^xlit/HSPZN/") then
                table.insert(xlit_rules, rule)
            else
                table.insert(main_rules, rule)
            end
        end
    end
    if #main_rules == 0 and #xlit_rules == 0 then return nil, nil end
    return main_rules, xlit_rules
end

local function get_schema_rules(env)
    local config = env.engine.schema.config
    local db_list = config:get_list("wanxiang_lookup/lookup")
    if not db_list or db_list.size == 0 then return {}, {} end
    local schema_id = db_list:get_value_at(0).value
    if not schema_id or #schema_id == 0 then return {}, {} end
    local main_rules, xlit_rules = parse_and_separate_rules(schema_id)
    if not main_rules and not xlit_rules then return {}, {} end
    return main_rules or {}, xlit_rules or {}
end

------------------------------------------------------------
-- 核心逻辑
------------------------------------------------------------
local function expand_code_variant(main_projection, xlit_projection, part)
    local out, seen = {}, {}
    local function add(s) 
        if s and #s > 0 and not seen[s] then
            seen[s] = true
            out[#out + 1] = s
        end 
    end

    add(part)
    if main_projection then
        local p = main_projection:apply(part, true)
        if p and #p > 0 then add(p) end
    end
    
    local base = {}
    for i = 1, #out do 
        local elem = out[i]
        if is_all_lower(elem) then base[#base + 1] = elem end
    end
    for _, s in ipairs(base) do
        if #s == 4 and is_all_lower(s) then
            add(s:sub(1,1) .. s:sub(3,3))
        end
    end
    if is_all_upper(part) and xlit_projection then
        local xlit_result = xlit_projection:apply(part, true)
        if xlit_result and #xlit_result > 0 then add(xlit_result) end
    end
    return out
end

local function build_reverse_group(main_projection, xlit_projection, db_table, text)
    local group, seen = {}, {}
    for _, db in ipairs(db_table) do
        local code = db:lookup(text)
        if code and #code > 0 then
            for part in code:gmatch('%S+') do
                local variants = expand_code_variant(main_projection, xlit_projection, part)
                for _, v in ipairs(variants) do 
                    if not seen[v] then
                        seen[v] = true
                        group[#group + 1] = v
                    end
                end
            end
        end
    end
    return group
end

local function group_match(group, fuma)
    if not group then return false end
    for i = 1, #group do
        if tostring(group[i]):sub(1, #fuma) == fuma then return true end
    end
    return false
end

------------------------------------------------------------
-- 过滤器主体
------------------------------------------------------------
local f = {}

function f.init(env)
    local config = env.engine.schema.config
    env.if_reverse_lookup = false
    env.db_table = nil
    
    local db = config:get_list("wanxiang_lookup/lookup")
    if db and db.size > 0 then
        env.db_table = {}
        for i = 0, db.size - 1 do
            table.insert(env.db_table, ReverseLookup(db:get_value_at(i).value))
        end
        env.if_reverse_lookup = true
    else
        return
    end

    local main_rules, xlit_rules = get_schema_rules(env)
    env.main_projection = (type(main_rules) == 'table' and #main_rules > 0) and Projection() or nil
    if env.main_projection then env.main_projection:load(main_rules) end
    
    env.xlit_projection = (type(xlit_rules) == 'table' and #xlit_rules > 0) and Projection() or nil
    if env.xlit_projection then env.xlit_projection:load(xlit_rules) end

    env.search_key_str = config:get_string('wanxiang_lookup/key') or '`'
    env.search_key_alt = alt_lua_punc(env.search_key_str)

    local tag = config:get_list('wanxiang_lookup/tags')
    if tag and tag.size > 0 then
        env.tag = {}
        for i = 0, tag.size - 1 do
            table.insert(env.tag, tag:get_value_at(i).value)
        end
    else
        env.tag = { 'abc' }
    end

    env.notifier = env.engine.context.select_notifier:connect(function(ctx)
        local input = ctx.input
        local code = input:match('^(.-)' .. env.search_key_alt)
        if (not code or #code == 0) then return end
        local preedit = ctx:get_preedit()
        local no_search_string = input:match('^(.-)' .. env.search_key_alt)
        local edit = preedit.text:match('^(.-)' .. env.search_key_alt)
        if edit and edit:match('[%w;]') then
            ctx.input = no_search_string .. env.search_key_str
        else
            ctx.input = no_search_string
            env.commit_code = no_search_string
            ctx:commit()
        end
    end)

    -- 【安全缓存】初始化
    env._global_group_cache = {}
    env.cache_size = 0 -- 计数器
end

function f.func(input, env)
    if not env.if_reverse_lookup then
        for cand in input:iter() do yield(cand) end
        return
    end

    local ctx_input = env.engine.context.input
    local s_start, s_end = ctx_input:find(env.search_key_alt, 1, false)
    
    if not s_start then
        for cand in input:iter() do yield(cand) end
        return
    end

    local fuma = ctx_input:sub(s_end + 1)
    
    -- 【惰性检查】无辅码，直接显示，不查库
    if #fuma == 0 then
        for cand in input:iter() do yield(cand) end
        return
    end

    local fuma_segments = {}
    for segment in fuma:gmatch('[^' .. env.search_key_alt .. ']+') do
         table.insert(fuma_segments, string.lower(segment))
    end
    
    local if_single_char_first = env.engine.context:get_option('char_priority')
    local long_word_cands = {}
    local cache = env._global_group_cache

    -- 如果缓存条目超过 3000，清空重来
    -- 3000个字足以覆盖99.9%的日常输入，且仅占用极小内存
    if env.cache_size > 3000 then
        env._global_group_cache = {}
        env.cache_size = 0
        cache = env._global_group_cache -- 更新引用
    end

    for cand in input:iter() do
        if cand.type == 'sentence' then goto skip end
        
        local cand_text = cand.text
        
        -- 西文跳过
        local b = string.byte(cand_text, 1)
        if b and b < 128 then goto skip end

        local cand_len = utf8.len(cand_text)
        
        local characters = {}
        local pos = 1
        for i = 1, cand_len do
            local next_pos = utf8.offset(cand_text, i + 1)
            local char_str = cand_text:sub(pos, next_pos and next_pos - 1)
            characters[i] = char_str
            pos = next_pos
            
            -- 【全局缓存】带计数
            if not cache[char_str] then
                cache[char_str] = build_reverse_group(env.main_projection, env.xlit_projection, env.db_table, char_str)
                env.cache_size = env.cache_size + 1 -- 增加计数
            end
        end

        local ok = true
        if #fuma_segments == 1 and cand_len == 1 then
            ok = group_match(cache[characters[1]], fuma_segments[1])
        elseif #fuma_segments > 0 and cand_len > 1 then
            local match_count = (#fuma_segments < cand_len) and #fuma_segments or cand_len
            for i = 1, match_count do
                if not group_match(cache[characters[i]], fuma_segments[i]) then
                    ok = false
                    break
                end
            end
        else
             if cand_len < #fuma_segments then ok = false end
        end

        if ok then
            if if_single_char_first and cand_len > 1 then
                table.insert(long_word_cands, cand)
            else
                yield(cand)
            end
        end
        ::skip::
    end

    for _, c in ipairs(long_word_cands) do yield(c) end
end

function f.tags_match(seg, env)
    for _, v in ipairs(env.tag) do if seg.tags[v] then return true end end
    return false
end

function f.fini(env)
    if env.if_reverse_lookup and env.notifier then env.notifier:disconnect() end
    env.db_table = nil
    env._global_group_cache = nil
    collectgarbage('collect')
end

return f