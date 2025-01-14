# # Stokes I Simultaneous Image and Instrument Modeling

# In this tutorial, we will create a preliminary reconstruction of the 2017 M87 data on April 6
# by simultaneously creating an image and model for the instrument. By instrument model, we
# mean something akin to self-calibration in traditional VLBI imaging terminology. However,
# unlike traditional self-cal, we will at each point in our parameter space effectively explore
# the possible self-cal solutions. This will allow us to constrain and marginalize over the
# instrument effects, such as time variable gains.

# To get started we load Comrade.
using Comrade


using Pkg #hide
Pkg.activate(joinpath(dirname(pathof(Comrade)), "..", "examples")) #hide
#-

using JSServe: Page # hide
Page(exportable=true, offline=true) # hide


using Pyehtim
using LinearAlgebra

# For reproducibility we use a stable random number genreator
using StableRNGs
rng = StableRNG(123)



# ## Load the Data


# To download the data visit https://doi.org/10.25739/g85n-f134
# First we will load our data:
obs = ehtim.obsdata.load_uvfits(joinpath(dirname(pathof(Comrade)), "..", "examples", "SR1_M87_2017_096_hi_hops_netcal_StokesI.uvfits"))

# Now we do some minor preprocessing:
#   - Scan average the data since the data have been preprocessed so that the gain phases
#      coherent.
#   - Add 1% systematic noise to deal with calibration issues that cause 1% non-closing errors.
obs = scan_average(obs.add_fractional_noise(0.02))

# Now we extract our complex visibilities.
dvis = extract_table(obs, ComplexVisibilities())

# ##Building the Model/Posterior

# Now, we must build our intensity/visibility model. That is, the model that takes in a
# named tuple of parameters and perhaps some metadata required to construct the model.
# For our model, we will use a raster or `ContinuousImage` for our image model.
# The model is given below:


function sky(θ, metadata)
    (;fg, c, σimg) = θ
    (;ftot, K, meanpr, grid, cache) = metadata
    ## Transform to the log-ratio pixel fluxes
    cp = meanpr .+ σimg.*c.params
    ## Transform to image space
    rast = (ftot*(1-fg))*K(to_simplex(CenteredLR(), cp))
    img = IntensityMap(rast, grid)
    m = ContinuousImage(img, cache)
    ## Add a large-scale gaussian to deal with the over-resolved mas flux
    g = modify(Gaussian(), Stretch(μas2rad(250.0), μas2rad(250.0)), Renormalize(ftot*fg))
    return m + g
end

# Unlike other imaging examples
# (e.g., [Imaging a Black Hole using only Closure Quantities](@ref)) we also need to include
# a model for the instrument, i.e., gains as well. The gains will be broken into two components
#   - Gain amplitudes which are typically known to 10-20%, except for LMT, which has amplitudes closer to 50-100%.
#   - Gain phases which are more difficult to constrain and can shift rapidly.


function instrument(θ, metadata)
    (; lgamp, gphase) = θ
    (; gcache, gcachep) = metadata
    ## Now form our instrument model
    gvis = exp.(lgamp)
    gphase = exp.(1im.*gphase)
    jgamp = jonesStokes(gvis, gcache)
    jgphase = jonesStokes(gphase, gcachep)
    return JonesModel(jgamp*jgphase)
end

# The model construction is very similar to [Imaging a Black Hole using only Closure Quantities](@ref),
# except we include a large scale gaussian since we want to model the zero baselines.
# For more information about the image model
# please read the closure-only example. Let's discuss the instrument model [`Comrade.JonesModel`](@ref).
# Thanks to the EHT pre-calibration, the gains are stable over scans. Therefore, we can
# model the gains on a scan-by-scan basis. To form the instrument model, we need our
#   1. Our (log) gain amplitudes and phases are given below by `lgamp` and `gphase`
#   2. Our function or cache that maps the gains from a list to the stations they impact `gcache.`
#   3. The set of [`Comrade.JonesPairs`](@ref) produced by [`jonesStokes`](@ref)
# These three ingredients then specify our instrument model. The instrument model can then be
# combined with our image model `cimg` to form the total `JonesModel`.




# Now, let's set up our image model. The EHT's nominal resolution is 20-25 μas. Additionally,
# the EHT is not very sensitive to a larger field of view. Typically 60-80 μas is enough to
# describe the compact flux of M87. Given this, we only need to use a small number of pixels
# to describe our image.
npix = 32
fovx = μas2rad(150.0)
fovy = μas2rad(150.0)

