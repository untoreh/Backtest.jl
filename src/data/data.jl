module Data

using Requires

include("zarr_utils.jl")

using PythonCall: Py
using Zarr: is_zarray
using DataFramesMeta
using Dates: Period, Millisecond, Second, unix2datetime, datetime2unix, now, UTC, DateTime
using Backtest.Misc:
    @as,
    @as_td,
    PairData,
    config,
    _empty_df,
    timefloat,
    dt,
    Candle,
    LeftContiguityException,
    RightContiguityException
using Backtest.Exchanges:
    exc, OHLCV_COLUMNS, OHLCV_COLUMNS_TS, get_pairlist, to_df, Exchange

function __init__()
    @require Temporal = "a110ec8f-48c8-5d59-8f7e-f91bc4cc0c3d" include("ts.jl")
end

macro zkey()
    p = esc(:pair)
    exn = esc(:exc_name)
    tf = esc(:timeframe)
    key = esc(:key)
    quote
        $key = joinpath($exn, $p, "ohlcv", "tf_" * $tf)
    end
end

macro check_td(args...)
    local check_data
    if !isempty(args)
        check_data = esc(args[1])
    else
        check_data = esc(:za)
    end
    col = esc(:saved_col)
    td = esc(:td)
    quote
        if size($check_data, 1) > 1
            timeframe_match = timefloat($check_data[2, $col] - $check_data[1, $col]) === $td
            if !timeframe_match
                @warn "Saved date not matching timeframe, resetting."
                throw(
                    TimeFrameError(
                        $check_data[1, $col] |> string,
                        $check_data[2, $col] |> string,
                        convert(Second, Millisecond($td)),
                    ),
                )
            end
        end
    end
end



macro as_mat(data)
    tp = esc(:type)
    d = esc(data)
    quote
        # Need to convert to Matrix otherwise assignement throws dimensions mismatch...
        # this allocates...
        if !(typeof($d) <: Matrix{$tp})
            $d = Matrix{$tp}($d)
        end
    end
end

macro to_mat(data, tp = nothing)
    if tp === nothing
        tp = esc(:type)
    else
        tp = esc(tp)
    end
    d = esc(data)
    quote
        # Need to convert to Matrix otherwise assignement throws dimensions mismatch...
        # this allocates...
        if !(typeof($d) <: Matrix{$tp})
            Matrix{$tp}($d)
        else
            $d
        end
    end
end

function data_td(data)
    @debug @assert size(data, 1) > 1 "Need a timeseries of at least 2 points to find a time delta."
    data.timestamp[2] - data.timestamp[1]
end

function combine_data(prev, data)
    df1 = DataFrame(prev, OHLCV_COLUMNS; copycols = false)
    df2 = DataFrame(data, OHLCV_COLUMNS; copycols = false)
    combinerows(df1, df2; idx = :timestamp)
end

@doc "(Right)Merge two dataframes on key, assuming the key is ordered and unique in both dataframes."
function combinerows(df1, df2; idx::Symbol)
    # all columns
    columns = union(names(df1), names(df2))
    empty_tup2 = (; zip(Symbol.(names(df2)), Array{Missing}(missing, size(df2)[2]))...)
    l2 = size(df2)[1]

    c2 = 1
    i2 = df2[c2, idx]
    rows = []
    for (n, r1) in enumerate(Tables.namedtupleiterator(df1))
        i1 = getindex(r1, idx)
        if i1 < i2
            push!(rows, merge(empty_tup2, r1))
        elseif i1 === i2
            push!(rows, merge(r1, df2[c2, :]))
        elseif c2 < l2 # bring the df2 index to the df1 position
            c2 += 1
            i2 = df2[c2, idx]
            while i2 < i1 && c2 < l2
                c2 += 1
                i2 = df2[c2, idx]
            end
            i2 === i1 && push!(rows, merge(r1, df2[c2, :]))
        else # merge the rest of df1
            for rr1 in Tables.namedtupleiterator(df1[n:end, :])
                push!(rows, merge(empty_tup2, rr1))
            end
            break
        end
    end
    # merge the rest of df2
    if c2 < l2
        empty_tup1 = (; zip(Symbol.(names(df1)), Array{Missing}(missing, size(df1)[2]))...)
        for r2 in Tables.namedtupleiterator(df2[c2:end, :])
            push!(rows, merge(empty_tup1, r2))
        end
    end
    DataFrame(rows; copycols = false)
