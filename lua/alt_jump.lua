-- amzxyz@https://github.com/amzxyz/rime_wanxiang
-- lua/alt_jump.lua
-- Alt + 字母：把输入法光标跳到对应字母后面，系统占用了asdt等几个按键不起作用，暂时不，没办法
-- 多个相同字母时轮询跳转（i > caret）

local wanxiang = require("wanxiang")
local R = wanxiang.RIME_PROCESS_RESULTS  -- 简化引用（可选）

----------------------------------------------------------------------
-- 移动光标到“下一个 ch 后面”，并支持轮询
----------------------------------------------------------------------
local function move_to_next_char(context, ch)
    local input = context.input
    if not input or input == "" then
        return false
    end

    local len   = #input
    local caret = context.caret_pos
    if type(caret) ~= "number" then
        caret = 0
    end

    local first_pos = nil
    local next_pos  = nil

    for i = 1, len do
        if input:sub(i, i) == ch then
            if not first_pos then
                first_pos = i
            end
            -- ⚠️ 核心：必须是 i > caret，而不是 i >= caret
            if (i > caret) and (not next_pos) then
                next_pos = i
            end
        end
    end

    if not first_pos then
        return false
    end

    -- 若后面没有相同字母 → 回圈到第一个
    local target = next_pos or first_pos

    context.caret_pos = target
    context:refresh_non_confirmed_composition()
    return true
end

----------------------------------------------------------------------
-- 主处理器：拦截 Alt + 字母
----------------------------------------------------------------------
local function processor(key, env)
    local context = env.engine.context

    if key:release() then
        return R.kNoop
    end

    if not key:alt() then
        return R.kNoop
    end

    if not context:is_composing() then
        return R.kNoop
    end

    local code = key.keycode
    if not code then
        return R.kNoop
    end

    local ch
    if code >= string.byte("a") and code <= string.byte("z") then
        ch = string.char(code)
    elseif code >= string.byte("A") and code <= string.byte("Z") then
        ch = string.char(code + 32)
    else
        return R.kNoop
    end

    if move_to_next_char(context, ch) then
        return R.kAccepted
    else
        return R.kNoop
    end
end

return processor
