"""
    Comrade
Composable Modeling of Radio Emission
"""
module Comrade

using AbstractMCMC
using ArgCheck: @argcheck
using DensityInterface
import Distributions as Dists
using DocStringExtensions
using ChainRulesCore
using FillArrays: Fill
using ForwardDiff
#using MappedArrays: mappedarray
using NamedTupleTools
using Printf
using Random
using RecipesBase
using Reexport
using StaticArraysCore
using StructArrays: StructVector, StructArray, append!!
import StructArrays
using Tables
using TypedTables
import ComradeBase: save

# Reexport the core libraries for Comrade
@reexport using VLBISkyModels
@reexport using ComradeBase
@reexport using PolarizedTypes

export linearpol, mbreve, evpa
using ComradeBase: AbstractDims, AbstractModel, AbstractPolarizedModel, AbstractHeader
using ComradeBase: load



export rad2μas, μas2rad, logdensity_def, logdensityof


import ComradeBase: flux, radialextent, intensitymap, intensitymap!,
                    intensitymap_analytic, intensitymap_analytic!,
                    intensitymap_numeric, intensitymap_numeric!,
                    visibilities, visibilities!,
                    _visibilities, _visibilities!,
                    visibilities_analytic, visibilities_analytic!,
                    visibilities_numeric, visibilities_numeric!,
                    visanalytic, imanalytic, ispolarized,
                    NotAnalytic, IsAnalytic, NotPolarized, IsPolarized,
                    visibility_point, intensity_point,
                    closure_phase, closure_phases,
                    logclosure_amplitude, logclosure_amplitudes,
                    visibility, amplitude,
                    amplitudes, bispectra, bispectrum
export create_cache
include("observations/observations.jl")
include("models/models.jl")
include("distributions/radiolikelihood.jl")
include("visualizations/visualizations.jl")
include("bayes/bayes.jl")
include("inference/inference.jl")
include("calibration/calibration.jl")
include("clean.jl")
include("rules.jl")

# Load extensions using requires for verions < 1.9
if !isdefined(Base, :get_extension)
    using Requires
end

@static if !isdefined(Base, :get_extension)
    function __init__()
        @require Pyehtim="3d61700d-6e5b-419a-8e22-9c066cf00468" include(joinpath(@__DIR__, "../ext/ComradePyehtimExt.jl"))
        @require Makie = "ee78f7c6-11fb-53f2-987a-cfe4a2b5a57a" include(joinpath(@__DIR__, "../ext/ComradeMakieExt.jl"))
    end
end



end