end


mutable struct TimeFrameError <: Exception
    first::Any
    last::Any
    td::Any
end

@doc """
`data_col`: the timestamp column of the new data (1)
`saved_col`: the timestamp column of the existing data (1)
`kind`: what type of trading data it is, (ohlcv or trades)
`pair`: the trading pair (BASE/QUOTE string)
`timeframe`: exchange timeframe (from exc.timeframes)
`type`: Primitive type used for storing the data (Float64)
"""
function save_pair(zi::ZarrInstance, exc_name, pair, timeframe, data; kwargs...)
    @as_td
    @zkey
    try
        _save_pair(zi, key, td, data; kwargs...)
    catch e
        if typeof(e) ??? (MethodError, DivideError, TimeFrameError)
            @warn "Resetting local data for pair $pair." e
            _save_pair(zi, key, td, data; kwargs..., reset = true)
        else
            rethrow(e)
        end
    end
end

function save_pair(pair, timeframe, data; kwargs...)
    @assert pair ??? keys(exc.markets) "Mismatching global exchange instance and pair. Pair not in exchange markets."
    save_pair(zi, exc.name, pair, timeframe, data; kwargs...)
end

save_pair(exc::Exchange, args...; kwargs...) = save_pair(zi, exc.name, args...; kwargs...)

function _get_zarray(
    zi::ZarrInstance,
    key::AbstractString,
    sz::Tuple;
    type,
    overwrite,
    reset,
)
    existing = false
    if is_zarray(zi.store, key)
        za = zopen(zi.store, "w"; path = key)
        if size(za, 2) !== sz[2] || reset
            if overwrite || reset
                rm(joinpath(zi.store.folder, key); recursive = true)
                za = zcreate(type, zi.store, sz...; path = key, compressor)
            else
                throw(
                    "Dimensions mismatch between stored data $(size(za)) and new data. $(sz)",
                )
            end
        else
            existing = true
        end
    else
        if !Zarr.isemptysub(zi.store, key)
            p = joinpath(zi.store.folder, key)
            @debug "Deleting garbage at path $p"
            rm(p; recursive = true)
        end
        za = zcreate(type, zi.store, sz...; path = key, compressor)
    end
    (za, existing)
end

