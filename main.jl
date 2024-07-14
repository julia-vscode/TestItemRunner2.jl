using TestItemRunner2

run_tests(
    joinpath(homedir(), ".julia/dev/CSTParser"),
    filter = i->i.name!="Parsing Files in Base",
    progress_ui=:log,
    environments=[
        TestEnvironment("Julia 1.0.5~x86", false, Dict("JULIAUP_CHANNEL" => "1.0.5~x86"))
    ]
)
