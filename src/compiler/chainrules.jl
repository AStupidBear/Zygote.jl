const chainrules_fallback = which(rrule, Tuple{Any})

"""
  has_chain_rrule(T)

For a type-tuple `T` e.g. `Tuple{typeof(f), Int, Float64}`, checks if there is a `rrule` defined for it.
Excluding the generic fallback.
The first return value is a Bool is whether or not the `rrule` exists.
If it does not, then the second argument is a list of edges to attach to the CodeInfo for a generated function,
such that if a suitable rule is defined later, the generated function will recompile.
"""
function has_chain_rrule(T)
  m = meta(Tuple{typeof(rrule),T.parameters...})
  if m.method !== chainrules_fallback
    # found a rrule, no need to add any edges
    return true, nothing
  end

  # Could be a kwarg function, handle that case
  ft_parts = T.parameters
  if is_kwfunc(T.parameters...)
    # Need to check for rrule for function not the kwfunction.
    base_T = Tuple{T.parameters[3:end]...}
    return has_chain_rrule(base_T)
  end

  # did not find anything, will have to attach edges so it recompiles if one is added
  @assert m.code.edges !== nothing
  return false, m.code.edges
end

"""
    is_kwfunc(sigt...)

Determines if `sigt` is the type signature of a kwfunction.
each element of `sigt` should be a type.
Either the first 3 types are a kwfunc type, a NamedTuple and the matching base function type,
or the first argument is the base function type and it is not a kwfunction.
the remaining types in `sigt` are the types of the argument.

"""
is_kwfunc(k, ::Type{<:NamedTuple}, f, args...) = k==Core.kwftype(f)
is_kwfunc(::Vararg{Any}) = false


"""
    wrap_chainrules_output(x)

Convert `x` from the differentials types ChainRules uses  to the format Zygote uses internally
(including conjugating complex gradients).
"""
wrap_chainrules_output(x) = conj(unthunk(x))  # For now we are just not going to deal with thunks
wrap_chainrules_output(x::Tuple) = map(wrap_chainrules_output, x)
wrap_chainrules_output(x::ChainRules.AbstractZero) = nothing
function wrap_chainrules_output(x::ChainRules.Composite{P, T}) where {P, T}
  T_outer = T <: NamedTuple  ? NamedTuple : Tuple  # must be a Tuple or NamedTuple, don't care about exact parameter types
  xp = map(wrap_chainrules_output, x)
  convert(T_outer, xp)
end


"""
    wrap_chainrules_input(x)

Convert `x` from the format  Zygote uses internally (including conjugated complex gradients)
to differentials types ChainRules uses.
"""
wrap_chainrules_input(x) = conj(x)
wrap_chainrules_input(::Nothing) = ChainRules.Zero()
function wrap_chainrules_input(xs::Union{Tuple, NamedTuple})
  xp = map(wrap_chainrules_input, xs)
  ChainRules.Composite{Any, typeof(xp)}(xp)
end

"""
    wrap_chainrules_pullback(f, args...)

Wrap a chainrule's pullback `f`, converting the format of the inputs (`args`),
and the outputs.
"""
function wrap_chainrules_pullback(pb, args...)
  return wrap_chainrules_output(pb(wrap_chainrules_input(args)...))
end


"""
    chain_rrule(f, args...)

Returns a the (primal) value of `f(args...)` and a pullback, by invoking `ChainRulesCore.rrule(f, args...)`.
The pullback is appropriately wrapped up to follow Zygote conventions.
"""
function chain_rrule(f, args...)
  local back

  # Dispatch here handles chainrules considing pullbacks to have multiple input if Tuple.
  # TODO: this could be removed if: https://github.com/JuliaDiff/ChainRulesCore.jl/issues/152
  zpullback(dy) = wrap_chainrules_pullback(back, dy)
  zpullback(dy::Tuple) = wrap_chainrules_pullback(back, dy...)

  # `nothing->nothing` can be deleted after https://github.com/FluxML/Zygote.jl/issues/603
  # though it might be worth keeping as a performance optimization (benchmarking pending)
  zpullback(::Nothing) = nothing

  if is_kwfunc(typeof(f), typeof.(args)...)
    kwargs = args[1]
    base_f = args[2]
    pos_args = args[3:end]
    y, back = rrule(base_f, pos_args...; kwargs...)

    kw_zpullback(dy) = (nothing, nothing, zpullback(dy)...)  # first two nothings are for kwfunc and kwargs
    return y, kw_zpullback
  else
    y, back = rrule(f, args...)
    return y, zpullback
  end
end

# Required for nested AD
@adjoint ChainRules.Composite{Any, T}(x::T) where T = ChainRules.Composite{Any, T}(x), x->(x,)
