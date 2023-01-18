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

JSONRPC.@dict_readable  struct Location
    uri::String
    range::Range
end

JSONRPC.@dict_readable struct TestMessage
    message::String
    # expectedOutput?: string;
    # actualOutput?: string;
    location::Union{Missing,Location}
end

JSONRPC.@dict_readable struct TestserverRunTestitemRequestParams <: JSONRPC.Outbound
    uri::String
    name::String
    packageName::String
    useDefaultUsings::Bool
    line::Int
    column::Int
    code::String
end

JSONRPC.@dict_readable struct TestserverRunTestitemRequestParamsReturn <: JSONRPC.Outbound
    status::String
    message::Union{Vector{TestMessage},Missing}
    duration::Union{Float64,Missing}
end

const testserver_revise_request_type = JSONRPC.RequestType("testserver/revise", Nothing, String)
const testserver_run_testitem_request_type = JSONRPC.RequestType("testserver/runtestitem", TestserverRunTestitemRequestParams, TestserverRunTestitemRequestParamsReturn)
