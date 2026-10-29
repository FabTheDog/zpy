"""Tests of the bindings generated from tests/fixture.zig.

Run with `zig build test-python`.
"""

import array
import gc
import importlib.util
import math
import pathlib
import re

import pytest

import fixture


def test_scalars():
    assert fixture.add(2, 3) == 5
    assert fixture.add(2**31 - 1, 1) == -(2**31)  # wrapping add in Zig
    assert fixture.is_positive(4) is True
    assert fixture.is_positive(-4) is False


def test_error_union():
    assert fixture.divide(1.0, 4.0) == 0.25
    with pytest.raises(fixture.DivisionByZero) as info:
        fixture.divide(1.0, 0.0)
    assert isinstance(info.value, fixture.Error)


def test_enums():
    assert fixture.mix(fixture.Color.red, fixture.Color.blue) is fixture.Color.blue
    assert fixture.mix(1, 2) is fixture.Color.red  # plain ints are accepted
    with pytest.raises(ValueError):
        fixture.mix(7, 0)  # rejected by IntEnum before reaching Zig
    assert fixture.level_value(fixture.Level.low) == -1
    assert fixture.level_value(fixture.Level.high) == 10


def test_values():
    v = fixture.Vec2(3.0, 4.0)
    assert v.length() == 5.0
    assert v.add(fixture.Vec2(1.0, 1.0)) == fixture.Vec2(4.0, 5.0)
    assert fixture.Vec2.init(1.0, 2.0) == fixture.Vec2(1.0, 2.0)
    assert fixture.Vec2(x=1.0).y == 0.5  # Zig field default
    with pytest.raises(TypeError):
        v.add((1.0, 1.0))


def test_value_defaults_and_nesting():
    brush = fixture.Brush(rgb=fixture.Rgb(r=1, g=2, b=3))
    assert brush.color is fixture.Color.green
    assert brush.size == 1.0
    assert brush.origin == fixture.Vec2(0.0, 0.0)
    assert brush.origin is not fixture.Brush(rgb=fixture.Rgb(r=0, g=0, b=0)).origin


def test_handle_lifecycle():
    with fixture.Canvas("abc") as canvas:
        assert canvas.name_length() == 3
        assert canvas.count() == 0
        with pytest.raises(fixture.Empty):
            canvas.last()

        brush = fixture.Brush(color=fixture.Color.blue, origin=fixture.Vec2(1.0, 1.0), rgb=fixture.Rgb(r=0, g=0, b=0))
        canvas.stroke(brush, fixture.Vec2(2.0, 3.0))
        assert canvas.count() == 1
        assert canvas.last() == fixture.Vec2(3.0, 4.0)
        assert canvas.last_color() is fixture.Color.blue

        with pytest.raises(fixture.OutOfBounds):
            canvas.stroke(brush, fixture.Vec2(1000.0, 0.0))
        assert canvas.count() == 1

    with pytest.raises(ValueError):
        canvas.count()  # closed
    canvas.close()  # closing twice is harmless


def test_handle_constructor_errors():
    with pytest.raises(fixture.NameTooLong):
        fixture.Canvas("a name that is too long")
    with pytest.raises(TypeError):
        fixture.Canvas(None)


def test_handle_type_checks():
    with fixture.Canvas("a") as canvas:
        with pytest.raises(TypeError):
            fixture.Canvas.count(fixture.Vec2(1.0, 1.0))
        assert fixture.Canvas.count(canvas) == 0


def test_skipped_declarations():
    assert not hasattr(fixture, "generic")  # anytype parameter
    assert not hasattr(fixture, "hidden")  # config.skip
    assert not hasattr(fixture, "mutable")  # []u8: Zig would write into it
    assert not hasattr(fixture.Canvas, "deinit")  # called by close()
    assert fixture.__skipped__["generic"] == "generic function"
    assert fixture.__skipped__["hidden"] == "listed in config.skip"
    assert "[]u8" in fixture.__skipped__["mutable"]


def test_docs_and_parameter_names():
    assert fixture.Vec2.__doc__ == "A point in the plane."
    assert fixture.Vec2.length.__doc__ == "Euclidean norm."
    assert fixture.divide(numerator=1.0, denominator=2.0) == 0.5
    with pytest.raises(TypeError):
        fixture.divide(a=1.0, b=2.0)


def test_constants_and_nested_types():
    assert fixture.answer == 42
    assert fixture.Vec2.zero == fixture.Vec2(0.0, 0.0)
    assert fixture.Shape.Rect is fixture.Shape_Rect


