GRMIDs(file) = CSV.File(file, 
                        header=["FAMILY_ID", "SAMPLE_ID"], 
                        select=["SAMPLE_ID"],
                        types=String) |> DataFrame

function readGRM(prefix)
    ids = GRMIDs(string(prefix, ".id"))
    n = size(ids, 1)
    grm_size = n*(n + 1) ÷ 2
    GRM = mmap(string(prefix, ".bin"), Vector{Float32}, grm_size)

    return GRM, ids
end

function align_ic(ic, sample_ids, grm_ids)
    leftjoin!(
        grm_ids, 
        DataFrame(IC=ic, SAMPLE_ID=sample_ids),
        on=:SAMPLE_ID
    )
    aligned_ic = grm_ids.IC
    select!(grm_ids, Not(:IC))
    return coalesce.(aligned_ic, 0)
end

init_output() = DataFrame(
    PARAMETER_TYPE=String[], 
    TREATMENTS=String[], 
    CASE=String[], 
    CONTROL=Union{String, Missing}[], 
    TARGET=String[], 
    CONFOUNDERS=String[], 
    COVARIATES=Union{String, Missing}[], 
    INITIAL_ESTIMATE=Union{Float64, Missing}[], 
    ESTIMATE=Union{Float64, Missing}[],
    STD=Union{Float64, Missing}[],
    PVALUE=Union{Float64, Missing}[],
    LWB=Union{Float64, Missing}[],
    UPB=Union{Float64, Missing}[],
    SIEVE_STD=Union{Float64, Missing}[],
    SIEVE_PVALUE=Union{Float64, Missing}[],
    SIEVE_LWB=Union{Float64, Missing}[],
    SIEVE_UPB=Union{Float64, Missing}[]
)


covariates_string(Ψ; join_string="_&_") = 
    length(Ψ.covariates) != 0 ? join(Ψ.covariates, join_string) : missing

function param_string(param::T) where T <: TMLE.Parameter
    str = string(T)
    return startswith(str, "TMLE.") ? str[6:end] : str
end

case(nt::NamedTuple) = nt.case
case(x) = x
case_string(Ψ; join_string="_&_") = join((case(x) for x in values(Ψ.treatment)), join_string)

control_string(t::Tuple{Vararg{<:NamedTuple}}; join_string="_&_") = 
    join((val.control for val in t), join_string)

control_string(t; join_string="_&_") = missing

control_string(Ψ::TMLE.Parameter; join_string="_&_") = 
    control_string(values(Ψ.treatment); join_string=join_string)

treatment_string(Ψ; join_string="_&_") = join(keys(Ψ.treatment), join_string)
confounders_string(Ψ; join_string="_&_") = join(Ψ.confounders, join_string)

restore_slash(x) = replace(string(x), "_OR_" => "/")

function push_sieveless!(output, Ψ, Ψ̂₀, result::Missing, target)
    param_type = param_string(Ψ)
    treatments = treatment_string(Ψ)
    case = case_string(Ψ)
    control = control_string(Ψ)
    confounders = confounders_string(Ψ)
    covariates = covariates_string(Ψ)
    row = (
        param_type, treatments, case, control, restore_slash(target), confounders, covariates, 
        Ψ̂₀, missing, 
        missing, missing, missing, missing, 
        missing, missing, missing, missing
    )
    push!(output, row)
end

function push_sieveless!(output, Ψ, Ψ̂₀, result, target)
    param_type = param_string(Ψ)
    treatments = treatment_string(Ψ)
    case = case_string(Ψ)
    control = control_string(Ψ)
    confounders = confounders_string(Ψ)
    covariates = covariates_string(Ψ)
    Ψ̂ = estimate(result)
    std = √(var(result))
    testresult = OneSampleTTest(result)
    pval = pvalue(testresult)
    lw, up = confint(testresult)
    row = (
        param_type, treatments, case, control, restore_slash(target), confounders, covariates, 
        Ψ̂₀, Ψ̂, 
        std, pval, lw, up, 
        missing, missing, missing, missing
    )
    push!(output, row)
end

"""
    bit_distances(sample_grm, nτs)

Returns a matrix of shape (n_samples,nτs) where n_samples is the 
size of sample_grm.
The sample_grm comes from the gcta software. 
The process is as follows:
- Round between -1 and 1 as some elements may be beyond that limit
- Take 1 - this value to convert this quantity to a distance
- For each τ return if the distance between individuals is less or equal than τ
"""
function bit_distances(sample_grm, τs)
    distances = 1 .-  max.(min.(sample_grm, 1), -1)
    return convert(Matrix{Float32}, permutedims(distances) .<= τs)
end


default_τs(nτs;max_τ=2) = Float32[max_τ*(i-1)/(nτs-1) for i in 1:nτs]


function build_work_list(prefix, grm_ids; pval=0.05)
    dirname_, prefix_ = splitdir(prefix)
    dirname__ = dirname_ == "" ? "." : dirname_
    hdf5files = filter(
            x -> startswith(x, prefix_) && endswith(x, ".hdf5"), 
            readdir(dirname__)
    )
    hdf5files = [joinpath(dirname_, x) for x in hdf5files]

    influence_curves = Vector{Float32}[]
    n_obs = Int[]
    row_ids = []
    row_id = 1
    output = init_output()
    for hdf5file in hdf5files
        jldopen(hdf5file) do io
            templateΨs = io["parameters"]
            results = io["results"]
            for target in keys(results)
                targetresults = results[target]
                sample_ids = string.(targetresults["sample_ids"])
                for index in eachindex(targetresults["tmle_results"])
                    templateΨ = templateΨs[index]
                    Ψ̂₀ = targetresults["initial_estimates"][index]
                    tmleresult = targetresults["tmle_results"][index]
                    if (tmleresult !== missing) && (pvalue(OneSampleTTest(tmleresult)) <= pval)
                        push!(influence_curves, align_ic(tmleresult.IC, sample_ids, grm_ids))
                        push!(n_obs, size(sample_ids, 1))
                        push!(row_ids, row_id)
                    end
                    push_sieveless!(output, templateΨ, Ψ̂₀, tmleresult, target)
                    row_id += 1
                end
            end
        end
    end
    influence_curves = length(influence_curves) > 0 ? reduce(vcat, transpose(influence_curves)) : influence_curves 
    return output, influence_curves, n_obs, row_ids
