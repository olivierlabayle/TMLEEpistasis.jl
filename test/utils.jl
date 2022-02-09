module TestUtils

using Test
using TMLEEpistasis
using MLJBase
using TOML
using BGEN
using DataFrames
using Serialization
using TMLE
using MLJLinearModels

include("helper_fns.jl")

@testset "Test parse_queries" begin
    build_query_file()
    queries = TMLEEpistasis.parse_queries(queryfile)
    expected_queries = [
        Query(case=(RSID_10="AG", RSID_100="AG"), control=(RSID_10="GG", RSID_100="GG"), name="QUERY_1"),
        Query(case=(RSID_10="AG", RSID_100="AA"), control=(RSID_10="GG", RSID_100="GG"), name="QUERY_2")
    ]
    test_queries(queries, expected_queries)

    rm(queryfile)
end

@testset "Test phenotypes parsing" begin
    allnames = TMLEEpistasis.phenotypes_from_data(phenotypefile)
    @test allnames == [:categorical_phenotype, :continuous_phenotype]

    # Fallback when no list is specified
    @test allnames == TMLEEpistasis.phenotypesnames(phenotypefile, nothing)
    @test [:continuous_phenotype] == TMLEEpistasis.phenotypesnames(phenotypefile, phenotypelist_file_1)
    @test allnames == TMLEEpistasis.phenotypesnames(phenotypefile, phenotypelist_file_2)

end

@testset "Test set_cv_folds!" begin
    tmle_config = joinpath("config", "tmle_config.toml")
    build_query_file()
    queries = TMLEEpistasis.parse_queries(queryfile)
    tmles =  TMLEEpistasis.estimators_from_toml(TOML.parsefile(tmle_config), queries)

    # Continuous y
    tmle = tmles["continuous"]
    @test tmle.Q̅.resampling.nfolds == 2

    ## adaptive_cv = false
    y = rand(100)
    TMLEEpistasis.set_cv_folds!(tmle, y, learner=:Q̅, adaptive_cv=false, verbosity=0)
    @test tmle.Q̅.resampling.nfolds == 2
    ## neff = n = 100 => 20 folds
    TMLEEpistasis.set_cv_folds!(tmle, y, learner=:Q̅, adaptive_cv=true, verbosity=0)
    @test tmle.Q̅.resampling.nfolds == 20
    ## neff = n = 20_000 => 3 folds
    y = rand(20_000)
    TMLEEpistasis.set_cv_folds!(tmle, y, learner=:Q̅, adaptive_cv=true, verbosity=0)
    @test tmle.Q̅.resampling.nfolds == 3


    # Categorical y
    tmle = tmles["binary"]
    @test tmle.Q̅.resampling.nfolds == 2
    y = categorical(["a", "a", "a", "b", "b", "c", "c"])
    @test TMLEEpistasis.countuniques(y) == [3, 2, 2]
    ## neff < 30 => nfolds = 5*neff = 7
    TMLEEpistasis.set_cv_folds!(tmle, y, learner=:Q̅, adaptive_cv=true, verbosity=0)
    @test tmle.Q̅.resampling.nfolds == 7
    ## neff = 2500 => 10
    y = categorical(vcat(repeat([true], 50_000), repeat([false], 500)))
    @test TMLEEpistasis.countuniques(y) == [50_000, 500]
    TMLEEpistasis.set_cv_folds!(tmle, y, learner=:Q̅, adaptive_cv=true, verbosity=0)
    @test tmle.Q̅.resampling.nfolds == 10

    # For G learner
    tmle.G.model.resampling.nfolds == 2
    T = DataFrame(
        t₁=["AC", "AC", "AG", "GG", "GG"],
        t₂=["CC", "CG", "CG", "GG", "GG"]
        )

    @test TMLEEpistasis.countuniques(T) == [1, 1, 1, 2]
    TMLEEpistasis.set_cv_folds!(tmle, T, learner=:G, adaptive_cv=true, verbosity=0)
    @test tmle.G.model.resampling.nfolds == 5
    rm(queryfile)

end


end;

true