# Now let's form our cache's. First, we have our usual image cache which is needed to numerically
# compute the visibilities.
grid = imagepixels(fovx, fovy, npix, npix)
buffer = IntensityMap(zeros(npix, npix), grid)
cache = create_cache(NFFTAlg(dvis), buffer, BSplinePulse{3}())

# Second, we now construct our instrument model cache. This tells us how to map from the gains
# to the model visibilities. However, to construct this map, we also need to specify the observation
# segmentation over which we expect the gains to change. This is specified in the second argument
# to `jonescache`, and currently, there are two options
#   - `FixedSeg(val)`: Fixes the corruption to the value `val` for all time. This is usefule for reference stations
#   - `ScanSeg()`: which forces the corruptions to only change from scan-to-scan
#   - `TrackSeg()`: which forces the corruptions to be constant over a night's observation
# For this work, we use the scan segmentation for the gain amplitudes since that is roughly
# the timescale we expect them to vary. For the phases we use a station specific scheme where
# we set AA to be fixed to unit gain because it will function as a reference station.
gcache = jonescache(dvis, ScanSeg())
gcachep = jonescache(dvis, ScanSeg(); autoref=SEFDReference((complex(1.0))))

using VLBIImagePriors
# Now we need to specify our image prior. For this work we will use a Gaussian Markov
# Random field prior
# Since we are using a Gaussian Markov random field prior we need to first specify our `mean`
# image. This behaves somewhat similary to a entropy regularizer in that it will
# start with an initial guess for the image structure. For this tutorial we will use a
# a symmetric Gaussian with a FWHM of 60 μas
fwhmfac = 2*sqrt(2*log(2))
mpr = modify(Gaussian(), Stretch(μas2rad(50.0)./fwhmfac))
imgpr = intensitymap(mpr, grid)

# Now since we are actually modeling our image on the simplex we need to ensure that
# our mean image has unit flux
imgpr ./= flux(imgpr)
# and since our prior is not on the simplex we need to convert it to `unconstrained or real space`.
meanpr = to_real(CenteredLR(), Comrade.baseimage(imgpr))

# Now we can form our metadata we need to fully define our model.
metadata = (;ftot=1.1, K=CenterImage(imgpr), meanpr, grid, cache, gcache, gcachep)

# We will also fix the total flux to be the observed value 1.1. This is because
# total flux is degenerate with a global shift in the gain amplitudes making the problem
# degenerate. To fix this we use the observed total flux as our value.

# Moving onto our prior, we first focus on the instrument model priors.
# Each station requires its own prior on both the amplitudes and phases.
# For the amplitudes
# we assume that the gains are apriori well calibrated around unit gains (or 0 log gain amplitudes)
# which corresponds to no instrument corruption. The gain dispersion is then set to 10% for
# all stations except LMT, representing that we expect 10% deviations from scan-to-scan. For LMT
# we let the prior expand to 100% due to the known pointing issues LMT had in 2017.
using Distributions
using DistributionsAD
distamp = station_tuple(dvis, Normal(0.0, 0.1); LM = Normal(1.0))


# For the phases, as mentioned above, we will use a segmented gain prior.
# This means that rather than the parameters
# being directly the gains, we fit the first gain for each site, and then
# the other parameters are the segmented gains compared to the previous time. To model this
# we break the gain phase prior into two parts. The first is the prior
# for the first observing timestamp of each site, `distphase0`, and the second is the
# prior for segmented gain ϵₜ from time i to i+1, given by `distphase`. For the EHT, we are
# dealing with pre-2*rand(rng, ndim) .- 1.5calibrated data, so often, the gain phase jumps from scan to scan are
# minor. As such, we can put a more informative prior on `distphase`.
# !!! warning
#     We use AA (ALMA) as a reference station so we do not have to specify a gain prior for it.
#-
distphase = station_tuple(dvis, DiagonalVonMises(0.0, inv(π^2)))



# In addition we want a reasonable guess for what the resolution of our image should be.
# For radio astronomy this is given by roughly the longest baseline in the image. To put this
# into pixel space we then divide by the pixel size.
beam = beamsize(dvis)
rat = (beam/(step(grid.X)))

