## reductions ##

###### Functors ######

# Note that functors are merely used as internal machinery to enhance code reuse.
# They are not exported.
# When function arguments can be inlined, the use of functors can be removed.

abstract Func{N}

type IdFun <: Func{1} end
type AbsFun <: Func{1} end
type Abs2Fun <: Func{1} end
type ExpFun <: Func{1} end
type LogFun <: Func{1} end

type AddFun <: Func{2} end
type MulFun <: Func{2} end
type AndFun <: Func{2} end
type OrFun <: Func{2} end

evaluate(::IdFun, x) = x
evaluate(::AbsFun, x) = abs(x)
evaluate(::Abs2Fun, x) = abs2(x)
evaluate(::ExpFun, x) = exp(x)
evaluate(::LogFun, x) = log(x)
evaluate(f::Callable, x) = f(x)

evaluate(::AddFun, x, y) = x + y
evaluate(::MulFun, x, y) = x * y
evaluate(::AndFun, x, y) = x & y
evaluate(::OrFun, x, y) = x | y
evaluate(f::Callable, x, y) = f(x, y)

###### Generic reduction functions ######

# Note that getting type-stable results from reduction functions,
# or at least having type-stable loops, is nontrivial (#6069).

## foldl

function _foldl(op, v0, itr, i)
    if done(itr, i)
        return v0
    else
        (x, i) = next(itr, i)
        v = evaluate(op, v0, x)
        while !done(itr, i)
            (x, i) = next(itr, i)
            v = evaluate(op, v, x)
        end
        return v
    end
end

function foldl(op::Callable, v0, itr, i)
    is(op, +) && return _foldl(AddFun(), v0, itr, i)
    is(op, *) && return _foldl(MulFun(), v0, itr, i)
    is(op, &) && return _foldl(AndFun(), v0, itr, i)
    is(op, |) && return _foldl(OrFun(), v0, itr, i)
    return _foldl(op, v0, itr, i)
end

foldl(op::Callable, v0, itr) = foldl(op, v0, itr, start(itr))

function foldl(op::Callable, itr)
    i = start(itr)
    done(itr, i) && error("Argument is empty.")
    (v0, i) = next(itr, i)
    return foldl(op, v0, itr, i)
end

## foldr

function foldr(op::Callable, v0, itr, i=endof(itr))
    # use type stable procedure
    if i == 0
        return v0
    else
        v = op(itr[i], v0)
        while i > 1
            x = itr[i -= 1]
            v = op(x, v)
        end
        return v
    end
end

foldr(op::Callable, itr) = (i = endof(itr); foldr(op, itr[i], itr, i-1))

## reduce

reduce(op::Callable, v, itr) = foldl(op, v, itr)

function reduce(op::Callable, itr) # this is a left fold
    if is(op, +)
        return sum(itr)
    elseif is(op, *)
        return prod(itr)
    elseif is(op, |)
        return any(itr)
    elseif is(op, &)
        return all(itr)
    end
    return foldl(op, itr)
end

# pairwise reduction, requires n > 1 (to allow type-stable loop)
function r_pairwise(op::Callable, A::AbstractArray, i1,n)
    if n < 128
        @inbounds v = op(A[i1], A[i1+1])
        for i = i1+2:i1+n-1
            @inbounds v = op(v,A[i])
        end
        return v
    else
        n2 = div(n,2)
        return op(r_pairwise(op,A, i1,n2), r_pairwise(op,A, i1+n2,n-n2))
    end
end

function reduce(op::Callable, A::AbstractArray)
    n = length(A)
    n == 0 ? error("argument is empty") : n == 1 ? A[1] : r_pairwise(op,A, 1,n)
end

function reduce(op::Callable, v0, A::AbstractArray)
    n = length(A)
    n == 0 ? v0 : n == 1 ? op(v0, A[1]) : op(v0, r_pairwise(op,A, 1,n))
end


