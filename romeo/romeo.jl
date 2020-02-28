include("dilation_and_erosion.jl")
include("priorityqueue.jl")
include("bestpathweight.jl")

function kunwrap!(wrapped::AbstractArray{T, 3}; weights = :romeo3, keyargs...) where {T <: AbstractFloat}
    nbins = 256

    weights = getweights(wrapped, nbins, weights; keyargs...)

    seed = findseed(wrapped, weights)
    if haskey(keyargs, :phase2) && haskey(keyargs, :TEs) # requires multiecho
        seedcorrection!(wrapped, seed, keyargs[:phase2], keyargs[:TEs])
    end

    growRegionUnwrap!(wrapped, weights, seed, nbins)
end

function getweights(wrapped, nbins, weights; keyargs...)
    if typeof(weights) != Symbol # weights are given as image
        return weights
    end
    if weights == :romeo3 || weights == :romeo2 # standard option
        return calculateweights(wrapped, nbins, weights; keyargs...) # this could be done instead on demand to save memory (performance comparison required, seed problem)
    elseif weights == :bestpath
        scale(w) = UInt8.(min(max(round((1 - (w / 10)) * (nbins - 1)), 1), 255)) # scaling function
        weights = scale.(getbestpathweight(wrapped))
        if haskey(keyargs, :mask) # apply mask to weights
            mask = keyargs[:mask]
            weights .*= reshape(mask, 1, size(mask)...)
        end
        return weights
    else
        error("Weights not defined: $weights")
    end
end

function seedcorrection!(wrapped, seed, phase2, TEs)
    vox = getfirstvoxfromedge(seed)
    best = Inf
    offset = 0
    for off1 in -2:2, off2 in -1:1
        diff = abs((wrapped[vox] + 2π*off1) / TEs[1] - (phase2[vox] + 2π*off2) / TEs[2])
        diff += (abs(off1) + abs(off2)) / 100 # small panelty for wraps (if TE1 == 2*TE2 wrong value is chosen otherwise)
        if diff < best
            best = diff
            offset = off1
        end
    end
    wrapped[vox] += 2π * offset
    return offset
end

# each edge gets a weight
function calculateweights(wrapped, nbins, weights; keyargs...)
    if haskey(keyargs, :mag)
        args = Dict{Symbol, Any}(keyargs)
        args[:maxmag] = maximum(args[:mag])
        if haskey(keyargs, :mask)
            args[:mag] = Float32.(args[:mag]) .* args[:mask]
        end
        keyargs = NamedTuple{Tuple(keys(args))}(values(args))
    end
    mask = if haskey(keyargs, :mask)
        keyargs[:mask]
    else
        trues(size(wrapped))
    end

    stridelist = strides(wrapped)
    weight_type = weights
    weights = zeros(UInt8, 3, size(wrapped)...)

    for dim in 1:3
        neighbor = stridelist[dim]
        for I in LinearIndices(wrapped)
            if mask[I]
                weights[dim + (I-1)*3] = getweight(wrapped, I, neighbor, nbins, dim, weight_type; keyargs...)
            end
        end
    end
    return weights
end

function Ω(x) # faster if only one wrap can occur
    if x < -π
        x+typeof(x)(2π)
    elseif x > π
        x-typeof(x)(2π)
    else
        x
    end
end

@inline function getweight(P, i, k, nbins, dim, weight_type; keyargs...) # Phase, index, neighbor-offset, nbins, dim
    j = i+k
    if !checkbounds(Bool, P, j) return 0 end

    phasecoherence = 1 - abs(Ω(P[i] - P[j]) / π)
    phasetempcoherence = 1

    if haskey(keyargs, :phase2) && weight_type == :romeo3
        P2, TEs = keyargs[:phase2], keyargs[:TEs]
        phasetempcoherence = max(0, 1 - abs(Ω(P[i] - P[j]) - Ω(P2[i] - P2[j]) * TEs[1] / TEs[2]))
    end

    weight = phasecoherence * phasetempcoherence

    if haskey(keyargs, :mag)
        M = keyargs[:mag]
        mini, maxi = minmax(M[i], M[j])
        magcoherence = (mini / maxi) ^ 2

        weight *= magcoherence
    end

    if 0 ≤ weight ≤ 1 # weight of 1 is best and 0 worst
        return max(round(Int, (1 - weight) * (nbins - 1)), 1)
    else
        return 0
    end # 1 is best, nbins is worst, 0 is not valid (not added to queue)
end

