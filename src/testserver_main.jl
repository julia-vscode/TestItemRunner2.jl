pushfirst!(LOAD_PATH, joinpath(@__DIR__, "..", "packages"))
using TestItemServer
popfirst!(LOAD_PATH)

import Sockets

try
    if isdir(ARGS[2])
        c = read(joinpath(ARGS[2], "Manifest.toml"), String)
        println("MANIFEST CONTENT")
        println(c)
    end

    TestItemServer.serve(ARGS[1], nothing, ARGS[2], ARGS[3], ARGS[4])

catch err
    open("testservererror.txt", "w") do file
        Base.display_error(file, err,catch_backtrace())
    end
end