function _save_pair(
    zi::ZarrInstance,
    key,
    td,
    data;
    kind = "ohlcv",
    type = Float64,
    data_col = 1,
    saved_col = 1,
    overwrite = true,
    reset = false,
)
    local za
    !reset && @check_td(data)

    za, existing = _get_zarray(zi, key, size(data); type, overwrite, reset)

    @debug "Zarr dataset for key $key, len: $(size(data))."
    if !reset && existing && size(za, 1) > 0
        local data_view
        saved_first_ts = za[1, saved_col]
        saved_last_ts = za[end, saved_col]
        data_first_ts = data[1, data_col] |> timefloat
        data_last_ts = data[end, data_col] |> timefloat
        _check_contiguity(data_first_ts, data_last_ts, saved_first_ts, saved_last_ts, td)
        # if appending data
        if data_first_ts >= saved_first_ts
            if overwrite
                # when overwriting get the index where data starts overwriting storage
                # we count the number of candles using the difference
                offset = convert(Int, ((data_first_ts - saved_first_ts + td) ?? td))
                data_view = @view data[:, :]
                @debug dt(data_first_ts), dt(saved_last_ts), dt(saved_last_ts + td)
                @debug :saved, dt.(za[end, saved_col]) :data, dt.(data[1, data_col]) :saved_off,
                dt(za[offset, data_col])
                @assert timefloat(data[1, data_col]) === za[offset, saved_col]
            else
                # when not overwriting get the index where data has new values
                data_offset = searchsortedlast(@view(data[:, data_col]), saved_last_ts) + 1
                offset = size(za, 1) + 1
                if data_offset <= size(data, 1)
                    data_view = @view data[data_offset:end, :]
                    @debug :saved, dt(za[end, saved_col]) :data_new,
                    dt(data[data_offset, data_col])
                    @assert za[end, saved_col] + td ===
                            timefloat(data[data_offset, data_col])
                else
                    data_view = @view data[1:0, :]
                end
            end
            szdv = size(data_view, 1)
            if szdv > 0
                resize!(za, (offset - 1 + szdv, size(za, 2)))
                za[offset:end, :] = @to_mat(data_view)
                @debug _contiguous_ts(za[:, saved_col], td)
            end
            @debug "Size data_view: " szdv
            # inserting requires overwrite
        else
            # fetch the saved data and combine with new one
            # fetch saved data starting after the last date of the new data
            # which has to be >= saved_first_date because we checked for contig
            saved_offset = Int(max(1, (data_last_ts - saved_first_ts + td) ?? td))
            saved_data = za[saved_offset+1:end, :]
            szd = size(data, 1)
            ssd = size(saved_data, 1)
            n_cols = size(za, 2)
            @debug ssd + szd, n_cols
            # the new size will include the amount of saved date not overwritten by new data plus new data
            resize!(za, (ssd + szd, n_cols))
            za[szd+1:end, :] = saved_data
            za[begin:szd, :] = @to_mat(data)
            @debug :data_last, dt(data_last_ts) :saved_first, dt(saved_first_ts)
        end
        @debug "Ensuring contiguity in saved data $(size(za))." _contiguous_ts(
            za[:, data_col],
            td,
        )
    else
        resize!(za, size(data))
        za[:, :] = @to_mat(data)
    end
    return za
end

@inline function pair_key(exc_name, pair, timeframe; kind = "ohlcv")
    "$exc_name/$(sanitize_pair(pair))/$kind/tf_$timeframe"
end

load_pairs(zi, exc, pairs::AbstractDict, timeframe) =
    load_pairs(zi, exc, keys(pairs), timeframe)
load_pairs(exc::Exchange, pair::AbstractString, timeframe) =
    load_pairs(zi, exc, [pair], timeframe)
load_pairs(
    exc::Exchange,
    pairs::Union{AbstractArray,AbstractDict},
    timeframe::AbstractString,
) = load_pairs(zi, exc, pairs, timeframe)
load_pairs(exc::Exchange, timeframe::AbstractString) = load_pairs(zi, exc, pairs, timeframe)
load_pairs(pairs::Union{AbstractArray,AbstractDict}, timeframe::AbstractString) =
    load_pairs(zi, exc, pairs, timeframe)
load_pairs(timeframe::AbstractString) =
    load_pairs(get_pairlist(config.qc; as_vec = true, margin = config.margin), timeframe)
load_pairs(pair::AbstractString, args...) = load_pairs([pair], args...)
load_pairs() = load_pairs(get_pairlist(config.qc), config.timeframe)

function load_pairs(zi, exc, pairs, timeframe)
    pairdata = Dict{String,PairData}()
    exc_name = exc.name
    for p in pairs
        (pair_df, za) = load_pair(zi, exc_name, p, timeframe; with_z = true)
        pairdata[p] = PairData(p, timeframe, pair_df, za)
    end
    pairdata
end

