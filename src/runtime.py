# Runtime of every module bindgen writes; python.zig copies it after the
# module docstring. A codec says how a type crosses the C boundary: `ctype`
# is its ctypes layout, `to_abi(v)` converts a Python value into it and
# `from_abi(a, keep)` converts back, with `keep` the objects a returned
# handle must keep alive. Generated classes carry their codec as `_abi`;
# ctypes scalars are their own codec.

from __future__ import annotations

import ctypes as _c
import dataclasses as _dc
import functools as _ft
import os as _os
import sys as _sys
from collections.abc import Iterable as _Iterable
from enum import IntEnum as _IntEnum
from typing import Any as _Any, ClassVar as _ClassVar, Literal as _Literal, TypeAlias as _TypeAlias, TypeVar as _TypeVar, overload as _overload

_lib = None  # the shared library, loaded by the generated module

# Hints of what a parameter accepts, wider than the type a result has.
_StrLike: _TypeAlias = "str | bytes | _os.PathLike[str]"
_BytesLike: _TypeAlias = "str | bytes | _os.PathLike[str] | _Iterable[int]"
if _sys.version_info >= (3, 12):
    from collections.abc import Buffer as _Buffer
else:
    _Buffer: _TypeAlias = _Any


class Error(Exception):
    """Error returned by the Zig library."""


class InvalidArgument(Error, ValueError):
    """Rejected by the binding layer: closed handle, enum value out of range."""


class OutOfMemory(Error, MemoryError):
    pass


_ERRORS = {-1: InvalidArgument, -2: OutOfMemory}


def _check(rc):
    if rc:
        cls = _ERRORS.get(rc)
        if cls is None:
            raise Error(f"unexpected error code {rc}")
        raise cls()


def _proto(name, *argtypes):
    f = getattr(_lib, name)
    f.argtypes = argtypes
    f.restype = _c.c_int
    return f


def _encode(s):
    if isinstance(s, str):
        return s.encode()
    if isinstance(s, _os.PathLike):
        return _os.fsencode(s)
    if isinstance(s, (bytes, bytearray, memoryview)):
        return bytes(s)
    raise TypeError(f"expected str, bytes or os.PathLike, got {type(s).__name__}")


def _val(obj, cls):
    if not isinstance(obj, cls):
        raise TypeError(f"expected {cls.__name__}, got {type(obj).__name__}")
    return obj


def _array(ctype, items, convert=None):
    if convert is None:
        try:
            view = memoryview(items)
        except TypeError:
            pass
        else:
            # Buffers already in the C layout (array.array, numpy) are copied as they are.
            if view.ndim == 1 and view.c_contiguous and view.format.lstrip("@=") == ctype._type_:
                return (ctype * len(view)).from_buffer_copy(view)
        values = list(items)
    else:
        values = [convert(item) for item in items]
    return (ctype * len(values))(*values)


def _payload(cls, args, kwargs):
    if len(args) == 1 and not kwargs and isinstance(args[0], cls):
        return args[0]
    return cls(*args, **kwargs)


def _struct(name, fields):
    return type(name, (_c.Structure,), {"_fields_": fields})


def _codec(x):
    """`x` as a codec: a ctypes scalar, a generated class or a codec already."""
    if isinstance(x, type):
        return x._abi if hasattr(x, "_abi") else _ScalarAbi(x)
    return x


class _ScalarAbi:
    def __init__(self, ctype):
        self.ctype = ctype

    def to_abi(self, v):
        return v

    def from_abi(self, a, keep):
        return a


class _StrAbi:
    ctype = _c.c_char_p

    def to_abi(self, v):
        return _encode(v)


_str = _StrAbi()


class _EnumAbi:
    def __init__(self, cls, ctype):
        self.cls = cls
        self.ctype = ctype

    def to_abi(self, v):
        return int(self.cls(v))

    def from_abi(self, a, keep):
        return self.cls(a)


