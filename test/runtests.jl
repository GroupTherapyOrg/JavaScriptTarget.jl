using Test
using JavaScriptTarget

include("utils.jl")

@testset "JavaScriptTarget.jl" begin
    @testset "S-001: Package loads" begin
        @test isdefined(JavaScriptTarget, :compile)
        @test isdefined(JavaScriptTarget, :compile_module)
        @test isdefined(JavaScriptTarget, :JSOutput)
    end

    @testset "S-002: Node.js harness" begin
        @test run_js("process.stdout.write('hello')") == "hello"
        @test run_js("process.stdout.write(String(2 + 3))") == "5"
    end

    @testset "S-003: compile() API" begin
        f_identity(x::Int32) = x
        result = compile(f_identity, (Int32,))
        @test result isa JSOutput
        @test !isempty(result.js)
        @test !isempty(result.dts)
        @test "f_identity" in result.exports
        @test result.runtime_bytes > 0
    end

    @testset "A-001: Identity function" begin
        f_id(x::Int32) = x
        @test compile_and_run(f_id, (Int32,), Int32(42)) == "42"
        @test compile_and_run(f_id, (Int32,), Int32(-7)) == "-7"
        @test compile_and_run(f_id, (Int32,), Int32(0)) == "0"

        # Float64 identity
        f_id_f(x::Float64) = x
        @test compile_and_run(f_id_f, (Float64,), 3.14) == "3.14"
    end

    @testset "A-002: Int32 arithmetic" begin
        f_add(a::Int32, b::Int32) = a + b
        @test compile_and_run(f_add, (Int32, Int32), Int32(3), Int32(4)) == "7"

        f_sub(a::Int32, b::Int32) = a - b
        @test compile_and_run(f_sub, (Int32, Int32), Int32(10), Int32(3)) == "7"

        f_mul(a::Int32, b::Int32) = a * b
        @test compile_and_run(f_mul, (Int32, Int32), Int32(5), Int32(6)) == "30"

        # Composite: a*a + b
        f_composite(a::Int32, b::Int32) = a * a + b
        @test compile_and_run(f_composite, (Int32, Int32), Int32(5), Int32(1)) == "26"
    end

    @testset "A-003: SSA locals (multi-statement)" begin
        f_multi(x::Int32) = x * x + Int32(1)
        @test compile_and_run(f_multi, (Int32,), Int32(5)) == "26"
        @test compile_and_run(f_multi, (Int32,), Int32(0)) == "1"

        f_chain(x::Int32) = (x + Int32(1)) * (x - Int32(1))
        @test compile_and_run(f_chain, (Int32,), Int32(5)) == "24"
    end

    @testset "A-004: Float64 arithmetic" begin
        f_fadd(a::Float64, b::Float64) = a + b
        @test compile_and_run(f_fadd, (Float64, Float64), 2.5, 3.0) == "5.5"

        f_fsub(a::Float64, b::Float64) = a - b
        @test compile_and_run(f_fsub, (Float64, Float64), 10.0, 3.5) == "6.5"

        f_fmul(a::Float64, b::Float64) = a * b
        @test compile_and_run(f_fmul, (Float64, Float64), 2.5, 3.0) == "7.5"

        f_fdiv(a::Float64, b::Float64) = a / b
        @test compile_and_run(f_fdiv, (Float64, Float64), 10.0, 4.0) == "2.5"

        # Composite: a*b + 1.0
        f_fcomp(a::Float64, b::Float64) = a * b + 1.0
        @test compile_and_run(f_fcomp, (Float64, Float64), 2.5, 3.0) == "8.5"
    end

    @testset "A-005: Intrinsics table" begin
        # Bitwise operations (use Base intrinsics directly to avoid control flow)
        f_and(a::Int32, b::Int32) = a & b
        @test compile_and_run(f_and, (Int32, Int32), Int32(0b1100), Int32(0b1010)) == "8"

        f_or(a::Int32, b::Int32) = a | b
        @test compile_and_run(f_or, (Int32, Int32), Int32(0b1100), Int32(0b1010)) == "14"

        f_xor(a::Int32, b::Int32) = xor(a, b)
        @test compile_and_run(f_xor, (Int32, Int32), Int32(0b1100), Int32(0b1010)) == "6"

        # Float math (abs_float is a direct intrinsic, no control flow)
        f_negf(x::Float64) = -x
        @test compile_and_run(f_negf, (Float64,), 3.14) == "-3.14"

        # Int↔Float conversions
        f_itof(x::Int32) = Float64(x)
        @test compile_and_run(f_itof, (Int32,), Int32(42)) == "42"

        f_ftoi(x::Float64) = unsafe_trunc(Int32, x)
        @test compile_and_run(f_ftoi, (Float64,), 3.7) == "3"
    end

    @testset "CF-001: if/else" begin
        # Ternary / conditional
        f_abs(x::Int32) = x > Int32(0) ? x : -x
        @test compile_and_run(f_abs, (Int32,), Int32(5)) == "5"
        @test compile_and_run(f_abs, (Int32,), Int32(-3)) == "3"

        # max function
        f_max(a::Int32, b::Int32) = a > b ? a : b
        @test compile_and_run(f_max, (Int32, Int32), Int32(3), Int32(7)) == "7"
        @test compile_and_run(f_max, (Int32, Int32), Int32(9), Int32(2)) == "9"
    end

    @testset "CF-002: while loops" begin
        # Sum 1 to n
        function f_sum(n::Int32)::Int32
            s = Int32(0)
            i = Int32(1)
            while i <= n
                s += i
                i += Int32(1)
            end
            return s
        end
        @test compile_and_run(f_sum, (Int32,), Int32(10)) == "55"
        @test compile_and_run(f_sum, (Int32,), Int32(0)) == "0"
        @test compile_and_run(f_sum, (Int32,), Int32(1)) == "1"

        # Factorial
        function f_fact(n::Int32)::Int32
            result = Int32(1)
            i = Int32(2)
            while i <= n
                result *= i
                i += Int32(1)
            end
            return result
        end
        @test compile_and_run(f_fact, (Int32,), Int32(5)) == "120"
        @test compile_and_run(f_fact, (Int32,), Int32(1)) == "1"
    end

    @testset "CF-003: Short-circuit && and ||" begin
        # Short-circuit &&
        function f_in_range(x::Int32)::Bool
            return x > Int32(0) && x < Int32(10)
        end
        @test compile_and_run(f_in_range, (Int32,), Int32(5)) == "true"
        @test compile_and_run(f_in_range, (Int32,), Int32(-1)) == "false"
        @test compile_and_run(f_in_range, (Int32,), Int32(15)) == "false"
    end

    @testset "CF-004: Nested control flow" begin
        # Count down with if inside while
        function f_count_evens(n::Int32)::Int32
            count = Int32(0)
            i = Int32(1)
            while i <= n
                if i & Int32(1) == Int32(0)
                    count += Int32(1)
                end
                i += Int32(1)
            end
            return count
        end
        @test compile_and_run(f_count_evens, (Int32,), Int32(10)) == "5"
        @test compile_and_run(f_count_evens, (Int32,), Int32(1)) == "0"
        @test compile_and_run(f_count_evens, (Int32,), Int32(4)) == "2"
    end

    @testset "CT-001: Bool, Nothing, type conversions" begin
        # Bool return
        f_is_positive(x::Int32)::Bool = x > Int32(0)
        @test compile_and_run(f_is_positive, (Int32,), Int32(5)) == "true"
        @test compile_and_run(f_is_positive, (Int32,), Int32(-3)) == "false"

        # Float64 to Int32
        f_ftoi2(x::Float64) = unsafe_trunc(Int32, x)
        @test compile_and_run(f_ftoi2, (Float64,), 7.9) == "7"
        @test compile_and_run(f_ftoi2, (Float64,), -2.1) == "-2"

        # Int32 to Float64
        f_itof2(x::Int32) = Float64(x)
        @test compile_and_run(f_itof2, (Int32,), Int32(100)) == "100"
    end

    @testset "CT-002: String literals, interpolation, concatenation" begin
        # String literal return
        f_hello() = "hello"
        @test compile_and_run(f_hello, ()) == "hello"

        # String argument passthrough
        f_echo(s::String) = s
        @test compile_and_run(f_echo, (String,), "world") == "world"

        # String interpolation (all strings)
        f_greet(name::String) = "Hello $(name)!"
        @test compile_and_run(f_greet, (String,), "Julia") == "Hello Julia!"

        # String interpolation with Int32
        f_intstr(x::Int32) = "Value: $(x)"
        @test compile_and_run(f_intstr, (Int32,), Int32(42)) == "Value: 42"

        # String concatenation with *
        f_star(a::String, b::String) = a * b
        @test compile_and_run(f_star, (String, String), "foo", "bar") == "foobar"

        # string() with multiple args
        f_concat(a::String, b::String) = string(a, b)
        @test compile_and_run(f_concat, (String, String), "hello", " world") == "hello world"

        # String comparison (== uses ===)
        f_streq(a::String, b::String) = a == b
        @test compile_and_run(f_streq, (String, String), "abc", "abc") == "true"
        @test compile_and_run(f_streq, (String, String), "abc", "def") == "false"

        # String repeat (^)
        f_rep(s::String, n::Int32) = s ^ n
        @test compile_and_run(f_rep, (String, Int32), "ab", Int32(3)) == "ababab"

        # Mixed type interpolation
        f_mix(name::String, age::Int32) = string(name, " is ", age)
        @test compile_and_run(f_mix, (String, Int32), "Alice", Int32(30)) == "Alice is 30"
    end
end
