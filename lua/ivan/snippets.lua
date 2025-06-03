local ls = require 'luasnip'
local fmt = require('luasnip.extras.fmt').fmt

local s = ls.snippet
local i = ls.insert_node
-- local t = ls.text_node
ls.add_snippets('php', {
  s(
    'debug',
    fmt(
      [[
    echo json_encode({});
    die();
  ]],
      { i(1) }
    )
  ),
})
