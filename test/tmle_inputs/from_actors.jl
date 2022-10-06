module TestFromActors

using Test
using CSV
using DataFrames
using TargeneCore
using YAML

include("test_utils.jl")


#####################################################################
###############               UNIT TESTS              ###############
#####################################################################

@testset "Test combine_by_bqtl" begin
    bQTLS = DataFrame(
        ID = ["rs1", "rs2", "rs3"],
        CHR = [1, 2, 3],
        DESCRIPTION = ["VDR", "VDR", "VDR"]
    )
    trans_actors = [
        DataFrame(
            ID = ["rs4", "rs5"],
            CHR = [1, 12],
            DESCRIPTION = ["VitD-QTL", "VitD-QTL"]
    ),
        DataFrame(
            ID = ["rs6", "rs7", "rs8"],
            CHR = [12, 9, 8],
            DESCRIPTION = ["RXR-QTL", "RXR-QTL", "RXR-QTL"]
        )
    ]
    envs = DataFrame(ID=["sex"], DESCRIPTION=["Env"])
    # order 2, no environmental variable
    combinations = TargeneCore.combine_by_bqtl(bQTLS, trans_actors, nothing, 2)
    @test combinations == [Dict("T" => ["rs1", "rs4"]),
                           Dict("T" => ["rs1", "rs5"]),
                           Dict("T" => ["rs2", "rs4"]),
                           Dict("T" => ["rs2", "rs5"]),
                           Dict("T" => ["rs3", "rs4"]),
                           Dict("T" => ["rs3", "rs5"]),
                           Dict("T" => ["rs1", "rs6"]),
                           Dict("T" => ["rs1", "rs7"]),
                           Dict("T" => ["rs1", "rs8"]),
                           Dict("T" => ["rs2", "rs6"]),
                           Dict("T" => ["rs2", "rs7"]),
                           Dict("T" => ["rs2", "rs8"]),
                           Dict("T" => ["rs3", "rs6"]),
                           Dict("T" => ["rs3", "rs7"]),
                           Dict("T" => ["rs3", "rs8"])]
    # order 2, only one trans-actors dataset
    combinations = TargeneCore.combine_by_bqtl(bQTLS, [trans_actors[1]], nothing, 2)
    @test combinations == [Dict("T" => ["rs1", "rs4"]),
                           Dict("T" => ["rs1", "rs5"]),
                           Dict("T" => ["rs2", "rs4"]),
                           Dict("T" => ["rs2", "rs5"]),
                           Dict("T" => ["rs3", "rs4"]),
                           Dict("T" => ["rs3", "rs5"])]
    # order 3, no environmental variable
    combinations = TargeneCore.combine_by_bqtl(bQTLS, trans_actors, nothing, 3)
    @test combinations == [Dict("T" => ["rs1", "rs4", "rs6"]),
                           Dict("T" => ["rs1", "rs4", "rs7"]),
                           Dict("T" => ["rs1", "rs4", "rs8"]),
                           Dict("T" => ["rs1", "rs5", "rs6"]),
                           Dict("T" => ["rs1", "rs5", "rs7"]),
                           Dict("T" => ["rs1", "rs5", "rs8"]),
                           Dict("T" => ["rs2", "rs4", "rs6"]),
                           Dict("T" => ["rs2", "rs4", "rs7"]),
                           Dict("T" => ["rs2", "rs4", "rs8"]),
                           Dict("T" => ["rs2", "rs5", "rs6"]),
                           Dict("T" => ["rs2", "rs5", "rs7"]),
                           Dict("T" => ["rs2", "rs5", "rs8"]),
                           Dict("T" => ["rs3", "rs4", "rs6"]),
                           Dict("T" => ["rs3", "rs4", "rs7"]),
                           Dict("T" => ["rs3", "rs4", "rs8"]),
                           Dict("T" => ["rs3", "rs5", "rs6"]),
                           Dict("T" => ["rs3", "rs5", "rs7"]),
                           Dict("T" => ["rs3", "rs5", "rs8"])]
    
    # order 2, environmental variable
    combinations = TargeneCore.combine_by_bqtl(bQTLS, trans_actors, envs, 2)
    @test combinations == [Dict("T" => ["rs1", "rs4"]),
                           Dict("T" => ["rs1", "rs5"]),
                           Dict("T" => ["rs2", "rs4"]),
                           Dict("T" => ["rs2", "rs5"]),
                           Dict("T" => ["rs3", "rs4"]),
                           Dict("T" => ["rs3", "rs5"]),
                           Dict("T" => ["rs1", "rs6"]),
                           Dict("T" => ["rs1", "rs7"]),
                           Dict("T" => ["rs1", "rs8"]),
                           Dict("T" => ["rs2", "rs6"]),
                           Dict("T" => ["rs2", "rs7"]),
                           Dict("T" => ["rs2", "rs8"]),
                           Dict("T" => ["rs3", "rs6"]),
                           Dict("T" => ["rs3", "rs7"]),
                           Dict("T" => ["rs3", "rs8"]),
                           Dict("T" => ["rs1", "sex"]),
                           Dict("T" => ["rs2", "sex"]),
                           Dict("T" => ["rs3", "sex"])]
    # order 3, only one trans-actors dataset
    combinations = TargeneCore.combine_by_bqtl(bQTLS, [trans_actors[1]], envs, 3)
    @test combinations == [Dict("T" => ["rs1", "rs4", "sex"]),
                           Dict("T" => ["rs1", "rs5", "sex"]),
                           Dict("T" => ["rs2", "rs4", "sex"]),
                           Dict("T" => ["rs2", "rs5", "sex"]),
                           Dict("T" => ["rs3", "rs4", "sex"]),
                           Dict("T" => ["rs3", "rs5", "sex"])]
    # order 2, no trans-actors dataset
    combinations = TargeneCore.combine_by_bqtl(bQTLS, nothing, envs, 2)
    @test combinations == [Dict("T" => ["rs1", "sex"]),
                           Dict("T" => ["rs2", "sex"]),
                           Dict("T" => ["rs3", "sex"])]
