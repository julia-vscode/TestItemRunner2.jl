# For easier dev, switch these two lines
const pkg_root = "../packages"
# const pkg_root = "~/.julia/dev"

include(joinpath(pkg_root, "Tokenize", "src", "Tokenize.jl"))
include(joinpath(pkg_root, "JSON", "src", "JSON.jl"))
include(joinpath(pkg_root, "URIParser", "src", "URIParser.jl"))
include(joinpath(pkg_root, "ProgressMeter", "src", "ProgressMeter.jl"))

module CSTParser
    using ..Tokenize
    import ..Tokenize.Tokens
    import ..Tokenize.Tokens: RawToken, AbstractToken, iskeyword, isliteral, isoperator, untokenize
    import ..Tokenize.Lexers: Lexer, peekchar, iswhitespace, readchar, emit, emit_error,  accept_batch, eof
    import ..pkg_root

    include(joinpath(pkg_root, "CSTParser", "src", "packagedef.jl"))
end

module TestItemDetection
    import ..CSTParser
    using ..CSTParser: EXPR
    import ..pkg_root

    include(joinpath(pkg_root, "TestItemDetection", "src", "packagedef.jl"))
end

module JSONRPC
    import UUIDs
    import ..JSON
    import ..pkg_root

    include(joinpath(pkg_root, "JSONRPC", "src", "packagedef.jl"))
end

import .CSTParser, TOML, UUIDs, Sockets
using .CSTParser: EXPR, parentof, headof
using .JSONRPC: @dict_readable
using .TestItemDetection: find_test_detail!

include(joinpath(pkg_root, "TestItemServer", "src", "testserver_protocol.jl"))
include(joinpath(pkg_root, "TestItemServer", "src", "helper.jl"))
