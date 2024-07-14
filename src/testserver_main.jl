pushfirst!(LOAD_PATH, joinpath(@__DIR__, "..", "packages"))
using TestItemServer
popfirst!(LOAD_PATH)

import Sockets


println("DEPOT IS $(get(ENV, "JULIA_DEPOT_PATH", "nix"))")

try
    TestItemServer.serve(ARGS[1], nothing, ARGS[2], ARGS[3], ARGS[4])
catch err
    bt = catch_backtrace()
    Base.display_error(err, bt)
    open("testservererror.txt", "w") do file
        Base.display_error(file, err,catch_backtrace())
    end
end
