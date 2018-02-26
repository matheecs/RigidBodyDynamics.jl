module CustomCollections

using Compat
using TypeSortedCollections

export
    ConstVector,
    NullDict,
    UnsafeVectorView,
    CacheElement,
    AbstractIndexDict,
    IndexDict,
    CacheIndexDict,
    SegmentedVector,
    DiscardVector

export
    foreach_with_extra_args,
    isdirty,
    segments,
    ranges

## TypeSortedCollections addendum
# `foreach_with_extra_args` below is a hack to avoid allocations associated with creating closures over
# heap-allocated variables. Hopefully this will not be necessary in a future version of Julia.
for num_extra_args = 1 : 5
    extra_arg_syms = [Symbol("arg", i) for i = 1 : num_extra_args]
    @eval begin
        @generated function foreach_with_extra_args(f, $(extra_arg_syms...), A1::TypeSortedCollection{<:Any, N}, As::Union{<:TypeSortedCollection{<:Any, N}, AbstractVector}...) where {N}
            extra_args = $extra_arg_syms
            expr = Expr(:block)
            push!(expr.args, :(Base.@_inline_meta)) # required to achieve zero allocation
            push!(expr.args, :(leading_tsc = A1))
            push!(expr.args, :(@boundscheck TypeSortedCollections.lengths_match(A1, As...) || TypeSortedCollections.lengths_match_fail()))
            for i = 1 : N
                vali = Val(i)
                push!(expr.args, quote
                    let inds = leading_tsc.indices[$i]
                        @boundscheck TypeSortedCollections.indices_match($vali, inds, A1, As...) || TypeSortedCollections.indices_match_fail()
                        @inbounds for j in linearindices(inds)
                            vecindex = inds[j]
                            f($(extra_args...), TypeSortedCollections._getindex_all($vali, j, vecindex, A1, As...)...)
                        end
                    end
                end)
            end
            quote
                $expr
                nothing
            end
        end
    end
end


## ConstVector
"""
An immutable `AbstractVector` for which all elements are the same, represented
compactly and as an isbits type if the element type is `isbits`.
"""
struct ConstVector{T} <: AbstractVector{T}
    val::T
    length::Int64
end
Base.size(A::ConstVector) = (A.length, )
@inline Base.getindex(A::ConstVector, i::Int) = (@boundscheck checkbounds(A, i); A.val)
Base.IndexStyle(::Type{<:ConstVector}) = IndexLinear()


## NullDict
"""
An immutable associative type that signifies an empty dictionary and does not
allocate any memory.
"""
struct NullDict{K, V} <: Associative{K, V}
end
Base.haskey(::NullDict, k) = false
Base.length(::NullDict) = 0
Base.start(::NullDict) = nothing
Base.done(::NullDict, state) = true


## CacheElement
mutable struct CacheElement{T}
    data::T
    dirty::Bool
    CacheElement(data::T) where {T} = new{T}(data, true)
end

@inline setdirty!(element::CacheElement) = (element.dirty = true; nothing)
@inline isdirty(element::CacheElement) = element.dirty


## IndexDicts
abstract type AbstractIndexDict{K, V} <: Associative{K, V} end

makekeys(::Type{UnitRange{K}}, start::K, stop::K) where {K} = start : stop
function makekeys(::Type{Base.OneTo{K}}, start::K, stop::K) where {K}
    @boundscheck start === K(1) || error()
    Base.OneTo(stop)
end

struct IndexDict{K, KeyRange<:AbstractUnitRange{K}, V} <: AbstractIndexDict{K, V}
    keys::KeyRange
    values::Vector{V}
    IndexDict(keys::KeyRange, values::Vector{V}) where {K, V, KeyRange<:AbstractUnitRange{K}} = new{K, KeyRange, V}(keys, values)
end

mutable struct CacheIndexDict{K, KeyRange<:AbstractUnitRange{K}, V} <: AbstractIndexDict{K, V}
    keys::KeyRange
    values::Vector{V}
    dirty::Bool
    function CacheIndexDict(keys::KeyRange, values::Vector{V}) where {K, V, KeyRange<:AbstractUnitRange{K}}
        @boundscheck length(keys) == length(values) || error("Mismatch between keys and values.")
        new{K, KeyRange, V}(keys, values, true)
    end
end

setdirty!(d::CacheIndexDict) = (d.dirty = true)
isdirty(d::CacheIndexDict) = d.dirty

