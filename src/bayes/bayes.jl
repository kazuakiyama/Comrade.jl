export Posterior, prior_sample, asflat, ascube, flatten, logdensityof, transform, inverse, dimension,
       skymodel, instrumentmodel, simulate_observation, dataproducts

import DensityInterface
import ParameterHandling
import ParameterHandling: flatten
using HypercubeTransform
using TransformVariables
using LogDensityProblems

abstract type AbstractPosterior end

# Satisfy the LogDensityProblems interface for easy AD!
LogDensityProblems.logdensity(d::AbstractPosterior, θ) = logdensityof(d, θ)
LogDensityProblems.dimension(d::AbstractPosterior) = dimension(d)
LogDensityProblems.capabilities(::Type{<:AbstractPosterior}) = LogDensityProblems.LogDensityOrder{0}()

"""
    Posterior(lklhd, prior)
Creates a Posterior density that follows obeys [DensityInterface](https://github.com/JuliaMath/DensityInterface.jl).
The `lklhd` object is expected to be a `VLB` object. For instance, these can be
created using [`RadioLikelihood`](@ref). `prior`

# Notes
Since this function obeys `DensityInterface` you can evaluate it with
```julia-repl
julia> ℓ = logdensityof(post)
julia> ℓ(x)
```
or using the 2-argument version directly
```julia-repl
julia> logdensityof(post, x)
```
where `post::Posterior`.

To generate random draws from the prior see the [`prior_sample`](@ref prior_sample) function.
"""
struct Posterior{L,P<:Dists.ContinuousDistribution} <: AbstractPosterior
    lklhd::L
    prior::P
end


@inline DensityInterface.DensityKind(::Posterior) = DensityInterface.IsDensity()

function DensityInterface.logdensityof(post::Posterior, x)
    pr = logdensityof(post.prior, x)
    !isfinite(pr) && return -Inf
    return logdensityof(post.lklhd, x) + pr
end

(post::Posterior)(θ) = logdensityof(post, θ)

"""
    prior_sample([rng::AbstractRandom], post::Posterior, args...)

Samples the prior distribution from the posterior. The `args...` are forwarded to the
`Base.rand` method.
"""
function prior_sample(rng, post::Posterior, args...)
    return rand(rng, post.prior, args...)
end


"""
    prior_sample([rng::AbstractRandom], post::Posterior)

Returns a single sample from the prior distribution.
"""
function prior_sample(rng, post::Posterior)
    return rand(rng, post.prior)
end

"""
    skymodel(post::Posterior, θ)

Returns the sky model or image of a posterior using the parameter values`θ`
"""
function skymodel(post::Posterior, θ)
    skymodel(post.lklhd, θ)
end

"""
    skymodel(post::Posterior, θ)

Returns the instrument model of a posterior using the parameter values`θ`
"""
function instrumentmodel(post::Posterior, θ)
    instrumentmodel(post.lklhd, θ)
end

"""
    vlbimodel(post::Posterior, θ)

Returns the instrument model and sky model as a [`VLBIModel`](@ref) of a posterior using the parameter values `θ`

"""
function vlbimodel(post::Posterior, θ)
    vlbimodel(post.lklhd, θ)
end

"""
    dataproducts(d::Posterior)

Returns the data products you are fitting as a tuple. The order of the tuple corresponds
to the order of the `dataproducts` argument in [`RadioLikelihood`](@ref).
"""
function dataproducts(d::Posterior)
    return dataproducts(d.lklhd)
end



"""
    simulate_observation([rng::Random.AbstractRNG], post::Posterior, θ)

Create a simulated observation using the posterior and its data `post` using the parameter
values `θ`. In Bayesian terminology this is a draw from the posterior predictive distribution.
"""
function simulate_observation(rng::Random.AbstractRNG, post::Posterior, θ)
    ls = map(x->likelihood(x, vlbimodel(post, θ)), post.lklhd.lklhds)
    return map(x->rand(rng, x), ls)
end
simulate_observation(post::Posterior, θ) = simulate_observation(Random.default_rng(), post, θ)





"""
    $(TYPEDEF)
A transformed version of a `Posterior` object.
This is an internal type that an end user shouldn't have to directly construct.
To construct a transformed posterior see the [`asflat`](@ref asflat), [`ascube`](@ref ascube),
and [`flatten`](@ref Comrade.flatten) docstrings.
"""
struct TransformedPosterior{P<:Posterior,T} <: AbstractPosterior
    lpost::P
    transform::T
end

(tpost::TransformedPosterior)(θ) = logdensityof(tpost, θ)


function prior_sample(rng, tpost::TransformedPosterior, args...)
    inv = Base.Fix1(HypercubeTransform.inverse, tpost)
    map(inv, prior_sample(rng, tpost.lpost, args...))
end

function prior_sample(rng, tpost::TransformedPosterior)
    inv = Base.Fix1(HypercubeTransform.inverse, tpost)
    inv(prior_sample(rng, tpost.lpost))
end

prior_sample(post::Union{TransformedPosterior, Posterior}, args...) = prior_sample(Random.default_rng(), post, args...)

