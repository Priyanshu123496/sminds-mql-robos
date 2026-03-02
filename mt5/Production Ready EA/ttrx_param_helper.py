#!/usr/bin/env python3
"""
TTR-X parameter encoder/decoder utility.

Usage examples:
  python ttrx_param_helper.py encode --fast 9 --slow 15 --filter 200
  python ttrx_param_helper.py decode --p2 709 --p3 1899 --p4 4452
"""

from __future__ import annotations

import argparse


def encode_fast(fast_ema: int) -> int:
    return ((fast_ema + 11) * 17) ^ 913


def decode_fast(code: int) -> int:
    t = code ^ 913
    if t % 17 != 0:
        raise ValueError("Invalid fast code")
    return (t // 17) - 11


def encode_slow(slow_ema: int) -> int:
    return ((slow_ema + 17) * 19) ^ 1291


def decode_slow(code: int) -> int:
    t = code ^ 1291
    if t % 19 != 0:
        raise ValueError("Invalid slow code")
    return (t // 19) - 17


def encode_filter(filter_ema: int) -> int:
    return ((filter_ema + 23) * 29) ^ 2087


def decode_filter(code: int) -> int:
    t = code ^ 2087
    if t % 29 != 0:
        raise ValueError("Invalid filter code")
    return (t // 29) - 23


def do_encode(args: argparse.Namespace) -> None:
    p2 = encode_fast(args.fast)
    p3 = encode_slow(args.slow)
    p4 = encode_filter(args.filter)
    print(f"InpP2={p2}")
    print(f"InpP3={p3}")
    print(f"InpP4={p4}")


def do_decode(args: argparse.Namespace) -> None:
    fast = decode_fast(args.p2)
    slow = decode_slow(args.p3)
    filt = decode_filter(args.p4)
    print(f"FastEMA={fast}")
    print(f"SlowEMA={slow}")
    print(f"FilterEMA={filt}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Encode/decode TTR-X EMA parameters.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_encode = sub.add_parser("encode", help="Encode EMA values to InpP2/InpP3/InpP4")
    p_encode.add_argument("--fast", type=int, required=True)
    p_encode.add_argument("--slow", type=int, required=True)
    p_encode.add_argument("--filter", type=int, required=True)
    p_encode.set_defaults(func=do_encode)

    p_decode = sub.add_parser("decode", help="Decode InpP2/InpP3/InpP4 to EMA values")
    p_decode.add_argument("--p2", type=int, required=True)
    p_decode.add_argument("--p3", type=int, required=True)
    p_decode.add_argument("--p4", type=int, required=True)
    p_decode.set_defaults(func=do_decode)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