# Constructors
for IDict in (:IndexDict, :CacheIndexDict)
    @eval begin
        function (::Type{$IDict{K, KeyRange, V}})(keys::KeyRange) where {K, KeyRange<:AbstractUnitRange{K}, V}
            $IDict(keys, Vector{V}(uninitialized, length(keys)))
        end

        function (::Type{$IDict{K, KeyRange, V}})(keys::KeyRange, values::Vector{V}) where {K, KeyRange<:AbstractUnitRange{K}, V}
            $IDict(keys, values)
        end

        function (::Type{$IDict{K, KeyRange, V}})(kv::Vector{Pair{K, V}}) where {K, KeyRange<:AbstractUnitRange{K}, V}
            if !issorted(kv, by = first)
                sort!(kv; by = first)
            end
            start, stop = if isempty(kv)
                K(1), K(0)
            else
                first(first(kv)), first(last(kv))
            end
            keys = makekeys(KeyRange, start, stop)
            for i in eachindex(kv)
                keys[i] === first(kv[i]) || error()
            end
            values = map(last, kv)
            $IDict(keys, values)
        end

        function (::Type{$IDict{K, KeyRange}})(kv::Vector{Pair{K, V}}) where {K, KeyRange<:AbstractUnitRange{K}, V}
            $IDict{K, KeyRange, V}(kv)
        end

        function (::Type{$IDict{K, KeyRange, V}})(itr) where {K, KeyRange<:AbstractUnitRange{K}, V}
            kv = map(x -> K(first(x)) => last(x)::V, itr)
            $IDict{K, KeyRange, V}(kv)
        end

        function (::Type{$IDict{K, KeyRange}})(itr) where {K, KeyRange<:AbstractUnitRange{K}}
            kv = map(x -> K(first(x)) => last(x), itr)
            $IDict{K, KeyRange}(kv)
        end
    end
end

@inline Base.isempty(d::AbstractIndexDict) = isempty(d.values)
@inline Base.length(d::AbstractIndexDict) = length(d.values)
@inline Base.start(d::AbstractIndexDict) = 1
@inline Base.next(d::AbstractIndexDict{K}, i) where {K} = (K(i) => d.values[i], i + 1)
@inline Base.done(d::AbstractIndexDict, i) = i == length(d) + 1
@inline Base.keys(d::AbstractIndexDict{K}) where {K} = d.keys
@inline Base.values(d::AbstractIndexDict) = d.values
@inline Base.haskey(d::AbstractIndexDict, key) = key ∈ d.keys
@inline keyindex(key::K, keyrange::Base.OneTo{K}) where {K} = Int(key)
@inline keyindex(key::K, keyrange::UnitRange{K}) where {K} = Int(key - first(keyrange) + 1)
Base.@propagate_inbounds Base.getindex(d::AbstractIndexDict{K}, key::K) where {K} = d.values[keyindex(key, d.keys)]
Base.@propagate_inbounds Base.setindex!(d::AbstractIndexDict{K}, value, key::K) where {K} = d.values[keyindex(key, d.keys)] = value


## SegmentedVector
const VectorSegment{T} = SubArray{T,1,Array{T, 1},Tuple{UnitRange{Int64}},true} # type of a n:m view into a Vector

struct SegmentedVector{K, T, KeyRange<:AbstractRange{K}, P<:AbstractVector{T}} <: AbstractVector{T}
    parent::P
    segments::IndexDict{K, KeyRange, VectorSegment{T}}

    function SegmentedVector(p::P, segments::IndexDict{K, KeyRange, VectorSegment{T}}) where {T, K, KeyRange, P}
        @boundscheck begin
            firstsegment = true
            start = 0
            l = 0
            for segment in values(segments)
                parent(segment) === parent(p) || error()
                indices = first(parentindexes(segment))
                if firstsegment
                    start = first(indices)
                else
                    first(indices) === start || error()
                end
                start = last(indices) + 1
                l += length(indices)
            end
            l == length(p) || error("Segments do not cover input data.")
        end
        new{K, T, KeyRange, P}(p, segments)
    end
end

function (::Type{SegmentedVector{K, T, KeyRange}})(parent::AbstractVector{T}, keys, viewlengthfun) where {K, T, KeyRange<:AbstractRange{K}}
    views = Vector{Pair{K, VectorSegment{T}}}()
    start = 1
    for key in keys
        stop = start[] + viewlengthfun(key) - 1
        push!(views, K(key) => view(parent, start : stop))
        start = stop + 1
    end
    SegmentedVector(parent, IndexDict{K, KeyRange, VectorSegment{T}}(views))
end

function (::Type{SegmentedVector{K}})(parent::AbstractVector{T}, keys, viewlengthfun) where {K, T}
    SegmentedVector{K, T, Base.OneTo{K}}(parent, keys, viewlengthfun)
end

Base.size(v::SegmentedVector) = size(v.parent)
Base.@propagate_inbounds Base.getindex(v::SegmentedVector, i::Int) = v.parent[i]
Base.@propagate_inbounds Base.setindex!(v::SegmentedVector, value, i::Int) = v.parent[i] = value

Base.parent(v::SegmentedVector) = v.parent
segments(v::SegmentedVector) = v.segments
ranges(v::SegmentedVector) = IndexDict(v.segments.keys, [first(parentindexes(view)) for view in v.segments.values])

function Base.similar(v::SegmentedVector{K, T, KeyRange}, ::Type{S} = T) where {K, T, KeyRange, S}
    p = similar(parent(v), S)
    segs = IndexDict{K, KeyRange, VectorSegment{S}}(keys(segments(v)),
        [view(p, first(parentindexes(segment))) for segment in values(segments(v))])
    SegmentedVector(p, segs)
end

struct DiscardVector <: AbstractVector{Any}
    length::Int
end
@inline Base.setindex!(v::DiscardVector, value, i::Int) = nothing
@inline Base.size(v::DiscardVector) = (v.length,)

end # module
