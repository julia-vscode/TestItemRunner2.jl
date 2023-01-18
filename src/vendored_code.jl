function withpath(f, path)
    tls = task_local_storage()
    hassource = haskey(tls, :SOURCE_PATH)
    hassource && (path′ = tls[:SOURCE_PATH])
    tls[:SOURCE_PATH] = path
    try
        return f()
    finally
        hassource ? (tls[:SOURCE_PATH] = path′) : delete!(tls, :SOURCE_PATH)
    end
end

function generate_pipe_name(part1, part2)
    if Sys.iswindows()
        return "\\\\.\\pipe\\$part1-$part2"
    end
    # Pipe names on unix may only be 92 chars (JuliaLang/julia#43281), and since
    # tempdir can be arbitrary long (in particular on macos) we try to keep the name
    # within bounds here.
    pipename = joinpath(tempdir(), "$part1-$part2")
    if length(pipename) >= 92
        # Try to use /tmp and if that fails, hope the long pipe name works anyway
        maybe = "/tmp/$part1-$part2"
        try
            touch(maybe); rm(maybe) # Check permissions on this path
            pipename = maybe
        catch
        end
    end
    return pipename
end
