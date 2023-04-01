module TestItemRunner2

export run_tests, kill_test_processes

# For easier dev, switch these two lines
const pkg_root = "../packages"
# const pkg_root = joinpath(homedir(), ".julia", "dev")

import JSON, JSONRPC, ProgressMeter, TOML, UUIDs, Sockets, JuliaWorkspaces

using JSONRPC: @dict_readable
using JuliaWorkspaces: JuliaWorkspace, get_text
using JuliaWorkspaces.URIs2: URI, filepath2uri, uri2filepath

include("vendored_code.jl")

include(joinpath(pkg_root, "TestItemServer", "src", "testserver_protocol.jl"))

mutable struct TestProcess
    key
    process
    connection
    current_testitem
    log_out
    log_err
end

const TEST_PROCESSES = Dict{NamedTuple{(:project_uri,:package_uri,:package_name),Tuple{Union{URI,Nothing},URI,String}},Vector{TestProcess}}()
const SOME_TESTITEM_FINISHED = Base.Event(true)

function get_key_from_testitem(testitem)
    return (
        project_uri = testitem.detail.project_uri,
        package_uri = testitem.detail.package_uri,
        package_name = testitem.detail.package_name
    )
end

function launch_new_process(testitem)
    key = get_key_from_testitem(testitem)

    pipe_name = generate_pipe_name("tir", UUIDs.uuid4())

    server = Sockets.listen(pipe_name)

    testserver_script = joinpath(@__DIR__, "testserver_main.jl")

    buffer_out = IOBuffer()
    buffer_err = IOBuffer()

    jl_process = open(
        pipeline(
            Cmd(`$(Base.julia_cmd()) --startup-file=no --history-file=no --depwarn=no $testserver_script $pipe_name $(key.project_uri===nothing ? "" : uri2filepath(key.project_uri)) $(uri2filepath(key.package_uri)) $(key.package_name)`),
            stdout = buffer_out,
            stderr = buffer_err
        )
    )

    socket = Sockets.accept(server)

    connection = JSONRPC.JSONRPCEndpoint(socket, socket)

    run(connection)

    test_process = TestProcess(key, jl_process, connection, nothing, buffer_out, buffer_err)
    
    if !haskey(TEST_PROCESSES, key)
        TEST_PROCESSES[key] = TestProcess[]
    end

    test_processes = TEST_PROCESSES[key]

    push!(test_processes, test_process)

    @async try
        wait(jl_process)

        i = findfirst(isequal(test_process), test_processes)

        popat!(test_processes, i)
    catch err
        Base.display_error(err, catch_backtrace())
    end

    return test_process
end

function isconnected(testprocess)
    # TODO Properly implement
    true
end

function isbusy(testprocess)
    return testprocess.current_testitem!==nothing
end

function run_revise(testprocess)
    return JSONRPC.send(testprocess.connection,testserver_revise_request_type, nothing)
end

function get_free_testprocess(testitem, max_num_processes)
    key = get_key_from_testitem(testitem)

    if !haskey(TEST_PROCESSES, key)
        return launch_new_process(testitem)
    else
        test_processes = TEST_PROCESSES[key]

        # TODO add some way to cancel
        while true

            # First lets just see whether we have an idle test process we can use
            for test_process in test_processes
                if !isbusy(test_process)
                    needs_new_process = false

                    if !isconnected(test_process)
                        needs_new_process = true
                    else
                        status = run_revise(test_process)

                        if status != "success"
                            terminate(test_process)

                            needs_new_process = true
                        end
                    end

                    if needs_new_process
                        test_process = launch_new_process(testitem)
                    end

                    return test_process
                end
            end

            if length(test_processes) < max_num_processes
                return launch_new_process(testitem)
            else
                wait(SOME_TESTITEM_FINISHED)
            end
        end
    end
end

function execute_test(test_process, testitem, testsetups, timeout)

    test_process.current_testitem = testitem

    return_value = Channel(1)

    finished = false

    timer = timeout>0 ? Timer(timeout) do i
        if !finished
            kill(test_process.process)
        end
    end : nothing

    @async try
        JSONRPC.send(
            test_process.connection,
            testserver_update_testsetups_type,
            TestserverUpdateTestsetupsRequestParams([TestsetupDetails(
                string(k),
                string(v.detail.uri),
                # TODO use proper location info here
                1,
                1,
                v.code
            ) for (k,v) in testsetups])
        )

        result = JSONRPC.send(
            test_process.connection,
            testserver_run_testitem_request_type,
            TestserverRunTestitemRequestParams(
                string(testitem.detail.uri),
                testitem.detail.name,
                testitem.detail.package_name,
                testitem.detail.option_default_imports,
                convert(Vector{String}, string.(testitem.detail.option_setup)),
                # TODO use proper location info here
                1, #pos.line,
                1, #pos.column,
                testitem.code
            )
        )

        out_log = String(take!(test_process.log_out))
        err_log = String(take!(test_process.log_err))

        finished = true

        timer === nothing || close(timer)

        test_process.current_testitem = nothing

        notify(SOME_TESTITEM_FINISHED)

        push!(return_value, (status = result.status, message = result.message, duration = result.duration, log_out = out_log, log_err = err_log))
    catch err
        if err isa InvalidStateException

            try
                out_log = String(take!(test_process.log_out))
                err_log = String(take!(test_process.log_err))

                notify(SOME_TESTITEM_FINISHED)

                push!(return_value, (status="timeout", message="The test timed out", log_out = out_log, log_err = err_log))
            catch err2
                Base.display_error(err2, catch_backtrace())
            end
        else
            Base.display_error(err, catch_backtrace())
        end
    end

    return return_value
