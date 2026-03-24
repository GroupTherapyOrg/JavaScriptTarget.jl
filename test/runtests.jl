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

    @testset "CO-002: For loops and iteration" begin
        # Range for loop: sum 1 to n
        function f_sum_range(n::Int32)::Int32
            s = Int32(0)
            for i in Int32(1):n
                s += i
            end
            return s
        end
        @test compile_and_run(f_sum_range, (Int32,), Int32(10)) == "55"
        @test compile_and_run(f_sum_range, (Int32,), Int32(0)) == "0"
        @test compile_and_run(f_sum_range, (Int32,), Int32(1)) == "1"

        # Array for loop: sum elements
        function f_sum_arr(v::Vector{Int32})::Int32
            s = Int32(0)
            for x in v
                s += x
            end
            return s
        end
        result = compile(f_sum_arr, (Vector{Int32},); module_format=:none)
        js1 = """
$(result.js)
process.stdout.write(String(f_sum_arr([1, 2, 3, 4, 5])));
"""
        @test run_js(js1) == "15"

        # Empty array
        js2 = """
$(result.js)
process.stdout.write(String(f_sum_arr([])));
"""
        @test run_js(js2) == "0"

        # Single element array
        js3 = """
$(result.js)
process.stdout.write(String(f_sum_arr([42])));
"""
        @test run_js(js3) == "42"

        # Range with computation in body
        function f_sum_squares(n::Int32)::Int32
            s = Int32(0)
            for i in Int32(1):n
                s += i * i
            end
            return s
        end
        @test compile_and_run(f_sum_squares, (Int32,), Int32(5)) == "55"
    end

    @testset "CO-003: Dict and Set" begin
        # Dict: create, set, get
        function f_dict_basic(k::String, v::Int32)::Int32
            d = Dict{String, Int32}()
            d[k] = v
            return d[k]
        end
        result = compile(f_dict_basic, (String, Int32); module_format=:none)
        @test occursin("new Map()", result.js)
        js1 = """
$(result.js)
process.stdout.write(String(f_dict_basic("hello", 42)));
"""
        @test run_js(js1) == "42"

        # Dict: set multiple keys, get second
        function f_dict_multi(a::String, b::String)::Int32
            d = Dict{String, Int32}()
            d[a] = Int32(10)
            d[b] = Int32(20)
            return d[b]
        end
        result2 = compile(f_dict_multi, (String, String); module_format=:none)
        js2 = """
$(result2.js)
process.stdout.write(String(f_dict_multi("x", "y")));
"""
        @test run_js(js2) == "20"

        # Dict: delete key, access remaining
        function f_dict_delete(k1::String, k2::String)::Int32
            d = Dict{String, Int32}()
            d[k1] = Int32(10)
            d[k2] = Int32(20)
            delete!(d, k1)
            return d[k2]
        end
        result3 = compile(f_dict_delete, (String, String); module_format=:none)
        js3 = """
$(result3.js)
process.stdout.write(String(f_dict_delete("a", "b")));
"""
        @test run_js(js3) == "20"
    end

    @testset "EX-001: try/catch" begin
        # Normal path: no exception
        function f_safe_div(a::Int32, b::Int32)::Int32
            try
                return div(a, b)
            catch
                return Int32(0)
            end
        end
        result = compile(f_safe_div, (Int32, Int32); module_format=:none)
        @test occursin("try {", result.js)
        @test occursin("catch", result.js)
        @test compile_and_run(f_safe_div, (Int32, Int32), Int32(10), Int32(3)) == "3"

        # Exception path: error() throws into catch
        function f_trycatch(x::Int32)::Int32
            try
                if x == Int32(0)
                    error("zero!")
                end
                return x * Int32(2)
            catch
                return Int32(-1)
            end
        end
        @test compile_and_run(f_trycatch, (Int32,), Int32(5)) == "10"
        @test compile_and_run(f_trycatch, (Int32,), Int32(0)) == "-1"

        # try/catch with computation in try body
        function f_try_compute(a::Float64, b::Float64)::Float64
            try
                return a / b
            catch
                return 0.0
            end
        end
        @test compile_and_run(f_try_compute, (Float64, Float64), 10.0, 4.0) == "2.5"
    end

    @testset "RT-001: Runtime library" begin
        # --- IO: println → console.log ---
        @testset "println / print" begin
            # println with single arg
            function f_println_int(x::Int32)::Nothing
                println(x)
                return nothing
            end
            result = compile(f_println_int, (Int32,); module_format=:none)
            @test occursin("jl_println", result.js)
            @test occursin("// JavaScriptTarget.jl runtime", result.js)
            # Verify runtime is included (tree-shaken)
            @test occursin("function jl_println", result.js)

            # println with string
            function f_println_str(s::String)::Nothing
                println(s)
                return nothing
            end
            result2 = compile(f_println_str, (String,); module_format=:none)
            @test occursin("jl_println", result2.js)
        end

        # --- String operations ---
        @testset "String operations" begin
            # startswith
            f_starts(s::String, p::String) = startswith(s, p)
            result3 = compile(f_starts, (String, String); module_format=:none)
            js3 = """
$(result3.js)
process.stdout.write(String(f_starts("hello world", "hello")));
"""
            @test run_js(js3) == "true"
            js3b = """
$(result3.js)
process.stdout.write(String(f_starts("hello world", "xyz")));
"""
            @test run_js(js3b) == "false"

            # endswith
            f_ends(s::String, p::String) = endswith(s, p)
            result4 = compile(f_ends, (String, String); module_format=:none)
            js4 = """
$(result4.js)
process.stdout.write(String(f_ends("hello world", "world")));
"""
            @test run_js(js4) == "true"

            # String repeat (already in CT-002, but verify it still works)
            f_rep2(s::String, n::Int32) = s ^ n
            @test compile_and_run(f_rep2, (String, Int32), "ab", Int32(3)) == "ababab"
        end

        # --- Math: div, fld, mod, cld, rem ---
        # Julia inlines these to intrinsics — no runtime helper needed
        @testset "Math: div, fld, mod, cld" begin
            # div (truncating)
            f_div(a::Int32, b::Int32) = div(a, b)
            @test compile_and_run(f_div, (Int32, Int32), Int32(7), Int32(2)) == "3"
            @test compile_and_run(f_div, (Int32, Int32), Int32(-7), Int32(2)) == "-3"

            # fld (floor division)
            f_fld(a::Int32, b::Int32) = fld(a, b)
            @test compile_and_run(f_fld, (Int32, Int32), Int32(7), Int32(2)) == "3"
            @test compile_and_run(f_fld, (Int32, Int32), Int32(-7), Int32(2)) == "-4"

            # mod (modulus, same sign as divisor)
            f_mod(a::Int32, b::Int32) = mod(a, b)
            @test compile_and_run(f_mod, (Int32, Int32), Int32(7), Int32(3)) == "1"
            @test compile_and_run(f_mod, (Int32, Int32), Int32(-7), Int32(3)) == "2"

            # cld (ceiling division)
            f_cld(a::Int32, b::Int32) = cld(a, b)
            @test compile_and_run(f_cld, (Int32, Int32), Int32(7), Int32(2)) == "4"
            @test compile_and_run(f_cld, (Int32, Int32), Int32(6), Int32(2)) == "3"
        end

        # --- Tree-shaking: no runtime when not needed ---
        @testset "Tree-shaking" begin
            # Simple arithmetic should NOT include runtime
            f_simple(x::Int32) = x + Int32(1)
            result = compile(f_simple, (Int32,); module_format=:none)
            @test !occursin("// JavaScriptTarget.jl runtime", result.js)

            # println SHOULD include runtime
            function f_println_tree(x::Int32)::Nothing
                println(x)
                return nothing
            end
            result2 = compile(f_println_tree, (Int32,); module_format=:none)
            @test occursin("function jl_println", result2.js)
            # but NOT unneeded helpers
            @test !occursin("function jl_div", result2.js)
            @test !occursin("function jl_fld", result2.js)
        end

        # --- Error types ---
        @testset "Error types in runtime" begin
            # error() should work (already tested in EX-001)
            # Test that thrown errors are catchable
            function f_catch_error(x::Int32)::String
                try
                    if x == Int32(0)
                        error("bad value")
                    end
                    return "ok"
                catch
                    return "caught"
                end
            end
            @test compile_and_run(f_catch_error, (Int32,), Int32(1)) == "ok"
            @test compile_and_run(f_catch_error, (Int32,), Int32(0)) == "caught"
        end

        # --- isempty (uses Core.sizeof → .length) ---
        @testset "isempty" begin
            f_isempty(s::String) = isempty(s)
            result = compile(f_isempty, (String,); module_format=:none)
            @test occursin(".length", result.js)
            js1 = """
$(result.js)
process.stdout.write(String(f_isempty("")));
"""
            @test run_js(js1) == "true"
            js2 = """
$(result.js)
process.stdout.write(String(f_isempty("hello")));
"""
            @test run_js(js2) == "false"
        end
    end

    @testset "RT-003: .d.ts generation" begin
        # --- Primitive type mapping ---
        @testset "Primitive types in .d.ts" begin
            f_int(x::Int32) = x
            result = compile(f_int, (Int32,))
            @test occursin("x: number", result.dts)
            @test occursin(": number;", result.dts)

            f_bool(x::Bool) = x
            result2 = compile(f_bool, (Bool,))
            @test occursin("x: boolean", result2.dts)

            f_str(s::String) = s
            result3 = compile(f_str, (String,))
            @test occursin("s: string", result3.dts)
            @test occursin(": string;", result3.dts)

            f_nothing()::Nothing = nothing
            result4 = compile(f_nothing, ())
            @test occursin(": null;", result4.dts)
        end

        # --- Branded struct types ---
        @testset "Branded struct .d.ts" begin
            struct DtsVec2
                x::Float64
                y::Float64
            end
            f_dts_vec(v::DtsVec2) = v.x + v.y
            result = compile(f_dts_vec, (DtsVec2,))

            # Should have a declare class with branded type
            @test occursin("declare class DtsVec2", result.dts)
            @test occursin("readonly x: number;", result.dts)
            @test occursin("readonly y: number;", result.dts)
            @test occursin("__brand: unique symbol", result.dts)
            @test occursin("constructor(x: number, y: number);", result.dts)

            # Function should reference the struct type
            @test occursin("v: DtsVec2", result.dts)
        end

        # --- Mutable struct (no brand, writable fields) ---
        @testset "Mutable struct .d.ts" begin
            mutable struct DtsMPoint
                x::Float64
                y::Float64
            end
            function f_dts_move!(p::DtsMPoint, dx::Float64)::Nothing
                p.x += dx
                return nothing
            end
            result = compile(f_dts_move!, (DtsMPoint, Float64))

            @test occursin("declare class DtsMPoint", result.dts)
            # Mutable: writable fields (no readonly)
            @test occursin("x: number;", result.dts)
            @test !occursin("readonly x:", result.dts)
            # Mutable: no brand
            @test !occursin("__brand", result.dts)
        end

        # --- Union types ---
        @testset "Union types in .d.ts" begin
            f_union(x::Union{Nothing, Int32})::Int32 = x === nothing ? Int32(0) : x
            result = compile(f_union, (Union{Nothing, Int32},))
            @test occursin("null | number", result.dts) || occursin("number | null", result.dts)
        end

        # --- Container types ---
        @testset "Container types in .d.ts" begin
            f_vec(v::Vector{Float64}) = v
            result = compile(f_vec, (Vector{Float64},))
            @test occursin("Array<number>", result.dts)

            f_dict(d::Dict{String, Int32}) = d
            result2 = compile(f_dict, (Dict{String, Int32},))
            @test occursin("Map<string, number>", result2.dts)

            f_set(s::Set{String}) = s
            result3 = compile(f_set, (Set{String},))
            @test occursin("Set<string>", result3.dts)
        end

        # --- Tuple return types ---
        @testset "Tuple types in .d.ts" begin
            f_tuple(a::Int32, b::Float64) = (a, b)
            result = compile(f_tuple, (Int32, Float64))
            @test occursin("readonly [number, number]", result.dts)
        end

        # --- Module .d.ts ---
        @testset "Module .d.ts with structs" begin
            struct DtsColor
                r::Int32
                g::Int32
                b::Int32
            end
            f_red(c::DtsColor) = c.r
            f_green(c::DtsColor) = c.g

            result = compile_module([
                (f_red, (DtsColor,), "f_red"),
                (f_green, (DtsColor,), "f_green"),
            ])
            # Struct declaration should appear once
            @test occursin("declare class DtsColor", result.dts)
            @test occursin("readonly r: number;", result.dts)
            # Both function declarations
            @test occursin("f_red(c: DtsColor): number", result.dts)
            @test occursin("f_green(c: DtsColor): number", result.dts)
        end

        # --- Parametric struct .d.ts ---
        @testset "Parametric struct .d.ts" begin
            struct DtsWrapper{T}
                value::T
            end
            f_wrap(x::Int32) = DtsWrapper{Int32}(x)
            result = compile(f_wrap, (Int32,))
            @test occursin("declare class DtsWrapper", result.dts)
            @test occursin("constructor", result.dts)
        end
    end

    @testset "RT-004: Source map generation" begin
        # --- VLQ encoding ---
        @testset "VLQ encoding" begin
            # Test basic VLQ encoding values
            # 0 → "A" (0 → unsigned 0, 5-bit chunk 0 → 'A')
            @test JavaScriptTarget.vlq_encode(0) == "A"
            # 1 → "C" (1 → unsigned 2, 5-bit chunk 2 → 'C')
            @test JavaScriptTarget.vlq_encode(1) == "C"
            # -1 → "D" (-1 → unsigned 3, 5-bit chunk 3 → 'D')
            @test JavaScriptTarget.vlq_encode(-1) == "D"
            # 5 → "K" (5 → unsigned 10, 5-bit chunk 10 → 'K')
            @test JavaScriptTarget.vlq_encode(5) == "K"
            # Larger value: 16 → unsigned 32, needs continuation
            @test length(JavaScriptTarget.vlq_encode(16)) == 2
        end

        # --- Source map generation ---
        @testset "Source map JSON structure" begin
            sm = JavaScriptTarget.generate_sourcemap(
                "test.jl", 10, "line1\nline2\nline3\n", "test_func"
            )
            @test occursin("\"version\": 3", sm)
            @test occursin("\"file\": \"test_func.js\"", sm)
            @test occursin("\"sources\": [\"test.jl\"]", sm)
            @test occursin("\"mappings\":", sm)
            @test occursin("\"names\": []", sm)
        end

        # --- Integration with compile ---
        @testset "Source map in compile()" begin
            # sourcemap=false (default) → empty
            f_sm_test(x::Int32) = x + Int32(1)
            result1 = compile(f_sm_test, (Int32,); sourcemap=false)
            @test result1.sourcemap == ""

            # sourcemap=true → generates map (may be empty for REPL functions)
            result2 = compile(f_sm_test, (Int32,); sourcemap=true)
            # REPL functions have file="none" so sourcemap may be empty
            # That's OK — just verify no errors
            @test result2.sourcemap isa String
        end

        # --- Mappings content ---
        @testset "Mappings semicolons" begin
            # 3-line JS should produce 2 semicolons in mappings (separating 3 line groups)
            sm = JavaScriptTarget.generate_sourcemap(
                "test.jl", 1, "a\nb\nc\n", "f"
            )
            mappings = match(r"\"mappings\": \"([^\"]+)\"", sm)
            @test mappings !== nothing
            # 3 lines → 2 semicolons
            @test count(';', mappings.captures[1]) == 2
        end
    end

    @testset "RT-002: Base function coverage" begin
        # --- Math functions (should map to Math.*) ---
        @testset "Math functions" begin
            f_sin(x::Float64) = sin(x)
            @test parse(Float64, compile_and_run(f_sin, (Float64,), 0.0)) ≈ 0.0
            @test parse(Float64, compile_and_run(f_sin, (Float64,), 1.0)) ≈ sin(1.0) atol=1e-10

            f_cos(x::Float64) = cos(x)
            @test parse(Float64, compile_and_run(f_cos, (Float64,), 0.0)) ≈ 1.0

            f_exp(x::Float64) = exp(x)
            @test parse(Float64, compile_and_run(f_exp, (Float64,), 0.0)) ≈ 1.0

            f_log(x::Float64) = log(x)
            @test parse(Float64, compile_and_run(f_log, (Float64,), 1.0)) ≈ 0.0

            f_sqrt(x::Float64) = sqrt(x)
            @test parse(Float64, compile_and_run(f_sqrt, (Float64,), 4.0)) ≈ 2.0

            f_floor(x::Float64) = floor(x)
            @test compile_and_run(f_floor, (Float64,), 3.7) == "3"

            f_ceil(x::Float64) = ceil(x)
            @test compile_and_run(f_ceil, (Float64,), 3.2) == "4"

            f_round(x::Float64) = round(x)
            @test compile_and_run(f_round, (Float64,), 3.5) == "4"

            f_trunc(x::Float64) = trunc(x)
            @test compile_and_run(f_trunc, (Float64,), 3.7) == "3"

            f_sign(x::Float64) = sign(x)
            @test compile_and_run(f_sign, (Float64,), -3.14) == "-1"
        end

        # --- Integer math (inlined to intrinsics) ---
        @testset "Integer math" begin
            f_div_i(a::Int32, b::Int32) = div(a, b)
            @test compile_and_run(f_div_i, (Int32, Int32), Int32(7), Int32(2)) == "3"
            @test compile_and_run(f_div_i, (Int32, Int32), Int32(-7), Int32(2)) == "-3"

            f_mod_i(a::Int32, b::Int32) = mod(a, b)
            @test compile_and_run(f_mod_i, (Int32, Int32), Int32(7), Int32(3)) == "1"
            @test compile_and_run(f_mod_i, (Int32, Int32), Int32(-7), Int32(3)) == "2"

            f_fld_i(a::Int32, b::Int32) = fld(a, b)
            @test compile_and_run(f_fld_i, (Int32, Int32), Int32(-7), Int32(2)) == "-4"

            f_cld_i(a::Int32, b::Int32) = cld(a, b)
            @test compile_and_run(f_cld_i, (Int32, Int32), Int32(7), Int32(2)) == "4"
        end

        # --- Type conversions ---
        @testset "Type conversions" begin
            f_i2f(x::Int32) = Float64(x)
            @test compile_and_run(f_i2f, (Int32,), Int32(42)) == "42"

            f_f2i(x::Float64) = unsafe_trunc(Int32, x)
            @test compile_and_run(f_f2i, (Float64,), 3.7) == "3"
            @test compile_and_run(f_f2i, (Float64,), -2.1) == "-2"
        end

        # --- String functions ---
        @testset "String operations" begin
            f_strlen(s::String) = isempty(s)
            @test compile_and_run(f_strlen, (String,), "") == "true"
            @test compile_and_run(f_strlen, (String,), "hello") == "false"

            f_strcat(a::String, b::String) = string(a, b)
            @test compile_and_run(f_strcat, (String, String), "foo", "bar") == "foobar"

            f_strrep(s::String, n::Int32) = s ^ n
            @test compile_and_run(f_strrep, (String, Int32), "ab", Int32(3)) == "ababab"

            f_interp(name::String) = "Hello $(name)!"
            @test compile_and_run(f_interp, (String,), "World") == "Hello World!"
        end

        # --- Comparison (already tested inline in earlier tests, verify via named functions) ---
        @testset "Comparisons" begin
            f_eq(a::Int32, b::Int32) = a == b
            @test compile_and_run(f_eq, (Int32, Int32), Int32(5), Int32(5)) == "true"
            @test compile_and_run(f_eq, (Int32, Int32), Int32(5), Int32(3)) == "false"

            f_lt(a::Int32, b::Int32) = a < b
            @test compile_and_run(f_lt, (Int32, Int32), Int32(3), Int32(5)) == "true"
            @test compile_and_run(f_lt, (Int32, Int32), Int32(5), Int32(3)) == "false"

            f_ge(a::Float64, b::Float64) = a >= b
            @test compile_and_run(f_ge, (Float64, Float64), 5.0, 5.0) == "true"
            @test compile_and_run(f_ge, (Float64, Float64), 3.0, 5.0) == "false"
        end

        # --- Boolean operations ---
        @testset "Boolean operations" begin
            f_not(x::Bool) = !x
            @test compile_and_run(f_not, (Bool,), true) == "false"
            @test compile_and_run(f_not, (Bool,), false) == "true"

            # Short-circuit && and || (already tested in CF-003)
            function f_sc_and(a::Bool, b::Bool)::Bool
                return a && b
            end
            @test compile_and_run(f_sc_and, (Bool, Bool), true, true) == "true"
            @test compile_and_run(f_sc_and, (Bool, Bool), true, false) == "false"
        end

        # --- Bitwise operations ---
        @testset "Bitwise operations" begin
            f_band(a::Int32, b::Int32) = a & b
            @test compile_and_run(f_band, (Int32, Int32), Int32(0b1100), Int32(0b1010)) == "8"

            f_bor(a::Int32, b::Int32) = a | b
            @test compile_and_run(f_bor, (Int32, Int32), Int32(0b1100), Int32(0b1010)) == "14"

            f_bxor(a::Int32, b::Int32) = xor(a, b)
            @test compile_and_run(f_bxor, (Int32, Int32), Int32(0b1100), Int32(0b1010)) == "6"
        end

        # --- Composite functions (real-world patterns) ---
        @testset "Composite patterns" begin
            # Euclidean distance
            function f_distance(x1::Float64, y1::Float64, x2::Float64, y2::Float64)::Float64
                dx = x2 - x1
                dy = y2 - y1
                return sqrt(dx * dx + dy * dy)
            end
            @test parse(Float64, compile_and_run(f_distance, (Float64, Float64, Float64, Float64), 0.0, 0.0, 3.0, 4.0)) ≈ 5.0

            # Polynomial evaluation
            function f_poly(x::Float64)::Float64
                return 3.0 * x * x + 2.0 * x + 1.0
            end
            @test parse(Float64, compile_and_run(f_poly, (Float64,), 2.0)) ≈ 17.0
        end
    end

    # =====================================================
    # PG-001: Pre-computed inference tables
    # =====================================================
    @testset "PG-001: Inference Tables" begin

        @testset "TypeRegistry built-in IDs" begin
            reg = JavaScriptTarget.TypeRegistry()
            # Special types
            @test JavaScriptTarget.get_type_id(reg, Any) == 0
            @test JavaScriptTarget.get_type_id(reg, Union{}) == 1
            @test JavaScriptTarget.get_type_id(reg, Nothing) == 2
            @test JavaScriptTarget.get_type_id(reg, Missing) == 3
            # Primitives
            @test JavaScriptTarget.get_type_id(reg, Bool) == 4
            @test JavaScriptTarget.get_type_id(reg, Int32) == 7
            @test JavaScriptTarget.get_type_id(reg, Int64) == 8
            @test JavaScriptTarget.get_type_id(reg, Float64) == 17
            @test JavaScriptTarget.get_type_id(reg, String) == 19
            # Abstract
            @test JavaScriptTarget.get_type_id(reg, Number) == 21
            @test JavaScriptTarget.get_type_id(reg, Integer) == 23
            @test JavaScriptTarget.get_type_id(reg, AbstractFloat) == 26
            # Containers
            @test JavaScriptTarget.get_type_id(reg, Vector{Int64}) == 29
            @test JavaScriptTarget.get_type_id(reg, Vector{Float64}) == 30
            # Names
            @test reg.id_to_name[8] == "Int64"
            @test reg.id_to_name[17] == "Float64"
            @test reg.id_to_name[0] == "Any"
            # Unknown type → -1
            @test JavaScriptTarget.get_type_id(reg, Complex{Float64}) == -1
        end

        @testset "TypeRegistry ensure_type_id!" begin
            reg = JavaScriptTarget.TypeRegistry()
            # Known type returns existing ID
            @test JavaScriptTarget.ensure_type_id!(reg, Int64) == 8
            # Unknown type gets registered
            id = JavaScriptTarget.ensure_type_id!(reg, Complex{Float64})
            @test id >= 0
            @test JavaScriptTarget.get_type_id(reg, Complex{Float64}) == id
            # Calling again returns same ID
            @test JavaScriptTarget.ensure_type_id!(reg, Complex{Float64}) == id
        end

        @testset "FNV-1a hash" begin
            # Empty input should return offset basis
            @test JavaScriptTarget.fnv1a_hash(UInt8[]) == 0x811c9dc5
            # Deterministic
            h1 = JavaScriptTarget.composite_hash(Int32(1), Int32[8, 8])
            h2 = JavaScriptTarget.composite_hash(Int32(1), Int32[8, 8])
            @test h1 == h2
            # Different inputs → different hashes (with high probability)
            h3 = JavaScriptTarget.composite_hash(Int32(1), Int32[8, 17])
            @test h1 != h3
            h4 = JavaScriptTarget.composite_hash(Int32(2), Int32[8, 8])
            @test h1 != h4
            # Hash is non-zero for typical inputs
            @test h1 != UInt32(0)
        end

        @testset "FuncRegistry" begin
            fr = JavaScriptTarget.FuncRegistry()
            id1 = JavaScriptTarget.register_func!(fr, "+")
            id2 = JavaScriptTarget.register_func!(fr, "sin")
            @test id1 != id2
            # Same name → same ID
            @test JavaScriptTarget.register_func!(fr, "+") == id1
            # Lookup
            @test JavaScriptTarget.get_func_id(fr, "+") == id1
            @test JavaScriptTarget.get_func_id(fr, "unknown") == -1
        end

        @testset "Hash table insert and lookup" begin
            table = JavaScriptTarget.InferenceHashTable(32)
            # Insert an entry
            func_id = Int32(0)
            arg_ids = Int32[8, 8]  # Int64, Int64
            ret_id = Int32(8)      # Int64
            hash = JavaScriptTarget.composite_hash(func_id, arg_ids)
            entry = JavaScriptTarget.HashEntry(hash, func_id, arg_ids, ret_id)
            @test JavaScriptTarget.insert!(table, entry) == true
            # Lookup succeeds
            result = JavaScriptTarget.lookup(table, func_id, arg_ids)
            @test result == ret_id
            # Lookup with different args → not found
            result2 = JavaScriptTarget.lookup(table, func_id, Int32[17, 17])
            @test result2 == -1
            # Insert more entries
            for i in 1:20
                fid = Int32(i)
                aids = Int32[Int32(i + 5)]
                h = JavaScriptTarget.composite_hash(fid, aids)
                JavaScriptTarget.insert!(table, JavaScriptTarget.HashEntry(h, fid, aids, Int32(i * 10)))
            end
            @test table.count == 21
            # All entries still retrievable
            result3 = JavaScriptTarget.lookup(table, func_id, arg_ids)
            @test result3 == ret_id
        end

        @testset "Method enumeration" begin
            type_reg = JavaScriptTarget.TypeRegistry()
            func_reg = JavaScriptTarget.FuncRegistry()
            entries = JavaScriptTarget.enumerate_base_methods(type_reg, func_reg)
            # Should find a substantial number of entries
            @test length(entries) >= 200
            # Check that +(Int64, Int64) → Int64 is present
            plus_id = JavaScriptTarget.get_func_id(func_reg, "+")
            int64_id = JavaScriptTarget.get_type_id(type_reg, Int64)
            @test plus_id >= 0
            found_plus = false
            for e in entries
                if e.func_id == plus_id && e.arg_type_ids == Int32[int64_id, int64_id]
                    @test e.return_type_id == int64_id
                    found_plus = true
                    break
                end
            end
            @test found_plus
            # Check sin(Float64) → Float64
            sin_id = JavaScriptTarget.get_func_id(func_reg, "sin")
            f64_id = JavaScriptTarget.get_type_id(type_reg, Float64)
            found_sin = false
            for e in entries
                if e.func_id == sin_id && e.arg_type_ids == Int32[f64_id]
                    @test e.return_type_id == f64_id
                    found_sin = true
                    break
                end
            end
            @test found_sin
        end

        @testset "Parametric rules" begin
            rules = JavaScriptTarget.generate_parametric_rules()
            @test length(rules) >= 100
            # Check specific rule: +(T<:Number, T) → T
            plus_rules = filter(r -> r["func"] == "+", rules)
            @test length(plus_rules) >= 1
            # Check comparison → Bool rule exists
            eq_rules = filter(r -> r["func"] == "==" && get(r["returns"], "type", "") == "Bool", rules)
            @test length(eq_rules) >= 1
            # Check getindex(Vector{T}, Int) → T
            getidx_rules = filter(r -> r["func"] == "getindex" && haskey(get(r["args"][1], "nothing", Dict()), "nothing") == false, rules)
            @test length(getidx_rules) >= 1
        end

        @testset "build_inference_tables (binary)" begin
            output = tempname() * ".bin"
            stats = build_inference_tables(output)
            # Stats checks
            @test stats.num_types >= 50
            @test stats.num_entries >= 200
            @test stats.num_rules >= 100
            @test stats.num_functions >= 30
            @test stats.hash_capacity >= stats.num_entries
            # File checks
            @test isfile(output)
            @test stats.file_size > 1000
            @test stats.file_size < 10_000_000
            # Verify magic number
            open(output) do f
                magic = read(f, 4)
                @test magic == UInt8[0x4a, 0x4c, 0x54, 0x49]  # "JLTI"
                version = read(f, UInt32)
                @test version == 1
            end
            rm(output)
        end

        @testset "Serialization round-trip" begin
            output = tempname() * ".bin"
            stats = build_inference_tables(output)
            # Read back and verify structure
            data = read(output)
            @test length(data) == stats.file_size
            # Parse header
            magic = data[1:4]
            @test String(magic) == "JLTI"
            version = reinterpret(UInt32, data[5:8])[1]
            @test version == 1
            json_offset = reinterpret(UInt32, data[9:12])[1]
            json_length = reinterpret(UInt32, data[13:16])[1]
            hash_offset = reinterpret(UInt32, data[17:20])[1]
            hash_length = reinterpret(UInt32, data[21:24])[1]
            # JSON section is valid-ish (starts with {)
            json_start = json_offset + 1  # 1-based
            json_str = String(data[json_start:json_start + json_length - 1])
            @test startswith(json_str, "{")
            @test endswith(json_str, "}")
            @test occursin("\"types\":", json_str)
            @test occursin("\"functions\":", json_str)
            @test occursin("\"rules\":", json_str)
            # Hash section has correct size
            hash_start = hash_offset + 1
            @test hash_length >= 8  # at least capacity + entry_size
            rm(output)
        end

        @testset "Hash table + method lookup integration" begin
            # Build tables, then verify hash table lookups match code_typed
            type_reg = JavaScriptTarget.TypeRegistry()
            func_reg = JavaScriptTarget.FuncRegistry()
            entries = JavaScriptTarget.enumerate_base_methods(type_reg, func_reg)
            table = JavaScriptTarget.InferenceHashTable(max(64, length(entries) * 2))
            seen = Set{UInt64}()
            for entry in entries
                key = hash((entry.func_id, entry.arg_type_ids))
                key in seen && continue
                push!(seen, key)
                JavaScriptTarget.insert!(table, entry)
            end
            # Verify +(Int64, Int64)
            plus_id = JavaScriptTarget.get_func_id(func_reg, "+")
            int64_id = JavaScriptTarget.get_type_id(type_reg, Int64)
            ret = JavaScriptTarget.lookup(table, plus_id, Int32[int64_id, int64_id])
            @test ret == int64_id
            # Verify sin(Float64) → Float64
            sin_id = JavaScriptTarget.get_func_id(func_reg, "sin")
            f64_id = JavaScriptTarget.get_type_id(type_reg, Float64)
            ret2 = JavaScriptTarget.lookup(table, sin_id, Int32[f64_id])
            @test ret2 == f64_id
            # Verify ==(Int64, Int64) → Bool
            eq_id = JavaScriptTarget.get_func_id(func_reg, "==")
            bool_id = JavaScriptTarget.get_type_id(type_reg, Bool)
            ret3 = JavaScriptTarget.lookup(table, eq_id, Int32[int64_id, int64_id])
            @test ret3 == bool_id
        end
    end

    @testset "PG-002: Thin inference engine (infer.js)" begin
        # Path to infer.js
        infer_js_path = joinpath(@__DIR__, "..", "src", "playground", "infer.js")
        @test isfile(infer_js_path)

        # Generate types.bin for all JS tests
        types_bin = tempname() * ".bin"
        result = build_inference_tables(types_bin)
        @test isfile(types_bin)

        @testset "FNV-1a hash matches Julia↔JS" begin
            # Compute hash on Julia side
            type_reg = JavaScriptTarget.TypeRegistry()
            func_reg = JavaScriptTarget.FuncRegistry()
            plus_id = JavaScriptTarget.register_func!(func_reg, "+")
            int64_id = JavaScriptTarget.get_type_id(type_reg, Int64)
            julia_hash = JavaScriptTarget.composite_hash(plus_id, Int32[int64_id, int64_id])

            # Compute same hash in JS and compare
            js_code = """
            const infer = require('$(replace(infer_js_path, "\\" => "\\\\"))');
            const h = infer.compositeHash($(Int(plus_id)), [$(Int(int64_id)), $(Int(int64_id))]);
            process.stdout.write(String(h));
            """
            js_result = run_js(js_code)
            @test parse(UInt32, js_result) == julia_hash
        end

        @testset "loadTables parses types.bin" begin
            js_code = """
            const fs = require('fs');
            const infer = require('$(replace(infer_js_path, "\\" => "\\\\"))');
            const buf = fs.readFileSync('$(replace(types_bin, "\\" => "\\\\"))');
            const tables = infer.loadTables(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));
            // Check we got types and functions
            process.stdout.write(JSON.stringify({
                numTypes: tables.typeByName.size,
                numFuncs: tables.funcByName.size,
                numRules: tables.rules.length,
                hasInt64: tables.typeByName.has('Int64'),
                hasPlus: tables.funcByName.has('+'),
            }));
            """
            js_result = run_js(js_code)
            parsed = let
                # Simple JSON parsing
                s = js_result
                has_int64 = occursin("\"hasInt64\":true", s)
                has_plus = occursin("\"hasPlus\":true", s)
                num_types = parse(Int, match(r"\"numTypes\":(\d+)", s).captures[1])
                num_funcs = parse(Int, match(r"\"numFuncs\":(\d+)", s).captures[1])
                num_rules = parse(Int, match(r"\"numRules\":(\d+)", s).captures[1])
                (; num_types, num_funcs, num_rules, has_int64, has_plus)
            end
            @test parsed.num_types >= 40
            @test parsed.num_funcs >= 50
            @test parsed.num_rules >= 100
            @test parsed.has_int64
            @test parsed.has_plus
        end

        @testset "Tier 1: Hash table lookup in JS" begin
            js_code = """
            const fs = require('fs');
            const infer = require('$(replace(infer_js_path, "\\" => "\\\\"))');
            const buf = fs.readFileSync('$(replace(types_bin, "\\" => "\\\\"))');
            const tables = infer.loadTables(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));

            // +(Int64, Int64) → Int64
            const plusId = tables.funcByName.get('+');
            const int64Id = tables.typeByName.get('Int64');
            const ret1 = infer.hashLookup(tables, plusId, [int64Id, int64Id]);

            // sin(Float64) → Float64
            const sinId = tables.funcByName.get('sin');
            const f64Id = tables.typeByName.get('Float64');
            const ret2 = infer.hashLookup(tables, sinId, [f64Id]);

            // ==(Int64, Int64) → Bool
            const eqId = tables.funcByName.get('==');
            const boolId = tables.typeByName.get('Bool');
            const ret3 = infer.hashLookup(tables, eqId, [int64Id, int64Id]);

            process.stdout.write(JSON.stringify({
                plus_ret: ret1, plus_expect: int64Id,
                sin_ret: ret2, sin_expect: f64Id,
                eq_ret: ret3, eq_expect: boolId,
            }));
            """
            js_result = run_js(js_code)
            # +(Int64,Int64) → Int64
            @test occursin(r"\"plus_ret\":(\d+).*\"plus_expect\":\1", js_result) ||
                  let m1 = match(r"\"plus_ret\":(\d+)", js_result),
                      m2 = match(r"\"plus_expect\":(\d+)", js_result)
                      m1.captures[1] == m2.captures[1]
                  end
            # sin(Float64) → Float64
            @test let m1 = match(r"\"sin_ret\":(\d+)", js_result),
                     m2 = match(r"\"sin_expect\":(\d+)", js_result)
                     m1.captures[1] == m2.captures[1]
                 end
            # ==(Int64,Int64) → Bool
            @test let m1 = match(r"\"eq_ret\":(\d+)", js_result),
                     m2 = match(r"\"eq_expect\":(\d+)", js_result)
                     m1.captures[1] == m2.captures[1]
                 end
        end

        @testset "Tier 2: Parametric rules in JS" begin
            js_code = """
            const fs = require('fs');
            const infer = require('$(replace(infer_js_path, "\\" => "\\\\"))');
            const buf = fs.readFileSync('$(replace(types_bin, "\\" => "\\\\"))');
            const tables = infer.loadTables(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));

            // sin(Int32) → Float64 (parametric rule: sin(Integer) → Float64)
            const int32Id = tables.typeByName.get('Int32');
            const f64Id = tables.typeByName.get('Float64');
            const ret1 = infer.matchRules(tables, 'sin', [int32Id]);

            // ==(Any, Any) → Bool (parametric rule)
            const boolId = tables.typeByName.get('Bool');
            const strId = tables.typeByName.get('String');
            const ret2 = infer.matchRules(tables, '==', [strId, strId]);

            // string(Any) → String
            const anyId = 0;
            const ret3 = infer.matchRules(tables, 'string', [int32Id]);

            process.stdout.write([ret1, f64Id, ret2, boolId, ret3, strId].join(','));
            """
            js_result = run_js(js_code)
            vals = parse.(Int, split(js_result, ","))
            @test vals[1] == vals[2]  # sin(Int32) → Float64
            @test vals[3] == vals[4]  # ==(String,String) → Bool
            @test vals[5] == vals[6]  # string(Int32) → String
        end

        @testset "Forward SSA: f(x) = x * x + 1" begin
            # IR for: f(x::Int64) = x * x + 1
            # SSA 0: x * x  (CALL "*", [arg0, arg0])
            # SSA 1: lit 1  (LITERAL Int64)
            # SSA 2: _0 + 1 (CALL "+", [ssa0, ssa1])
            # SSA 3: return  (RETURN ssa2)
            js_code = """
            const fs = require('fs');
            const infer = require('$(replace(infer_js_path, "\\" => "\\\\"))');
            const buf = fs.readFileSync('$(replace(types_bin, "\\" => "\\\\"))');
            const tables = infer.loadTables(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));

            const int64Id = tables.typeByName.get('Int64');
            const func = {
                code: [
                    { kind: 1, callee: '*', args: [{arg: 0}, {arg: 0}] },
                    { kind: 5, typeId: int64Id },
                    { kind: 1, callee: '+', args: [{ssa: 0}, {ssa: 1}] },
                    { kind: 6, val: {ssa: 2} },
                ],
                argCount: 1
            };

            const ssaTypes = infer.inferFunction(func, [int64Id], tables);
            process.stdout.write(JSON.stringify({
                ssa0: ssaTypes[0],
                ssa1: ssaTypes[1],
                ssa2: ssaTypes[2],
                ssa3: ssaTypes[3],
                int64Id: int64Id,
            }));
            """
            js_result = run_js(js_code)
            # All SSAs should be Int64
            m = match(r"\"int64Id\":(\d+)", js_result)
            int64_str = m.captures[1]
            @test occursin("\"ssa0\":$(int64_str)", js_result)
            @test occursin("\"ssa1\":$(int64_str)", js_result)
            @test occursin("\"ssa2\":$(int64_str)", js_result)
            @test occursin("\"ssa3\":$(int64_str)", js_result)
        end

        @testset "Forward SSA: f(x::Float64) = sin(x) + cos(x)" begin
            js_code = """
            const fs = require('fs');
            const infer = require('$(replace(infer_js_path, "\\" => "\\\\"))');
            const buf = fs.readFileSync('$(replace(types_bin, "\\" => "\\\\"))');
            const tables = infer.loadTables(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));

            const f64Id = tables.typeByName.get('Float64');
            const func = {
                code: [
                    { kind: 1, callee: 'sin', args: [{arg: 0}] },
                    { kind: 1, callee: 'cos', args: [{arg: 0}] },
                    { kind: 1, callee: '+', args: [{ssa: 0}, {ssa: 1}] },
                    { kind: 6, val: {ssa: 2} },
                ],
                argCount: 1
            };

            const ret = infer.inferReturnType(func, [f64Id], tables);
            process.stdout.write(String(ret === f64Id));
            """
            @test run_js(js_code) == "true"
        end

        @testset "PhiNode inference: if/else merge" begin
            # f(x::Int64) = x > 0 ? x : -x
            # SSA 0: x > 0     (CALL ">", [arg0, lit(Int64)])
            # SSA 1: gotoifnot (GOTOIFNOT cond=ssa0, dest=4)
            # SSA 2: -x        (CALL "-_unary", [arg0])  (true branch)
            # SSA 3: goto      (GOTO dest=5)
            # SSA 4: -x neg    (CALL "-_unary", [arg0])  (false branch → abs)
            # SSA 5: phi       (PHI edges from true/false)
            # SSA 6: return    (RETURN ssa5)
            js_code = """
            const fs = require('fs');
            const infer = require('$(replace(infer_js_path, "\\" => "\\\\"))');
            const buf = fs.readFileSync('$(replace(types_bin, "\\" => "\\\\"))');
            const tables = infer.loadTables(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));

            const int64Id = tables.typeByName.get('Int64');
            const boolId = tables.typeByName.get('Bool');
            const func = {
                code: [
                    { kind: 1, callee: '>', args: [{arg: 0}, {lit: int64Id}] },
                    { kind: 8, cond: {ssa: 0}, dest: 4 },
                    { kind: 5, typeId: int64Id },
                    { kind: 7, dest: 5 },
                    { kind: 1, callee: '-_unary', args: [{arg: 0}] },
                    { kind: 2, edges: [{from: 3, val: {ssa: 2}}, {from: 4, val: {ssa: 4}}] },
                    { kind: 6, val: {ssa: 5} },
                ],
                argCount: 1
            };

            const ssaTypes = infer.inferFunction(func, [int64Id], tables);
            const retType = ssaTypes[6];
            process.stdout.write(String(retType === int64Id));
            """
            @test run_js(js_code) == "true"
        end

        @testset "Union type handling" begin
            js_code = """
            const infer = require('$(replace(infer_js_path, "\\" => "\\\\"))');

            // joinTypes basics
            const a = infer.joinTypes(infer.UNKNOWN, 8);  // UNKNOWN + Int64 → Int64
            const b = infer.joinTypes(8, 8);               // Int64 + Int64 → Int64
            const c = infer.joinTypes(8, 17);              // Int64 + Float64 → [8,17]
            const d = infer.joinTypes(infer.TYPE_ANY, 8);  // Any + anything → Any
            const e = infer.joinTypes(infer.TYPE_BOTTOM, 8); // Bottom + Int64 → Int64
            const f = infer.joinTypes([7, 8], 17);         // [Int32,Int64] + Float64 → [7,8,17]

            process.stdout.write(JSON.stringify({
                a: a,
                b: b,
                c: JSON.stringify(c),
                d: d,
                e: e,
                f_len: Array.isArray(f) ? f.length : -1,
            }));
            """
            js_result = run_js(js_code)
            @test occursin("\"a\":8", js_result)           # UNKNOWN + 8 → 8
            @test occursin("\"b\":8", js_result)           # 8 + 8 → 8
            @test occursin("\"c\":\"[8,17]\"", js_result)  # union
            @test occursin("\"d\":0", js_result)           # Any
            @test occursin("\"e\":8", js_result)           # Bottom + 8 → 8
            @test occursin("\"f_len\":3", js_result)       # 3-element union
        end

        @testset "Union cap at MAX_UNION → Any" begin
            js_code = """
            const infer = require('$(replace(infer_js_path, "\\" => "\\\\"))');
            // Join 5 different types → exceeds MAX_UNION (4) → Any
            let t = infer.joinTypes(5, 6);   // [Int8, Int16]
            t = infer.joinTypes(t, 7);       // [Int8, Int16, Int32]
            t = infer.joinTypes(t, 8);       // [Int8, Int16, Int32, Int64]
            t = infer.joinTypes(t, 17);      // 5 types → Any
            process.stdout.write(String(t));
            """
            @test run_js(js_code) == "0"  # TYPE_ANY
        end

        @testset "PiNode type narrowing" begin
            js_code = """
            const fs = require('fs');
            const infer = require('$(replace(infer_js_path, "\\" => "\\\\"))');
            const buf = fs.readFileSync('$(replace(types_bin, "\\" => "\\\\"))');
            const tables = infer.loadTables(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));

            const int64Id = tables.typeByName.get('Int64');
            // SSA 0: literal int64
            // SSA 1: PiNode narrowing to Int64
            // SSA 2: return ssa1
            const func = {
                code: [
                    { kind: 5, typeId: int64Id },
                    { kind: 9, val: {ssa: 0}, typeId: int64Id },
                    { kind: 6, val: {ssa: 1} },
                ],
                argCount: 0
            };

            const ret = infer.inferReturnType(func, [], tables);
            process.stdout.write(String(ret === int64Id));
            """
            @test run_js(js_code) == "true"
        end

        @testset "Loop fixed-point: sum 1 to n" begin
            # f(n::Int64): i=1, s=0; while i<=n: s+=i; i+=1; return s
            # SSA 0: lit 1 (Int64)
            # SSA 1: lit 0 (Int64)
            # SSA 2: phi i (from init and loop back)
            # SSA 3: phi s (from init and loop back)
            # SSA 4: i <= n (CALL "<=", [ssa2, arg0])
            # SSA 5: gotoifnot ssa4, dest=10
            # SSA 6: s + i (CALL "+", [ssa3, ssa2])
            # SSA 7: lit 1 (Int64)
            # SSA 8: i + 1 (CALL "+", [ssa2, ssa7])
            # SSA 9: goto 2
            # SSA 10: return ssa3
            js_code = """
            const fs = require('fs');
            const infer = require('$(replace(infer_js_path, "\\" => "\\\\"))');
            const buf = fs.readFileSync('$(replace(types_bin, "\\" => "\\\\"))');
            const tables = infer.loadTables(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));

            const int64Id = tables.typeByName.get('Int64');
            const func = {
                code: [
                    { kind: 5, typeId: int64Id },
                    { kind: 5, typeId: int64Id },
                    { kind: 2, edges: [{from: 0, val: {ssa: 0}}, {from: 9, val: {ssa: 8}}] },
                    { kind: 2, edges: [{from: 1, val: {ssa: 1}}, {from: 9, val: {ssa: 6}}] },
                    { kind: 1, callee: '<=', args: [{ssa: 2}, {arg: 0}] },
                    { kind: 8, cond: {ssa: 4}, dest: 10 },
                    { kind: 1, callee: '+', args: [{ssa: 3}, {ssa: 2}] },
                    { kind: 5, typeId: int64Id },
                    { kind: 1, callee: '+', args: [{ssa: 2}, {ssa: 7}] },
                    { kind: 7, dest: 2 },
                    { kind: 6, val: {ssa: 3} },
                ],
                argCount: 1
            };

            const ssaTypes = infer.inferFunction(func, [int64Id], tables);
            // All phi nodes and arithmetic should be Int64
            const allInt64 = ssaTypes[2] === int64Id && ssaTypes[3] === int64Id &&
                             ssaTypes[6] === int64Id && ssaTypes[8] === int64Id &&
                             ssaTypes[10] === int64Id;
            process.stdout.write(String(allInt64));
            """
            @test run_js(js_code) == "true"
        end

        @testset "inferReturnType: mixed types" begin
            js_code = """
            const fs = require('fs');
            const infer = require('$(replace(infer_js_path, "\\" => "\\\\"))');
            const buf = fs.readFileSync('$(replace(types_bin, "\\" => "\\\\"))');
            const tables = infer.loadTables(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));

            const int64Id = tables.typeByName.get('Int64');
            const strId = tables.typeByName.get('String');

            // Function with two return paths: returns Int64 or String
            const func = {
                code: [
                    { kind: 1, callee: '>', args: [{arg: 0}, {lit: int64Id}] },
                    { kind: 8, cond: {ssa: 0}, dest: 4 },
                    { kind: 6, val: {arg: 0} },
                    { kind: 7, dest: 5 },
                    { kind: 6, val: {lit: strId} },
                    { kind: 5, typeId: int64Id },
                ],
                argCount: 1
            };

            const ret = infer.inferReturnType(func, [int64Id], tables);
            // Should be union [Int64, String] or Any
            const isUnion = Array.isArray(ret) && ret.includes(int64Id) && ret.includes(strId);
            process.stdout.write(String(isUnion));
            """
            @test run_js(js_code) == "true"
        end

        @testset "isa special-casing returns Bool" begin
            js_code = """
            const fs = require('fs');
            const infer = require('$(replace(infer_js_path, "\\" => "\\\\"))');
            const buf = fs.readFileSync('$(replace(types_bin, "\\" => "\\\\"))');
            const tables = infer.loadTables(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));

            const int64Id = tables.typeByName.get('Int64');
            const boolId = tables.typeByName.get('Bool');
            const func = {
                code: [
                    { kind: 1, callee: 'isa', args: [{arg: 0}, {lit: int64Id}] },
                    { kind: 6, val: {ssa: 0} },
                ],
                argCount: 1
            };

            const ssaTypes = infer.inferFunction(func, [int64Id], tables);
            process.stdout.write(String(ssaTypes[0] === boolId));
            """
            @test run_js(js_code) == "true"
        end

        @testset "User method table" begin
            js_code = """
            const infer = require('$(replace(infer_js_path, "\\" => "\\\\"))');
            const umt = infer.createUserMethodTable();

            // Register a user function: myfunc(Int64) → Float64
            umt.register('myfunc', [8], 17);
            const ret = umt.lookup('myfunc', [8]);
            const miss = umt.lookup('myfunc', [19]);  // Wrong arg type

            process.stdout.write(JSON.stringify({ret: ret, miss: miss}));
            """
            js_result = run_js(js_code)
            @test occursin("\"ret\":17", js_result)    # Found: Float64
            @test occursin("\"miss\":-1", js_result)   # Not found
        end

        @testset "typesEqual utility" begin
            js_code = """
            const infer = require('$(replace(infer_js_path, "\\" => "\\\\"))');
            const results = [
                infer.typesEqual(8, 8),           // true: same scalar
                infer.typesEqual(8, 17),          // false: different scalar
                infer.typesEqual([7,8], [7,8]),   // true: same array
                infer.typesEqual([7,8], [7,9]),   // false: different array
                infer.typesEqual(8, [8]),          // false: scalar vs array
                infer.typesEqual(-1, -1),         // true: UNKNOWN
            ];
            process.stdout.write(results.map(String).join(','));
            """
            @test run_js(js_code) == "true,false,true,false,false,true"
        end

        # Clean up
        isfile(types_bin) && rm(types_bin)
    end
end