###### Specific reduction functions ######

## in & contains

function in(x, itr)
    for y in itr
        if y == x
            return true
        end
    end
    return false
end
const ∈ = in
∉(x, itr)=!∈(x, itr)
∋(itr, x)= ∈(x, itr)
∌(itr, x)=!∋(itr, x)

function contains(itr, x)
    depwarn("contains(collection, item) is deprecated, use in(item, collection) instead", :contains)
    in(x, itr)
end

function contains(eq::Function, itr, x)
    for y in itr
        if eq(y, x)
            return true
        end
    end
    return false
end


## countnz & count

function countnz(itr)
    n = 0
    for x in itr
        if x != 0
            n += 1
        end
    end
    return n
end

function countnz(a::AbstractArray)
    n = 0
    for i = 1:length(a)
        @inbounds x = a[i]
        if x != 0
            n += 1
        end
    end
    return n
end

function count(pred::Function, itr)
    n = 0
    for x in itr
        if pred(x)
            n += 1
        end
    end
    return n
end


## sum

# result type inference for sum

sumtype{T}(::Type{T}) = typeof(zero(T) + zero(T))
sumzero{T}(::Type{T}) = zero(T) + zero(T)
addzero(x) = x + zero(x) 

typealias SumResultNumber Union(Uint,Uint64,Uint128,Int,Int64,Int128,Float32,Float64,Complex64,Complex128)

sumtype{T<:SumResultNumber}(::Type{T}) = T
sumzero{T<:SumResultNumber}(::Type{T}) = zero(T)
addzero(x::SumResultNumber) = x

sumzero{T<:AbstractArray}(::Type{T}) = error("Summing over an empty collection of arrays is not allowed.")
addzero(a::AbstractArray) = a

# general sum over iterables

function _sum(f, itr, s)  # deal with non-empty cases
    # pre-condition: s = start(itr) && !done(itr, s)
    (v, s) = next(itr, s)
    done(itr, s) && return addzero(evaluate(f, v)) # adding zero for type stability
    # specialize for length > 1 to have type-stable loop
    (x, s) = next(itr, s)
    result = evaluate(f, v) + evaluate(f, x)
    while !done(itr, s)
        (x, s) = next(itr, s)
        result += evaluate(f, x)
    end
    return result    
end 

function sum(itr)
    s = start(itr)
    if done(itr, s)
        if applicable(eltype, itr)
            return sumzero(eltype(itr))
        else
            throw(ArgumentError("sum(itr) is undefined for empty collections; instead, do isempty(itr) ? z : sum(itr), where z is the correct type of zero for your sum"))
        end
    end
    _sum(IdFun(), itr, s)
end

function sum(f::Union(Function,Func{1}), itr)
    s = start(itr)
    done(itr, s) && error("Argument is empty.")
    _sum(f, itr, s)
end

sum(x::Number) = x
sum(A::AbstractArray{Bool}) = countnz(A)

sumabs(itr) = sum(AbsFun(), itr)
sumabs2(itr) = sum(Abs2Fun(), itr)

sumabs(x::Number) = abs(x)
sumabs2(x::Number) = abs2(x)

# Note: sum_seq uses four accumulators, so each accumulator gets at most 256 numbers
sum_pairwise_blocksize(f) = 1024