@inline DensityInterface.DensityKind(::TransformedPosterior) = DensityInterface.IsDensity()



"""
    transform(posterior::TransformedPosterior, x)

Transforms the value `x` from the transformed space (e.g. unit hypercube if using [`ascube`](@ref ascube))
to parameter space which is usually encoded as a `NamedTuple`.

For the inverse transform see [`inverse`](@ref HypercubeTransform.inverse)
"""
HypercubeTransform.transform(p::TransformedPosterior, x) = transform(p.transform, x)


"""
    inverse(posterior::TransformedPosterior, x)

Transforms the value `y` from parameter space to the transformed space
(e.g. unit hypercube if using [`ascube`](@ref ascube)).

For the inverse transform see [`transform`](@ref HypercubeTransform.transform)
"""
HypercubeTransform.inverse(p::TransformedPosterior, y) = HypercubeTransform.inverse(p.transform, y)



# MeasureBase.logdensityof(tpost::Union{Posterior,TransformedPosterior}, x) = DensityInterface.logdensityof(tpost, x)


"""
    asflat(post::Posterior)

Construct a flattened version of the posterior where the parameters are transformed to live in
(-∞, ∞).

This returns a `TransformedPosterior` that obeys the `DensityInterface` and can be evaluated
in the usual manner, i.e. `logdensityof`. Note that the transformed posterior automatically
includes the terms log-jacobian terms of the transformation.

# Example
```julia-repl
julia> tpost = ascube(post)
julia> x0 = prior_sample(tpost)
julia> logdensityof(tpost, x0)
```

# Notes
This is the transform that should be used if using typical MCMC methods, i.e. `ComradeAHMC`.
For the transformation to the unit hypercube see [`ascube`](@ref ascube)

"""
function HypercubeTransform.asflat(post::Posterior)
    pr = post.prior
    tr = asflat(pr)
    return TransformedPosterior(post, tr)
end

@inline function DensityInterface.logdensityof(post::TransformedPosterior{P, T}, x::AbstractArray) where {P, T<:TransformVariables.AbstractTransform}
    p, logjac = transform_and_logjac(post.transform, x)
    lp = post.lpost
    return logdensityof(lp, p) + logjac
end

HypercubeTransform.dimension(post::TransformedPosterior) = dimension(post.transform)
HypercubeTransform.dimension(post::Posterior) = dimension(asflat(post))

"""
    ascube(post::Posterior)

Construct a flattened version of the posterior where the parameters are transformed to live in
(0, 1), i.e. the unit hypercube.

This returns a `TransformedPosterior` that obeys the `DensityInterface` and can be evaluated
in the usual manner, i.e. `logdensityof`. Note that the transformed posterior automatically
includes the terms log-jacobian terms of the transformation.

# Example
```julia-repl
julia> tpost = ascube(post)
julia> x0 = prior_sample(tpost)
julia> logdensityof(tpost, x0)
```

# Notes
This is the transform that should be used if using typical NestedSampling methods,
i.e. `ComradeNested`. For the transformation to unconstrained space see [`asflat`](@ref asflat)
"""
function HypercubeTransform.ascube(post::Posterior)
    pr = post.prior
    tr = ascube(pr)
    return TransformedPosterior(post, tr)
end

function DensityInterface.logdensityof(tpost::TransformedPosterior{P, T}, x::AbstractArray) where {P, T<:HypercubeTransform.AbstractHypercubeTransform}
    # Check that x really is in the unit hypercube. If not return -Inf
    for xx in x
        (xx > 1 || xx < 0) && return -Inf
    end
    p = transform(tpost.transform, x)
    post = tpost.lpost
    return logdensityof(post.lklhd, p)
end

struct FlatTransform{T}
    transform::T
end

HypercubeTransform.transform(t::FlatTransform, x) = t.transform(x)
HypercubeTransform.inverse(::FlatTransform, x) = first(ParameterHandling.flatten(x))
HypercubeTransform.dimension(t::FlatTransform) = t.transform.unflatten.sz[end]

"""
    flatten(post::Posterior)

Construct a flattened version of the posterior but **do not** transform to any space, i.e.
use the support specified by the prior.

This returns a `TransformedPosterior` that obeys the `DensityInterface` and can be evaluated
in the usual manner, i.e. `logdensityof`. Note that the transformed posterior automatically
includes the terms log-jacobian terms of the transformation.

# Example
```julia-repl
julia> tpost = flatten(post)
julia> x0 = prior_sample(tpost)
julia> logdensityof(tpost, x0)
```

# Notes
This is the transform that should be used if using typical MCMC methods, i.e. `ComradeAHMC`.
For the transformation to the unit hypercube see [`ascube`](@ref ascube)
"""
function ParameterHandling.flatten(post::Posterior)
    x0 = rand(post.prior)
    _, unflatten = ParameterHandling.flatten(x0)
    return TransformedPosterior(post, FlatTransform(unflatten))
end

# function DensityInterface.logdensityof(post::TransformedPosterior{P,T}, x) where {P, T<: HypercubeTransform.NamedFlatTransform}
#     return logdensity(post.lpost, transform(post.transform, x))
# end
