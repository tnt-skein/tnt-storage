--- Число без потерь: где double ещё точен и как записать его текстом,
--- не потеряв ни одного разряда.
---
--- Граница точности у всех диалектов одна — у double, в котором число
--- пришло: PostgreSQL и Redis получают число текстом, MongoDB — типом
--- BSON, но NaN, бесконечность и целое за ±2⁵³ не доезжают до сервера
--- тем же ни у кого. Поэтому правило живёт отдельно от диалектов:
--- разнесённое по ним, оно однажды разойдётся — один диалект отвергнет
--- число, а другой молча запишет его с потерей.

local Module = {}

--- Больше этого целое в double уже неточно: 2⁵³ + 1 не представимо.
local EXACT = 2 ^ 53

--- Точные записи числа по возрастанию длины: рок `pg` превращает число
--- в текст `%.14g`, и всё, что длиннее, приходится писать самим.
--- Семнадцати знаков хватает любому double.
local SHORTER = { '%.15g', '%.16g' }
local LONGEST = '%.17g'

--- Проверяет, что число дойдёт до сервера тем же, что дал вызывающий:
--- иначе исключение.
---
--- За ±2⁵³ double хранит не все целые, и число там уже могло потерять
--- точность до вызова: `2^60 + 1` в Lua — это `2^60`. Проверки на целое
--- здесь нет нарочно — дробных за этой границей у double не бывает.
---@param number number
---@param level integer Уровень вины для `error` из кадра того, кто зовёт
function Module.check(number, level)
    if number ~= number or number == math.huge or number == -math.huge then
        error(
            'число — NaN или бесконечность: серверу его не передать',
            level + 1
        )
    end

    if number > EXACT or number < -EXACT then
        error(
            ('число %s за пределом ±2^53: целые там неточны — передайте int64 либо decimal'):format(
                tostring(number)
            ),
            level + 1
        )
    end
end

--- Точная запись числа, которое `%.14g` портит: самая короткая из тех,
--- что читаются обратно тем же числом.
---@param number number
---@return string
local function shortest(number)
    for _, format in ipairs(SHORTER) do
        local text = format:format(number)

        if tonumber(text) == number then
            return text
        end
    end

    return LONGEST:format(number)
end

--- Точная запись числа для текста: целое — цифрами без степени, дробное —
--- самой короткой записью.
---
--- Целое степенью не пишется: `int8` PostgreSQL запись `1.2e+15` не читает,
--- а `INCRBY` Redis её отвергает. Формат `%d` берёт double без потерь
--- до 2⁶³, а сюда число приходит не дальше 2⁵³ — после `check`.
---@param number number
---@return string
function Module.digits(number)
    if math.floor(number) == number then
        return ('%d'):format(number)
    end

    return shortest(number)
end

return Module
