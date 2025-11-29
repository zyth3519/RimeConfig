-- @amzxyz https://github.com/amzxyz/rime_wanxiang
-- 自动造词
local AP = {}

-- 注释缓存：text -> comment（只给中文造词用）
local comment_cache = {}

-- 工具：是否纯英文（ASCII 且至少 1 个字母）
local function is_ascii_word(text)
    if not text or text == "" then
        return false
    end
    local has_alpha = false
    for i = 1, #text do
        local b = text:byte(i)
        if b > 127 then
            return false
        end
        if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then
            has_alpha = true
        end
    end
    return has_alpha
end

-- 判断字符是否为汉字（原逻辑）
function AP.is_chinese_only(text)
    local non_chinese_pattern = "[%w%p]"

    if not text or text == "" then
        return false
    end

    if text:match(non_chinese_pattern) then
        return false
    end

    for _, cp in utf8.codes(text) do
        -- 常用汉字区 + 扩展 A/B/C/D/E/F/G
        if not (
            (cp >= 0x4E00 and cp <= 0x9FFF) or -- CJK Unified Ideographs
            (cp >= 0x3400 and cp <= 0x4DBF) or -- CJK Ext-A
            (cp >= 0x20000 and cp <= 0x2EBEF)  -- CJK Ext-B~G
        ) then
            return false
        end
    end
    return true
end

function AP.init(env)
    local config = env.engine.schema.config
    local ctx    = env.engine.context

    -- 中文自动造词的开关（只控制 add_user_dict）
    local enable_auto_phrase =
        config:get_bool("add_user_dict/enable_auto_phrase") or false
    local enable_user_dict  =
        config:get_bool("add_user_dict/enable_user_dict") or false

    -- 中文：add_user_dict（受 add_* 开关影响）
    if enable_auto_phrase and enable_user_dict then
        env.memory = Memory(env.engine, env.engine.schema, "add_user_dict")
    else
        env.memory = nil
    end

    -- 英文：enuser（不受 add_* 开关影响，始终尝试启用）
    env.en_memory = Memory(env.engine, env.engine.schema, "wanxiang_mixedcode")

    -- 只要有一边需要，就挂上 commit/delete 通知
    if env.en_memory or env.memory then
        env._commit_conn = ctx.commit_notifier:connect(function(c)
            AP.commit_handler(c, env)
        end)

        env._delete_conn = ctx.delete_notifier:connect(function(_)
            comment_cache = {}
        end)
    end
end

function AP.fini(env)
    if env._commit_conn then
        env._commit_conn:disconnect()
        env._commit_conn = nil
    end

    if env._delete_conn then
        env._delete_conn:disconnect()
        env._delete_conn = nil
    end

    if env.memory then
        env.memory:disconnect()
        env.memory = nil
    end

    if env.en_memory then
        env.en_memory:disconnect()
        env.en_memory = nil
    end
end

function AP.save_comment_cache(cand)
    local comment      = cand.comment
    local comment_text = cand.text

    if comment_text and comment_text ~= "" and comment and comment ~= "" then
        comment_cache[comment_text] = comment
    end
end

-- 入口（lua_filter）
function AP.func(input, env)
    local config  = env.engine.schema.config
    local context = env.engine.context

    local use_comment_cache = env.memory ~= nil  -- 只有中文造词才需要缓存注释

    for cand in input:iter() do
        local genuine_cand    = cand:get_genuine()
        local preedit         = genuine_cand.preedit or ""
        local initial_comment = genuine_cand.comment

        if use_comment_cache then
            AP.save_comment_cache(cand)
        end

        yield(cand)
    end
end

-- 造词（原逻辑 + 新增 '\' 英文造词）
function AP.commit_handler(ctx, env)
    if not ctx or not ctx.composition then
        comment_cache = {}
        return
    end

    local segments       = ctx.composition:toSegmentation():get_segments()
    local segments_count = #segments
    local commit_text    = ctx:get_commit_text() or ""
    local raw_input      = ctx.input or ""

    ---------------------------------------------------
    -- ① 英文 + '\' 造词 —— 始终启用，只依赖 env.en_memory
    -- 条件：
    --   - raw_input 末尾为 '\'
    --   - commit_text 为“ASCII 且至少 1 字母”的英文
    -- 行为：
    --   - text        = commit_text
    --   - custom_code = 编码去掉末尾 '\' + 空格
    ---------------------------------------------------
    if raw_input ~= "" and raw_input:sub(-1) == "\\" and is_ascii_word(commit_text) then
        local code_body = raw_input:gsub("\\+$", "")   -- 去掉末尾连续 '\'
        code_body = code_body:gsub("%s+$", "")         -- 去掉尾部空白

        if code_body ~= "" and env.en_memory then
            local entry = DictEntry()
            entry.text        = commit_text          -- 上屏英文本身
            entry.weight      = 1
            entry.custom_code = code_body .. " "     -- 真实编码（无 '\') + 空格

            env.en_memory:update_userdict(entry, 1, "")
            -- log.info(string.format("[auto_phrase] EN 造词：[%s], code=[%s]", entry.text, entry.custom_code))
        end

        comment_cache = {}
        return
    end

    ---------------------------------------------------
    -- ② 中文自动造词：只在 env.memory 存在时工作
    ---------------------------------------------------
    if not env.memory then
        -- 中文造词功能被关掉时，直接跳过这一段
        comment_cache = {}
        return
    end

    -- 检查是否符合最小造词单元要求
    if segments_count <= 1 or utf8.len(commit_text) <= 1 then
        comment_cache = {}
        return
    end

    -- 检查是否符合造词内容要求
    if not AP.is_chinese_only(commit_text) or comment_cache[commit_text] then
        comment_cache = {}
        return
    end

    local preedits_table = {}
    local config = env.engine.schema.config
    local delimiter = config:get_string("speller/delimiter") or " '"
    local escaped_delimiter =
        utf8.char(utf8.codepoint(delimiter)):gsub("(%W)", "%%%1")

    for i = 1, segments_count do
        local seg  = segments[i]
        local cand = seg:get_selected_candidate()

        if cand then
            local cand_text = cand.text
            local preedit   = comment_cache[cand_text]

            if preedit and preedit ~= "" then
                for part in preedit:gmatch("[^" .. escaped_delimiter .. "]+") do
                    table.insert(preedits_table, part)
                end
            end
        end
    end

    if #preedits_table == 0 then
        comment_cache = {}
        return
    end

    local dictEntry = DictEntry()
    dictEntry.text        = commit_text
    dictEntry.weight      = 1
    dictEntry.custom_code = table.concat(preedits_table, " ") .. " "

    env.memory:update_userdict(dictEntry, 1, "")

    comment_cache = {}
end

return AP
