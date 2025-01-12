using TestItemRunner2

run_tests(
    joinpath(homedir(), ".julia/dev/CSTParser"),
    filter = i->i.name!="Parsing Files in Base",
    print_failed_results=true,
    return_results=false,
    # progress_ui=:log,
    max_workers=5,
    env=Dict("JULIAUP_CHANNEL" => "1.0")
    # environments=[
    #     # TestEnvironment("Julia 1.0.5~x86", false, Dict("JULIAUP_CHANNEL" => "1.0.5~x86"))
    #     TestEnvironment("Julia Release", false, Dict("JULIAUP_CHANNEL" => "release"))
    # ]
)
