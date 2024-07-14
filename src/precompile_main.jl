import Pkg

include("../packages/TestEnv/src/TestEnv.jl")

project_path, package_path, package_name = ARGS

if project_path==""
    @static if VERSION >= v"1.5.0"
        Pkg.activate(temp=true)
    else
        temp_path = mktempdir()
        Pkg.activate(temp_path)
    end

    Pkg.develop(Pkg.PackageSpec(path=package_path))

    TestEnv.activate(package_name) do
        Core.eval(Main, :(using $(Symbol(package_name))))
    end
else
    Pkg.activate(project_path)

    if package_name!=""
        TestEnv.activate(package_name) do
            Core.eval(Main, :(using $(Symbol(package_name))))
        end
    else
        Core.eval(Main, :(using $(Symbol(package_name))))
    end
end