function findseed(wrapped, weights)
    cp = copy(weights)
    cp[cp .== 0] .= 255
    filtered = dilate(cp, 2:4)
    min = findmin(filtered)[2]
    return LinearIndices(weights)[min]
end

function growRegionUnwrap!(wrapped, weights, seed, nbins)
    stridelist = strides(wrapped)
    visited = falses(size(wrapped))
    pqueue = PQueue(nbins, seed)

    while !isempty(pqueue)
        edge = pop!(pqueue)
        oldvox, newvox = getvoxelsfromedge(edge, visited, stridelist)
        if !visited[newvox]
            unwrapedge!(wrapped, oldvox, newvox)
            visited[newvox] = true
            for e in getnewedges(newvox, visited, stridelist)
                if weights[e] > 0
                    push!(pqueue, e, weights[e])
                end
            end
        end
    end
    return wrapped
end

# edge calculations
getdimfromedge(edge) = (edge - 1) % 3 + 1
getfirstvoxfromedge(edge) = div(edge - 1, 3) + 1
getedgeindex(leftvoxel, dim) = dim + 3(leftvoxel-1)

function getvoxelsfromedge(edge, visited, stridelist)
    dim = getdimfromedge(edge)
    vox = getfirstvoxfromedge(edge)
    neighbor = vox + stridelist[dim] # direct neigbor in dim
    if visited[neighbor] == 0
        return vox, neighbor
    else
        return neighbor, vox
    end
end

function unwrapedge!(wrapped, oldvox, newvox)
    wrapped[newvox] = unwrapvoxel(wrapped[newvox], wrapped[oldvox])
end
unwrapvoxel(new, old) = new - 2pi * round((new - old) / 2pi)
wrap(x) = mod2pi(x+π) - π

function getnewedges(v, visited, stridelist)
    notvisited(i) = checkbounds(Bool, visited, i) && visited[i] == 0

    edges = []
    for iDim = 1:3
        n = stridelist[iDim] # neigbor-offset in dimension iDim
        if notvisited(v+n) push!(edges, getedgeindex(v, iDim)) end
        if notvisited(v-n) push!(edges, getedgeindex(v-n, iDim)) end
    end
    return edges
end

# kunwrap version that does not modify its input
kunwrap(wrapped; keyargs...) = kunwrap!(Float32.(wrapped); keyargs...)

# multi echo unwrapping
function kunwrap!(wrapped::AbstractArray{T, 4}; TEs = 1:size(wrapped, 4), keyargs...) where {T <: AbstractFloat}
    args = Dict{Symbol, Any}(keyargs)

    template = args[:template]

    p2ref = template - 1

    args[:phase2] = view(wrapped,:,:,:,p2ref)
    args[:TEs] = TEs[[template, p2ref]]


    if haskey(args, :mag)
        args[:mag] = view(args[:mag],:,:,:,template)
    end
    kunwrap!(view(wrapped,:,:,:,template); args...)
    for iEco in [(template-1):-1:1; (template+1):length(TEs)]
        iRef = if (iEco < template) iEco + 1 else iEco - 1 end
        wrapped[:,:,:,iEco] .= unwrapvoxel.(wrapped[:,:,:,iEco], wrapped[:,:,:,iRef] .* (TEs[iEco] / TEs[iRef]))
    end
    return wrapped
end

function unwrapfilter!(phase, mag)
    smoothedphase = if mag == nothing
        gaussiansmooth3d(phase, boxsizes = [3,3,3], nbox = 1)
    else
        gaussiansmooth3d(phase; weight = Float32.(mag), boxsizes = [3,3,3], nbox = 1) # corresponds to weighted meanfilter with nbox = 1# TODO try other filter
    end
    phase .= unwrapvoxel.(phase, smoothedphase)
end

kunwrap_single(wrapped; keyargs...) = kunwrap_single!(Float32.(wrapped); keyargs...)
function kunwrap_single!(wrapped::AbstractArray{T1, 4}; TEs = 1:size(wrapped, 4), keyargs...) where {T1 <: AbstractFloat}
    for ieco in 1:length(TEs)
        e2 = ieco - 1
        if e2 == 0 e2 = 2 end

        args = Dict{Symbol, Any}(keyargs)
        if haskey(keyargs, :mag) args[:mag] = view(keyargs[:mag],:,:,:,ieco) end
        kunwrap!(view(wrapped,:,:,:,ieco); phase2 = view(wrapped,:,:,:,e2), TEs = TEs[[ieco, e2]], args...)
    end
    return wrapped
end
