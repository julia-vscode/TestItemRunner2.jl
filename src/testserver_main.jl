import Pkg
Pkg.activate(joinpath(@__DIR__, "..", "environments", "v$(VERSION.major).$(VERSION.minor)"))
using TestItemServer

import Sockets

try
    TestItemServer.serve(ARGS[1], nothing, ARGS[2], ARGS[3], ARGS[4])
catch err
    bt = catch_backtrace()
    Base.display_error(err, bt)
    open("testservererror.txt", "w") do file
        Base.display_error(file, err,catch_backtrace())
    end
end
