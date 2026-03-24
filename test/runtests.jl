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

    @testset "CT-003: Union{Nothing, T} and isa checks" begin
        # x === nothing check
        function f_maybe(x::Union{Nothing, Int32})::Int32
            if x === nothing
                return Int32(0)
            else
                return x
            end
        end
        @test compile_and_run(f_maybe, (Union{Nothing, Int32},), Int32(42)) == "42"
        @test compile_and_run(f_maybe, (Union{Nothing, Int32},), nothing) == "0"

        # isa(x, Int32)
        f_isa_int(x::Union{Nothing, Int32}) = isa(x, Int32)
        @test compile_and_run(f_isa_int, (Union{Nothing, Int32},), Int32(5)) == "true"
        @test compile_and_run(f_isa_int, (Union{Nothing, Int32},), nothing) == "false"

        # isa(x, Nothing)
        f_isa_nothing(x::Union{Nothing, Int32}) = isa(x, Nothing)
        @test compile_and_run(f_isa_nothing, (Union{Nothing, Int32},), nothing) == "true"
        @test compile_and_run(f_isa_nothing, (Union{Nothing, Int32},), Int32(7)) == "false"

        # Nothing return
        f_ret_nothing()::Nothing = nothing
        @test compile_and_run(f_ret_nothing, ()) == "null"
    end

    @testset "FN-001: compile_module() multi-function" begin
        # Cross-function call
        @noinline f_helper(x::Int32)::Int32 = x + Int32(10)
        f_main(x::Int32)::Int32 = f_helper(x) * Int32(2)

        @test compile_module_and_run([
            (f_helper, (Int32,), "f_helper"),
            (f_main, (Int32,), "f_main"),
        ], "f_main", Int32(5)) == "30"

        # Multiple independent functions
        f_double(x::Int32)::Int32 = x * Int32(2)
        f_triple(x::Int32)::Int32 = x * Int32(3)

        result = compile_module([
            (f_double, (Int32,), "f_double"),
            (f_triple, (Int32,), "f_triple"),
        ]; module_format=:none)
        @test occursin("f_double", result.js)
        @test occursin("f_triple", result.js)
        @test "f_double" in result.exports
        @test "f_triple" in result.exports

        # ESM format generates export statement
        result_esm = compile_module([
            (f_double, (Int32,), "f_double"),
        ]; module_format=:esm)
        @test occursin("export", result_esm.js)

        # .dts generated for module
        @test !isempty(result.dts)
        @test occursin("f_double", result.dts)
        @test occursin("f_triple", result.dts)
    end

    @testset "FN-002: Closures" begin
        # Simple closure: adder
        function f_adder(n::Int32)
            return x::Int32 -> x + n
        end
        result = compile(f_adder, (Int32,); module_format=:none)
        js_code = """
$(result.js)
const add5 = f_adder(5);
process.stdout.write(String(add5(10)));
"""
        @test run_js(js_code) == "15"

        # Multi-capture closure
        function f_linear(a::Int32, b::Int32)
            return x::Int32 -> a * x + b
        end
        result2 = compile(f_linear, (Int32, Int32); module_format=:none)
        js_code2 = """
$(result2.js)
const f = f_linear(2, 3);
process.stdout.write(String(f(5)));
"""
        @test run_js(js_code2) == "13"

        # Closure with no capture (constant function)
        function f_const_maker()
            return x::Int32 -> x * Int32(2)
        end
        result3 = compile(f_const_maker, (); module_format=:none)
        js_code3 = """
$(result3.js)
const double = f_const_maker();
process.stdout.write(String(double(7)));
"""
        @test run_js(js_code3) == "14"
    end

    @testset "FN-003: Higher-order functions" begin
        # apply_twice with sin (concrete callee)
        function f_apply_twice(f, x::Float64)::Float64
            return f(f(x))
        end
        result = compile(f_apply_twice, (typeof(sin), Float64); module_format=:none)
        # Should produce Math.sin calls
        @test occursin("Math.sin", result.js)

        # Verify correct result: sin(sin(1.0))
        expected = sin(sin(1.0))
        js_code = """
$(result.js)
process.stdout.write(String(f_apply_twice(Math.sin, 1.0)));
"""
        @test parse(Float64, run_js(js_code)) ≈ expected atol=1e-10

        # Math function: cos
        f_cosine(x::Float64) = cos(x)
        @test parse(Float64, compile_and_run(f_cosine, (Float64,), 0.0)) ≈ 1.0

        # Math function: exp
        f_exp(x::Float64) = exp(x)
        @test parse(Float64, compile_and_run(f_exp, (Float64,), 0.0)) ≈ 1.0

        # Math function: log
        f_log(x::Float64) = log(x)
        @test parse(Float64, compile_and_run(f_log, (Float64,), 1.0)) ≈ 0.0
    end

    @testset "ST-001: Immutable and mutable structs" begin
        # Immutable struct: field access
        struct TestPoint
            x::Float64
            y::Float64
        end
        f_getx(p::TestPoint) = p.x
        result = compile(f_getx, (TestPoint,); module_format=:none)
        js_code = """
$(result.js)
const p = new TestPoint(3.0, 4.0);
process.stdout.write(String(f_getx(p)));
"""
        @test run_js(js_code) == "3"

        # Struct construction + field access
        f_add_pts(a::TestPoint, b::TestPoint) = TestPoint(a.x + b.x, a.y + b.y)
        result2 = compile(f_add_pts, (TestPoint, TestPoint); module_format=:none)
        js_code2 = """
$(result2.js)
const r = f_add_pts(new TestPoint(1.0, 2.0), new TestPoint(3.0, 4.0));
process.stdout.write(r.x + "," + r.y);
"""
        @test run_js(js_code2) == "4,6"

        # Mutable struct with setfield!
        mutable struct TestMPoint
            x::Float64
            y::Float64
        end
        function f_move_mut!(p::TestMPoint, dx::Float64)::Nothing
            p.x += dx
            return nothing
        end
        result3 = compile(f_move_mut!, (TestMPoint, Float64); module_format=:none)
        # Function name ! → _b in JS
        js_code3 = """
$(result3.js)
const p = new TestMPoint(1.0, 2.0);
f_move_mut_b(p, 5.0);
process.stdout.write(String(p.x));
"""
        @test run_js(js_code3) == "6"

        # Class definition is generated
        @test occursin("class TestPoint", result2.js)
        @test occursin("constructor", result2.js)

        # Struct distance function
        f_dist(p::TestPoint) = p.x * p.x + p.y * p.y
        @test run_js("""
$(compile(f_dist, (TestPoint,); module_format=:none).js)
process.stdout.write(String(f_dist(new TestPoint(3.0, 4.0))));
""") == "25"
    end

    @testset "ST-002: Parametric types (type erasure)" begin
        struct TestBox{T}
            value::T
        end

        # Int32 box
        f_box_int(x::Int32) = TestBox{Int32}(x)
        result = compile(f_box_int, (Int32,); module_format=:none)
        @test occursin("class TestBox", result.js)
        js_code = """
$(result.js)
const b = f_box_int(42);
process.stdout.write(String(b.value));
"""
        @test run_js(js_code) == "42"

        # String box
        f_box_str(s::String) = TestBox{String}(s)
        result2 = compile(f_box_str, (String,); module_format=:none)
        # Same class name (type erasure)
        @test occursin("class TestBox", result2.js)
        js_code2 = """
$(result2.js)
const b = f_box_str("hello");
process.stdout.write(b.value);
"""
        @test run_js(js_code2) == "hello"

        # Unbox
        f_unbox(b::TestBox{Int32}) = b.value
        @test run_js("""
$(compile(f_unbox, (TestBox{Int32},); module_format=:none).js)
process.stdout.write(String(f_unbox(new TestBox(99))));
""") == "99"
    end

    @testset "ST-003: typeof, isa, dispatch" begin
        struct TestCircle
            radius::Float64
        end
        struct TestRect
            w::Float64
            h::Float64
        end

        # isa check for struct types
        f_is_circle(s::Union{TestCircle, TestRect}) = isa(s, TestCircle)
        result = compile(f_is_circle, (Union{TestCircle, TestRect},); module_format=:none)
        @test occursin("instanceof", result.js)
        js_code = """
$(result.js)
process.stdout.write(String(f_is_circle(new TestCircle(5.0))));
"""
        @test run_js(js_code) == "true"
        js_code2 = """
$(result.js)
process.stdout.write(String(f_is_circle(new TestRect(3.0, 4.0))));
"""
        @test run_js(js_code2) == "false"

        # Union dispatch via isa + if/else
        function f_area(s::Union{TestCircle, TestRect})::Float64
            if isa(s, TestCircle)
                return 3.14159 * s.radius * s.radius
            else
                return s.w * s.h
            end
        end
        result3 = compile(f_area, (Union{TestCircle, TestRect},); module_format=:none)
        js_code3 = """
$(result3.js)
process.stdout.write(String(f_area(new TestRect(3.0, 4.0))));
"""
        @test run_js(js_code3) == "12"

        js_code4 = """
$(result3.js)
const a = f_area(new TestCircle(1.0));
process.stdout.write(a.toFixed(5));
"""
        @test run_js(js_code4) == "3.14159"
    end

    @testset "CO-001: Vector indexing and length" begin
        # getindex: 1-based → 0-based
        f_vget(v::Vector{Int32}, i::Int32)::Int32 = v[i]
        result = compile(f_vget, (Vector{Int32}, Int32); module_format=:none)
        js = """
$(result.js)
process.stdout.write(String(f_vget([10, 20, 30], 2)));
"""
        @test run_js(js) == "20"

        # First element
        js2 = """
$(result.js)
process.stdout.write(String(f_vget([10, 20, 30], 1)));
"""
        @test run_js(js2) == "10"

        # Last element
        js3 = """
$(result.js)
process.stdout.write(String(f_vget([10, 20, 30], 3)));
"""
        @test run_js(js3) == "30"

        # length
        f_vlen(v::Vector{Int32}) = length(v)
        result2 = compile(f_vlen, (Vector{Int32},); module_format=:none)
        js4 = """
$(result2.js)
process.stdout.write(String(f_vlen([1, 2, 3, 4, 5])));
"""
        @test run_js(js4) == "5"

        # Empty vector length
        js5 = """
$(result2.js)
process.stdout.write(String(f_vlen([])));
"""
        @test run_js(js5) == "0"
    end

    @testset "CO-004: Tuple basics" begin
        # Tuple creation
        f_mktuple(a::Int32, b::Float64) = (a, b)
        result = compile(f_mktuple, (Int32, Float64); module_format=:none)
        js = """
$(result.js)
const t = f_mktuple(42, 3.14);
process.stdout.write(t[0] + "," + t[1]);
"""
        @test run_js(js) == "42,3.14"

        # Tuple element access
        f_first(t::Tuple{Int32, Float64})::Int32 = t[1]
        result2 = compile(f_first, (Tuple{Int32, Float64},); module_format=:none)
        js2 = """
$(result2.js)
process.stdout.write(String(f_first([10, 3.14])));
"""
        @test run_js(js2) == "10"

        # Tuple second element
        f_second(t::Tuple{Int32, Float64})::Float64 = t[2]
        result3 = compile(f_second, (Tuple{Int32, Float64},); module_format=:none)
        js3 = """
$(result3.js)
process.stdout.write(String(f_second([10, 3.14])));
"""
        @test run_js(js3) == "3.14"

        # Tuple in function return
        function f_swap(a::Int32, b::Int32)
            return (b, a)
        end
        result4 = compile(f_swap, (Int32, Int32); module_format=:none)
        js4 = """
$(result4.js)
const r = f_swap(1, 2);
process.stdout.write(r[0] + "," + r[1]);
"""
        @test run_js(js4) == "2,1"
    end

    @testset "ST-004: Abstract type hierarchies" begin
        abstract type TestAnimal end
        struct TestDog <: TestAnimal
            name::String
        end
        struct TestCat <: TestAnimal
            name::String
        end

        # isa check with abstract type argument — concrete subtype check
        function check_is_dog(a::TestAnimal)::Bool
            return isa(a, TestDog)
        end
        result = compile(check_is_dog, (TestAnimal,); module_format=:none)
        @test occursin("instanceof", result.js)
        js1 = """
$(result.js)
process.stdout.write(String(check_is_dog(new TestDog("Rex"))));
"""
        @test run_js(js1) == "true"
        js2 = """
$(result.js)
process.stdout.write(String(check_is_dog(new TestCat("Whiskers"))));
"""
        @test run_js(js2) == "false"

        # Dispatch on abstract type subtypes with field access
        function animal_speak(a::TestAnimal)::String
            if isa(a, TestDog)
                return "woof"
            else
                return "meow"
            end
        end
        result2 = compile(animal_speak, (TestAnimal,); module_format=:none)
        js3 = """
$(result2.js)
process.stdout.write(animal_speak(new TestDog("Rex")));
"""
        @test run_js(js3) == "woof"
        js4 = """
$(result2.js)
process.stdout.write(animal_speak(new TestCat("Whiskers")));
"""
        @test run_js(js4) == "meow"

        # $type is set on struct prototypes when abstract types are in arg_types
        result3 = compile(check_is_dog, (TestAnimal,); module_format=:none)
        @test occursin("prototype.\$type", result3.js)

        # Both concrete subtypes get classes even if only one is checked
        @test occursin("class TestDog", result3.js)
        @test occursin("class TestCat", result3.js)
    end
end
