function parse_queries(queryfile::String)
    config = TOML.parsefile(queryfile)
    queries = Dict()
    for (queryname, querydict) in config
        if lowercase(queryname) ∉ ("threshold", "snps")
            rsids = collect(keys(querydict))
            vals = [split(filter(x->!isspace(x), querydict[rsid]), "->") for rsid in rsids]
            rsids_symbols = Tuple(Symbol(x) for x in rsids)
            queries[queryname] = NamedTuple{rsids_symbols}(vals)
        end
    end
    return queries
end


function read_bgen(bgen_file::String)
    kwargs = Dict{Symbol, Any}(:sample_path => nothing, :idx_path => nothing)
    if bgen_file[end-3:end] == "bgen"
        base = bgen_file[1:end-4]

        samplefile = base * "sample"
        isfile(samplefile) ? kwargs[:sample_path] = samplefile : nothing

        bgifile = bgen_file * ".bgi"
        isfile(bgifile) ? kwargs[:idx_path] = bgifile : nothing
    end
    return Bgen(bgen_file; kwargs...)
end


function samples_genotype(probabilities, variant_genotypes, threshold=0.9)
    n = size(probabilities)[2]
    # The default value is missing
    t = Vector{Union{String, Missing}}(missing, n)
    for i in 1:n
        # If no allele has been annotated with sufficient confidence
        # the sample is declared as missing for this variant
        sample_gen_index = findfirst(x -> x >= threshold, probabilities[:, i])
        sample_gen_index isa Nothing || (t[i] = variant_genotypes[sample_gen_index])
    end
    return t
end


"""

A heterozygous genotype can be specified as (ALLELE₁, ALLELE₂) or (ALLELE₂, ALLELE₁).
Here we align this heterozygous specification on the query and default to 
(ALLELE₁, ALLELE₂) provided in the BGEN file if nothing is specified in the query.
"""
function variant_genotypes(variant::Variant, queries::Dict)
    all₁, all₂ = alleles(variant)
    # Either (ALLELE₂, ALLELE₁) is provided in the query
    # and we return it as the heterozygous genotype. 
    # Or the other specification will do in all other cases.
    queried_alleles = [q[Symbol(variant.rsid)] for q in values(queries)]
    if all₂*all₁ in collect(Iterators.flatten(queried_alleles))
        return [all₁*all₁, all₂*all₁, all₂*all₂]
    end
    return [all₁*all₁, all₁*all₂, all₂*all₂]
end


function UKBBGenotypes(queryfile, queries)
    config = TOML.parsefile(queryfile)
    snps = config["SNPS"]
    threshold = config["threshold"]
    # Let's load the variants by the files they are in
    bgen_groups = Dict()
    for (rsid, path) in snps
        haskey(bgen_groups, path) ? push!(bgen_groups[path], rsid) : bgen_groups[path] = [rsid]
    end

    genotypes = nothing
    for (path, rsids) in bgen_groups
        b = GenesInteraction.read_bgen(path)
        chr_genotypes = DataFrame(SAMPLE_ID=b.samples)

        # Iterate over variants in this chromosome
        for rsid in rsids
            v = variant_by_rsid(b, rsid)
            variant_gens = variant_genotypes(v, queries)
            probabilities = probabilities!(b, v)
            chr_genotypes[!, rsid] = samples_genotype(probabilities, variant_gens, threshold)
        end
        # I think concatenating should suffice but I still join as a safety
        genotypes isa Nothing ? genotypes = chr_genotypes :
            genotypes = innerjoin(genotypes, chr_genotypes, on=:SAMPLE_ID)
    end
    return genotypes
end


function preprocess(genotypes, confounders, phenotypes;
                    verbosity=1)
    
    # Make sure data SAMPLE_ID types coincide
    genotypes.SAMPLE_ID = string.(genotypes.SAMPLE_ID)
    confounders.SAMPLE_ID = string.(confounders.SAMPLE_ID)
    phenotypes.eid = string.(phenotypes.eid)
    
    # Join all elements together
    data = innerjoin(
            innerjoin(genotypes, confounders, on=:SAMPLE_ID),
            phenotypes,
            on = :SAMPLE_ID =>:eid
            )

    # Check no data has been lost at this stage
    any(nrows(array) != nrows(data) for array in (genotypes, confounders, phenotypes)) &&
        @warn """The number of matching samples is different in data sources: \n 
            - Genotypes: $(nrows(genotypes)) \n
            - Confounders: $(nrows(confounders)) \n
            - Phenotypes: $(nrows(phenotypes)) \n
            - After Join: $(nrows(data)) \n
        """

    # Filter any line where an element is missing
    filtered_data = dropmissing(data)
    verbosity >= 1 && @info "Samples size after missing removed: $(nrows(filtered_data))"

    # Retrieve T and convert to categorical data
    T = filtered_data[!, filter(!=("SAMPLE_ID"), names(genotypes))]
    for name in names(T)
        T[!, name] = categorical(T[:, name])
    end

    # Retrieve W
    W = filtered_data[!, filter(!=("SAMPLE_ID"), names(confounders))]

    # Retrieve y which is assumed to be the first column after SAMPLE_ID
    # and convert to categorical array if needed
    y = filtered_data[!, filter(!=("eid"), names(phenotypes))][!, 1]
    
    # Only support binary and continuous traits for now
    is_binary(y) ? y = categorical(convert(Vector{Bool}, y)) : nothing

    return T, W, y
end


function TMLEEpistasisUKBB(parsed_args)
    v = parsed_args["verbosity"]
    # Read Target
    phenotype = CSV.File(parsed_args["phenotypes"], select=["eid", parsed_args["phenotype"]]) |> DataFrame

    # Parse queries
    queries = parse_queries(parsed_args["queries"])

    v >= 1 && @info "Loading Genotypes, Confounders and Phenotypes."
    # Build Genotypes
    genotypes = UKBBGenotypes(parsed_args["queries"], queries)

    # Read Confounders
    confounders = CSV.File(parsed_args["confounders"]) |> DataFrame

    v >= 1 && @info "Preprocessing."
    # Filter data based on missingness
    T, W, y = preprocess(genotypes, 
                         confounders, 
                         phenotype;
                         verbosity=v)

    # Build tmle
    tmle_config = TOML.parsefile(parsed_args["estimator"])
    tmle = tmle_from_toml(tmle_config, y)

    # Run TMLE over potential epistatic SNPS
    mach = machine(tmle, T, W, y)
    results = DataFrame(
        QUERY=String[], 
        ESTIMATE=Float64[], 
        PVALUE=Float64[],
        LOWER_BOUND=Float64[],
        UPPER_BOUND=Float64[],
        STD_ERROR=Float64[]
        )
    for (queryname, query) in queries
        v >= 1 && @info "Estimation for query: $queryname."
        # Update the query
        mach.model.fluctuation.query = query

        fit!(mach; verbosity=v-1)

        estimate = mach.fitresult.estimate
        stderror = mach.fitresult.stderror
        pval = pvalue(mach.model, estimate, stderror)
        lwb, upb = confint(mach.model, estimate, stderror)

        push!(results, (queryname, estimate, pval, lwb, upb, stderror))
    end

    CSV.write(parsed_args["output"], results)
    
    v >= 1 && @info "Done."
end