# To make the Gaussian Markov random field efficient we first precompute a bunch of quantities
# that allow us to scale things linearly with the number of image pixels. This drastically improves
# the usual N^3 scaling you get from usual Gaussian Processes.
crcache = MarkovRandomFieldCache(meanpr)

# One of the benefits of the Bayesian approach is that we can fit for the hyperparameters
# of our prior/regularizers unlike traditional RML appraoches. To construct this heirarchical
# prior we will first make a map that takes in our regularizer hyperparameters and returns
# the image prior given those hyperparameters.
fmap = let crcache=crcache
    x->GaussMarkovRandomField(x, 1.0, crcache)
end

# Now we can finally form our image prior. For this we use a heirarchical prior where the
# inverse correlation length is given by a Half-Normal distribution whose peak is at zero and
# standard deviation is `0.1/rat` where recall `rat` is the beam size per pixel.
# For the variance of the random field we use another
# half normal prior with standard deviation 0.1. The reason we use the half-normal priors is
# to prefer "simple" structures. Gaussian Markov random fields are extremly flexible models,
# and to prevent overfitting it is common to use priors that penalize complexity. Therefore, we
# want to use priors that enforce similarity to our mean image. If the data wants more complexity
# then it will drive us away from the prior.
cprior = HierarchicalPrior(fmap, InverseGamma(1.0, -log(0.01*rat)))


# We can now form our model parameter priors. Like our other imaging examples, we use a
# Dirichlet prior for our image pixels. For the log gain amplitudes, we use the `CalPrior`
# which automatically constructs the prior for the given jones cache `gcache`.
prior = NamedDist(
         c = cprior,
         fg = Uniform(0.0, 1.0),
         σimg = truncated(Normal(0.0, 0.1); lower = 0.0),
         lgamp = CalPrior(distamp, gcache),
         gphase = CalPrior(distphase, gcachep),
        )


# Putting it all together we form our likelihood and posterior objects for optimization and
# sampling.
lklhd = RadioLikelihood(sky, instrument, dvis; skymeta=metadata, instrumentmeta=metadata)
post = Posterior(lklhd, prior)

# ## Reconstructing the Image and Instrument Effects

# To sample from this posterior, it is convenient to move from our constrained parameter space
# to an unconstrained one (i.e., the support of the transformed posterior is (-∞, ∞)). This is
# done using the `asflat` function.
tpost = asflat(post)
ndim = dimension(tpost)

# Our `Posterior` and `TransformedPosterior` objects satisfy the `LogDensityProblems` interface.
# This allows us to easily switch between different AD backends and many of Julia's statistical
# inference packages use this interface as well.
using LogDensityProblemsAD
using Zygote
gtpost = ADgradient(Val(:Zygote), tpost)
x0 = randn(rng, ndim)
LogDensityProblemsAD.logdensity_and_gradient(gtpost, x0)

# We can now also find the dimension of our posterior or the number of parameters we are going to sample.
# !!! warning
#     This can often be different from what you would expect. This is especially true when using
#     angular variables where we often artificially increase the dimension
#     of the parameter space to make sampling easier.
#-

# To initialize our sampler we will use optimize using LBFGS
using ComradeOptimization
using OptimizationOptimJL
f = OptimizationFunction(tpost, Optimization.AutoZygote())
prob = Optimization.OptimizationProblem(f, prior_sample(rng, tpost), nothing)
ℓ = logdensityof(tpost)
sol = solve(prob, LBFGS(), maxiters=4_000, g_tol=1e-1);

# Now transform back to parameter space
xopt = transform(tpost, sol.u)

# !!! warning
#     Fitting gains tends to be very difficult, meaning that optimization can take a lot longer.
#     The upside is that we usually get nicer images.
#-
# First we will evaluate our fit by plotting the residuals
using Plots
residual(vlbimodel(post, xopt), dvis)

# These look reasonable, although there may be some minor overfitting. This could be
# improved in a few ways, but that is beyond the goal of this quick tutorial.
# Plotting the image, we see that we have a much cleaner version of the closure-only image from
# [Imaging a Black Hole using only Closure Quantities](@ref).
import WGLMakie as CM
img = intensitymap(skymodel(post, xopt), fovx, fovy, 128, 128)
CM.image(img, axis=(xreversed=true, aspect=1, title="MAP Image"), colormap=:afmhot)