function trim_pairs_data(data::AbstractDict{String,PairData}, from::Int)
    for (_, p) in data
        tmp = copy(p.data)
        select!(p.data, [])
        if from >= 0
            idx = max(size(tmp, 1), from)
            @with tmp begin
                for col in eachcol(tmp)
                    p.data[!, col] = @view col[begin:idx-1]
                end
            end
        else
            idx = size(tmp, 1) + from
            if idx > 0
                @with tmp begin
                    for (col, name) in zip(eachcol(tmp), names(tmp))
                        p.data[!, name] = @view col[idx+1:end]
                    end
                end
            end
        end
    end
end

@doc "Load a pair ohlcv data from storage.
`as_z`: returns the ZArray
"
function load_pair(zi, exc_name, pair, timeframe = "1m"; kwargs...)
    @as_td
    @zkey
    try
        _load_pair(zi, key, td; kwargs...)
    catch e
        if typeof(e) ??? (MethodError, DivideError)
            :as_z ??? keys(kwargs) && return [], (0, 0)
            :with_z ??? keys(kwargs) && return _empty_df(), []
            return _empty_df()
        else
            rethrow(e)
        end
    end
end

function _load_pair(
    zi,
    key,
    td;
    from = "",
    to = "",
    saved_col = 1,
    as_z = false,
    with_z = false,
)
    @debug "Loading data for pair at $key."
    za, _ = _get_zarray(
        zi,
        key,
        (1, length(OHLCV_COLUMNS));
        overwrite = true,
        type = Float64,
        reset = false,
    )

    if size(za, 1) === 0
        as_z && return za, (0, 0)
        with_z && return (_empty_df(), za)
        return _empty_df()
    end

    @as from timefloat(from)
    @as to timefloat(to)

    saved_first_ts = za[begin, saved_col]
    @debug "Pair first timestamp is $(saved_first_ts |> dt)"

    with_from = !iszero(from)
    with_to = !iszero(to)
    if with_from
        ts_start = max(1, (from - saved_first_ts + td) ?? td) |> Int
    else
        ts_start = firstindex(za, saved_col)
    end
    if with_to
        ts_stop = (ts_start + ((to - from) ?? td)) |> Int
    else
        ts_stop = lastindex(za, saved_col)
    end

    as_z && return za, (ts_start, ts_stop)

    data = za[ts_start:ts_stop, :]

    with_from && @assert data[begin, saved_col] >= from
    with_to && @assert data[end, saved_col] <= to

    with_z && return (to_df(data), za)
    to_df(data)
end


function _contiguous_ts(series::AbstractVector{DateTime}, td::AbstractFloat)
    pv = dtfloat(series[1])
    for i = 2:length(series)
        nv = dtfloat(series[i])
        nv - pv !== td && throw("Time series is not contiguous at index $i.")
        pv = nv
    end
    true
end

contiguous_ts(series, timeframe::AbstractString) = begin
    @as_td
    _contiguous_ts(series, td)
end

function _contiguous_ts(series::AbstractVector{Float64}, td::Float64)
    pv = series[1]
    for i = 2:length(series)
        nv = series[i]
        nv - pv !== td && throw("Time series is not contiguous at index $i.")
        pv = nv
    end
    true
end

function _check_contiguity(
    data_first_ts::AbstractFloat,
    data_last_ts::AbstractFloat,
    saved_first_ts::AbstractFloat,
    saved_last_ts::AbstractFloat,
    td,
)
    data_first_ts > saved_last_ts + td &&
        throw(RightContiguityException(dt(saved_last_ts), dt(data_first_ts)))
    data_first_ts < saved_first_ts &&
        data_last_ts + td < saved_first_ts &&
        throw(LeftContiguityException(dt(saved_last_ts), dt(data_first_ts)))
end

@enum CandleField cdl_ts = 1 cdl_o = 2 cdl_h = 3 cdl_lo = 4 cdl_cl = 5 cdl_vol = 6

const CandleCol = (; timestamp = 1, open = 2, high = 3, low = 4, close = 5, volume = 6)

using DataFramesMeta

