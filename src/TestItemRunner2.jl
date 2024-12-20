module TestItemRunner2

export run_tests, kill_test_processes, TestEnvironment, print_process_diag

# For easier dev, switch these two lines
const pkg_root = "../packages"
# const pkg_root = joinpath(homedir(), ".julia", "dev")

import JSON, JSONRPC, ProgressMeter, TOML, UUIDs, Sockets, JuliaWorkspaces, AutoHashEquals
using Query

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
    coverage::Bool
    env::Dict{String,Any}
end

struct TestrunResultMessage
    message::String
    # expectedOutput::Union{String,Missing}
    # actualOutput::Union{String,Missing}
    uri::URI
    line::Int
    column::Int
end

struct TestrunResultTestitemProfile
    profile_name::String
    status::Symbol
    duration::Union{Float64,Missing}
    messages::Union{Vector{TestrunResultMessage},Missing}
end

struct TestrunResultTestitem
    name::String
    uri::URI
    profiles::Vector{TestrunResultTestitemProfile}
end

struct TestrunResultDefinitionError
    message::String
    uri::URI
    line::Int
    column::Int
end

struct TestrunResult
    definition_errors::Vector{TestrunResultDefinitionError}
    testitems::Vector{TestrunResultTestitem}
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

function precompil_test_env(environment, test_env)
    precompile_script = joinpath(@__DIR__, "precompile_main.jl")

    # buffer_out = IOBuffer()
    # buffer_err = IOBuffer()

    run(
        pipeline(
            addenv(
                Cmd(`julia --code-coverage=$(test_env.coverage ? "user" : "none") --startup-file=no --history-file=no --depwarn=no $precompile_script $(environment.project_uri===nothing ? "" : uri2filepath(environment.project_uri)) $(uri2filepath(environment.package_uri)) $(environment.package_name)`),
                test_env.env
            ),
            # stdout = buffer_out,
            # stderr = buffer_err
        )
    )

    println("Finished precompiling from the coordinator process.")
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
                Cmd(`julia --code-coverage=$(environment.coverage ? "user" : "none") --startup-file=no --history-file=no --depwarn=no $testserver_script $pipe_name $(key.project_uri===nothing ? "" : uri2filepath(key.project_uri)) $(uri2filepath(key.package_uri)) $(key.package_name)`),
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
        precompil_test_env(testitem.env, environment)

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

    timed_out = false

    timer = timeout>0 ? Timer(timeout) do i
        if !finished
            timed_out = true
            kill(test_process.process)
        end
    end : nothing

    @async try
        result = nothing
        try 
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
        catch err
            if err isa InvalidStateException
                if timed_out
                    msg = TestMessage("The test timed out", missing, missing, Location(string(testitem.detail.uri), Range(Position(testitem.line, testitem.column), Position(testitem.line, testitem.column))))
                    result = TestserverRunTestitemRequestParamsReturn("timeout", [msg], missing, missing)
                else
                    msg = TestMessage("The test process crashed", missing, missing, Location(string(testitem.detail.uri), Range(Position(testitem.line, testitem.column), Position(testitem.line, testitem.column))))
                    result = TestserverRunTestitemRequestParamsReturn("crash", [msg], missing, missing)
                end
            else
                rethrow()
            end            
        end

        out_log = String(take!(test_process.log_out))
        err_log = String(take!(test_process.log_err))

        finished = true

        timer === nothing || close(timer)

        test_process.current_testitem = nothing

        notify(SOME_TESTITEM_FINISHED)

        push!(return_value, (status = result.status, messages = result.messages, duration = result.duration, log_out = out_log, log_err = err_log))
    catch err
        Base.display_error(err, catch_backtrace())

        println("child process log_out start")
        println(String(take!(test_process.log_out)))
        println("child process log_out end")
        println()
        println("child process log_err start")
        println(String(take!(test_process.log_err)))
        println("child process log_err start")
    end

    return return_value
end

