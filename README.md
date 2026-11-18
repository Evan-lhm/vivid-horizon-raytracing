# Vivid Horizon Raytracing

A ray-traced shader pack for [Horizon](https://github.com/horizon-rust/horizon) (shader API 0.2, WGSL), in a vibrant style: ray-traced indirect light, soft sun shadows, light shafts, physical water, a painted sky with a Milky Way, soft-edged cubic clouds, glare and bloom. Each departure from physics is named in the source comments. **Beta (0.9.0).**

The non-ray-traced vibrant pack is [Vivid Horizon](https://github.com/Evan-lhm/vivid-horizon).

## Install

Get it from the Horizon launcher (Mods, then Horizon), or put the `vivid_horizon_raytracing` folder in the game's `shaderpacks` folder and pick **Vivid Horizon Raytracing** in the shader menu. It needs ray tracing turned on (opt-in), a float HDR frame, and a GPU with hardware ray queries.

## Check and pack

```sh
horizon-shader check vivid_horizon_raytracing
horizon-shader pack vivid_horizon_raytracing --out vivid_horizon_raytracing-0.9.0.hshader
```

## Known issues

Some flicker in caves and on block edges; caustics stop on sharp block edges; the cubic clouds use rather small cubes; particles and lamps do not get the pack's full lighting yet.

Written with the help of an AI agent (Claude Code), reviewed and tested by the author. MIT licence: see `LICENSE` and `CREDITS.md`.