# a fast implementation of sum in sequential order (from left to right).
# to allow type-stable loops, requires length > 1
function sum_seq(f, a::AbstractArray, ifirst::Int, ilast::Int)
    
    @inbounds if ifirst + 6 >= ilast  # length(a) < 8
        i = ifirst
        s = evaluate(f, a[i]) + evaluate(f, a[i+1])
        i = i+1
        while i < ilast
            s += evaluate(f, a[i+=1])
        end
        return s

    else # length(a) >= 8

        # more effective utilization of the instruction
        # pipeline through manually unrolling the sum
        # into four-way accumulation. Benchmark shows
        # that this results in about 2x speed-up.                

        s1 = evaluate(f, a[ifirst]) + evaluate(f, a[ifirst + 4])
        s2 = evaluate(f, a[ifirst + 1]) + evaluate(f, a[ifirst + 5])
        s3 = evaluate(f, a[ifirst + 2]) + evaluate(f, a[ifirst + 6])
        s4 = evaluate(f, a[ifirst + 3]) + evaluate(f, a[ifirst + 7])

        i = ifirst + 8
        il = ilast - 3
        while i <= il
            s1 += evaluate(f, a[i])
            s2 += evaluate(f, a[i+1])
            s3 += evaluate(f, a[i+2])
            s4 += evaluate(f, a[i+3])
            i += 4
        end

        while i <= ilast
            s1 += evaluate(f, a[i])
            i += 1
        end

        return s1 + s2 + s3 + s4
    end
end

# Pairwise (cascade) summation of A[i1:i1+n-1], which has O(log n) error growth
# [vs O(n) for a simple loop] with negligible performance cost if
# the base case is large enough.  See, e.g.:
#        http://en.wikipedia.org/wiki/Pairwise_summation
#        Higham, Nicholas J. (1993), "The accuracy of floating point
#        summation", SIAM Journal on Scientific Computing 14 (4): 783–799.
# In fact, the root-mean-square error growth, assuming random roundoff
# errors, is only O(sqrt(log n)), which is nearly indistinguishable from O(1)
# in practice.  See:
#        Manfred Tasche and Hansmartin Zeuner, Handbook of
#        Analytic-Computational Methods in Applied Mathematics (2000).
#
# sum_impl requires length(a) > 1
#
function sum_impl(f, a::AbstractArray, ifirst::Int, ilast::Int)
    if ifirst + sum_pairwise_blocksize(f) >= ilast
        sum_seq(f, a, ifirst, ilast)
    else
        imid = (ifirst + ilast) >>> 1
        sum_impl(f, a, ifirst, imid) + sum_impl(f, a, imid+1, ilast)
    end
end
sum_impl{T<:Integer}(f::Union(IdFun,AbsFun,Abs2Fun), a::AbstractArray{T}, ifirst::Int, ilast::Int) = 
    sum_seq(f, a, ifirst, ilast)

function sum(f::Union(Function,Func{1}), a::AbstractArray)
    n = length(a)
    n == 0 && error("Argument is empty.")
    n == 1 && return addzero(evaluate(f, a[1]))
    sum_impl(f, a, 1, n)
end

for (fname, func, cutoff) in ((:sum, :IdFun, 16), (:sumabs, :AbsFun, 32), (:sumabs2, :Abs2Fun, 32))
    @eval function $fname{T}(a::AbstractArray{T})
        n = length(a)
        n == 0 && return addzero(evaluate($func(), zero(T)))
        n == 1 && return addzero(evaluate($func(), a[1]))
        if n < $cutoff
            # It is important that this is inlined to provide good
            # performance for small inputs
            @inbounds s = evaluate($func(), a[1]) + evaluate($func(), a[2])
            for i = 3:length(a)
                @inbounds s += evaluate($func(), a[i])
            end
            return s
        end
        sum_impl($func(), a, 1, n)
    end
end

# Kahan (compensated) summation: O(1) error growth, at the expense
# of a considerable increase in computational expense.
function sum_kbn{T<:FloatingPoint}(A::AbstractArray{T})
    n = length(A)
    if n == 0
        return sumzero(T)
    end
    s = addzero(A[1])
    c = sumzero(T)
    for i in 2:n
        @inbounds Ai = A[i]
        t = s + Ai
        if abs(s) >= abs(Ai)
            c += ((s-t) + Ai)
        else
            c += ((Ai-t) + s)
        end
        s = t
    end
    s + c
end


## prod