end


"""
    normalize(variances, n_observations)

Divides the variance estimates by the effective number of observations 
used for each phenotype at estimation time.
"""
normalize!(variances, n_observations) = 
    variances ./= permutedims(n_observations)


"""
    aggregate_variances(influence_curves, indicator, sample)

This function computes the sum for a single index i, see also `compute_variances`.
As the GRM is symetric it is performed as : 
    2 times off-diagonal elements with j < i + diagonal term 
and this for all τs. Some diagonal elements are not equal to 1 while in theory they should be,
this is an artefact of the GRM. We thus always include diagonal elements in the aggregate 
whatever the value of the indicator.
"""
function aggregate_variances(influence_curves, indicator, sample)
    @views begin
        D_off_diag = transpose(influence_curves[:, 1:sample-1])
        D_diag = transpose(influence_curves[:, sample])
        return D_diag .* (2indicator[:, 1:sample-1] * D_off_diag .+ D_diag)
    end
end


"""
    compute_variances(influence_curves, nτs, grm_files)

An overall variance estimate for a distance function d, a threshold τ 
and influence curve D is given by:
            σ̂ = 1/n ∑ᵢ∑ⱼ1(dᵢⱼ ≤ τ)DᵢDⱼ
              = 1/n 2∑ᵢDᵢ∑ⱼ<ᵢ1(dᵢⱼ ≤ τ)DᵢDⱼ + 1(dᵢᵢ ≤ τ)DᵢDᵢ

This function computes those variance estimates at each τ for all phenotypes
and queries.

# Arguments:
- influence_curves: Array of size (n_samples, n_queries, n_phenotypes)
- grm: Vector containing the lower elements of the GRM ie: n(n+1)/2 elements
- τs: 1 row matrix containing the distance thresholds between individuals
- n_obs: Vector of size (n_phenotypes,), containing the number of effective 
observations used during estimation

# Returns:
- variances: An Array of size (nτs, n_curves) where n_curves is the number of influence curves.
"""
function compute_variances(influence_curves, grm, τs, n_obs)
    n_curves, n_samples = size(influence_curves)
    variances = zeros(Float32, length(τs), n_curves)
    start_idx = 1
    for sample in 1:n_samples
        # lower diagonal of the GRM are stored in a single vector 
        # that are accessed one row at a time
        end_idx = start_idx + sample - 1
        sample_grm = view(grm, start_idx:end_idx)
        indicator = bit_distances(sample_grm, τs)
        variances .+= aggregate_variances(influence_curves, indicator, sample)
        start_idx = end_idx + 1
    end
    normalize!(variances, n_obs)
    return variances
end


function grm_rows_bounds(n_samples)
    bounds = Pair{Int, Int}[]
    start_idx = 1
    for sample in 1:n_samples
        # lower diagonal of the GRM are stored in a single vector 
        # that are accessed one row at a time
        end_idx = start_idx + sample - 1
        push!(bounds, start_idx => end_idx)
        start_idx = end_idx + 1
    end
    return bounds
end


function save_results(outprefix, output, τs, variances)
    CSV.write(string(outprefix, ".csv"), output)
    jldopen(string(outprefix, ".hdf5"), "w") do io
        io["taus"] = τs
        io["variances"] = variances
    end
end

function save_results(outprefix, output, τs)
    CSV.write(string(outprefix, ".csv"), output)
    jldopen(string(outprefix, ".hdf5"), "w") do io
        io["taus"] = τs
    end
end

corrected_stderrors(variances, n_obs) =
    sqrt.(view(maximum(variances, dims=1), 1, :) ./ n_obs)

function update_with_sieve!(df, stds, row_ids, n_obs)
    for (index, row_id) in enumerate(row_ids)
        std = stds[index]
        row = df[row_id, :]
        testresult = OneSampleTTest(row.ESTIMATE, std, n_obs[index])
        lwb, upb = confint(testresult)
        row.SIEVE_STD = std
        row.SIEVE_PVALUE = pvalue(testresult)
        row.SIEVE_LWB = lwb
        row.SIEVE_UPB = upb
    end
end

function sieve_variance_plateau(parsed_args)
    prefix = parsed_args["prefix"]
    pval = parsed_args["pval"]
    outprefix = parsed_args["out-prefix"]
    verbosity = parsed_args["verbosity"]

    τs = default_τs(parsed_args["nb-estimators"];max_τ=parsed_args["max-tau"])
    grm, grm_ids = readGRM(parsed_args["grm-prefix"])
    verbosity > 0 && @info "Preparing work list."
    output, influence_curves, n_obs, row_ids = build_work_list(prefix, grm_ids; pval=pval)

    verbosity > 0 && @info "Computing variance estimates."
    if length(influence_curves) > 0
        variances = compute_variances(influence_curves, grm, τs, n_obs)
        std_errors = corrected_stderrors(variances, n_obs)
        update_with_sieve!(output, std_errors, row_ids, n_obs)
        save_results(outprefix, output, τs, variances)
    else
        save_results(outprefix, output, τs)
    end
    
    verbosity > 0 && @info "Done."
    return 0
end