@doc """Assuming timestamps are sorted, returns a new dataframe with a contiguous rows based on timeframe.
Rows are filled either by previous close, or NaN. """
fill_missing_rows(df, timeframe::AbstractString; strategy = :close) = begin
    @as_td
    _fill_missing_rows(df, prd; strategy, inplace = false)
end

fill_missing_rows!(df, prd::Period; strategy = :close) = begin
    _fill_missing_rows(df, prd; strategy, inplace = true)
end

fill_missing_rows!(df, timeframe::AbstractString; strategy = :close) = begin
    @as_td
    _fill_missing_rows(df, prd; strategy, inplace = true)
end

function _fill_missing_rows(df, prd::Period; strategy, inplace)
    size(df, 1) === 0 && return _empty_df()
    let ordered_rows = []
        # fill the row by previous close or with NaNs
        can =
            strategy === :close ? (x) -> [x, x, x, x, 0] : (_) -> [NaN, NaN, NaN, NaN, NaN]
        @with df begin
            ts_cur, ts_end = first(:timestamp) + prd, last(:timestamp)
            ts_idx = 2
            # NOTE: we assume that ALL timestamps are multiples of the timedelta!
            while ts_cur < ts_end
                if ts_cur !== :timestamp[ts_idx]
                    close = :close[ts_idx-1]
                    push!(ordered_rows, Candle(ts_cur, can(close)...))
                else
                    ts_idx += 1
                end
                ts_cur += prd
            end
        end
        inplace || (df = deepcopy(df); true)
        append!(df, ordered_rows)
        sort!(df, :timestamp)
        return df
    end
end

@doc """Similar to the freqtrade homonymous function.
`fill_missing`: `:close` fills non present candles with previous close and 0 volume, else with `NaN`.
"""
function cleanup_ohlcv_data(data, timeframe; col = 1, fill_missing = :close)
    @debug "Cleaning dataframe of size: $(size(data, 1))."
    size(data, 1) === 0 && return _empty_df()
    df = data isa DataFrame ? data : to_df(data)

    @as_td

    # For when for example 1d candles start at hours other than 00
    ts_float = timefloat.(df.timestamp)
    ts_offset = ts_float .% td
    if all(ts_offset .== ts_offset[begin])
        @debug "Offsetting timestamps for $(ts_offset[begin])."
        df.timestamp .= (ts_float .- ts_offset[begin]) .|> dt
    end

    # remove rows with bad timestamps
    # delete!(df, timefloat.(df.timestamp) .% td .!== 0.)
    # @debug "DataFrame without bad timestamp size: $(size(df, 1))"

    gd = groupby(df, :timestamp; sort = true)
    df = combine(
        gd,
        :open => first,
        :high => maximum,
        :low => minimum,
        :close => last,
        :volume => maximum;
        renamecols = false,
    )

    if is_incomplete_candle(df[end, :], td)
        last_candle = copy(df[end, :])
        delete!(df, lastindex(df, 1))
        @debug "Dropping last candle ($(last_candle[:timestamp] |> string)) because it is incomplete."
    end
    if fill_missing !== false
        fill_missing_rows!(df, prd; strategy = fill_missing)
    end
    df
end

function is_incomplete_candle(ts::AbstractFloat, td::AbstractFloat)
    nw = timefloat(now(UTC))
    ts + td > nw
end

function is_incomplete_candle(x::String, td::AbstractFloat)
    ts = timefloat(x)
    is_incomplete_candle(ts, td)
end

function is_incomplete_candle(candle, td::AbstractFloat)
    ts = timefloat(candle.timestamp)
    nw = timefloat(now(UTC))
    ts + td > nw
end

function is_incomplete_candle(x, timeframe = "1m")
    @as_td
    is_incomplete_candle(x, td)
end

function is_last_complete_candle(x, timeframe)
    @as_td
    ts = timefloat(x)
    is_incomplete_candle(ts + td, td)
end

export PairData, ZarrInstance, @as_df, @as_mat, @to_mat, load_pairs, save_pair

end
