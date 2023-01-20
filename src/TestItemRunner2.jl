module TestItemRunner2

export @run_package_tests, @testitem

# For easier dev, switch these two lines
const pkg_root = "../packages"
# const pkg_root = joinpath(homedir(), ".julia", "dev")

import JSON, JSONRPC, ProgressMeter, CSTParser, TOML, UUIDs, Sockets, JuliaWorkspaces
using TestItems

module TestItemDetection
    import CSTParser
    using CSTParser: EXPR

    import JuliaWorkspaces
    using JuliaWorkspaces: JuliaWorkspace
    using JuliaWorkspaces.URIs2: URI, filepath2uri, uri2filepath

    import ..pkg_root

    include(joinpath(pkg_root, "TestItemDetection", "src", "packagedef.jl"))
end

using CSTParser: EXPR, parentof, headof
using JSONRPC: @dict_readable
using .TestItemDetection: find_test_detail!
using JuliaWorkspaces: JuliaWorkspace
using JuliaWorkspaces.URIs2: filepath2uri, uri2filepath

include("vendored_code.jl")

include(joinpath(pkg_root, "TestItemServer", "src", "testserver_protocol.jl"))

function compute_line_column(content, target_pos)
    line = 1
    column = 1

    pos = 1
    while pos < target_pos
        if content[pos] == '\n'
            line += 1
            column = 1
        else
            column += 1
        end

        pos = nextind(content, pos)
    end

    return (line=line, column=column)
end

@testitem "compute_line_column" begin
    content = "abc\ndef\nghi"

    @test TestItemRunner2.compute_line_column(content, 1) == (line=1, column=1)
    @test TestItemRunner2.compute_line_column(content, 2) == (line=1, column=2)
    @test TestItemRunner2.compute_line_column(content, 3) == (line=1, column=3)
    @test TestItemRunner2.compute_line_column(content, 5) == (line=2, column=1)
    @test TestItemRunner2.compute_line_column(content, 6) == (line=2, column=2)
    @test TestItemRunner2.compute_line_column(content, 7) == (line=2, column=3)
    @test TestItemRunner2.compute_line_column(content, 9) == (line=3, column=1)
    @test TestItemRunner2.compute_line_column(content, 10) == (line=3, column=2)
    @test TestItemRunner2.compute_line_column(content, 11) == (line=3, column=3)
end

mutable struct TestProcess
    key
    process
    connection
    current_testitem
end

const TEST_PROCESSES = Dict{NamedTuple{(:project_path,:package_path,:package_name),Tuple{String,String,String}},Vector{TestProcess}}()
const SOME_TESTITEM_FINISHED = Base.Event(true)

function get_key_from_testitem(testitem)
    return (
        project_path = testitem.project_path,
        package_path = testitem.package_path,
        package_name = testitem.package_name
    )
end

function launch_new_process(testitem)
    key = get_key_from_testitem(testitem)

    pipe_name = generate_pipe_name("tir", UUIDs.uuid4())

    server = Sockets.listen(pipe_name)

    testserver_script = joinpath(@__DIR__, "testserver_main.jl")

    jl_process = open(Cmd(`$(Base.julia_cmd()) --startup-file=no --history-file=no --depwarn=no $testserver_script $pipe_name $(key.project_path) $(key.package_path) $(key.package_name)`))

    socket = Sockets.accept(server)

    connection = JSONRPC.JSONRPCEndpoint(socket, socket)

    run(connection)

    test_process = TestProcess(key, jl_process, connection, nothing)
    
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

function get_free_testprocess(testitem)
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

            # TODO Make this somehow configurable
            max_num_processes = 5

            if length(test_processes) < max_num_processes
                return launch_new_process(testitem)
            else
                wait(SOME_TESTITEM_FINISHED)
            end
        end
    end
end