function run_tests(
            path;
            filter=nothing,
            verbose=false,
            max_workers::Int=Sys.CPU_THREADS,
            timeout=60*5,
            fail_on_detection_error=true,
            return_results=false,
            print_failed_results=true,
            print_summary=true,
            progress_ui=:bar,
            environments=[TestEnvironment("Default", false, Dict{String,Any}())]
        )
    jw = JuliaWorkspaces.workspace_from_folders(([path]))
    
    # Flat list of @testitems and @testmodule and @testsnippet
    testitems = []
    testsetups = []
    testerrors = []
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

        for item in items.testerrors
            line, column = JuliaWorkspaces.position_at(textfile.content, item.range.start)
            push!(testerrors,
                (
                    uri=string(uri),
                    line=line,
                    column=column,
                    message=item.message
                )
            )
        end
    end

    count_success = 0
    count_timeout = 0
    count_fail = 0
    count_error = 0
    count_crash = 0

    responses = []
    executed_testitems = []

    if length(testerrors) == 0  || fail_on_detection_error==false
        # Filter @testitems
        if filter !== nothing
            filter!(i->filter((filename=uri2filepath(i.uri), name=i.detail.name, tags=i.detail.option_tags, package_name=i.env.package_name)), testitems)
        end

        p = ProgressMeter.Progress(length(testitems)*length(environments), barlen=50, enabled=progress_ui==:bar)

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
                elseif res.status == "crash"
                    count_crash += 1
                else
                    error("Unknown test status")
                end

                if progress_ui==:bar
                    ProgressMeter.next!(
                        p,
                        showvalues = [
                            (Symbol("Successful tests"), count_success),
                            (Symbol("Failed tests"), count_fail),
                            (Symbol("Errored tests"), count_error),
                            (Symbol("Crashed tests"), count_crash),
                            (Symbol("Timed out tests"), count_timeout),
                            ((Symbol("Number of processes for package '$(i.first.package_name)'"), length(i.second)) for i in TEST_PROCESSES)...
                        ]
                    )
                end

                if progress_ui==:log
                    duration_string = res.duration !== missing ? " ($(res.duration)ms)" : ""
                    println("$(res.status=="passed" ? "✓" : "✗") $(environment.name) $(uri2filepath(testitem.uri)):$(testitem.detail.name) → $(res.status)$duration_string")
                end

                push!(progress_reported_channel, true)
            catch err
                Base.display_error(err, catch_backtrace())
            end

            push!(executed_testitems, (testitem=testitem, testenvironment=environment, result=result_channel, progress_reported_channel=progress_reported_channel))
        end

        yield()


        for i in executed_testitems
            wait(i.result)
        end

        append!(responses, (testitem=i.testitem, testenvironment=i.testenvironment, result=take!(i.result)) for i in executed_testitems)
    end

    if print_summary
        summaries = String[]

        if length(testerrors)>0
            push!(summaries, "$(length(testerrors)) definition error$(ifelse(length(testerrors)==1,"", "s"))")
        end

        push!(summaries, "$(length(responses)) tests ran")
        push!(summaries, "$(count_success) passed")
        push!(summaries, "$(count_fail) failed")
        push!(summaries, "$(count_error) errored")
        push!(summaries, "$(count_crash) crashed")
        push!(summaries, "$(count_timeout) timed out")

        println()
        println(join(summaries, ", "), ".")
    end

    if print_failed_results
        for te in testerrors
            println()
            println("Definition error at $(uri2filepath(URI(te.uri))):$(te.line)")
            println("  $(te.message)")
        end
    
        for i in responses
            if i.result.status in ("failed", "errored", "crash") 
                println()

                if i.result.status == "failed"
                    println("Test failure in $(uri2filepath(URI(i.testitem.uri))):$(i.testitem.detail.name)")
                elseif i.result.status == "errored"
                    println("Test error in $(uri2filepath(URI(i.testitem.uri))):$(i.testitem.detail.name)")
                end

                if i.result.messages!==missing                
                    for j in i.result.messages
                        println("  at $(uri2filepath(URI(j.location.uri))):$(j.location.range.start.line)")
                        println("    ", replace(j.message, "\n"=>"\n    "))
                    end
                end

                if i.result.status == "crash"
                    println("    stdout log:")
                    println("      ", replace(i.result.log_out, "\n"=>"\n      "))
                    println("    stderr log:")
                    println("      ", replace(i.result.log_err, "\n"=>"\n      "))
                end
            end
        end
    end

    for i in executed_testitems
        wait(i.progress_reported_channel)
    end

    if return_results
        duplicated_testitems = TestrunResultTestitem[TestrunResultTestitem(ti.testitem.detail.name, ti.testitem.uri, [TestrunResultTestitemProfile(ti.testenvironment.name, Symbol(ti.result.status), ti.result.duration, ti.result.messages===missing ? missing : [TestrunResultMessage(msg.message, URI(msg.location.uri), msg.location.range.start.line, msg.location.range.start.character) for msg in ti.result.messages])]) for ti in responses]

        deduplicated_testitems = duplicated_testitems |>
            @groupby({_.name, _.uri}) |>
            @map(TestrunResultTestitem(key(_).name, key(_).uri, [_.profiles...;])) |>
            collect

        typed_results = TestrunResult(
            TestrunResultDefinitionError[TestrunResultDefinitionError(i.message, URI(i.uri), i.line, i.column) for i in testerrors],
            deduplicated_testitems
        )
        return typed_results
    else
        return nothing
    end
end

function  print_process_diag()
    for (k,v) in pairs(TEST_PROCESSES)
        println()
        println("$(length(v)) processes with")
        println("  project_uri: $(k.project_uri)")
        println("  package_uri: $(k.package_uri)")
        println("  package_name: $(k.package_name)")
        println("  env name: $(k.environment.name)")
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