# Because we also fit the instrument model, we can inspect their parameters.
# To do this, `Comrade` provides a `caltable` function that converts the flattened gain parameters
# to a tabular format based on the time and its segmentation.
gt = Comrade.caltable(gcachep, xopt.gphase)
plot(gt, layout=(3,3), size=(600,500))

# The gain phases are pretty random, although much of this is due to us picking a random
# reference station for each scan.

# Moving onto the gain amplitudes, we see that most of the gain variation is within 10% as expected
# except LMT, which has massive variations.
gt = Comrade.caltable(gcache, exp.(xopt.lgamp))
plot(gt, layout=(3,3), size=(600,500))


# To sample from the posterior, we will use HMC, specifically the NUTS algorithm. For
# information about NUTS,
# see Michael Betancourt's [notes](https://arxiv.org/abs/1701.02434).
# !!! note
#     For our `metric,` we use a diagonal matrix due to easier tuning
#-
# However, due to the need to sample a large number of gain parameters, constructing the posterior
# is rather time-consuming. Therefore, for this tutorial, we will only do a quick preliminary
# run, and any posterior
# inferences should be appropriately skeptical.
#-
using ComradeAHMC
metric = DiagEuclideanMetric(ndim)
chain, stats = sample(rng, post, AHMC(;metric, autodiff=Val(:Zygote)), 700; nadapts=500, init_params=xopt)
#-
# !!! note
#     The above sampler will store the samples in memory, i.e. RAM. For large models this
#     can lead to out-of-memory issues. To fix that you can include the keyword argument
#     `saveto = DiskStore()` which periodically saves the samples to disk limiting memory
#     useage. You can load the chain using `load_table(diskout)` where `diskout` is
#     the object returned from sample. For more information please see [ComradeAHMC](@ref).
#-

# Now we prune the adaptation phase
chain = chain[501:end]

#-
# !!! warning
#     This should be run for likely an order of magnitude more steps to properly estimate expectations of the posterior
#-


# Now that we have our posterior, we can put error bars on all of our plots above.
# Let's start by finding the mean and standard deviation of the gain phases
gphase  = hcat(chain.gphase...)
mgphase = mean(gphase, dims=2)
sgphase = std(gphase, dims=2)

# and now the gain amplitudes
gamp  = exp.(hcat(chain.lgamp...))
mgamp = mean(gamp, dims=2)
sgamp = std(gamp, dims=2)

# Now we can use the measurements package to automatically plot everything with error bars.
# First we create a `caltable` the same way but making sure all of our variables have errors
# attached to them.
using Measurements
gmeas_am = measurement.(mgamp, sgamp)
ctable_am = caltable(gcache, vec(gmeas_am)) # caltable expects gmeas_am to be a Vector
gmeas_ph = measurement.(mgphase, sgphase)
ctable_ph = caltable(gcachep, vec(gmeas_ph))

# Now let's plot the phase curves
plot(ctable_ph, layout=(3,3), size=(600,500))
#-
# and now the amplitude curves
plot(ctable_am, layout=(3,3), size=(600,500))

# Finally let's construct some representative image reconstructions.
samples = skymodel.(Ref(post), chain[begin:2:end])
imgs = intensitymap.(samples, fovx, fovy, 128,  128)

mimg = mean(imgs)
simg = std(imgs)
fig = CM.Figure(;resolution=(400, 400))
CM.image(fig[1,1], mimg,
                   axis=(xreversed=true, aspect=1, title="Mean Image"),
                   colormap=:afmhot)
CM.image(fig[1,2], simg./(max.(mimg, 1e-5)),
                   axis=(xreversed=true, aspect=1, title="1/SNR",),
                   colormap=:afmhot)
CM.image(fig[2,1], imgs[1],
                   axis=(xreversed=true, aspect=1,title="Draw 1"),
                   colormap=:afmhot)
CM.image(fig[2,2], imgs[end],
                   axis=(xreversed=true, aspect=1,title="Draw 2"),
                   colormap=:afmhot)
fig

# Now let's check the residuals

p = plot();
for s in sample(chain, 10)
    residual!(p, vlbimodel(post, s), dvis)
end
p



# And viola, you have just finished making a preliminary image and instrument model reconstruction.
# In reality, you should run the `sample` step for many more MCMC steps to get a reliable estimate
# for the reconstructed image and instrument model parameters.