class _ValueAbi:
    def __init__(self, cls, /, **fields):
        self.cls = cls
        self.fields = {name: _codec(codec) for name, codec in fields.items()}
        self.ctype = _struct(f"_Abi_{cls.__name__}", [(name, codec.ctype) for name, codec in self.fields.items()])
        self.defaultable = all(f.default is not _dc.MISSING or f.default_factory is not _dc.MISSING for f in _dc.fields(cls))

    def to_abi(self, v):
        if v is None and self.defaultable:
            v = self.cls()
        _val(v, self.cls)
        return self.ctype(**{name: codec.to_abi(getattr(v, name)) for name, codec in self.fields.items()})

    def from_abi(self, a, keep):
        return self.cls(**{name: codec.from_abi(getattr(a, name), keep) for name, codec in self.fields.items()})


class _UnionAbi:
    def __init__(self, cls, tag, /, **variants):
        self.cls = cls
        self.variants = {name: (code, None if codec is None else _codec(codec)) for name, (code, codec) in variants.items()}
        self.by_tag = {code: name for name, (code, _) in self.variants.items()}
        payload = type(f"_Abi_{cls.__name__}_payload", (_c.Union,), {
            "_fields_": [(name, codec.ctype) for name, (_, codec) in self.variants.items() if codec is not None],
        })
        self.ctype = _struct(f"_Abi_{cls.__name__}", [("tag", tag), ("payload", payload)])
        # A payload class used by a single variant stands for that variant.
        payloads = [codec.cls for _, codec in self.variants.values() if isinstance(codec, (_ValueAbi, _UnionAbi))]
        self.by_type = {codec.cls: name for name, (_, codec) in self.variants.items() if isinstance(codec, (_ValueAbi, _UnionAbi)) and payloads.count(codec.cls) == 1}

    def to_abi(self, v):
        if not isinstance(v, self.cls):
            name = self.by_type.get(type(v))
            if name is None:
                raise TypeError(f"expected {self.cls.__name__}, got {type(v).__name__}")
            v = self.cls(name, v)
        code, codec = self.variants[v.tag]
        a = self.ctype(tag=code)
        if codec is not None:
            setattr(a.payload, v.tag, codec.to_abi(v.value))
        return a

    def from_abi(self, a, keep):
        name = self.by_tag.get(a.tag)
        if name is None:
            raise ValueError(f"invalid {self.cls.__name__} tag {a.tag}")
        codec = self.variants[name][1]
        return self.cls(name, None if codec is None else codec.from_abi(getattr(a.payload, name), keep))


class _OptAbi:
    def __init__(self, child):
        self.child = _codec(child)
        self.ctype = _struct(f"_Abi_opt_{self.child.ctype.__name__}", [("some", _c.c_bool), ("value", self.child.ctype)])

    def to_abi(self, v):
        return self.ctype() if v is None else self.ctype(True, self.child.to_abi(v))

    def from_abi(self, a, keep):
        return self.child.from_abi(a.value, keep) if a.some else None


class _SliceAbi:
    def __init__(self, elem):
        self.elem = _codec(elem)
        self.ctype = _struct(f"_Abi_slice_{self.elem.ctype.__name__}", [("ptr", _c.POINTER(self.elem.ctype)), ("len", _c.c_size_t)])

    def to_abi(self, v):
        if not isinstance(self.elem, _ScalarAbi):
            a = _array(self.elem.ctype, v, self.elem.to_abi)
        elif self.elem.ctype is _c.c_uint8 and isinstance(v, (str, _os.PathLike)):
            a = _array(_c.c_uint8, _encode(v))
        else:
            a = _array(self.elem.ctype, v)
        return self.ctype(a, len(a))


class _BufferAbi:
    """`[]T` of scalars: a writable, contiguous, 1-d buffer of T (array.array,
    bytearray, numpy array, ...) that the call fills in place."""

    def __init__(self, elem):
        self.elem = _codec(elem)
        self.ctype = _struct(f"_Abi_buffer_{self.elem.ctype.__name__}", [("ptr", _c.POINTER(self.elem.ctype)), ("len", _c.c_size_t)])

    def to_abi(self, v):
        want = self.elem.ctype._type_
        try:
            view = memoryview(v)
        except TypeError:
            raise TypeError(f"expected a writable buffer of '{want}', got {type(v).__name__}") from None
        if view.readonly or view.ndim != 1 or not view.c_contiguous or view.format.lstrip("@=") != want:
            shape = "readonly" if view.readonly else f"{view.ndim}-d{'' if view.c_contiguous else ' non-contiguous'} '{view.format}'"
            raise TypeError(f"expected a writable, contiguous 1-d buffer of '{want}', got a {shape} one")
        # Shares the memory, so the call writes straight into the caller's buffer.
        a = (self.elem.ctype * len(view)).from_buffer(view)
        return self.ctype(a, len(a))


