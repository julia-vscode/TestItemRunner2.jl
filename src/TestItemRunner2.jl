module TestItemRunner2

export run_tests, kill_test_processes, print_process_diag, kill_controller

import ProgressMeter, UUIDs, JuliaWorkspaces, TestItemControllers
using Query

using JuliaWorkspaces: JuliaWorkspace
using JuliaWorkspaces.URIs2: URI, filepath2uri, uri2filepath
using TestItemControllers: TestItemController

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

const g_controller = Ref{Union{TestItemController,Nothing}}(nothing)

function kill_controller()
    g_controller[] = nothing
end

function  print_process_diag()
    for (k,v) in pairs(g_controller[].testprocesses)
        println()
        println("$(length(v)) processes with")
        println("  project_uri: $(k.project_uri)")
        println("  package_uri: $(k.package_uri)")
        println("  package_name: $(k.package_name)")
        # println("  env name: $(k.environment.name)")
    end
end

function kill_test_processes()
    for i in values(TEST_PROCESSES)
        for j in i
            kill(j.process)
        end
    end
end

function run_tests(
            path;
            filter=nothing,
            max_workers::Int=Sys.CPU_THREADS,
            timeout=60*5,
            fail_on_detection_error=true,
            return_results=false,
            print_failed_results=true,
            print_summary=true,
            progress_ui=:bar,
            profile_name="",
            env::Dict=Dict{String,Union{String,Nothing}}(),
            coverage=false,
        )
    if g_controller[] === nothing
        g_controller[] = TestItemController((a,b)->println("ERROR"))

        @async try
            run(
                g_controller[],
                (id, package_name, package_uri, project_uri, coverage, env) -> nothing,
                id -> nothing,
                (id, status) -> nothing,
                (id, output) -> nothing
            )
        catch err
            Base.display_error(err, catch_backtrace())
        end
    end

    jw = JuliaWorkspaces.workspace_from_folders(([path]))
    
    # Flat list of @testitems and @testmodule and @testsnippet
    testitems = []
    testitems_by_id = Dict{String,TestItemControllers.TestItemDetail}()
    testsetups = TestItemControllers.TestSetupDetail[]
    testerrors = []
    coverage_root_uris = Set{String}()
    for (uri, items) in pairs(JuliaWorkspaces.get_test_items(jw))
        project_details = JuliaWorkspaces.get_test_env(jw, uri)
        textfile = JuliaWorkspaces.get_text_file(jw, uri)

        for item in items.testitems            
            line, column = JuliaWorkspaces.position_at(textfile.content, item.range.start)
            codeLine, codeColumn = JuliaWorkspaces.position_at(textfile.content, item.code_range.start)

            testitem_detail = TestItemControllers.TestItemDetail(
                item.id,
                string(item.uri),
                item.name,
                project_details.package_name,
                project_details.package_uri === nothing ? nothing : string(project_details.package_uri),
                project_details.project_uri === nothing ? nothing : string(project_details.project_uri),
                project_details.env_content_hash,
                item.option_default_imports,
                string.(item.option_setup),
                line,
                column,
                textfile.content.content[item.code_range],
                codeLine,
                codeColumn
            )

            if project_details.package_uri !== nothing
                push!(coverage_root_uris, string(project_details.package_uri))
            end

            push!(
                testitems,
                (
                    option_tags = item.option_tags,
                    details = testitem_detail
                )                
            )

            testitems_by_id[item.id] = testitem_detail
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
            filter!(i->filter((filename=uri2filepath(URI(i.details.uri)), name=i.details.label, tags=i.option_tags, package_name=i.details.package_name)), testitems)
        end

        p = ProgressMeter.Progress(length(testitems), barlen=50, enabled=progress_ui==:bar)

        update_progress_bar() = if progress_ui==:bar
            ProgressMeter.next!(
                p,
                showvalues = [
                    (Symbol("Successful tests"), count_success),
                    (Symbol("Failed tests"), count_fail),
                    (Symbol("Errored tests"), count_error),
                    (Symbol("Crashed tests"), count_crash),
                    (Symbol("Timed out tests"), count_timeout),
                    # ((Symbol("Number of processes for package '$(i.first.package_name)'"), length(i.second)) for i in TEST_PROCESSES)...
                ]
            )
        end

        cs = TestItemControllers.CancellationTokens.CancellationTokenSource()

        ret = TestItemControllers.execute_testrun(
            g_controller[],
            string(UUIDs.uuid4()), # Generate random id
            [TestItemControllers.TestProfile(
                profile_name,
                profile_name,
                "julia",
                String[],
                "",
                env isa Dict{String,Union{String,Nothing}} ? env : Dict{String,Union{String,Nothing}}(i for i in pairs(env)),
                max_workers,
                coverage ? "Coverage" : "Normal",
                [i for i in coverage_root_uris]
            )],
            [i.details for i in testitems],
            testsetups,
            # testitem_started_callback,
            (testrun_id, testitem_id) -> nothing,
            # testitem_passed_callback
            (testrun_id, testitem_id, duration) -> begin
                count_success += 1

                testitem_detail = testitems_by_id[testitem_id]

                push!(
                    responses,
                    (
                        result = (;
                            status = "passed",
                            duration = duration,
                            messages = missing
                        ),
                        testitem = (;
                            detail = testitem_detail
                        )
                    )
                )

                update_progress_bar()

                if progress_ui==:log
                    duration_string = duration !== missing ? " ($(duration)ms)" : ""
                    println("✓ $(uri2filepath(URI(testitem_detail.uri))):$(testitem_detail.line) $(testitem_detail.label) → passed$duration_string")
                    # println("✓ (environment.name) $(uri2filepath(testitem.uri)):$(testitem.detail.name) → $(res.status)$duration_string")
                    # println("$(res.status=="passed" ? "✓" : "✗") $(environment.name) $(uri2filepath(testitem.uri)):$(testitem.detail.name) → $(res.status)$duration_string")
                end
            end,
            # testitem_failed_callback
            (testrun_id, testitem_id, messages, duration) -> begin
                count_fail += 1

                testitem_detail = testitems_by_id[testitem_id]

                push!(
                    responses,
                    (
                        result = (;
                            status = "failed",
                            duration = missing,
                            messages = messages
                        ),
                        testitem = (;
                            detail = testitem_detail
                        )
                    )
                )

                
                update_progress_bar()

                if progress_ui==:log
                    duration_string = duration !== missing ? " ($(duration)ms)" : ""
                    println("✗ $(uri2filepath(URI(testitem_detail.uri))):$(testitem_detail.line) $(testitem_detail.label) → failed$duration_string")
                    # println("✓ (environment.name) $(uri2filepath(testitem.uri)):$(testitem.detail.name) → $(res.status)$duration_string")
                    # println("$(res.status=="passed" ? "✓" : "✗") $(environment.name) $(uri2filepath(testitem.uri)):$(testitem.detail.name) → $(res.status)$duration_string")
                end
            end,
            # testitem_errored_callback
            (testrun_id, testitem_id, messages, duration) -> begin
                count_error += 1

                testitem_detail = testitems_by_id[testitem_id]

                push!(
                    responses,
                    (
                        result = (;
                            status = "errored",
                            duration = missing,
                            messages = messages
                        ),
                        testitem = (;
                            detail = testitem_detail
                        )
                    )
                )

                
                update_progress_bar()

                if progress_ui==:log
                    duration_string = duration !== missing ? " ($(duration)ms)" : ""
                    println("✗ $(uri2filepath(URI(testitem_detail.uri))):$(testitem_detail.line) $(testitem_detail.label) → errored$duration_string")
                    # println("✓ (environment.name) $(uri2filepath(testitem.uri)):$(testitem.detail.name) → $(res.status)$duration_string")
                    # println("$(res.status=="passed" ? "✓" : "✗") $(environment.name) $(uri2filepath(testitem.uri)):$(testitem.detail.name) → $(res.status)$duration_string")
                end
            end,
            # append_output_callback
            (testrun_id, testitem_id, output) -> nothing,
            # attach_debugger_callback
            (testrun_id, debug_pipename) -> error("Not Implemented"),
            TestItemControllers.CancellationTokens.get_token(cs)
        )




                # if res.status=="passed"
                #     count_success += 1
                # elseif res.status=="timeout"
                #     count_timeout += 1
                # elseif res.status == "failed"
                #     count_fail += 1
                # elseif res.status == "errored"
                #     count_error += 1
                # elseif res.status == "crash"
                #     count_crash += 1
                # else
                #     error("Unknown test status")
                # end

                # if progress_ui==:bar
                #     ProgressMeter.next!(
                #         p,
                #         showvalues = [
                #             (Symbol("Successful tests"), count_success),
                #             (Symbol("Failed tests"), count_fail),
                #             (Symbol("Errored tests"), count_error),
                #             (Symbol("Crashed tests"), count_crash),
                #             (Symbol("Timed out tests"), count_timeout),
                #             ((Symbol("Number of processes for package '$(i.first.package_name)'"), length(i.second)) for i in TEST_PROCESSES)...
                #         ]
                #     )
                # end

                # if progress_ui==:log
                #     duration_string = res.duration !== missing ? " ($(res.duration)ms)" : ""
                #     println("$(res.status=="passed" ? "✓" : "✗") $(environment.name) $(uri2filepath(testitem.uri)):$(testitem.detail.name) → $(res.status)$duration_string")
                # end



        # append!(responses, (testitem=i.testitem, testenvironment=i.testenvironment, result=take!(i.result)) for i in executed_testitems)
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
                    println("Test failure in $(uri2filepath(URI(i.testitem.detail.uri))):$(i.testitem.detail.line) $(i.testitem.detail.label)")
                elseif i.result.status == "errored"
                    println("Test error in $(uri2filepath(URI(i.testitem.detail.uri))):$(i.testitem.detail.line) $(i.testitem.detail.label)")
                end

                if i.result.messages!==missing                
                    for j in i.result.messages
                        println("  at $(uri2filepath(URI(j.uri))):$(j.line)")
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

    if return_results
        duplicated_testitems = TestrunResultTestitem[
            TestrunResultTestitem(
                ti.testitem.detail.label,
                URI(ti.testitem.detail.uri),
                [
                    TestrunResultTestitemProfile(
                        profile_name,
                        Symbol(ti.result.status),
                        ti.result.duration,
                        ti.result.messages===missing ? missing : [
                            TestrunResultMessage(msg.message, URI(msg.uri), msg.line, msg.column) for msg in ti.result.messages
                        ]
                    )
                ]
            ) for ti in responses
        ]

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



end
