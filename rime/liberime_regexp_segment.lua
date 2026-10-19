-- Public librime-lua APIs only.  This translator is a transport for Emacs;
-- it never selects/commits candidates or updates a user dictionary.
local M = {}

local function backend(env, schema_id)
  if env.backends[schema_id] then return env.backends[schema_id] end
  local source = Schema(schema_id).config
  local dictionary = assert(source:get_string('translator/dictionary'),
    'Source schema has no translator/dictionary')
  local id = assert(env.engine.schema.config:get_string('segment/backends/' .. dictionary),
    'No segmentation backend configured for ' .. dictionary)
  local schema = Schema(id)
  local translator = Component.Translator(env.engine, schema, 'translator', 'script_translator')
  -- Rime compiles a reverse database only for the primary table. Packs share
  -- its syllabary and are searched by the translator, not separate reverse DBs.
  local reverse = assert(ReverseLookup(dictionary),
    'Cannot load reverse dictionary ' .. dictionary .. '; redeploy Rime')
  -- Keep the schema alive for native components created with its ticket.
  local result = {schema = schema, translator = translator, reverse = reverse}
  env.backends[schema_id] = result
  return result
end

local function codes(db, text, limit)
  local result = {}
  for code in db.reverse:lookup(text):gmatch('%S+') do
    result[#result + 1] = code
    if #result == limit then break end
  end
  return result
end

local function phrase_weight(db, code, text, limit)
  local segment = Segment(0, #code)
  segment.tags = Set({'abc'})
  local translation = db.translator:query(code, segment)
  if not translation then return nil end
  local best, count = nil, 0
  for candidate in translation:iter() do
    count = count + 1
    local genuine = candidate:get_genuine()
    if genuine:get_dynamic_type() == 'Phrase' and candidate.type ~= 'completion'
        and candidate.text == text and candidate._end == #code then
      best = math.max(best or -math.huge, genuine:to_phrase().weight)
    end
    if count >= limit then break end
  end
  return best
end

local function unhex(hex)
  return (hex:gsub('..', function(c) return string.char(tonumber(c, 16)) end))
end

local function process(input, env)
  local schema_hex, max_word, combinations, candidates, text_hex =
    input:match('^([0-9a-f]+)g(%d+)g(%d+)g(%d+)g([0-9a-f]*)z$')
  max_word, combinations, candidates = tonumber(max_word), tonumber(combinations), tonumber(candidates)
  local text = unhex(text_hex)
  local db = backend(env, unhex(schema_hex))
  local chars = {}
  for _, cp in utf8.codes(text) do chars[#chars + 1] = utf8.char(cp) end
  local records = {}
  local char_codes, lookup_cache = {}, {}
  for i, char in ipairs(chars) do char_codes[i] = codes(db, char, combinations) end
  for first = 1, #chars do
    local spellings = {''}
    for last = first, math.min(#chars, first + max_word - 1) do
      local next_spellings = {}
      for _, prefix in ipairs(spellings) do
        for _, code in ipairs(char_codes[last]) do
          next_spellings[#next_spellings + 1] = prefix == '' and code or prefix .. "'" .. code
          if #next_spellings == combinations then break end
        end
        if #next_spellings == combinations then break end
      end
      spellings = next_spellings
      local word = table.concat(chars, '', first, last)
      local weight = lookup_cache[word]
      if weight == nil then
        -- Direct codes also allow single-spelling phrases in shape dictionaries.
        local queries, seen = codes(db, word, combinations), {}
        for _, code in ipairs(queries) do seen[code] = true end
        for _, code in ipairs(spellings) do
          if #queries >= combinations then break end
          if not seen[code] then
            queries[#queries + 1], seen[code] = code, true
          end
        end
        for _, code in ipairs(queries) do
          local value = phrase_weight(db, code, word, candidates)
          if value then weight = math.max(weight or -math.huge, value) end
        end
        lookup_cache[word] = weight or false
      end
      if weight then
        records[#records + 1] = string.format('[%d,%d,%.17g]', first - 1, last, weight)
      end
    end
  end
  records[#records + 1] = 'done'
  return records
end

function M.init(env)
  env.backends = {}
end

function M.func(input, segment, env)
  -- liberime-search simulates keys.  Do no dictionary work on partial input.
  if input:sub(-1) ~= 'z' then return end
  local ok, records = pcall(process, input, env)
  if ok then
    for _, record in ipairs(records) do
      yield(Candidate('segment', segment.start, segment._end, record, ''))
    end
  else
    yield(Candidate('segment', segment.start, segment._end, 'error', tostring(records)))
  end
end

return M