_opt = _ft.cache(_OptAbi)
_slice = _ft.cache(_SliceAbi)
_buffer = _ft.cache(_BufferAbi)


class _HandleAbi:
    ctype = _c.c_void_p

    def __init__(self, cls, destroy, views=None):
        self.cls = cls
        self.destroy = _proto(destroy, _c.c_void_p)
        # Interface class -> function returning the pointer to pass as it.
        self.views = {base: _proto(name, _c.c_void_p, _c.c_void_p) for base, name in (views or {}).items()}

    def to_abi(self, v):
        _val(v, self.cls)
        if not v._h:
            raise ValueError(f"{type(v).__name__} is closed")
        view = type(v)._abi.views.get(self.cls)
        if view is None:
            return v._h
        out = _c.c_void_p()
        _check(view(v._h, _c.byref(out)))
        return out.value

    def from_abi(self, a, keep):
        return self.cls._wrap(a, keep)


def _declare(codec):
    """Class decorator factory: `@_x(args)` sets `cls._abi = codec(cls, args)`."""

    def factory(*args, **kwargs):
        def declare(cls):
            cls._abi = codec(cls, *args, **kwargs)
            return cls

        return declare

    return factory


_enum = _declare(_EnumAbi)
_value = _declare(_ValueAbi)
_union = _declare(_UnionAbi)
_handle = _declare(_HandleAbi)


class _Fn:
    """A C function `int symbol(Frame *)`: the arguments, then the result slot."""

    def __init__(self, symbol, params, out=None):
        self.params = [_codec(p) for p in params]
        self.out = None if out is None else _codec(out)
        fields = [(f"a{i}", p.ctype) for i, p in enumerate(self.params)]
        if self.out is not None:
            fields.append(("out", self.out.ctype))
        self.frame = _struct(f"_Frame_{symbol}", fields)
        self.call = _proto(symbol, _c.c_void_p)

    def __call__(self, *args: _Any) -> _Any:
        frame = self.frame(*[p.to_abi(a) for p, a in zip(self.params, args)])
        _check(self.call(_c.byref(frame)))
        if self.out is not None:
            return self.out.from_abi(frame.out, (frame, args))


_fn = _Fn


_H = _TypeVar("_H", bound="_Handle")


class _Handle:
    """Object owned by the Zig library. Release it with close() or a with block."""

    _h: _Any = None
    _keep: _Any = ()

    def __init__(self, *args: _Any, **kwargs: _Any) -> None:
        raise TypeError(f"{type(self).__name__} has no init; use one of its static constructors")

    @classmethod
    def _wrap(cls: type[_H], h: _Any, keep: _Any = ()) -> _H:
        obj = cls.__new__(cls)
        obj._h = h
        obj._keep = keep
        return obj

    def _adopt(self, other: _Handle) -> None:
        """Takes over a handle just returned by the library."""
        self._h, self._keep = other._h, other._keep
        other._h = None

    def close(self) -> None:
        h, self._h = self._h, None
        if h:
            try:
                _check(type(self)._abi.destroy(h))
            finally:
                self._keep = ()

    def __enter__(self: _H) -> _H:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:
            pass


class _Union:
    """Tagged union: `tag` names the active variant, `value` holds its payload."""

    __slots__ = ("tag", "value")
    # Narrowed by each generated subclass to its variant names and payloads.
    tag: _Any
    value: _Any

    def __init__(self, tag: str, value: _Any = None):
        if tag not in type(self)._abi.variants:
            raise ValueError(f"{type(self).__name__} has no variant {tag!r}")
        self.tag = tag
        self.value = value

    def __eq__(self, other: object) -> bool:
        return type(other) is type(self) and other.tag == self.tag and other.value == self.value  # type: ignore[attr-defined]

    __hash__: _ClassVar[None] = None  # type: ignore[assignment]

    def __repr__(self) -> str:
        value = "" if self.value is None else repr(self.value)
        return f"{type(self).__name__}.{self.tag}({value})"
