import math
import os
import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


CLK_PERIOD_NS = 1


def bits_per_chunk():
    value = int(os.environ.get("BITS_PER_CHUNK", "8"))
    assert value > 0, "BITS_PER_CHUNK must be greater than zero"
    return value


def chunk_mask(bits):
    return (1 << bits) - 1


def signal_chunk_width(signal, bits):
    width = len(signal.value)
    assert width % bits == 0, (
        f"{signal._name} width {width} is not divisible by BITS_PER_CHUNK={bits}"
    )
    return width // bits


def chunks_to_word(data, bits):
    word = 0
    for idx, chunk in enumerate(data):
        word |= chunk << (bits * idx)
    return word


def word_to_chunks(word, width, bits):
    mask = chunk_mask(bits)
    return [(word >> (bits * idx)) & mask for idx in range(width)]


def signal_to_int(signal, name):
    try:
        return int(signal.value)
    except ValueError as exc:
        raise AssertionError(f"{name} has unresolved bits: {signal.value}") from exc


def aligned_in_beats(in_chunks_per_beat, out_chunks_per_beat, min_beats):
    beat_alignment = out_chunks_per_beat // math.gcd(
        in_chunks_per_beat,
        out_chunks_per_beat,
    )
    return beat_alignment * math.ceil(min_beats / beat_alignment)


def in_chunks_for_beat(beat_idx, in_chunks_per_beat, bits):
    mask = chunk_mask(bits)
    return [
        ((beat_idx * in_chunks_per_beat + chunk_idx) * 37 + 11) & mask
        for chunk_idx in range(in_chunks_per_beat)
    ]


async def reset_dut(dut):
    dut.rstn.value = 0
    dut.in_strm_vld.value = 0
    dut.out_strm_rdy.value = 0
    dut.in_strm_data.value = 0

    for _ in range(3):
        await RisingEdge(dut.clk)

    dut.rstn.value = 1
    await RisingEdge(dut.clk)


async def run_strm_case(
    dut,
    name,
    min_in_beats,
    vld_probability,
    rdy_probability,
    seed,
):
    chunk_bits = bits_per_chunk()
    in_chunks_per_beat = signal_chunk_width(dut.in_strm_data, chunk_bits)
    out_chunks_per_beat = signal_chunk_width(dut.out_strm_data, chunk_bits)
    in_beats = aligned_in_beats(
        in_chunks_per_beat,
        out_chunks_per_beat,
        min_in_beats,
    )
    expected_total_chunks = in_beats * in_chunks_per_beat

    rng = random.Random(seed)
    expected = deque()
    held_vld = False
    held_chunks = []
    held_word = 0
    sent_beats = 0
    received_chunks = 0
    cycle = 0
    max_cycles = max(200, in_beats * 30)

    await reset_dut(dut)

    while received_chunks < expected_total_chunks:
        if not held_vld and sent_beats < in_beats:
            held_vld = rng.random() < vld_probability
            if held_vld:
                held_chunks = in_chunks_for_beat(
                    sent_beats,
                    in_chunks_per_beat,
                    chunk_bits,
                )
                held_word = chunks_to_word(held_chunks, chunk_bits)

        # Drive stimulus immediately after a posedge and hold it stable until
        # the next posedge, where the DUT samples the handshake.
        dut.in_strm_vld.value = int(held_vld)
        dut.in_strm_data.value = held_word if held_vld else 0

        draining = sent_beats >= in_beats and not held_vld
        rdy_probability_now = 1.0 if draining else rdy_probability
        dut.out_strm_rdy.value = int(rng.random() < rdy_probability_now)

        await Timer(1, unit="ps")

        in_strm_rdy = signal_to_int(dut.in_strm_rdy, "in_strm_rdy")
        out_strm_vld = signal_to_int(dut.out_strm_vld, "out_strm_vld")
        out_strm_rdy = signal_to_int(dut.out_strm_rdy, "out_strm_rdy")

        in_handshake = held_vld and in_strm_rdy
        out_handshake = out_strm_vld and out_strm_rdy

        if in_handshake:
            expected.extend(held_chunks)
            sent_beats += 1
            held_vld = False
            held_chunks = []
            held_word = 0

        if out_handshake:
            actual_word = signal_to_int(dut.out_strm_data, "out_strm_data")
            actual_chunks = word_to_chunks(
                actual_word,
                out_chunks_per_beat,
                chunk_bits,
            )
            assert len(expected) >= out_chunks_per_beat, (
                f"{name}: DUT produced an output with only "
                f"{len(expected)} expected chunks queued"
            )
            expected_chunks = [expected.popleft() for _ in range(out_chunks_per_beat)]
            assert actual_chunks == expected_chunks, (
                f"{name}: output chunk mismatch at chunk {received_chunks}: "
                f"got {actual_chunks}, expected {expected_chunks}"
            )
            received_chunks += out_chunks_per_beat

        await RisingEdge(dut.clk)

        cycle += 1
        assert cycle < max_cycles, (
            f"{name}: timed out after {cycle} cycles; sent {sent_beats}/"
            f"{in_beats} beats and received {received_chunks}/"
            f"{expected_total_chunks} chunks"
        )

    assert not expected, f"{name}: scoreboard still has {len(expected)} chunks queued"

    for _ in range(3):
        dut.in_strm_vld.value = 0
        dut.in_strm_data.value = 0
        dut.out_strm_rdy.value = 1
        await Timer(1, unit="ps")
        assert signal_to_int(dut.out_strm_vld, "out_strm_vld") == 0, (
            f"{name}: out_strm_vld remained asserted after all expected chunks drained"
        )
        await RisingEdge(dut.clk)


@cocotb.test()
async def chunk_strm_regression(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())

    await run_strm_case(
        dut,
        name="continuous",
        min_in_beats=40,
        vld_probability=1.0,
        rdy_probability=1.0,
        seed=0xC001,
    )

    await run_strm_case(
        dut,
        name="random_backpressure",
        min_in_beats=120,
        vld_probability=0.70,
        rdy_probability=0.55,
        seed=0xACE5,
    )