def test_unions():
    assert fixture.Shape.dot().area() == 0.0
    assert math.isclose(fixture.Shape.circle(1.0).area(), math.pi)
    assert fixture.Shape.rect(w=2.0, h=3.0).area() == 6.0
    assert fixture.Shape.rect(fixture.Shape.Rect(2.0, 3.0)) == fixture.Shape.rect(w=2.0, h=3.0)
    assert fixture.Shape.poly().value.sides == 3  # default of the anonymous payload
    assert repr(fixture.Shape.circle(2.0)) == "Shape.circle(2.0)"
    with pytest.raises(ValueError):
        fixture.Shape("square")


def test_union_payload_stands_for_its_variant():
    # Shape_Rect is the payload of `rect` only, so it can be passed as a Shape.
    assert fixture.widest([fixture.Shape.Rect(1.0, 1.0), fixture.Shape.circle(1.0)]) == fixture.Shape.circle(1.0)


def test_optionals():
    assert fixture.half(3.0) == 1.5
    assert fixture.half(None) is None
    assert fixture.widest([]) is None

    brush = fixture.Brush(rgb=fixture.Rgb(0, 0, 0))
    assert brush.shape is None
    assert brush.tip == fixture.Shape.poly(sides=3)


def test_slices():
    assert fixture.sum([1.0, 2.0, 3.5]) == 6.5
    assert fixture.sum([]) == 0.0
    assert fixture.sum(array.array("d", [1.0, 2.0])) == 3.0  # buffer, copied as is
    assert fixture.sum(x / 2 for x in range(4)) == 3.0  # any iterable
    assert fixture.byte_sum(b"\x01\x02") == 3
    assert fixture.byte_sum("AB") == 131  # str is encoded
    assert fixture.total_length(["ab", b"cde", ""]) == 5
    colors = [fixture.Color.red, fixture.Color.blue, fixture.Color.red]
    assert fixture.count_color(colors, fixture.Color.red) == 2
    assert fixture.centroid([fixture.Vec2(0.0, 0.0), fixture.Vec2(2.0, 4.0)]) == fixture.Vec2(1.0, 2.0)
    with pytest.raises(fixture.Empty):
        fixture.centroid([])
    with pytest.raises(ValueError):
        fixture.count_color([7], fixture.Color.red)  # rejected by IntEnum


def test_handle_references_in_values():
    with fixture.Canvas("c") as canvas:
        canvas.stroke(fixture.Brush(rgb=fixture.Rgb(0, 0, 0)), fixture.Vec2(1.0, 1.0))
        assert fixture.stamped_count(fixture.Stamp(canvas=canvas, scale=2.0)) == 2.0
    with pytest.raises(ValueError):
        fixture.stamped_count(fixture.Stamp(canvas=canvas))  # closed


def test_interfaces():
    with fixture.Tally() as tally:
        assert isinstance(tally, fixture.Counter)
        assert fixture.feed(tally, 2) == 2
        assert fixture.feed(tally, 3) == 5
        assert tally.total() == 5


def test_constructor_keeps_its_arguments_alive():
    label = fixture.Label("".join(chr(65 + i % 26) for i in range(1000)))
    expected = sum(65 + i % 26 for i in range(1000))
    gc.collect()
    assert label.checksum() == expected


def test_injection():
    assert fixture.magic(1) == 8  # Context comes from config.inject
    assert fixture.cwd_accessible() is True  # std.Io comes from the library


def test_abi_hash_is_checked(tmp_path):
    module = pathlib.Path(fixture.__file__)
    package = tmp_path / "stale"
    package.mkdir()
    lib = next(p for p in module.parent.iterdir() if p.suffix in (".so", ".dylib", ".dll"))
    (package / lib.name).symlink_to(lib)
    text = module.read_text()
    (package / "__init__.py").write_text(re.sub(r"0x[0-9a-f]{16}", "0x" + "0" * 16, text, count=1))
    spec = importlib.util.spec_from_file_location("stale", package / "__init__.py")
    with pytest.raises(ImportError, match="rebuild both"):
        spec.loader.exec_module(importlib.util.module_from_spec(spec))


def test_garbage_collected_handle_is_released():
    canvas = fixture.Canvas("gc")
    del canvas  # must not crash or leak an exception


def test_float_precision():
    assert math.isclose(fixture.Vec2(0.1, 0.2).add(fixture.Vec2(0.2, 0.1)).x, 0.3)
