"""
    $(TYPEDEF)

A type to represent memory-mapped TIFF data. Useful for opening and operating on
images too large to store in memory.

$(FIELDS)
"""
mutable struct DiskTaggedImage{T <: Colorant, O <: Unsigned, S <: Stream, AA <: AbstractArray} <: AbstractDenseTIFF{T, 3}

    """
    Pointer to keep track of the backing file
    """
    file::TiffFile{O, S}
    """
    The associated tags for each slice in this array
    """
    ifds::Vector{IFD{O}}

    dims::NTuple{3, Int}

    """
    An internal cache to fill reading from disk
    """
    cache::AA

    """
    The index of the currently loaded slice
    """
    cache_index::Int

    microcache::Vector{T}

    """
    A flag tracking whether this file is editable
    """
    readonly::Bool
end

function DiskTaggedImage(file::TiffFile{O, S}, ifds::Vector{IFD{O}}) where {O, S}
    ifd = ifds[1]
    dims = (nrows(ifd), ncols(ifd), length(ifds))
    cache = getcache(ifd)
    microcache = Vector{eltype(cache)}(undef, 1)
    img = DiskTaggedImage{eltype(cache), O, S, typeof(cache)}(file, ifds, dims, cache, -1, microcache, true)
    @async watch(img)
    img
end

Base.size(A::DiskTaggedImage) = A.dims

function convert!(A::DiskTaggedImage; writeable=false) 
    if writeable
        A.readonly = false
        try
            close(A.file.io)
        catch
        end
        path = A.file.filepath
        A.file.io = Stream(format"TIFF", open(path, append=true, read=true), path)
    end
    return nothing
end

function watch(A::DiskTaggedImage)
    @info "Watching $(A.file.filepath) for changes"
    while true
        ev = watch_file(A.file.filepath)
        if ev.renamed
            error("Watched file $(A.file.filepath) has been moved.")
        elseif ev.changed
            A.cache_index = -1 #invalidate cache
            convert!(A; writeable=!A.readonly)
        end
    end
end

function Base.getindex(A::DiskTaggedImage, i1::Int, i2::Int, i::Int)
    # check the loaded cache is already the correct slice
    if A.cache_index == i
        return A.cache[i2, i1]
    end

    ifd = A.ifds[i]

    # if the file isn't open, lets open a handle and update it
    if !isopen(A.file.io)
        path = A.file.filepath
        A.file.io = getstream(format"TIFF", open(path), path)
    end

    read!(A.cache, A.file, ifd)

    A.cache_index = i

    return A.cache[i2, i1]
end

function Base.setindex!(A::DiskTaggedImage{T, O, S, AA}, value, i1::Int, i2::Int, i3::Int) where {T, O, S, AA}
    if A.readonly
        error("This is a read only memory-mapped file. Make sure to run convert!(img, writeable=true) first.")
    end

    linear = LinearIndices((1:size(A, 2), 1:size(A, 1)))
    linidx = O(linear[i2, i1] * sizeof(T))::O
    
    ifd = A.ifds[i3]

    bytecounts = ifd[STRIPBYTECOUNTS].data::Vector{O}

    stripidx = 1
    counts = O(0)
    for i in 1:length(bytecounts)
        stripidx = i
        counts = bytecounts[stripidx]::O
        (linidx < counts) && break
        linidx -= counts
    end

    A.cache_index = -1
    
    offsets = ifd[STRIPOFFSETS].data::Vector{O}
    offset = offsets[stripidx]::O
    seek(A.file, Int(offset+linidx))
    A.microcache[1] = value
    write(A.file.io, A.microcache)
end
