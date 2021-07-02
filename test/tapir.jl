# This file is a part of Julia. License is MIT: https://julialang.org/license

module TestTapir
include("tapir_examples.jl")

using InteractiveUtils
using Test

macro test_error(expr)
    @gensym err tmp
    quote
        local $err = nothing
        $Test.@test try
            $expr
            false
        catch $tmp
            $err = $tmp
            true
        end
        $err
    end |> esc
end

@testset "fib" begin
    @test fib(1) == 1
    @test fib(2) == 1
    @test fib(3) == 2
    @test fib(4) == 3
    @test fib(5) == 5
    @test fib_noinline_wrap(1) == 1
    @test fib_noinline_wrap(2) == 1
    @test fib_noinline_wrap(3) == 2
    @test fib_noinline_wrap(4) == 3
    @test fib_noinline_wrap(5) == 5
    @test fib1() == 1
    @test fib2() == 1
    @test fib3() == 2
    @test fib10() == 55
end

@testset "return via Ref" begin
    @test ReturnViaRef.f() == (1, 1)
    @test ReturnViaRef.g() == (1, 1)
end

@testset "decayed pointers" begin
    @test begin
        a, b = DecayedPointers.f()
        (a.y.y, b.y)
    end == (0, 0)
end

@testset "sync in loop" begin
    @test (SyncInLoop.loop0(1); true)
    @test (SyncInLoop.loop0(3); true)
end

@testset "nested aggregates" begin
    x = NestedAggregates.twotwooneone()
    desired = (x, x)
    @test NestedAggregates.f() == desired
end

@testset "@spawn syntax" begin
    function setindex_in_spawn()
        ref = Ref{Any}()
        Tapir.@sync begin
            Tapir.@spawn ref[] = (1, 2)
        end
        return ref[]
    end
    @test setindex_in_spawn() == (1, 2)

    function let_in_spawn()
        a = 1
        b = 2
        ref = Ref{Any}()
        Tapir.@sync begin
            Tapir.@spawn let a = a, b = b
                ref[] = (a, b)
            end
        end
        return ref[]
    end
    @test let_in_spawn() == (1, 2)
end

@testset "`Tapir.Output`" begin
    @test @inferred(TaskOutputs.simple()) == 2
    @test @inferred(TaskOutputs.f()) == (('a', 1), 1)
    @test @inferred(TaskOutputs.set_distinct(true)) == 4
    @test @inferred(TaskOutputs.set_distinct(false)) == 6
    @test @inferred(TaskOutputs.set_distinct_optimizable(true)) == 4
    @test @inferred(TaskOutputs.set_distinct_optimizable(false)) == 6
    @test @inferred(TaskOutputs.update_distinct(true)) == 4
    @test @inferred(TaskOutputs.update_distinct(false)) == 6
    @test @inferred(TaskOutputs.local_update_after_store(3)) == sum(1:3)
    @test @inferred(TaskOutputs.conditional_output(true)) == 2
    @test @inferred(tmap(x -> x + 0.5, 1:10)) == 1.5:1:10.5

    @test_throws UndefVarError(:a) TaskOutputs.conditional_output(false)
end

@testset "Race detection" begin
    logptn = (:warn, r"Detected racy updates")
    err = @test_logs logptn @test_error Racy.simple_race()
    @test occursin("racy", sprint(showerror, err))
    err = @test_logs logptn @test_error Racy.update_distinct(true)
    @test occursin("racy", sprint(showerror, err))
    @test occursin("racy store", sprint(showerror, Tapir.RacyStoreError(0)))
    @test occursin("racy load", sprint(showerror, Tapir.RacyLoadError(0)))
end

@testset "SROA" begin
    @test SROA.demo_sroa_half() == sum(1:10)
    @test SROA.demo_sroa() == sum(1:10)
end

@testset "ad-hoc loop" begin
    @test AdHocLoop.f() == 1:10
end

@testset "nested spawns" begin
    @test NestedSpawns.f() == 11
end

@noinline always() = rand() <= 1

@testset "exceptions" begin
    function f()
        Tapir.@sync begin
            Tapir.@spawn always() && throw(KeyError(1))
            always() && throw(KeyError(2))
        end
    end
    err = @test_error f()
    @test err isa CompositeException
    @test length(err) == 2
    e1, e2 = err
    @test e1 == KeyError(2)
    @test e2 isa TaskFailedException
    @test e2.task.result === KeyError(1)

    @test_throws CompositeException([KeyError(0)]) OptimizableTasks.always_throw()
end

@testset "tak" begin
    @code_typed tak(5, 1, 5)  # expecting no error
    @test @inferred(tak(5, 1, 5)) == 1
    @test @inferred(tak(9, 1, 9)) == 1
end

@noinline consume(x) = (global SINK = x; nothing)

function unreachable_spawn()
    if false
        Tapir.@sync begin
            Tapir.@spawn nothing
        end
    end
end

@testset "unreachable spawn" begin
    @test unreachable_spawn() === nothing
end

@testset "OptimizableTasks" begin
    @testset "$label" for (label, ci) in [
        :trivial_detach => first(@code_typed OptimizableTasks.trivial_detach(0, 0)),
        :trivial_continuation =>
            first(@code_typed OptimizableTasks.trivial_continuation(0, 0)),
        :always_throw => first(@code_typed OptimizableTasks.always_throw()),
        :set_distinct =>
            first(@code_typed TaskOutputs.set_distinct_optimizable(true)),
    ]
        @test !Core.Compiler.has_tapir(ci::Core.Compiler.CodeInfo)
    end
end

@testset "NonOptimizableTasks" begin
    @testset "$label" for (label, ci) in [
        :loop_in_spawn => first(@code_typed NonOptimizableTasks.loop_in_spawn(1)),
        :loop_in_continuation =>
            first(@code_typed NonOptimizableTasks.loop_in_continuation(1)),
        :spawn_in_loop => first(@code_typed NonOptimizableTasks.spawn_in_loop()),
    ]
        @test Core.Compiler.has_tapir(ci::Core.Compiler.CodeInfo)
    end
end

end