end


@testset "Test treatments_from_actors" begin
    # At least two type of actors should be specified
    @test_throws ArgumentError TargeneCore.treatments_from_actors(nothing, nothing, 1)
    @test_throws ArgumentError TargeneCore.treatments_from_actors(1, nothing, nothing)
    @test_throws ArgumentError TargeneCore.treatments_from_actors(nothing, 1, nothing)

    bqtl_file = joinpath("data", "bqtls.csv")
    trans_actors_prefix = joinpath("data", "trans_actors_1.csv")
    env_file = joinpath("data", "extra_treatments.txt")
    # bqtls and trans_actors
    bqtls, transactors, envs = TargeneCore.treatments_from_actors(bqtl_file, nothing, trans_actors_prefix)
    @test bqtls isa DataFrame
    @test envs isa Nothing
    @test transactors isa Vector{DataFrame}
    @test size(transactors, 1) == 1

    # bqtls and env
    bqtls, transactors, envs = TargeneCore.treatments_from_actors(bqtl_file, env_file, nothing)
    @test bqtls isa DataFrame
    @test envs == ["TREAT_1"]
    @test transactors isa Nothing

    # trans actors and env
    bqtls, transactors, envs = TargeneCore.treatments_from_actors(nothing, env_file, trans_actors_prefix)
    @test bqtls isa Nothing
    @test envs == ["TREAT_1"]
    @test transactors isa Vector{DataFrame}
    @test size(transactors, 1) == 1
end

#####################################################################
###############           END-TO-END TESTS            ###############
#####################################################################


