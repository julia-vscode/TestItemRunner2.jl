module TestItemServer

include("pkg_imports.jl")

import .JSONRPC: @dict_readable
import Test, Pkg

include("testserver_protocol.jl")
include("helper.jl")

const conn_endpoint = Ref{Union{Nothing,JSONRPC.JSONRPCEndpoint}}(nothing)
const TESTSETUPS = Dict{Symbol,Any}()

function run_update_testsetups(conn, params::TestserverUpdateTestsetupsRequestParams)
    new_testsetups = Dict(i.name => i for i in params.testsetups)

    # Delete all existing test setups that are not in the new list
    for i in keys(TESTSETUPS)
        if !haskey(new_testsetups, i)
            delete!(TESTSETUPS, i)
        end
    end

    for i in params.testsetups
        # We only add new if not there before or if the code changed
        if !haskey(TESTSETUPS, i.name) || (haskey(TESTSETUPS, i.name) && TESTSETUPS[i.name].code != i.code)
                TESTSETUPS[Symbol(i.name)] = (
                    name = i.name,
                    uri = i.uri,
                    line = i.line,
                    column = i.column,
                    code = i.code,
                    evaled = false
                )
        end
    end
end

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


function run_revise_handler(conn, params::Nothing)
    try
        Revise.revise(throw=true)
        return "success"
    catch err
        Base.display_error(err, catch_backtrace())
        return "failed"
    end
end

function flatten_failed_tests!(ts, out)
    append!(out, i for i in ts.results if !(i isa Test.Pass))

    for cts in ts.children
        flatten_failed_tests!(cts, out)
    end
end

function format_error_message(err, bt)
    try
        return Base.invokelatest(sprint, Base.display_error, err, bt)
    catch err
        # TODO We could probably try to output an even better error message here that
        # takes into account `err`. And in the callsites we should probably also
        # handle this better.
        return "Error while trying to format an error message"
    end
end

