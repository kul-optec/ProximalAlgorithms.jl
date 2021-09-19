# An implementation of a generalized FISTA method where the smooth part of the objective function can be strongly convex. The
# scheme is based on Nesterov's accelerated gradient method [1, Eq. (4.9)] and Beck's method for the convex case [2]. Its full
# definition is given in [3, Algorithm 2.2.2.] and some analyses of this method are given in [3, 4, 5].

using Base.Iterators
using ProximalAlgorithms.IterationTools
using ProximalOperators: Zero
using LinearAlgebra
using Printf

"""
    FistaIteration(; <keyword-arguments>)

Instantiate the generalized FISTA algorithm [3] for solving strongly-convex optimization problems of the form

    minimize f(x) + h(x),

where h is proper closed convex and f is a continuously differentiable function that is μ-strongly convex and whose gradient is
Lf-Lipschitz continuous.

# Arguments
- `y0`: initial point; must be in the domain of h.
- `f=Zero()`: smooth objective term.
- `h=Zero()`: proximable objective term.
- `μ=0` : strong convexity constant of f (see above).
- `L_f` : Lipschitz constant of ∇f (see above).
- `adaptive=false` : enables the use of adaptive stepsize selection.

# References
- [1] Nesterov, Y. (2013). Gradient methods for minimizing composite functions. Mathematical Programming, 140(1), 125-161.
- [2] Beck, A., & Teboulle, M. (2009). A fast iterative shrinkage-thresholding algorithm for linear inverse problems. SIAM journal
on imaging sciences, 2(1), 183-202.
- [3] Kong, W. (2021). Accelerated Inexact First-Order Methods for Solving Nonconvex Composite Optimization Problems. arXiv
preprint arXiv:2104.09685.
- [4] Kong, W., Melo, J. G., & Monteiro, R. D. (2021). FISTA and Extensions - Review and New Insights. arXiv preprint
arXiv:2107.01267.
- [5] Florea, M. I. (2018). Constructing Accelerated Algorithms for Large-scale Optimization-Framework, Algorithms, and
Applications.
"""

@Base.kwdef struct FISTAIteration{R,C<:Union{R,Complex{R}},Tx<:AbstractArray{C},Tf,Th}
    y0::Tx
    f::Tf = Zero()
    h::Th = Zero()
    Lf::R
    μ::R = real(eltype(Lf))(0.0)
    adaptive::Bool = false # TODO: Implement adaptive FISTA.
end

Base.IteratorSize(::Type{<:FISTAIteration}) = Base.IsInfinite()

Base.@kwdef mutable struct FISTAState{R, Tx}
    λ::R                                # stepsize (mutable if iter.adaptive == true).
    yPrev::Tx                           # previous main iterate.
    y:: Tx = zero(yPrev)                # main iterate.
    xPrev::Tx = copy(yPrev)             # previous auxiliary iterate.
    x::Tx  = zero(yPrev)                # auxiliary iterate (see [3]).
    xt::Tx = zero(yPrev)                # prox center used to generate main iterate y.
    τ::R = real(eltype(yPrev))(1.0)     # helper variable (see [3]).
    a::R = real(eltype(yPrev))(0.0)     # helper variable (see [3]).
    APrev::R = real(eltype(yPrev))(1.0) # previous A (helper variable).
    A::R = real(eltype(yPrev))(0.0)     # helper variable (see [3]).
    gradf_xt::Tx = zero(yPrev)          # array containing ∇f(xt).
    gradf_y::Tx = zero(yPrev)           # array containing ∇f(y).
end

function Base.iterate(iter::FISTAIteration,
                      state::FISTAState = FISTAState(λ=1/iter.Lf, yPrev=copy(iter.y0)))
    # Set up helper variables.
    state.τ = state.λ * (1 + iter.μ * state.APrev)
    state.a = (state.τ + sqrt(state.τ ^ 2 + 4 * state.τ * state.APrev)) / 2
    state.A = state.APrev + state.a
    state.xt .= state.APrev / state.A * state.yPrev + state.a / state.A * state.xPrev
    gradient!(state.gradf_xt, iter.f, state.xt)
    λ2 = state.λ / (1 + state.λ * iter.μ)
    # FISTA acceleration steps.
    prox!(state.y, iter.h, state.xt - λ2 * state.gradf_xt, λ2)
    gradient!(state.gradf_y, iter.f, state.y)
    state.x .= state.xPrev + state.a / (1 + state.A * iter.μ) * ((state.y - state.xt) / state.λ + iter.μ * (state.y - state.xPrev))
    # Update state variables.
    state.yPrev .= state.y
    state.xPrev .= state.x
    state.APrev = state.A
    return state, state
end

## Solver.

struct FISTA{R, K}
    maxit::Int
    tol::R
    termination_type::String
    verbose::Bool
    freq::Int
    kwargs::K
end

# Different stopping conditions (sc). Returns the current residual value and whether or not a stopping condition holds.
function check_sc(state::FISTAState, iter::FISTAIteration, tol, termination_type)
    if termination_type == "AIPP"
        # AIPP-style termination [4]. The main inclusion is: r ∈ ∂_η(f + h)(y).
        r = (iter.y0 - state.x) / state.A
        η = (norm(iter.y0 - state.y) ^ 2 - norm(state.x - state.y) ^ 2) / (2 * state.A)
        res = (norm(r) ^ 2 + max(η, 0.0)) / max(norm(iter.y0 - state.y + r) ^ 2, 1e-16)
    else
        # Classic (approximate) first-order stationary point [4]. The main inclusion is: r ∈ ∇f(y) + ∂h(y).
        r = state.gradf_y - state.gradf_xt + iter.Lf * (state.xt - state.y)
        res = norm(r)
    end
    return res, (res <= tol || res ≈ tol)
end

# Functor ('function-like object') for the above type.
function (solver::FISTA)(y0; kwargs...)
    raw_iter = FISTAIteration(; y0=y0, solver.kwargs..., kwargs...)
    stop(state::FISTAState) = check_sc(state, raw_iter, solver.tol, solver.termination_type)[2]
    disp((it, state)) = @printf("%5d | %.3e\n", it, check_sc(state, raw_iter, solver.tol, solver.termination_type)[1])
    iter = take(halt(raw_iter, stop), solver.maxit)
    iter = enumerate(iter)
    if solver.verbose
        iter = tee(sample(iter, solver.freq), disp)
    end
    num_iters, state_final = loop(iter)
    return state_final.y, num_iters
end

FISTA(; maxit=1000, tol=1e-6, termination_type="", verbose=false, freq=(maxit < Inf ? Int(maxit/100) : 100), kwargs...) =
    FISTA(maxit, tol, termination_type, verbose, freq, kwargs)