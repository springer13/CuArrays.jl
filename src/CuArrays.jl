module CuArrays

using CUDAapi, CUDAdrv, CUDAnative

using GPUArrays

export CuArray, CuVector, CuMatrix, CuVecOrMat, cu
export CUBLAS, CUSPARSE, CUSOLVER, CUFFT, CURAND, CUDNN, CUTENSOR

import LinearAlgebra

using Adapt

using Libdl

using Requires


const depsfile = joinpath(dirname(dirname(@__FILE__)), "deps", "deps.jl")
if isfile(depsfile)
    include(depsfile)
else
    error("CuArrays is not properly installed. Please run Pkg.build(\"CuArrays\")")
end

const libcudnn = Sys.iswindows() ? "cudnn" : "libcudnn"
const libcutensor = Sys.iswindows() ? "cutensor" : "libcutensor"


## source code includes

include("memory.jl")
include("array.jl")
include("subarray.jl")
include("permuteddimsarray.jl")
include("utils.jl")
include("indexing.jl")
include("broadcast.jl")
include("matmul.jl")
include("mapreduce.jl")
include("accumulate.jl")
include("linalg.jl")

include("gpuarray_interface.jl")

# many libraries need to be initialized per-device (per-context, really, but we assume users
# of CuArrays and/or CUDAnative only use a single context), so keep track of the active one.
const active_context = Ref{CuContext}()

include("blas/CUBLAS.jl")
include("sparse/CUSPARSE.jl")
include("solver/CUSOLVER.jl")
include("fft/CUFFT.jl")
include("rand/CURAND.jl")
include("dnn/CUDNN.jl")
include("tensor/CUTENSOR.jl")

include("nnlib.jl")

include("deprecated.jl")


## initialization

const __initialized__ = Ref(false)
functional() = __initialized__[]

export has_cudnn, has_cutensor
has_cudnn() = !in(Libdl.dlopen_e(libcudnn), (C_NULL, nothing))
has_cutensor() = !in(Libdl.dlopen_e(libcutensor), (C_NULL, nothing))

function __init__()
    silent = parse(Bool, get(ENV, "JULIA_CUDA_SILENT", "false"))
    verbose = parse(Bool, get(ENV, "JULIA_CUDA_VERBOSE", "false"))
    precompiling = ccall(:jl_generating_output, Cint, ()) != 0

    # if any dependent GPU package failed, expect it to have logged an error and bail out
    if !CUDAdrv.functional() || !CUDAnative.functional()
        verbose && @warn "CuArrays.jl did not initialize because CUDAdrv.jl or CUDAnative.jl failed to"
        return
    end

    precompiling = ccall(:jl_generating_output, Cint, ()) != 0
    try
        check_deps()

        # library compatibility
        if has_cutensor()
            ver = CUTENSOR.version()
            if ver.major != 0 || ver.minor != 2
                error("CuArrays.jl only supports CUTENSOR 0.2")
            end
        end

        # package integrations
        @require ForwardDiff="f6369f11-7733-5829-9624-2563aa707210" include("forwarddiff.jl")

        # update the active context when we switch devices
        callback = (::CuDevice, ctx::CuContext) -> begin
            active_context[] = ctx

            # wipe the active handles
            CUBLAS._handle[] = C_NULL
            CUBLAS._xt_handle[] = C_NULL
            CUSOLVER._dense_handle[] = C_NULL
            CUSOLVER._sparse_handle[] = C_NULL
            CUSPARSE._handle[] = C_NULL
            CURAND._generator[] = nothing
            CUDNN._handle[] = C_NULL
            CUTENSOR._handle[] = C_NULL
        end
        push!(CUDAnative.device!_listeners, callback)

        # a device might be active already
        existing_ctx = CUDAdrv.CuCurrentContext()
        if existing_ctx !== nothing
            active_context[] = existing_ctx
        end

        __init_memory__()
    catch ex
        # don't actually fail to keep the package loadable
        silent = parse(Bool, get(ENV, "JULIA_CUDA_SILENT", "false"))
        if !silent && !precompiling
            verbose = parse(Bool, get(ENV, "JULIA_CUDA_VERBOSE", "false"))
            if verbose
                @error "CuArrays.jl failed to initialize" exception=(ex, catch_backtrace())
            else
                @info "CuArrays.jl failed to initialize and will be unavailable (set JULIA_CUDA_SILENT or JULIA_CUDA_VERBOSE to silence or expand this message)"
            end
        end
    end
end

end # module
