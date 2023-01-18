pushfirst!(LOAD_PATH, joinpath(@__DIR__, "..", "packages"))
using TestItemServer
popfirst!(LOAD_PATH)

import Sockets

try
    conn = Sockets.connect(ARGS[1])

    TestItemServer.serve(conn, ARGS[2], ARGS[3], ARGS[4])

catch err
    Base.display(err)
end
