using TestItemRunner2, Logging, LoggingFormats, LoggingExtras

global_logger(
    TeeLogger(
        TransformerLogger(
            FormatLogger(LoggingFormats.JSON(), joinpath(@__DIR__, "tic.log.json"))
        ) do log
            old_kwargs = log.kwargs
            new_kwargs = (;old_kwargs..., timestamp=time_ns(), node=TestItemRunner2.TestItemControllers.logging_node[])
            (log..., kwargs=new_kwargs)
        end,
        global_logger()
    )
)


run_tests(
    joinpath(homedir(), ".julia/dev/TomlSyntax"),
    # filter = i->i.name!="Parsing Files in Base",
    progress_ui=:bar,
    max_workers = 10,
    environments=[
        TestEnvironment("Julia", false, Dict("JULIAUP_CHANNEL" => "release"))
    ]
)
