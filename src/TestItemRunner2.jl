module TestItemRunner2

export run_tests, kill_test_processes, TestEnvironment, print_process_diag

import ProgressMeter, JuliaWorkspaces, AutoHashEquals, TestItemControllers, Logging
using Query

using JuliaWorkspaces: JuliaWorkspace
using JuliaWorkspaces.URIs2: URI, filepath2uri, uri2filepath
using AutoHashEquals: @auto_hash_equals
using TestItemControllers: TestItemController

const g_testitemcontroller = Ref{TestItemController}()

function get_testitemcontroller()
    if !isassigned(g_testitemcontroller)
        g_testitemcontroller[] = TestItemController()
        @async try
            run(g_testitemcontroller[])
        catch err
            Base.display_error(err, catch_backtrace())
        end
    end

    return g_testitemcontroller[]
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
            environments=[TestEnvironment("Default", false, Dict{String,Any}())],
            token=nothing
        )
    tic = get_testitemcontroller()

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
                TestItemControllers.TestSetupDetail(
                    missing,  # packageUri
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
    count_skipped = 0

    progressbar_next = () -> begin
        ProgressMeter.next!(
            p,
            showvalues = [
                (Symbol("Successful tests"), count_success),
                (Symbol("Failed tests"), count_fail),
                (Symbol("Errored tests"), count_error),
                (Symbol("Crashed tests"), count_crash),
                (Symbol("Timed out tests"), count_timeout),
                (Symbol("Skipped tests"), count_skipped),
                # Process count not available - TestItemControllers manages processes internally
            ]
        )
    end

    responses = []
    executed_testitems = []

    if length(testerrors) == 0  || fail_on_detection_error==false
        # Filter @testitems
        if filter !== nothing
            filter!(i->filter((filename=uri2filepath(i.uri), name=i.detail.name, tags=i.detail.option_tags, package_name=i.env.package_name)), testitems)
        end

        p = ProgressMeter.Progress(length(testitems)*length(environments), barlen=50, enabled=progress_ui==:bar)

        debuglogger = Logging.ConsoleLogger(stderr, Logging.Warn)

        environment_name = environments[1].name

        Logging.with_logger(debuglogger) do

            testitems_to_run_by_id = pairs(JuliaWorkspaces.get_test_items(jw)) |>
                    @map({uri = _.first, items = _.second.testitems}) |>
                    @mutate(
                        project_details = JuliaWorkspaces.get_test_env(jw, _.uri),
                        textfile = JuliaWorkspaces.get_text_file(jw, _.uri)
                    ) |>
                    @mapmany(
                        _.items,
                        __.id => 
                        TestItemControllers.TestItemDetail(
                            __.id,
                            string(__.uri),
                            __.name,
                            _.project_details.package_name,
                            string(_.project_details.package_uri),
                            _.project_details.project_uri === nothing ? nothing : string(_.project_details.project_uri),
                            string(_.project_details.env_content_hash),
                            __.option_default_imports,
                            __.option_setup,
                            JuliaWorkspaces.position_at(_.textfile.content, __.code_range.start)[1],
                            JuliaWorkspaces.position_at(_.textfile.content, __.code_range.start)[2],
                            _.textfile.content.content[__.code_range],
                            JuliaWorkspaces.position_at(_.textfile.content, __.code_range.stop)[1],
                            JuliaWorkspaces.position_at(_.textfile.content, __.code_range.stop)[2]
                        )
                    ) |>
                    Dict

            ret = try
                TestItemControllers.execute_testrun(
                    tic,
                    "Testrun ID",
                [
                    TestItemControllers.TestProfile(
                        i.name, #i.id,
                        "$(i.name) Profile", #i.label,
                        "julia", #i.juliaCmd,
                        String[], #i.juliaArgs,
                        missing, #i.juliaNumThreads,
                        i.env, #i.juliaEnv,
                        max_workers, #i.maxProcessCount,
                        i.coverage ? "Coverage" : "Normal", #i.mode,
                        nothing #coalesce(i.coverageRootUris,nothing)
                    ) for i in environments
                ],
                collect(values(testitems_to_run_by_id)),
                pairs(JuliaWorkspaces.get_test_items(jw)) |>
                    @map({uri = _.first, items = _.second.testsetups}) |>
                    @mutate(
                        textfile = JuliaWorkspaces.get_text_file(jw, _.uri)
                    ) |>
                    @mapmany(
                        _.items,
                        TestItemControllers.TestSetupDetail(
                            missing,  # packageUri
                            string(__.name),
                            string(__.kind),
                            string(_.uri),
                            JuliaWorkspaces.position_at(_.textfile.content, __.code_range.start)[1],
                            JuliaWorkspaces.position_at(_.textfile.content, __.code_range.start)[2],
                            _.textfile.content.content[__.code_range]
                        )
                    ) |>
                    i-> collect(TestItemControllers.TestSetupDetail, i),
                # testitem_started_callback,
                (testrun_id, testitem_id) -> nothing,
                # testitem_passed_callback
                (testrun_id, testitem_id, duration) -> begin
                    count_success += 1

                    testitem = testitems_to_run_by_id[testitem_id]

                    if progress_ui==:log
                        duration_string = duration !== missing ? " ($(duration)ms)" : ""
                        println("✓ $environment_name $(uri2filepath(URI(testitem.uri))):$(testitem.label) → passed$duration_string")
                    end

                    if progress_ui==:bar
                        progressbar_next()
                    end

                    push!(responses, (testitem=testitem, testenvironment=environments[1], result=(status=:passed, messages=missing, duration=duration)))
                end,
                # testitem_failed_callback
                (testrun_id, testitem_id, messages, duration) -> begin
                    count_fail += 1
                    testitem = testitems_to_run_by_id[testitem_id]

                    if progress_ui==:log
                        duration_string = duration !== missing ? " ($(duration)ms)" : ""
                        println("✗ $environment_name $(uri2filepath(URI(testitem.uri))):$(testitem.label) → failed$duration_string")
                    end

                    if progress_ui==:bar
                        progressbar_next()
                    end

                    push!(responses, (testitem=testitem, testenvironment=environments[1], result=(status=:failed, messages=messages, duration=duration)))
                end,
                # testitem_errored_callback
                (testrun_id, testitem_id, messages, duration) -> begin
                    count_error += 1
                    testitem = testitems_to_run_by_id[testitem_id]

                    if progress_ui==:log
                        duration_string = duration !== missing ? " ($(duration)ms)" : ""
                        println("✗ $environment_name $(uri2filepath(URI(testitem.uri))):$(testitem.label) → errored$duration_string")
                    end

                    if progress_ui==:bar
                        progressbar_next()
                    end

                    push!(responses, (testitem=testitem, testenvironment=environments[1], result=(status=:errored, messages=messages, duration=duration)))
                end,
                # testitem_skipped_callback
                (testrun_id, testitem_id) -> begin
                    count_skipped += 1
                    testitem = testitems_to_run_by_id[testitem_id]

                    if progress_ui==:log
                        println("⊘ $environment_name $(uri2filepath(URI(testitem.uri))):$(testitem.label) → skipped")
                    end

                    if progress_ui==:bar
                        progressbar_next()
                    end

                    push!(responses, (testitem=testitem, testenvironment=environments[1], result=(status=:skipped, messages=missing, duration=missing)))
                end,
                # append_output_callback
                (testrun_id, testitem_id, output) -> nothing,
                # attach_debugger_callback
                (testrun_id, debug_pipename) -> nothing,
                # token
                token
            )
            catch err
                @error "TestItemControllers.execute_testrun failed" exception=(err, catch_backtrace())
                rethrow(err)
            end

            # Extract coverage data if coverage mode is enabled
            if any(env -> env.coverage, environments) && ret.coverage !== nothing
                # TODO: Process coverage data from ret.coverage
                @info "Coverage data collected but not yet processed"
            end
        end

       

       
        #         if res.status=="passed"
        #             count_success += 1
        #         elseif res.status=="timeout"
        #             count_timeout += 1
        #         elseif res.status == "failed"
        #             count_fail += 1
        #         elseif res.status == "errored"
        #             count_error += 1
        #         elseif res.status == "crash"
        #             count_crash += 1
        #         else
        #             error("Unknown test status")
        #         end

        #         if progress_ui==:bar
        #             ProgressMeter.next!(
        #                 p,
        #                 showvalues = [
        #                     (Symbol("Successful tests"), count_success),
        #                     (Symbol("Failed tests"), count_fail),
        #                     (Symbol("Errored tests"), count_error),
        #                     (Symbol("Crashed tests"), count_crash),
        #                     (Symbol("Timed out tests"), count_timeout),
        #                     ((Symbol("Number of processes for package '$(i.first.package_name)'"), length(i.second)) for i in TEST_PROCESSES)...
        #                 ]
        #             )
        #         end

        #         if progress_ui==:log
        #             duration_string = res.duration !== missing ? " ($(res.duration)ms)" : ""
        #             println("$(res.status=="passed" ? "✓" : "✗") $(environment.name) $(uri2filepath(testitem.uri)):$(testitem.detail.name) → $(res.status)$duration_string")
        #         end

        #         push!(progress_reported_channel, true)
        #     catch err
        #         Base.display_error(err, catch_backtrace())
        #     end

        #     push!(executed_testitems, (testitem=testitem, testenvironment=environment, result=result_channel, progress_reported_channel=progress_reported_channel))
        # end

    #     yield()


    #     for i in executed_testitems
    #         wait(i.result)
    #     end

    #     append!(responses, (testitem=i.testitem, testenvironment=i.testenvironment, result=take!(i.result)) for i in executed_testitems)
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
        push!(summaries, "$(count_skipped) skipped")
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
            if i.result.status in (:failed, :errored, :crash, :skipped) 
                println()

                if i.result.status == :failed
                    println("Test failure in $(uri2filepath(URI(i.testitem.uri))):$(i.testitem.label)")
                elseif i.result.status == :errored
                    println("Test error in $(uri2filepath(URI(i.testitem.uri))):$(i.testitem.label)")
                end

                if i.result.messages!==missing                
                    for j in i.result.messages
                        println("  at $(uri2filepath(URI(j.uri))):$(j.line)")
                        println("    ", replace(j.message, "\n"=>"\n    "))
                    end
                end

                if i.result.status == :crash
                    println("    stdout log:")
                    println("      ", replace(i.result.log_out, "\n"=>"\n      "))
                    println("    stderr log:")
                    println("      ", replace(i.result.log_err, "\n"=>"\n      "))
                end
            end
        end
    end

    # Note: executed_testitems is no longer used in the refactored synchronous execution model
    # for i in executed_testitems
    #     wait(i.progress_reported_channel)
    # end

    if return_results
        duplicated_testitems = TestrunResultTestitem[TestrunResultTestitem(ti.testitem.label, URI(ti.testitem.uri), [TestrunResultTestitemProfile(ti.testenvironment.name, ti.result.status, ti.result.duration, ti.result.messages===missing ? missing : [TestrunResultMessage(msg.message, URI(msg.uri), msg.line, msg.column) for msg in ti.result.messages])]) for ti in responses]

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
    # TODO: Implement process diagnostics
    # TestItemControllers manages processes internally
    println("Process diagnostics not available - TestItemControllers manages processes internally")
end

function kill_test_processes()
    # TODO: Implement graceful test process termination
    # TestItemControllers manages process lifecycle internally  
    if isassigned(g_testitemcontroller)
        TestItemControllers.shutdown(g_testitemcontroller[])
    end
end

end
