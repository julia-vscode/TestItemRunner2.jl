module TestItemRunner2

export run_tests, kill_test_processes, TestEnvironment

# For easier dev, switch these two lines
const pkg_root = "../packages"
# const pkg_root = joinpath(homedir(), ".julia", "dev")

import JSON, JSONRPC, ProgressMeter, TOML, UUIDs, Sockets, JuliaWorkspaces, AutoHashEquals

using JSONRPC: @dict_readable
using JuliaWorkspaces: JuliaWorkspace
using JuliaWorkspaces.URIs2: URI, filepath2uri, uri2filepath
using AutoHashEquals: @auto_hash_equals

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

@auto_hash_equals struct TestEnvironment
    name::String
    env::Dict{String,String}
end

const TEST_PROCESSES = Dict{NamedTuple{(:project_uri,:package_uri,:package_name,:environment),Tuple{Union{URI,Nothing},URI,String,TestEnvironment}},Vector{TestProcess}}()
const SOME_TESTITEM_FINISHED = Base.Event(true)

function get_key_from_testitem(testitem, environment)
    return (
        project_uri = testitem.env.project_uri,
        package_uri = testitem.env.package_uri,
        package_name = testitem.env.package_name,
        environment = environment
    )
end

function launch_new_process(testitem, environment)
    key = get_key_from_testitem(testitem, environment)

    pipe_name = generate_pipe_name("tir", UUIDs.uuid4())

    server = Sockets.listen(pipe_name)

    testserver_script = joinpath(@__DIR__, "testserver_main.jl")

    buffer_out = IOBuffer()
    buffer_err = IOBuffer()

    jl_process = open(
        pipeline(
            addenv(
                Cmd(`julia --startup-file=no --history-file=no --depwarn=no $testserver_script $pipe_name $(key.project_uri===nothing ? "" : uri2filepath(key.project_uri)) $(uri2filepath(key.package_uri)) $(key.package_name)`),
                environment.env
            ),
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

function get_free_testprocess(testitem, environment, max_num_processes)
    key = get_key_from_testitem(testitem, environment)

    if !haskey(TEST_PROCESSES, key)
        return launch_new_process(testitem, environment)
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
                            kill(test_process.process)

                            needs_new_process = true
                        end
                    end

                    if needs_new_process
                        test_process = launch_new_process(testitem, environment)
                    end

                    return test_process
                end
            end

            if length(test_processes) < max_num_processes
                return launch_new_process(testitem, environment)
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
            TestserverUpdateTestsetupsRequestParams(testsetups)
        )

        result = JSONRPC.send(
            test_process.connection,
            testserver_run_testitem_request_type,
            TestserverRunTestitemRequestParams(
                string(testitem.detail.uri),
                testitem.detail.name,
                testitem.env.package_name,
                testitem.detail.option_default_imports,
                convert(Vector{String}, string.(testitem.detail.option_setup)),
                testitem.line,
                testitem.column,
                testitem.code,
                "Normal",
                missing
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

function run_tests(path; filter=nothing, verbose=false, max_workers::Int=Sys.CPU_THREADS, timeout=60*5, return_results=false, print_failed_results=true, environments=[TestEnvironment("Default", Dict{String,String}())])
    jw = JuliaWorkspaces.workspace_from_folders(([path]))

    # TODO Reenable
    # if count(i -> true, Iterators.flatten(values(jw._testerrors))) > 0
    #     println("There are errors in your test definitions, we are aborting.")

    #     for te in Iterators.flatten(values(jw._testerrors))
    #         pos = JuliaWorkspaces.get_position_from_offset(jw._text_documents[te.uri], te.range[1])
    #         println()
    #         println("File: $(uri2filepath(te.uri)):$(pos[1]+1)")
    #         println()
    #         println(te.message)
    #         println()
    #     end

    #     return nothing
    # end

    # testsetups maps @testsetup PACKAGE => NAME => TESTSETUPdetail
    testsetups = Dict{JuliaWorkspaces.URIs2.URI,Dict{Symbol,Any}}()
    # TODO Reenable
    # for i in Iterators.flatten(values(jw._testsetups))
    #     testsetups_in_package = get!(() -> Dict{Symbol,Any}(), testsetups, i.package_uri)

    #     haskey(testsetups_in_package, i.name) && error("The name '$(i.name)' is used for more than one test setup.")

    #     testsetups_in_package[i.name] = (detail=i, code=get_text(jw._text_documents[i.uri])[i.code_range])
    # end

    # Flat list of @testitems and @testmodule and @testsnippet
    testitems = []
    testsetups = []
    for (uri, items) in pairs(JuliaWorkspaces.get_test_items(jw))
        project_details = JuliaWorkspaces.get_test_env(jw, uri)
        textfile = JuliaWorkspaces.get_text_file(jw, uri)

        for item in items.testitems            
            line, column = JuliaWorkspaces.position_at(textfile.content, item.code_range.start)
            push!(testitems, (
                uri=uri,
                line=line,
                column=column,
                code=textfile.content.content[item.code_range],
                env=project_details,
                detail=item),
            )
        end

        for item in items.testsetups
            line, column = JuliaWorkspaces.position_at(textfile.content, item.code_range.start)
            push!(testsetups,
                TestsetupDetails(
                    string(item.name),
                    string(item.kind),
                    string(uri),
                    line,
                    column,
                    textfile.content.content[item.code_range]
                )
            )
        end
    end

    # testitems = [(detail=i, code=get_text(jw._text_documents[i.uri])[i.code_range]) for i in Iterators.flatten(values(jw._testitems))]   

    # Filter @testitems
    if filter !== nothing
        filter!(i->filter((filename=uri2filepath(i.uri), name=i.detail.name, tags=i.detail.option_tags, package_name=i.detail.package_name)), testitems)
    end

    executed_testitems = []

    p = ProgressMeter.Progress(length(testitems)*length(environments), barlen=50)

    count_success = 0
    count_timeout = 0
    count_fail = 0
    count_error = 0

    # Loop over all test items that should be executed
    for testitem in testitems, environment in environments
        test_process = get_free_testprocess(testitem, environment, max_workers)

        result_channel = execute_test(test_process, testitem, testsetups, timeout)

        progress_reported_channel = Channel(1)

        @async try
            res = fetch(result_channel)

            if res.status=="passed"
                count_success += 1
            elseif res.status=="timeout"
                count_timeout += 1
            elseif res.status == "failed"
                count_fail += 1
            elseif res.status == "errored"
                count_error += 1
            else
                error("Unknown test status")
            end

            ProgressMeter.next!(
                p,
                showvalues = [
                    (Symbol("Successful tests"), count_success),
                    (Symbol("Failed tests"), count_fail),
                    (Symbol("Errored tests"), count_error),
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
            if i.result.status in ("failed", "errored") && i.result.message!==missing                
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

    println("$(length(responses)) tests ran, $(count_success) passed, $(count_fail) failed, $(count_error) errored, $(count_timeout) timed out.")

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
