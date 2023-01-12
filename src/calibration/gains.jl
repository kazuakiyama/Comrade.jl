
export GainCache, GainPrior, GainModel

"""
    $(TYPEDEF)

Abstract type that encompasses all RIME style corruptions.
"""
abstract type RIMEModel <: AbstractModel end

basemodel(m::RIMEModel) = m.model
flux(m::RIMEModel) = flux(basemodel(m))
radialextent(m::RIMEModel) = radialextent(basemodel(m))

function intensitymap(model::RIMEModel, dims::DataNames)
    return intensitymap(basemodel(model), dims)
end

function intensity_point(model::RIMEModel, p)
    return intensity_point(model.model, p)
end


"""
    $(TYPEDEF)

Internal type that holds the gain design matrices for visibility corruption.
See [`GainCache`](@ref GainCache).
"""
struct DesignMatrix{X,M<:AbstractMatrix{X},T,S} <: AbstractMatrix{X}
    matrix::M
    times::T
    stations::S
end

Base.getindex(m::DesignMatrix, i::Int) = getindex(m.matrix, i)
Base.size(m::DesignMatrix) = size(m.matrix)
Base.IndexStyle(::Type{<:DesignMatrix{X,M}}) where {X,M} = Base.IndexStyle(M)
Base.getindex(m::DesignMatrix, I::Vararg{Int,N}) where {N} = getindex(m.matrix, I...)
Base.setindex!(m::DesignMatrix, v, i::Int) = setindex!(m.matrix, v, i)
Base.setindex!(m::DesignMatrix, v, i::Vararg{Int, N}) where {N} = setindex!(m.matrix, v, i...)

Base.similar(m::DesignMatrix, ::Type{S}, dims::Dims) where {S} = DesignMatrix(similar(m.matrix, S, dims), m.times, m.stations)


"""
    $(TYPEDEF)

# Fields
$(FIELDS)

# Notes
Internal type. This should be created using the [`GainCache(st::ScanTable)`](@ref GainCache) method.
"""
struct GainCache{D1<:DesignMatrix, D2<:DesignMatrix, T, S}
    """
    Gain design matrix for the first station
    """
    m1::D1
    """
    Gain design matrix for the second station
    """
    m2::D2
    """
    Set of times for each gain
    """
    times::T
    """
    Set of stations for each gain
    """
    stations::S
end




"""
    GainCache(st::ScanTable)

Creates a cache for the application of gain corruptions to the model visibilities.
This cache consists of the gain design matrices for each station and the set of times
and stations for each gain.

"""
function GainCache(st::ScanTable)
    gtime, gstat = gain_stations(st)
    m1, m2 = gain_design(st)
    return GainCache(m1, m2, gtime, gstat)
end

"""
    $(TYPEDEF)

A model that applies gain corruptions to a `Comrade` `model`.
This obeys the usual `Comrade` interface and can be evaluated using
`visibilities`.

# Fields
$(FIELDS)
"""
struct GainModel{C, G<:AbstractArray, M} <: RIMEModel
    """
    Cache for the application of gain. This can be constructed with
    [`GainCache`](@ref GainCache).
    """
    cache::C
    """
    Array of the specific gains that are to be applied to the visibilities.
    """
    gains::G
    """
    Base model that will be used to compute the uncorrupted visibilities.
    """
    model::M
end

"""
    caltable(g::GainModel)

Compute the gain calibration table from the [`GainModel`](@ref) `g`. This will
return a [`CalTable`](@ref) object, whose rows are different times,
and columns are different telescopes.
"""
function caltable(g::GainModel)
    return caltable(g.cache, g.gains)
end

function intensity_point(model::GainModel, p)
    return intensity_point(model.model, p)
end

function intensitymap!(img::IntensityMap, model::GainModel, p)
    return intensitymap!(img, model.model, p)
end

function _visibilities(model::GainModel, u, v, time, freq)
    vis = _visibilities(model.model, u, v, time, freq)
    return corrupt(vis, model.cache, model.gains)
end

function amplitudes(model::GainModel, u, v, time, freq)
    amp = visibilities(model.model, u, v, time, freq)
    return abs.(corrupt(amp, model.cache, model.gains))
end

amplitudes(model, u, v, time, freq) = abs.(_visibilities(m, u, v, time, freq))

# Pass through since closure phases are independent of gains
function closure_phases(model::GainModel, args::Vararg{<:AbstractArray, N}) where {N}
    return closure_phases(model.model, args...)
end


# Pass through since log-closure amplitudes are independent of gains
function logclosure_amplitudes(model::GainModel, args::Vararg{<:AbstractArray, N}) where {N}
    return logclosure_amplitudes(model.model, args...)
end

"""
    corrupt(vis::AbstractArray, cache::GainCache, gains::AbstractArray)

Corrupt the visibilities `vis` with the gains `gains` using a `cache`.

This returns an array of corrupted visibilties. This is called internally
by the `GainModel` when producing the visibilties.
"""
function corrupt(vis::AbstractArray, cache::GainCache, gains::AbstractArray)
    g1 = cache.m1.matrix*gains
    g2 = cache.m2.matrix*gains
    return @. g1*vis*conj(g2)
end

# ChainRulesCore.@non_differentiable getproperty(cache::GainCache, s::Symbol)

# function ChainRulesCore.rrule(::typeof(corrupt), vis::AbstractArray, cache::GainCache, gains::AbstractArray)
#     g1 = cache.m1*gains
#     cg2 = conj.(cache.m2*gains)
#     viscor = @. g1*vis*cg2
#     function _corrupt_pullback(ΔV)
#         cΔV = conj.(ΔV)
#         Δf = NoTangent()
#         Δvis   = @thunk(cΔV.*g1.*cg2)
#         Δcache = NoTangent()

#         tmp1 = Diagonal(vis.*g1)*cache.m1
#         tmp2 = Diagonal(vis.*cg2)*cache.m2
#         Δgains = ΔV'*tmp1 + ΔV'*tmp2
#         return (Δf, Δvis, Δcache, Δgains)
#     end
#     return viscor, _corrupt_pullback
# end


# This is an internal function that computes the set of stations from a ScanTable
function gain_stations(st::ScanTable)
    gainstat = Symbol[]
    times = eltype(st.times)[]
    for i in 1:length(st)
        s = stations(st[i])
        append!(gainstat, s)
        append!(times, fill(st[i].time, length(s)))
    end
    return times, gainstat
end


# Construct a gain design matrices for each baseline station in a scan table
function gain_design(st::ScanTable)

    # Construct the indices that will tag where gains are
    rowInd1 = Int[]
    colInd1 = Int[]
    rowInd2 = Int[]
    colInd2 = Int[]
    times = st.obs[:T]
    bl = st.obs[:baseline]
    gaintime, gainstat = gain_stations(st)
    gts = collect(zip(gaintime, gainstat))
    for i in 1:length(times)
        t = times[i]
        s1, s2 = bl[i]
        # now get the columns that corresponds to the gain
        c1 = findall(x->((x[1]==t)&&(x[2]==s1)), gts)
        c2 = findall(x->((x[1]==t)&&(x[2]==s2)), gts)
        append!(colInd1, c1)
        append!(rowInd1, fill(i, length(c1)))
        append!(colInd2, c2)
        append!(rowInd2, fill(i, length(c2)))
    end
    z = fill(1.0, length(rowInd1))
    m1 = sparse(rowInd1, colInd1, z, length(times), length(gaintime))
    m2 = sparse(rowInd2, colInd2, z, length(times), length(gaintime))
    return DesignMatrix(m1, gaintime, gainstat), DesignMatrix(m2, gaintime, gainstat)
end
