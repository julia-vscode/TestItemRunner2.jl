module TestItemServer

include("pkg_imports.jl")

import .JSONRPC: @dict_readable
import .CoverageTools: LCOV, amend_coverage_from_src!
import Test, Pkg, Sockets

include("testserver_protocol.jl")
include("helper.jl")
include("vscode_testset.jl")

mutable struct Testsetup
    name::String
    kind::Symbol
    uri::String
    line::Int
    column::Int
    code::String
    evaled::Bool
end

const conn_endpoint = Ref{Union{Nothing,JSONRPC.JSONRPCEndpoint}}(nothing)
const DEBUG_SESSION = Ref{Channel{DebugAdapter.DebugSession}}()
const TESTSETUPS = Dict{Symbol,Testsetup}()

function __init__()
    DEBUG_SESSION[] = Channel{DebugAdapter.DebugSession}(1)

    Core.eval(Main, :(module Testsetups end))
end

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
                TESTSETUPS[Symbol(i.name)] = Testsetup(
                    i.name,
                    Symbol(i.kind),
                    i.uri,
                    i.line,
                    i.column,
                    i.code,
                    false
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

function clear_coverage_data()
    @static if VERSION >= v"1.12.0-"
        try
            @ccall jl_clear_coverage_data()::Cvoid
        catch err
            # TODO Call global error handler
        end
    end
end

function collect_coverage_data!(coverage_results, roots)
    @static if VERSION >= v"1.12.0-"
        lcov_filename = tempname() * ".info"
        @ccall jl_write_coverage_data(lcov_filename::Cstring)::Cvoid
        cov_info = try
            LCOV.readfile(lcov_filename)
        finally
            rm(lcov_filename)
        end

        filter!(i->isabspath(i.filename) && any(j->startswith(filepath2uri(i.filename), j), roots) && isfile(i.filename), cov_info)

        append!(coverage_results, cov_info)
    end
end

function process_coverage_data(coverage_results)
    if length(coverage_results) == 0
        return missing
    end

    merged_coverage = CoverageTools.merge_coverage_counts(coverage_results)

    coverage_info = FileCoverage[]

    for i in merged_coverage
        file_cov = CoverageTools.FileCoverage(i.filename, read(i.filename, String), i.coverage)

        amend_coverage_from_src!(file_cov)

        push!(coverage_info, FileCoverage(filepath2uri(file_cov.filename), file_cov.coverage))
    end

    return coverage_info
end

function run_testitem_handler(conn, params::TestserverRunTestitemRequestParams)
    coverage_results = CoverageTools.FileCoverage[] # This will hold the results of various coverage sprints

    for i in params.testsetups
        if !haskey(TESTSETUPS, Symbol(i))
            ret = TestserverRunTestitemRequestParamsReturn(
                "errored",
                [
                    TestMessage(
                        "The specified testsetup $i does not exist.",
                        Location(
                            params.uri,
                            Range(Position(params.line, 1), Position(params.line, 1))
                        )
                    )
                ],
                missing,
                missing
            )
            return ret
        end

        setup_details = TESTSETUPS[Symbol(i)]

        if setup_details.kind==:module && !setup_details.evaled
            mod = Core.eval(Main.Testsetups, :(module $(Symbol(i)) end))

            code = string('\n'^(setup_details.line-1), ' '^(setup_details.column-1), setup_details.code)

            filepath = uri2filepath(setup_details.uri)

            t0 = time_ns()
            try
                withpath(filepath) do
                    Base.invokelatest(include_string, mod, code, filepath)
                end
                setup_details.evaled = true
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
                                Range(Position(max(1, error_line), 1), Position(max(1, error_line), 1))
                            )
                        )
                    ],
                    elapsed_time,
                    missing
                )
            end
        end
    end

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
                            Range(Position(params.line, 1), Position(params.line, 1))
                        )
                    )
                ],
                missing,
                missing
            )
        end

        if params.packageName!=""
            try
                params.mode == "Coverage" && clear_coverage_data()

                try
                    Core.eval(mod, :(using $(Symbol(params.packageName))))
                finally
                    params.mode == "Coverage" && collect_coverage_data!(coverage_results, params.coverageRoots)
                end
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
                                Range(Position(params.line, 1), Position(params.line, 1))
                            )
                        )
                    ],
                    missing,
                    process_coverage_data(coverage_results)
                )
            end
        end
    end

    for i in params.testsetups
        testsetup_details = TESTSETUPS[Symbol(i)]

        try
            if testsetup_details.kind==:module
                Core.eval(mod, :(using ..Testsetups: $(Symbol(i))))
            elseif testsetup_details.kind==:snippet
                testsnippet_filepath = uri2filepath(testsetup_details.uri)
                testsnippet_code = string('\n'^(testsetup_details.line-1), ' '^(testsetup_details.column-1), testsetup_details.code)

                withpath(testsnippet_filepath) do
                    if params.mode == "Debug"
                        debug_session = wait_for_debug_session()
                        DebugAdapter.debug_code(debug_session, mod, testsnippet_code, testsnippet_filepath, false)
                    else
                        params.mode == "Coverage" && clear_coverage_data()
                        try
                            Base.invokelatest(include_string, mod, testsnippet_code, testsnippet_filepath)
                        finally
                            params.mode == "Coverage" && collect_coverage_data!(coverage_results, params.coverageRoots)
                        end
                    end
                end
            else
                error("Unknown testsetup kind $(i.kind).")
            end
        catch err
            Base.display_error(err, catch_backtrace())
            return TestserverRunTestitemRequestParamsReturn(
                "errored",
                [
                    TestMessage(
                        "Unable to load the `$i` testsetup.",
                        Location(
                            params.uri,
                            Range(Position(params.line, 1), Position(params.line, 1))
                        )
                    )
                ],
                missing,
                missing
            )
        end
    end

    filepath = uri2filepath(params.uri)

    code = string('\n'^(params.line-1), ' '^(params.column-1), params.code)

    ts = Test.DefaultTestSet("$filepath:$(params.name)")

    Test.push_testset(ts)

    elapsed_time = UInt64(0)

    t0 = time_ns()
    try
        withpath(filepath) do

            if params.mode == "Debug"
                debug_session = wait_for_debug_session()
                DebugAdapter.debug_code(debug_session, mod, code, filepath, false)
            else
                params.mode == "Coverage" && clear_coverage_data()
                try
                    Base.invokelatest(include_string, mod, code, filepath)
                finally
                    params.mode == "Coverage" && collect_coverage_data!(coverage_results, params.coverageRoots)
                end
            end
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
                        Range(Position(max(1, error_line), 1), Position(max(1, error_line), 1))
                    )
                )
            ],
            elapsed_time,
            process_coverage_data(coverage_results)
        )
    end

    ts = Test.pop_testset()

    try
        Test.finish(ts)

        return TestserverRunTestitemRequestParamsReturn("passed", missing, elapsed_time, process_coverage_data(coverage_results))
    catch err
        if err isa Test.TestSetException
            failed_tests = Test.filter_errors(ts)

            return TestserverRunTestitemRequestParamsReturn(
                "failed",
                [ create_test_message_for_failed(i) for i in failed_tests],
                elapsed_time,
                process_coverage_data(coverage_results)
            )
        else
            rethrow(err)
        end
    end
