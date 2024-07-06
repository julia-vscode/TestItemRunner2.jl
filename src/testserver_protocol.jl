@dict_readable struct Position <: JSONRPC.Outbound
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

@dict_readable struct Location <: JSONRPC.Outbound
    uri::String
    range::Range
end

@dict_readable struct TestMessage <: JSONRPC.Outbound
    message::String
    expectedOutput::Union{String,Missing}
    actualOutput::Union{String,Missing}
    location::Location
end

TestMessage(message, location) = TestMessage(message, missing, missing, location)

@dict_readable struct TestserverRunTestitemRequestParams <: JSONRPC.Outbound
    uri::String
    name::String
    packageName::String
    useDefaultUsings::Bool
    testsetups::Vector{String}
    line::Int
    column::Int
    code::String
    mode::String
    coverageRoots::Union{Vector{String},Missing}
end

@dict_readable struct FileCoverage <: JSONRPC.Outbound
    uri::String
    coverage::Vector{Union{Int,Nothing}}
end

@dict_readable struct TestserverRunTestitemRequestParamsReturn <: JSONRPC.Outbound
    status::String
    message::Union{Vector{TestMessage},Missing}
    duration::Union{Float64,Missing}
    coverage::Union{Missing,Vector{FileCoverage}}
end

@dict_readable struct TestsetupDetails <: JSONRPC.Outbound
    name::String
    kind::String
    uri::String
    line::Int
    column::Int
    code::String
end

@dict_readable struct TestserverUpdateTestsetupsRequestParams <: JSONRPC.Outbound
    testsetups::Vector{TestsetupDetails}
end

const testserver_revise_request_type = JSONRPC.RequestType("testserver/revise", Nothing, String)
const testserver_run_testitem_request_type = JSONRPC.RequestType("testserver/runtestitem", TestserverRunTestitemRequestParams, TestserverRunTestitemRequestParamsReturn)
const testserver_update_testsetups_type = JSONRPC.RequestType("testserver/updateTestsetups", TestserverUpdateTestsetupsRequestParams, Nothing)