function run_testitem_handler(conn, params::TestserverRunTestitemRequestParams)
    for i in params.testsetups
        if !haskey(TESTSETUPS, Symbol(i))
            ret = TestserverRunTestitemRequestParamsReturn(
                "errored",
                [
                    TestMessage(
                        "The specified testsetup $i does not exist.",
                        Location(
                            params.uri,
                            Range(Position(params.line, 0), Position(params.line, 0))
                        )
                    )
                ],
                missing
            )
            return ret
        end

        setup_details = TESTSETUPS[Symbol(i)]

        if !setup_details.evaled
            mod = Core.eval(Main.Testsetups, :(module $(Symbol(i)) end))

            code = string('\n'^setup_details.line, ' '^setup_details.column, setup_details.code)

            filepath = uri2filepath(setup_details.uri)

            t0 = time_ns()
            try                
                withpath(filepath) do
                    Base.invokelatest(include_string, mod, code, filepath)
                end
            catch err
                elapsed_time = (time_ns() - t0) / 1e6 # Convert to milliseconds
        
                bt = catch_backtrace()
                st = stacktrace(bt)
        
                error_message = format_error_message(err, bt)
        
                if err isa LoadError
                    error_filepath = err.file
                    error_line = err.line
                else
                    error_filepath =  string(st[1].file)
                    error_line = st[1].line
                end
        
                return TestserverRunTestitemRequestParamsReturn(
                    "errored",
                    [
                        TestMessage(
                            error_message,
                            Location(
                                isabspath(error_filepath) ? filepath2uri(error_filepath) : "",
                                Range(Position(max(0, error_line - 1), 0), Position(max(0, error_line - 1), 0))
                            )
                        )
                    ],
                    elapsed_time
                )
            end
        end
    end

    @info "AND WE GOT PAST THIS"

    mod = Core.eval(Main, :(module $(gensym()) end))

    if params.useDefaultUsings
        try
            Core.eval(mod, :(using Test))
        catch
            return TestserverRunTestitemRequestParamsReturn(
                "errored",
                [
                    TestMessage(
                        "Unable to load the `Test` package. Please ensure that `Test` is listed as a test dependency in the Project.toml for the package.",
                        Location(
                            params.uri,
                            Range(Position(params.line, 0), Position(params.line, 0))
                        )
                    )
                ],
                nothing
            )
        end

        if params.packageName!=""
            try
                Core.eval(mod, :(using $(Symbol(params.packageName))))
            catch err
                bt = catch_backtrace()
                error_message = format_error_message(err, bt)

                return TestserverRunTestitemRequestParamsReturn(
                    "errored",
                    [
                        TestMessage(
                            error_message,
                            Location(
                                params.uri,
                                Range(Position(params.line, 0), Position(params.line, 0))
                            )
                        )
                    ],
                    nothing
                )
            end
        end
    end

    filepath = uri2filepath(params.uri)

    code = string('\n'^params.line, ' '^params.column, params.code)

    ts = Test.DefaultTestSet("$filepath:$(params.name)")

    Test.push_testset(ts)

    elapsed_time = UInt64(0)

    t0 = time_ns()
    try
        withpath(filepath) do
            Base.invokelatest(include_string, mod, code, filepath)
            elapsed_time = (time_ns() - t0) / 1e6 # Convert to milliseconds
        end
    catch err
        elapsed_time = (time_ns() - t0) / 1e6 # Convert to milliseconds

        Test.pop_testset()

        bt = catch_backtrace()
        st = stacktrace(bt)

        error_message = format_error_message(err, bt)

        if err isa LoadError
            error_filepath = err.file
            error_line = err.line
        else
            error_filepath =  string(st[1].file)
            error_line = st[1].line
        end

        return TestserverRunTestitemRequestParamsReturn(
            "errored",
            [
                TestMessage(
                    error_message,
                    Location(
                        isabspath(error_filepath) ? filepath2uri(error_filepath) : "",
                        Range(Position(max(0, error_line - 1), 0), Position(max(0, error_line - 1), 0))
                    )
                )
            ],
            elapsed_time
        )
    end

    ts = Test.pop_testset()

    try
        Test.finish(ts)

        return TestserverRunTestitemRequestParamsReturn("passed", missing, elapsed_time)
    catch err
        if err isa Test.TestSetException
            failed_tests = Test.filter_errors(ts)

            return TestserverRunTestitemRequestParamsReturn(
                "failed",
                [TestMessage(sprint(Base.show, i), Location(filepath2uri(string(i.source.file)), Range(Position(i.source.line - 1, 0), Position(i.source.line - 1, 0)))) for i in failed_tests],
                elapsed_time
            )
        else
            rethrow(err)
        end
    end
end

function serve_in_env(conn)
    conn_endpoint[] = JSONRPC.JSONRPCEndpoint(conn, conn)
    @debug "connected"
    run(conn_endpoint[])
    @debug "running"

    msg_dispatcher = JSONRPC.MsgDispatcher()

    msg_dispatcher[testserver_revise_request_type] = run_revise_handler
    msg_dispatcher[testserver_run_testitem_request_type] = run_testitem_handler
    msg_dispatcher[testserver_update_testsetups_type] = run_update_testsetups

    while conn_endpoint[] isa JSONRPC.JSONRPCEndpoint && isopen(conn)
        msg = JSONRPC.get_next_message(conn_endpoint[])

        JSONRPC.dispatch_msg(conn_endpoint[], msg_dispatcher, msg)
    end
end

function serve(conn, project_path, package_path, package_name; is_dev=false, crashreporting_pipename::Union{AbstractString,Nothing}=nothing)
    if project_path==""
        Pkg.activate(temp=true)

        Pkg.develop(path=package_path)

        TestEnv.activate(package_name) do
            serve_in_env(conn)
        end
    else
        Pkg.activate(project_path)

        if package_name!=""
            TestEnv.activate(package_name) do
                serve_in_env(conn)
            end
        else
            serve_in_env(conn)
        end
    end
end

function __init__()
    Core.eval(Main, :(module Testsetups end))
end

end