end

function create_test_message_for_failed(i)
    (expected, actual) = extract_expected_and_actual(i)
    return TestMessage(sprint(Base.show, i),
        expected,
        actual,
        Location(filepath2uri(string(i.source.file)), Range(Position(i.source.line, 1), Position(i.source.line, 1))))
end

function extract_expected_and_actual(result)
    if isa(result, Test.Fail)
        s = result.data
        if isa(s, String)
            m = match(r"\"(.*)\" == \"(.*)\"", s)
            if m !== nothing
                try
                    expected = unescape_string(m.captures[1])
                    actual = unescape_string(m.captures[2])

                    if expected === nothing
                        expected = missing
                    end
                    if actual ===nothing
                        actual = missing
                    end
                    return (expected, actual)
                catch err
                    # theoretically possible if a user registers a Fail instance that matches
                    # above regexp, but doesn't contain two escaped strings.
                    # just return nothing in this unlikely case, meaning no diff will be shown.
                end
            end
        end
    end
    return (missing, missing)
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

function start_debug_backend(debug_pipename, error_handler)
    ready = Channel{Bool}(1)
    @async try
        server = Sockets.listen(debug_pipename)

        put!(ready, true)

        while true
            conn = Sockets.accept(server)

            debug_session = DebugAdapter.DebugSession(conn)

            global DEBUG_SESSION

            put!(DEBUG_SESSION[], debug_session)

            try
                run(debug_session, error_handler)
            finally
                take!(DEBUG_SESSION[])
            end
        end
    catch err
        error_handler(err, Base.catch_backtrace())
    end

    take!(ready)
end

function wait_for_debug_session()
    fetch(DEBUG_SESSION[])
end

function get_debug_session_if_present()
    if isready(DEBUG_SESSION[])
        return fetch(DEBUG_SESSION[])
    else
        return nothing
    end
end

function serve(pipename, debug_pipename, project_path, package_path, package_name; is_dev=false, error_handler=nothing)
    if debug_pipename!==nothing
        start_debug_backend(debug_pipename, error_handler)
    end

    conn = Sockets.connect(pipename)

    @info "This test server instance was started with the following configuration." project_path package_path package_name
    if project_path==""
        @static if VERSION >= v"1.5.0"
            Pkg.activate(temp=true)
        else
            temp_path = mktempdir()
            Pkg.activate(temp_path)
        end

        Pkg.develop(Pkg.PackageSpec(path=package_path))

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

end
