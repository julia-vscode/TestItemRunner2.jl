using TestItemRunner2

run_tests(
    joinpath(homedir(), ".julia/dev/CSTParser"),
    filter = i->i.name!="Parsing Files in Base",
    progress_ui=:bar,
    environments=[
        TestEnvironment("Julia", false, Dict("JULIAUP_CHANNEL" => "release"))
    ]
)
