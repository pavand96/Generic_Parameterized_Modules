# Gearbox WaveDrom Examples

These examples show the intended ready/valid behavior for the gearbox stream
interface. They can be pasted into the WaveDrom editor or rendered by markdown
tooling that supports `wavedrom` code blocks.

## Input Handshake

An input beat is accepted only when `input_stream_valid` and
`input_stream_ready` are both high on the same rising clock edge. The producer
must hold `input_stream_data` stable while `input_stream_valid` is high and the
gearbox is not ready.

```wavedrom
{
  signal: [
    { name: "clk",                wave: "p..........." },
    { name: "input_stream_valid", wave: "01..0.1..0.." },
    { name: "input_stream_ready", wave: "1.0.1.0.1..." },
    { name: "input_stream_data",  wave: "x=..x.=..x..", data: ["A0", "A1"] },
    { name: "input handshake",    wave: "0...1....1..", node: "....a....b.." }
  ],
  edge: [
    "a~>b accepted input beats"
  ]
}
```

## Output Backpressure

When `output_stream_valid` is high and `output_stream_ready` is low,
`output_stream_data` remains stable. The output beat transfers when both
signals are high.

```wavedrom
{
  signal: [
    { name: "clk",                 wave: "p..........." },
    { name: "output_stream_valid", wave: "0.1....0.1.." },
    { name: "output_stream_ready", wave: "1..0..1..1.." },
    { name: "output_stream_data",  wave: "x.=....x.=..", data: ["B0", "B1"] },
    { name: "output handshake",    wave: "0.....1...1." }
  ]
}
```

## Packing Smaller Input Beats Into Larger Output Beats

For `INPUT_BYTES_PER_BEAT=3` and `OUTPUT_BYTES_PER_BEAT=5`, the output stream
does not assert valid until enough input bytes are stored to form one complete
output beat.

```wavedrom
{
  signal: [
    { name: "clk",                 wave: "p..............." },
    { name: "input_stream_valid",  wave: "01.01.01.0....." },
    { name: "input_stream_ready",  wave: "1.............." },
    { name: "input_stream_data",   wave: "x=.x=.x=.x.....", data: ["I0[2:0]", "I1[2:0]", "I2[2:0]"] },
    { name: "stored bytes",        wave: "x=.=.=.=.=.....", data: ["0", "3", "6", "4", "7"] },
    { name: "output_stream_valid", wave: "0...1.0.1....." },
    { name: "output_stream_ready", wave: "1.............." },
    { name: "output_stream_data",  wave: "x...=.x.=.....", data: ["O0[4:0]", "O1[4:0]"] }
  ]
}
```

## Random Backpressure Test Shape

The cocotb testbench randomly toggles input valid and output ready. The
scoreboard only updates on handshakes, so stalls do not change expected byte
ordering.

```wavedrom
{
  signal: [
    { name: "clk",                 wave: "p................" },
    { name: "input_stream_valid",  wave: "01.0.1..01.0...." },
    { name: "input_stream_ready",  wave: "1..01.0..1.01..." },
    { name: "input handshake",     wave: "0...10...1......" },
    { name: "output_stream_valid", wave: "0....1....01...." },
    { name: "output_stream_ready", wave: "1.0..1.0...1...." },
    { name: "output handshake",    wave: "0....1.....1...." }
  ]
}
```