function execute_test(test_process, testitem, testsetups)

    test_process.current_testitem = testitem

    return_value = Channel(1)

    @async try
        JSONRPC.send(
            test_process.connection,
            testserver_update_testsetups_type,
            TestserverUpdateTestsetupsRequestParams([TestsetupDetails(
                k,
                string(v.uri),
                1,
                1,
                v.code
            ) for (k,v) in testsetups])
        )

        result = JSONRPC.send(
            test_process.connection,
            testserver_run_testitem_request_type,
            TestserverRunTestitemRequestParams(
                string(filepath2uri(testitem.filename)),
                testitem.name,
                testitem.package_name,
                testitem.option_default_imports,
                convert(Vector{String}, string.(testitem.option_setup)),
                # TODO use proper location info here
                1, #pos.line,
                1, #pos.column,
                testitem.code
            )
        )

        test_process.current_testitem = nothing

        notify(SOME_TESTITEM_FINISHED)

        push!(return_value, result)
    catch err
        Base.display_error(err, catch_backtrace())
    end

    return return_value
end

function run_tests(path; filter=nothing, verbose=false)
    # Find all Julia files in this folder and sub folders
    julia_files = String[]
    for (root, _, files) in walkdir(path)
        for file in files
            if endswith(lowercase(file), ".jl")
                push!(julia_files, normpath(joinpath(root, file)))
            end
        end
    end

    # Construct a JuliaWorkspace
    jw = JuliaWorkspace(Set([filepath2uri(path)]))

    # Find all @testitems and @testsetup
    testitems = []
    # testsetups maps @testsetup PACKAGE => NAME => (filename, code, name, line, column)
    testsetups = Dict{JuliaWorkspaces.URIs2.URI,Dict{String,Any}}()
    for file in julia_files
        content = read(file, String)
        cst = CSTParser.parse(content, true)

        ret = TestItemDetection.find_tests_in_file!(jw, filepath2uri(file), cst, "")

        if length(ret.testerrors) > 0
            error("There is an error in your test item or test setup definition, we are aborting.")
        end

        append!(
            testitems,
            (; i..., filename=file, code=content[i.code_range], project_path=ret.project_uri !== nothing ? uri2filepath(ret.project_uri) : "", package_uri = ret.package_uri, package_path = ret.package_uri !==nothing ? uri2filepath(ret.package_uri) : "", package_name=ret.package_name) for i in ret.testitems
        )

        for i in ret.testsetups
            if !haskey(testsetups, ret.package_uri)
                testsetups[ret.package_uri] = Dict{String,Any}()
            end


            if haskey(testsetups[ret.package_uri], i.name)
                error("The name '$(i.name)' is used for more than one test setup.")
            end
            testsetups[ret.package_uri][i.name] = (filename=file, uri=filepath2uri(file), code=content[i.code_range], name=Symbol(i.name), compute_line_column(content, i.code_range.start)...)
        end
    end

    # # Filter @testitems
    # if filter !== nothing
    #     for file in keys(testitems)
    #         testitems[file] = Base.filter(i -> filter((filename=file, name=i.name, tags=i.option_tags)), testitems[file])
    #         isempty(testitems[file]) && pop!(testitems, file)
    #     end
    # end

    executed_testitems = []

    p = ProgressMeter.Progress(length(testitems), barlen=50)

    # Loop over all test items that should be executed
    for testitem in testitems
        test_process = get_free_testprocess(testitem)

        result_channel = execute_test(test_process, testitem, testsetups[testitem.package_uri])

        progress_reported_channel = Channel(1)

        @async try
            wait(result_channel)
            ProgressMeter.next!(p, showvalues = [(Symbol("Number of processes for package '$(i.first.package_name)'"), length(i.second)) for i in TEST_PROCESSES])
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

    count_success = 0

    for i in responses
        if i.result.status=="success"
            count_success += 1
        elseif i.result.message!==missing
            println("Errors for test $(i.testitem.name)")
            for j in i.result.message
                println(j.message)
            end
        end
    end

    for i in executed_testitems
        wait(i.progress_reported_channel)
    end

    println("$(length(responses)) tests passed.")
end

function kill_test_processes()
    for i in values(TEST_PROCESSES)
        for j in i
            kill(j.process)
        end
    end
end

end