prodtype{T}(::Type{T}) = typeof(zero(T) * zero(T))
prodone{T}(::Type{T}) = one(T) * one(T) 
multone(x) = x * one(x)

function _prod(f, itr, s)
    (x, s) = next(itr, s)
    v = evaluate(f, x)
    done(itr, s) && return multone(v) # multiplying by one for type stability
    # specialize for length > 1 to have type-stable loop
    (x, s) = next(itr, s)
    result = v * evaluate(f, x)
    while !done(itr, s)
        (x, s) = next(itr, s)
        result *= evaluate(f, x)
    end
    return result
end

function prod(itr)
    s = start(itr)
    if done(itr, s)
        if applicable(eltype, itr)
            T = eltype(itr)
            return prodone(T)
        else
            throw(ArgumentError("prod(itr) is undefined for empty collections; instead, do isempty(itr) ? o : prod(itr), where o is the correct type of identity for your product"))
        end
    end
    _prod(IdFun(), itr, s)
end

function prod(f::Function, itr)
    s = start(itr)
    done(itr, s) && error("Argument is empty.")
    _prod(f, itr, s)
end

prod(x::Number) = x

prod(A::AbstractArray{Bool}) =
    error("use all() instead of prod() for boolean arrays")

function prod_impl{T}(f, A::AbstractArray{T}, first::Int, last::Int)
    # pre-condition: last > first
    i = first
    @inbounds v = evaluate(f, A[i])
    @inbounds result = v * evaluate(f, A[i+=1])
    while i < last
        @inbounds result *= evaluate(f, A[i+=1])
    end
    return result
end

function prod{T}(A::AbstractArray{T})
    n = length(A)
    n == 0 && return prodone(T)
    n == 1 && return multone(A[1])
    prod_impl(IdFun(), A, 1, n)
end 

function prod(f::Function, A::AbstractArray) 
    n = length(A)
    n == 0 && error("Argument is empty.")
    n == 1 && return multone(evaluate(f, A[1]))
    prod_impl(f, A, 1, n)
end


## maximum & minimum 

function maximum(f::Union(Function,Func{1}), itr)
    s = start(itr)
    if done(itr, s)
        error("argument is empty")
    end
    (x, s) = next(itr, s)
    v = evaluate(f, x)
    while !done(itr, s)
        (x, s) = next(itr, s)
        v = scalarmax(v, evaluate(f, x))
    end
    return v
end

function minimum(f::Union(Function,Func{1}), itr)
    s = start(itr)
    if done(itr, s)
        error("argument is empty")
    end
    (x, s) = next(itr, s)
    v = evaluate(f, x)
    while !done(itr, s)
        (x, s) = next(itr, s)
        v = scalarmin(v, evaluate(f, x))
    end
    return v
end

maximum(itr) = maximum(IdFun(), itr)
minimum(itr) = minimum(IdFun(), itr)

function maximum_impl(f, A::AbstractArray, first::Int, last::Int)
    # locate the first non NaN number
    v = evaluate(f, A[first])
    i = first + 1
    while v != v && i <= last
        @inbounds v = evaluate(f, A[i])
        i += 1
    end

    while i <= last
        @inbounds x = evaluate(f, A[i])
        if x > v
            v = x
        end
        i += 1
    end
    v
end

function minimum_impl(f, A::AbstractArray, first::Int, last::Int)
    # locate the first non NaN number
    v = evaluate(f, A[first])
    i = first + 1
    while v != v && i <= last
        @inbounds v = evaluate(f, A[i])
        i += 1
    end

    while i <= last
        @inbounds x = evaluate(f, A[i])
        if x < v
            v = x
        end
        i += 1
    end
    v
end

function maximum(f::Union(Function,Func{1}), A::AbstractArray)
    n = length(A)
    n == 0 && error("Argument is empty.")
    n == 1 && return evaluate(f, A[1])
    maximum_impl(f, A, 1, n)
end

