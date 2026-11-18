# Vivid Horizon Vibrant

A shader pack for [Horizon](https://github.com/horizon-rust/horizon) (shader API 0.2, WGSL): ray-traced indirect light, soft sun shadows, light shafts, physical water, a painted sky with a Milky Way, soft-edged cubic clouds, glare and bloom. Each departure from physics is named in the source comments.

## Install

Put the `vivid_horizon_vibrant` folder (or the `.hshader` file from the registry) in the game's `shaderpacks` folder, then pick **Vivid Horizon Vibrant** in the shader menu. The pack needs ray tracing turned on (opt-in) and a float HDR frame, on a GPU with hardware ray queries.

## Check and pack

```sh
horizon-shader check vivid_horizon_vibrant
horizon-shader pack vivid_horizon_vibrant --out vivid_horizon_vibrant-1.0.0.hshader
```

## Status

First release in preparation. Known issues are listed on the registry page. Written with the help of an AI agent (Claude Code), reviewed and tested by the author.

MIT licence. See `LICENSE` and `CREDITS.md`.
