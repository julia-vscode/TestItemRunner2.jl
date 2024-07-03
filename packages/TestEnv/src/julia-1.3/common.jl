struct TestEnvError <: Exception
    msg::AbstractString
end

function Base.showerror(io::IO, ex::TestEnvError, bt; backtrace=true)
    printstyled(io, ex.msg, color=Base.error_color())
end


function current_pkg_name()
    ctx = Context()
    ctx.env.pkg === nothing && throw(TestEnvError("trying to activate test environment of an unnamed project"))
    return ctx.env.pkg.name
end

"""
   ctx, pkgspec = ctx_and_pkgspec(pkg::AbstractString)
   
For a given package name `pkg`, instantiate a `Context` for it, and return that `Context`,
and it's `PackageSpec`.
"""
function ctx_and_pkgspec(pkg::AbstractString)
    pkgspec = deepcopy(PackageSpec(pkg))
    ctx = Context()
    isinstalled!(ctx, pkgspec) || throw(TestEnvError("$pkg not installed 👻"))
    Pkg.instantiate(ctx)
    return ctx, pkgspec
end

"""
    isinstalled!(ctx::Context, pkgspec::Pkg.Types.PackageSpec)

Checks if the package is installed by using `ensure_resolved` from `Pkg/src/Types.jl`.
This function fails if the package is not installed, but here we wrap it in a
try-catch as we may want to test another package after the one that isn't installed.
"""
function isinstalled!(ctx::Context, pkgspec::Pkg.Types.PackageSpec)
    project_resolve!(ctx.env, [pkgspec])
    project_deps_resolve!(ctx.env, [pkgspec])
    manifest_resolve!(ctx.env, [pkgspec])

    try
        ensure_resolved(ctx.env, [pkgspec])
    catch err
        err isa MethodError && rethrow()
        return false
    end
    return true
end


function test_dir_has_project_file(ctx, pkgspec)
    test_dir = get_test_dir(ctx, pkgspec)
    test_dir === nothing && return false
    return isfile(joinpath(test_dir, "Project.toml"))
end

"""
    get_test_dir(ctx::Context, pkgspec::Pkg.Types.PackageSpec)

Gets the testfile path of the package. Code for each Julia version mirrors that found 
in `Pkg/src/Operations.jl`.
"""
function get_test_dir(ctx::Context, pkgspec::Pkg.Types.PackageSpec)
    pkgspec.special_action = Pkg.Types.PKGSPEC_TESTED
    if is_project_uuid(ctx.env, pkgspec.uuid)
        pkgspec.path = dirname(ctx.env.project_file)
        pkgspec.version = ctx.env.pkg.version
    else
        update_package_test!(pkgspec, manifest_info(ctx.env, pkgspec.uuid))
        pkgspec.path = joinpath(project_rel_path(ctx, source_path(pkgspec)))
    end
    pkgfilepath = project_rel_path(ctx, source_path(pkgspec))::String
    return joinpath(pkgfilepath, "test")
end