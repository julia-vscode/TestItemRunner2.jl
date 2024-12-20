versions = ["1.0", "1.1", "1.2", "1.3", "1.4", "1.5", "1.6", "1.7", "1.8", "1.9", "1.10", "1.11"]

for version in versions
    env_folder = joinpath(@__DIR__, "v$version")
    mkpath(env_folder)

    run(Cmd(`julia +$version --project=. -e 'using Pkg; Pkg.develop(PackageSpec(path="../../packages/TestItemServer"))'`, dir=env_folder))
end
