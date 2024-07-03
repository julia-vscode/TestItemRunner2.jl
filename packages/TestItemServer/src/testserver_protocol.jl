@dict_readable struct Position
    line::Int
    character::Int
end

struct Range
    start::Position
    stop::Position
end
function Range(d::Dict)
    Range(Position(d["start"]), Position(d["end"]))
end
function JSON.lower(a::Range)
    Dict("start" => a.start, "end" => a.stop)
end

@dict_readable struct Location
    uri::String
    range::Range
end

@dict_readable struct TestMessage
    message::String
    expectedOutput::Union{String,Nothing}
    actualOutput::Union{String,Nothing}
    location::Union{Nothing,Location}
end

TestMessage(message, location) = TestMessage(message, nothing, nothing, location)

JSONRPC.@dict_readable struct TestserverRunTestitemRequestParams <: JSONRPC.Outbound
    uri::String
    name::String
    packageName::String
    useDefaultUsings::Bool
    testsetups::Vector{String}
    line::Int
    column::Int
    code::String
    mode::String
    coverageRoots::Union{Vector{String},Nothing}
end

JSONRPC.@dict_readable struct FileCoverage <: JSONRPC.Outbound
    uri::String
    coverage::Vector{Union{Int,Nothing}}
end

JSONRPC.@dict_readable struct TestserverRunTestitemRequestParamsReturn <: JSONRPC.Outbound
    status::String
    message::Union{Vector{TestMessage},Nothing}
    duration::Union{Float64,Nothing}
    coverage::Union{Nothing,Vector{FileCoverage}}
end

JSONRPC.@dict_readable struct TestsetupDetails <: JSONRPC.Outbound
    name::String
    uri::String
    line::Int
    column::Int
    code::String
end

JSONRPC.@dict_readable struct TestserverUpdateTestsetupsRequestParams <: JSONRPC.Outbound
    testsetups::Vector{TestsetupDetails}
end

const testserver_revise_request_type = JSONRPC.RequestType("testserver/revise", Nothing, String)
const testserver_run_testitem_request_type = JSONRPC.RequestType("testserver/runtestitem", TestserverRunTestitemRequestParams, TestserverRunTestitemRequestParamsReturn)
const testserver_update_testsetups_type = JSONRPC.RequestType("testserver/updateTestsetups", TestserverUpdateTestsetupsRequestParams, Nothing)
