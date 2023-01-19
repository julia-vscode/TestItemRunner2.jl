# For easier dev, switch these two lines
const pkg_root = "../packages"
# const pkg_root = joinpath(homedir(), ".julia", "dev")

import JSON, JSONRPC, ProgressMeter

module TestItemDetection
    import CSTParser
    using CSTParser: EXPR

    import JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace
    using JuliaWorkspaces.URIs2: URI, filepath2uri, uri2filepath

    import ..pkg_root

    include(joinpath(pkg_root, "TestItemDetection", "src", "packagedef.jl"))
end


import CSTParser, TOML, UUIDs, Sockets, JuliaWorkspaces
using CSTParser: EXPR, parentof, headof
using JSONRPC: @dict_readable
using .TestItemDetection: find_test_detail!
using JuliaWorkspaces: JuliaWorkspace
using JuliaWorkspaces.URIs2: filepath2uri, uri2filepath

include(joinpath(pkg_root, "TestItemServer", "src", "testserver_protocol.jl"))