function minimum(f::Union(Function,Func{1}), A::AbstractArray) 
    n = length(A)
    n == 0 && error("Argument is empty.")
    n == 1 && return evaluate(f, A[1])
    minimum_impl(f, A, 1, n)
end

maximum(A::AbstractArray) = maximum(IdFun(), A)
minimum(A::AbstractArray) = minimum(IdFun(), A)

minabs(A::AbstractArray) = minimum(AbsFun(), A)

# maxabs accepts empty array
function maxabs(A::AbstractArray)
    n = length(A)
    n == 0 && return abs(zero(T))
    n == 1 && return abs(A[1])
    maximum_impl(AbsFun(), A, 1, n)
end


maximum(x::Real) = x
minimum(x::Real) = x
maxabs(x::Number) = abs(x)
minabs(x::Number) = abs(x)


## extrema

extrema(r::Range) = (minimum(r), maximum(r))

function extrema(itr)
    s = start(itr)
    if done(itr, s)
        error("argument is empty")
    end
    (v, s) = next(itr, s)
    vmin = v
    vmax = v
    while !done(itr, s)
        (x, s) = next(itr, s)
        if x == x
            if x > vmax
                vmax = x
            elseif x < vmin
                vmin = x
            end
        end
    end
    return (vmin, vmax)
end

function extrema{T<:Real}(A::AbstractArray{T})
    if isempty(A); error("argument must not be empty"); end
    n = length(A)

    # locate the first non NaN number
    v = A[1]
    i = 2
    while v != v && i <= n
        @inbounds v = A[i]
        i += 1
    end

    vmin = v
    vmax = v
    while i <= n
        @inbounds v = A[i]
        if v > vmax
            vmax = v
        elseif v < vmin
            vmin = v
        end
        i += 1
    end

    return (vmin, vmax)
end


## all & any

function all(itr)
    for x in itr
        if !x
            return false
        end
    end
    return true
end

function any(itr)
    for x in itr
        if x
            return true
        end
    end
    return false
end

function any(pred::Union(Function,Func{1}), itr)
    for x in itr
        if pred(x)
            return true
        end
    end
    return false
end

function all(pred::Union(Function,Func{1}), itr)
    for x in itr
        if !pred(x)
            return false
        end
    end
    return true
end


###### mapreduce ######

function mapreduce(f::Callable, op::Callable, itr)
    s = start(itr)
    if done(itr, s)
        error("argument is empty")
    end
    (x, s) = next(itr, s)
    v = f(x)
    if done(itr, s)
        return v
    else # specialize for length > 1 to have a hopefully type-stable loop
        (x, s) = next(itr, s)
        result = op(v, f(x))
        while !done(itr, s)
            (x, s) = next(itr, s)
            result = op(result, f(x))
        end
        return result
    end
end

function mapreduce(f::Callable, op::Callable, v0, itr)
    v = v0
    for x in itr
        v = op(v,f(x))
    end
    return v
end

# pairwise reduction, requires n > 1 (to allow type-stable loop)
function mr_pairwise(f::Callable, op::Callable, A::AbstractArray, i1,n)
    if n < 128
        @inbounds v = op(f(A[i1]), f(A[i1+1]))
        for i = i1+2:i1+n-1
            @inbounds v = op(v,f(A[i]))
        end
        return v
    else
        n2 = div(n,2)
        return op(mr_pairwise(f,op,A, i1,n2), mr_pairwise(f,op,A, i1+n2,n-n2))
    end
end
function mapreduce(f::Callable, op::Callable, A::AbstractArray)
    n = length(A)
    n == 0 ? error("argument is empty") : n == 1 ? f(A[1]) : mr_pairwise(f,op,A, 1,n)
end
function mapreduce(f::Callable, op::Callable, v0, A::AbstractArray)
    n = length(A)
    n == 0 ? v0 : n == 1 ? op(v0, f(A[1])) : op(v0, mr_pairwise(f,op,A, 1,n))
end