end

function run_tests(path; filter=nothing, verbose=false, max_workers::Int=Sys.CPU_THREADS, timeout=60*5, return_results=false, print_failed_results=true)
    jw = JuliaWorkspace(Set([filepath2uri(path)]))

    if count(i -> true, Iterators.flatten(values(jw._testerrors))) > 0
        println("There are errors in your test definitions, we are aborting.")

        for te in Iterators.flatten(values(jw._testerrors))
            pos = JuliaWorkspaces.get_position_from_offset(jw._text_documents[te.uri], te.range[1])
            println()
            println("File: $(uri2filepath(te.uri)):$(pos[1]+1)")
            println()
            println(te.message)
            println()
        end

        return nothing
    end

    # testsetups maps @testsetup PACKAGE => NAME => TESTSETUPdetail
    testsetups = Dict{JuliaWorkspaces.URIs2.URI,Dict{Symbol,Any}}()
    for i in Iterators.flatten(values(jw._testsetups))
        testsetups_in_package = get!(() -> Dict{Symbol,Any}(), testsetups, i.package_uri)

        haskey(testsetups_in_package, i.name) && error("The name '$(i.name)' is used for more than one test setup.")

        testsetups_in_package[i.name] = (detail=i, code=get_text(jw._text_documents[i.uri])[i.code_range])
    end

    # Flat list of @testitems
    testitems = [(detail=i, code=get_text(jw._text_documents[i.uri])[i.code_range]) for i in Iterators.flatten(values(jw._testitems))]   

    # Filter @testitems
    if filter !== nothing
        filter!(i->filter((filename=uri2filepath(i.detail.uri), name=i.detail.name, tags=i.detail.option_tags, package_name=i.detail.package_name)), testitems)
    end

    executed_testitems = []

    p = ProgressMeter.Progress(length(testitems), barlen=50)

    count_success = 0
    count_timeout = 0
    count_fail = 0

    # Loop over all test items that should be executed
    for testitem in testitems
        test_process = get_free_testprocess(testitem, max_workers)

        result_channel = execute_test(test_process, testitem, get(()->Dict{Symbol,Any}(), testsetups, testitem.detail.package_uri), timeout)

        progress_reported_channel = Channel(1)

        @async try
            res = fetch(result_channel)

            if res.status=="passed"
                count_success += 1
            elseif res.status=="timeout"
                count_timeout += 1
            elseif res.status == "failed"
                count_fail += 1
            end

            ProgressMeter.next!(
                p,
                showvalues = [
                    (Symbol("Successful tests"), count_success),
                    (Symbol("Failed tests"), count_fail),
                    (Symbol("Timed out tests"), count_timeout),
                    ((Symbol("Number of processes for package '$(i.first.package_name)'"), length(i.second)) for i in TEST_PROCESSES)...
                ]
            )
            push!(progress_reported_channel, true)
        catch err
            Base.display_error(err, catch_backtrace())
        end

        push!(executed_testitems, (testitem=testitem, result=result_channel, progress_reported_channel=progress_reported_channel))
    end

    yield()

    for i in executed_testitems
        wait(i.result)
    end

    responses = [(testitem=i.testitem, result=take!(i.result)) for i in executed_testitems]

    if print_failed_results
        for i in responses
            if i.result.status == "failed" && i.result.message!==missing                
                println()
                println("Errors for test $(i.testitem.detail.name)")
                for j in i.result.message
                    println(j.message)
                end
                println()
            end
        end
    end

    for i in executed_testitems
        wait(i.progress_reported_channel)
    end

    println("$(length(responses)) tests ran, $(count_success) passed, $(count_fail) failed, $(count_timeout) timed out.")

    if return_results
        return responses
    else
        return nothing
    end
end

function kill_test_processes()
    for i in values(TEST_PROCESSES)
        for j in i
            kill(j.process)
        end
    end
end

end