@testset "Test tmle_inputs from-actors: scenario 1" begin
    # Scenario:
    # - Trans-actors
    # - Extra Treatment
    # - Extra Covariates
    # - Order 2
    parsed_args = Dict(
        "from-actors" => Dict{String, Any}(
            "bqtls" => joinpath("data", "bqtls.csv"), 
            "trans-actors-prefix" => joinpath("data", "trans_actors_1.csv"),
            "extra-covariates" => joinpath("data", "extra_covariates.txt"),
            "extra-treatments" => joinpath("data", "extra_treatments.txt"),
            "extra-confounders" => nothing,
            "orders" => "2"
            ),
        "traits" => joinpath("data", "traits_1.csv"),
        "pcs" => joinpath("data", "pcs.csv"),
        "call-threshold" => 0.8,  
        "%COMMAND%" => "from-actors", 
        "bgen-prefix" => joinpath("data", "ukbb", "imputed" ,"ukbb"), 
        "out-prefix" => "final", 
        "phenotype-batch-size" => nothing,
        "positivity-constraint" => 0.
    )
    tmle_inputs(parsed_args)

    trait_data = CSV.read("final.data.csv", DataFrame)
    @test names(trait_data) == [
        "SAMPLE_ID", "BINARY_1", "BINARY_2", "CONTINUOUS_1", "CONTINUOUS_2", 
        "COV_1", "21003", "22001", "TREAT_1", "PC1", "PC2", "RSID_2", "RSID_102", 
        "RSID_17", "RSID_198", "RSID_99"]
    
    # Parameter files: 
    # Pairwise interactions between
    # 3 bqtls x (1 environmental treatment +  2 trans actors) = 9
    # with both continuous and binary phenotypes not batched = 18 expected param_files
    for i in 1:18
        param_file = YAML.load_file(string(parsed_args["out-prefix"], ".param_$i.yaml"))
        @test param_file["W"] == ["PC1", "PC2"]
        @test param_file["C"] == ["COV_1", "21003", "22001"]
        @test (param_file["Y"] == ["CONTINUOUS_1", "CONTINUOUS_2"]) || (param_file["Y"] == ["BINARY_1", "BINARY_2"])
        for param in param_file["Parameters"]
            @test param["name"] == "IATE"
        end
    end

    cleanup()
end

@testset "Test tmle_inputs from-actors: scenario 2" begin
    # Scenario:
    # - 2 sets of trans actors
    # - no extra treatment
    # - no extra covariate
    # - extra confounders
    # - orders 2 and 3
    # - no continuous phenotypes 
    # - batched
    parsed_args = Dict(
        "from-actors" => Dict{String, Any}(
            "bqtls" => joinpath("data", "bqtls.csv"), 
            "trans-actors-prefix" => joinpath("data", "trans_actors_2"),
            "extra-covariates" => nothing,
            "extra-treatments" => nothing,
            "extra-confounders" => joinpath("data", "extra_confounders.txt"),
            "orders" => "2,3"
            ),
        "traits" => joinpath("data", "traits_2.csv"),
        "pcs" => joinpath("data", "pcs.csv"),
        "call-threshold" => 0.8,  
        "%COMMAND%" => "from-actors", 
        "bgen-prefix" => joinpath("data", "ukbb", "imputed" ,"ukbb"), 
        "out-prefix" => "final", 
        "phenotype-batch-size" => 1,
        "positivity-constraint" => 0.
    )
    tmle_inputs(parsed_args)
    
    traits = CSV.read("final.data.csv", DataFrame)
    @test names(traits) == [
        "SAMPLE_ID", "BINARY_1", "BINARY_2", "COV_1", "21003", "22001", 
        "PC1", "PC2", "RSID_2", "RSID_102", "RSID_17", "RSID_198", "RSID_99"]
    
    # Parameter files: 
    # Pairwise interactions between
    # no order 3 interaction seems to be sufficiently represented in the dataset 
    # to pass the existence constraint
    # 3 bqtls x 2 trans actors = 6 pairwise
    # with batched binary phenotypes = 12 expected param_files
    for i in 1:12
        param_file = YAML.load_file(string(parsed_args["out-prefix"], ".param_$i.yaml"))
        @test param_file["W"] == ["PC1", "PC2", "COV_1", "21003", "22001"]
        @test ! haskey(param_file, "C")
        @test (param_file["Y"] == ["BINARY_1"]) || (param_file["Y"] == ["BINARY_2"])
        for param in param_file["Parameters"]
            @test param["name"] == "IATE"
        end
    end

    cleanup()

    # Adding positivity constraint, only 4 files are generated
    parsed_args["positivity-constraint"] = 0.05
    tmle_inputs(parsed_args)

    param_files = filter(x -> occursin.(r"^final.*yaml$",x), readdir())
    @test size(param_files, 1) == 4

    cleanup()
end

end

true